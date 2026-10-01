import { and, desc, eq } from 'drizzle-orm';
import type { Agent, NeedsYouItem } from '@schermes/shared';
import { isWorker, listAgents } from './agents.ts';
import { describeApproval, listApprovals } from './approvals.ts';
import { BROWSER_HUNG } from './browser.ts';
import { parseHandsReason } from './control.ts';
import { findForm, formRequest } from './forms.ts';
import {
  lastMessageBy,
  listConversations,
  listMessagesWithoutImages,
} from './conversations.ts';
import { parseAskOwner } from './interview.ts';
import { RUN_FAILED } from './loop.ts';
import { listAuthFailures } from './models.ts';
import { alwaysAllowable } from './rules.ts';
import { goalNeeds } from './goals.ts';
import { loginRequests } from './triggers.ts';
import { messages } from './schema.ts';
import type { Db } from './db.ts';

/**
 * Everything waiting on the owner, derived on every read from the rows that already say so, so
 * nothing here has to be cleared: answering the approval drops its row, the owner's reply lands
 * after the question, and a new turn moves the agent out of `failed`.
 */
export function listNeedsYou(db: Db): NeedsYouItem[] {
  const approvals: NeedsYouItem[] = listApprovals(db).map((approval) => ({
    id: `approval:${approval.id}`,
    kind: 'approval',
    agent: approval.agent,
    conversationId: approval.conversationId,
    title: `Asks to ${describeApproval(approval)}`,
    detail: approval.reason,
    approval,
    createdAt: approval.createdAt,
    actions: alwaysAllowable(approval) === undefined ? ['approve', 'deny'] : ['approve', 'always', 'deny'],
  }));
  const owned = listAgents(db).filter((agent) => !isWorker(agent));
  const refused: NeedsYouItem[] = listAuthFailures(db).map((failure) => ({
    id: `provider-auth:${failure.modelId}`,
    kind: 'provider_auth',
    agent: failure.agent,
    conversationId: failure.conversationId,
    title: `${failure.modelName} refused its key`,
    detail: failure.error,
    createdAt: failure.at,
    actions: ['settings'],
  }));
  // One item for a refused key, not one failed turn per agent on it. Once the key is fixed the
  // failures show again, each with its retry.
  const failures = owned
    .flatMap((agent) => failure(db, agent))
    .filter((item) => refused.length === 0 || !AUTH_REFUSED.test(item.detail ?? ''));
  return [
    ...approvals,
    ...refused,
    ...owned.flatMap((agent) => {
      const threads = threadsOf(db, agent);
      return [
        ...waitingQuestions(agent, threads),
        ...hungBrowsers(db, agent, threads),
        ...handOvers(db, agent, threads),
        ...formRequests(db, agent, threads),
      ];
    }),
    ...owned.flatMap((agent) => loginRequests(db, agent)),
    ...goalNeeds(db),
    ...failures,
  ].sort((a, b) => a.createdAt - b.createdAt);
}

const AUTH_REFUSED = /HTTP 40[13]\b/;

/**
 * The item a turn's push is about, found the moment the turn hands it over: the asker's newest
 * approval, its failure (or the refused key standing in for it), or what its last reply in that
 * thread asked for. A plain reply is about nothing, even with an older item still open there.
 */
export function pushedItem(
  db: Db,
  agent: string,
  conversationId: number,
  kind: 'reply' | 'failure' | 'approval',
): NeedsYouItem | undefined {
  const items = listNeedsYou(db).filter((item) => item.agent === agent);
  if (kind === 'approval') {
    return items
      .filter((item) => item.approval !== undefined && item.conversationId === conversationId)
      .sort((a, b) => (a.approval?.id ?? 0) - (b.approval?.id ?? 0))
      .at(-1);
  }
  if (kind === 'failure') return items.find((item) => item.kind === 'failure' || item.kind === 'provider_auth');
  const said = db
    .select({ id: messages.id })
    .from(messages)
    .where(and(eq(messages.conversationId, conversationId), eq(messages.role, 'assistant'), eq(messages.sender, agent)))
    .orderBy(desc(messages.id))
    .limit(1)
    .get();
  if (said === undefined) return undefined;
  return items.find(
    (item) => item.conversationId === conversationId && item.messageId !== undefined && item.messageId >= said.id,
  );
}

export function threadsOf(db: Db, agent: Agent) {
  return listConversations(db, agent.id).map((conversation) => ({
    conversation,
    thread: listMessagesWithoutImages(db, conversation.id),
  }));
}

type Threads = ReturnType<typeof threadsOf>;

// ponytail: reads every thread of every agent once per call; keep an "asked" row if that shows up.
function waitingQuestions(agent: Agent, threads: Threads): NeedsYouItem[] {
  return threads.flatMap(({ conversation, thread }) => {
    // The chat's own rule (`pendingInterview`): the newest call of its own, unless the owner
    // wrote after it. Worker reports and other agents' rows carry a sender and answer nothing.
    const at = thread.findLastIndex(
      (m) =>
        (m.role === 'user' && m.sender === undefined) ||
        (m.role === 'assistant' && m.sender === agent.name && m.toolCalls?.some((c) => c.name === 'ask_owner')),
    );
    const asking = thread[at];
    const call = asking?.toolCalls?.find((c) => c.name === 'ask_owner');
    if (asking === undefined || call === undefined) return [];
    const result = thread.slice(at + 1).find((m) => m.toolCallId === call.id);
    if (result === undefined || result.content.startsWith('error:')) return [];
    const questions = parseAskOwner(JSON.parse(call.arguments) as Record<string, unknown>);
    if ('error' in questions) return [];
    const more = questions.length - 1;
    return [
      {
        id: `question:${asking.id}`,
        kind: 'question',
        agent: agent.name,
        conversationId: conversation.id,
        title: questions[0]?.question ?? 'Has a question',
        ...(more === 0 ? {} : { detail: `and ${more} more question${more === 1 ? '' : 's'}` }),
        messageId: asking.id,
        createdAt: asking.createdAt,
        actions: ['answer'],
      },
    ];
  });
}

/**
 * The agent's newest call of `tool` in a thread, by the question rule: answered without an
 * error, and no owner row after it. The owner's reply, or the line a route writes for them, is
 * what clears it.
 */
function pendingCall(agent: Agent, thread: Threads[number]['thread'], tool: string) {
  const at = thread.findLastIndex(
    (m) =>
      (m.role === 'user' && m.sender === undefined) ||
      (m.role === 'assistant' && m.sender === agent.name && m.toolCalls?.some((c) => c.name === tool)),
  );
  const asking = thread[at];
  const call = asking?.toolCalls?.find((c) => c.name === tool);
  if (asking === undefined || call === undefined) return undefined;
  const result = thread.slice(at + 1).find((m) => m.toolCallId === call.id);
  if (result === undefined || result.content.startsWith('error:')) return undefined;
  return { asking, call };
}

/** Pending `ask_for_hands` calls. Giving the screen back writes the owner row. The chat card finds
 * them the same way (`pendingHandOver`). */
export function handOvers(db: Db, agent: Agent, threads = threadsOf(db, agent)): NeedsYouItem[] {
  return threads.flatMap(({ conversation, thread }) => {
    const pending = pendingCall(agent, thread, 'ask_for_hands');
    if (pending === undefined) return [];
    const reason = parseHandsReason(JSON.parse(pending.call.arguments) as Record<string, unknown>);
    if (typeof reason !== 'string') return [];
    return [
      {
        id: `hands:${pending.asking.id}`,
        kind: 'hand_over',
        agent: agent.name,
        conversationId: conversation.id,
        title: 'Asks you to take the screen',
        detail: reason,
        messageId: pending.asking.id,
        createdAt: pending.asking.createdAt,
        actions: ['open', 'take_screen'],
      },
    ];
  });
}

/** Pending `request_form` calls with the form the daemon read for them. The fill route's owner
 * line, or giving back the screen, clears one. */
export function formRequests(db: Db, agent: Agent, threads = threadsOf(db, agent)): NeedsYouItem[] {
  return threads.flatMap(({ conversation, thread }) => {
    const pending = pendingCall(agent, thread, 'request_form');
    const stored = pending === undefined ? undefined : findForm(db, conversation.id, pending.call.id);
    if (pending === undefined || stored === undefined) return [];
    const form = formRequest(db, stored);
    return [
      {
        id: `form:${form.id}`,
        kind: 'form',
        agent: agent.name,
        conversationId: conversation.id,
        title: `Asks you to fill a form on ${form.origin}`,
        detail: form.reason,
        messageId: pending.asking.id,
        form,
        createdAt: pending.asking.createdAt,
        actions: form.fields.length === 0 ? ['open', 'take_screen'] : ['fill', 'take_screen'],
      },
    ];
  });
}

/**
 * A browser that did not come back after the watchdog restarted it, per thread: the tool row
 * that said so, unless the owner wrote after it (the restart routes write that line). The chat
 * card finds it by the same rule.
 */
export function hungBrowsers(db: Db, agent: Agent, threads = threadsOf(db, agent)): NeedsYouItem[] {
  return threads.flatMap(({ conversation, thread }) => {
    const at = thread.findLastIndex(
      (m) =>
        (m.role === 'user' && m.sender === undefined) ||
        (m.role === 'tool' && m.sender === agent.name && m.content.startsWith(`error: ${BROWSER_HUNG}`)),
    );
    const row = thread[at];
    if (row === undefined || row.role !== 'tool') return [];
    return [
      {
        id: `browser:${row.id}`,
        kind: 'browser_hung',
        agent: agent.name,
        conversationId: conversation.id,
        title: 'Its browser stopped answering',
        detail: 'It was restarted once on its own and still does not answer.',
        messageId: row.id,
        createdAt: row.createdAt,
        actions: ['screen', 'restart_desktop', 'restart_browser'],
      },
    ];
  });
}

/** A failed turn ends with the agent's own failure line, so its newest message is that line. */
function failure(db: Db, agent: Agent): NeedsYouItem[] {
  if (agent.state !== 'failed') return [];
  const row = db.select().from(messages).where(eq(messages.id, lastMessageBy(db, agent.name))).get();
  if (row === undefined) return [];
  const detail = row.content.startsWith(`${RUN_FAILED}: `)
    ? row.content.slice(RUN_FAILED.length + 2)
    : undefined;
  return [
    {
      id: `failure:${row.id}`,
      kind: 'failure',
      agent: agent.name,
      conversationId: row.conversationId,
      title: 'Could not finish its turn',
      ...(detail === undefined ? {} : { detail }),
      messageId: row.id,
      createdAt: row.createdAt,
      actions: ['retry', 'open'],
    },
  ];
}
