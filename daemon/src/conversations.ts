import { and, asc, desc, eq, gt, gte, inArray, isNull, lt, max, ne, or, sql } from 'drizzle-orm';
import type {
  Agent,
  Conversation,
  EventType,
  ExecutionEvent,
  Message,
  MessageRole,
  SearchHit,
  ToolCall,
} from '@schermes/shared';
import { AGENT_NAME, findAgent, listAgents } from './agents.ts';
import type { Db } from './db.ts';
import type { Image, ToolDef } from './provider.ts';
import {
  approvals,
  conversationParticipants,
  conversations,
  events,
  messages,
  summaries,
} from './schema.ts';

const MAX_MESSAGE_CHARS = 8_192;

/**
 * How many messages agents may pass between themselves before one of them has to answer the
 * owner. Two agents that keep writing to each other would otherwise never stop, and nothing in
 * a turn is expensive enough to notice the runaway on its own.
 *
 * ponytail: an agent-to-agent thread the owner never posts to hits this ceiling permanently.
 * Posting to that conversation clears it; a decay rule can wait until anyone wants one.
 */
export const MAX_AGENT_CHAIN = 6;

export type NewMessage = {
  role: MessageRole;
  content: string;
  /** The agent that wrote it. Omitted means the owner. */
  sender?: string;
  toolCalls?: readonly ToolCall[];
  toolCallId?: string;
  image?: Image;
};

function participantRows(db: Db): { conversationId: number; agentId: number }[] {
  return db.select().from(conversationParticipants).all();
}

/**
 * A conversation is its participant set: one agent is that agent's owner thread, two is the
 * thread those two share, more is a group. Find-or-create, so `send_message` and the group
 * route both land in the same row rather than growing a new thread per message.
 */
export function conversationWith(db: Db, agentIds: readonly number[]): number {
  const wanted = [...new Set(agentIds)].sort((a, b) => a - b);
  const grouped = new Map<number, number[]>();
  for (const row of participantRows(db)) {
    grouped.set(row.conversationId, [...(grouped.get(row.conversationId) ?? []), row.agentId]);
  }
  for (const [conversationId, members] of grouped) {
    const sorted = [...members].sort((a, b) => a - b);
    if (sorted.length === wanted.length && sorted.every((id, i) => id === wanted[i])) {
      return conversationId;
    }
  }

  const created = db.insert(conversations).values({ createdAt: Date.now() }).returning().get();
  for (const agentId of wanted) {
    db.insert(conversationParticipants).values({ conversationId: created.id, agentId }).run();
  }
  return created.id;
}

/** The thread an agent shares with nobody but the owner. */
export function conversationFor(db: Db, agentId: number): number {
  return conversationWith(db, [agentId]);
}

/**
 * A thread and everything written in it. The agents in it stay; only their seats here go.
 * Find-or-create means a deleted owner thread comes back empty the next time anyone writes to
 * that agent, which is what makes this "clear this thread" as well as "delete this group".
 */
export function deleteConversation(db: Db, conversationId: number): void {
  db.delete(approvals).where(eq(approvals.conversationId, conversationId)).run();
  db.delete(messages).where(eq(messages.conversationId, conversationId)).run();
  db.delete(summaries).where(eq(summaries.conversationId, conversationId)).run();
  db
    .delete(conversationParticipants)
    .where(eq(conversationParticipants.conversationId, conversationId))
    .run();
  db.delete(conversations).where(eq(conversations.id, conversationId)).run();
}

/**
 * Takes a thread back to just before `fromId`. A tool result answering a call from before the cut
 * stays: a message to a busy agent can land between a call and its answer, and a strict endpoint
 * rejects a call left unanswered. Summaries reaching past the cut would replay rows that are gone.
 */
export function rewindConversation(db: Db, conversationId: number, fromId: number): void {
  const stored = listMessages(db, conversationId);
  const asked = new Set(
    stored.filter((m) => m.id < fromId).flatMap((m) => (m.toolCalls ?? []).map((call) => call.id)),
  );
  const gone = stored.filter(
    (m) => m.id >= fromId && !(m.role === 'tool' && asked.has(m.toolCallId ?? '')),
  );
  if (gone.length === 0) return;
  db.delete(messages).where(inArray(messages.id, gone.map((m) => m.id))).run();
  db.delete(summaries)
    .where(and(eq(summaries.conversationId, conversationId), gte(summaries.throughMessageId, fromId)))
    .run();
}

export function participantAgents(db: Db, conversationId: number): Agent[] {
  const members = new Set(
    participantRows(db)
      .filter((row) => row.conversationId === conversationId)
      .map((row) => row.agentId),
  );
  return listAgents(db).filter((agent) => members.has(agent.id));
}

export function findConversation(db: Db, conversationId: number): Conversation | undefined {
  const row = db.select().from(conversations).where(eq(conversations.id, conversationId)).get();
  if (row === undefined) return undefined;
  return {
    id: row.id,
    participants: participantAgents(db, row.id).map((agent) => agent.name),
    createdAt: row.createdAt,
  };
}

export function listConversations(db: Db, agentId: number): Conversation[] {
  const mine = participantRows(db)
    .filter((row) => row.agentId === agentId)
    .map((row) => row.conversationId)
    .sort((a, b) => a - b);
  return mine.flatMap((id) => {
    const conversation = findConversation(db, id);
    return conversation === undefined ? [] : [conversation];
  });
}

function parse<T>(raw: string | null): T | undefined {
  return raw === null ? undefined : (JSON.parse(raw) as T);
}

function toMessage(row: typeof messages.$inferSelect): Message {
  const toolCalls = parse<ToolCall[]>(row.toolCalls);
  const image = parse<Image>(row.image);
  return {
    id: row.id,
    role: row.role as MessageRole,
    content: row.content,
    ...(row.sender === null ? {} : { sender: row.sender }),
    ...(toolCalls === undefined ? {} : { toolCalls }),
    ...(row.toolCallId === null ? {} : { toolCallId: row.toolCallId }),
    ...(image === undefined ? {} : { image }),
    createdAt: row.createdAt,
  };
}

export function appendMessage(db: Db, conversationId: number, message: NewMessage): Message {
  const row = db
    .insert(messages)
    .values({
      conversationId,
      role: message.role,
      content: message.content,
      sender: message.sender ?? null,
      toolCalls: message.toolCalls === undefined ? null : JSON.stringify(message.toolCalls),
      toolCallId: message.toolCallId ?? null,
      image: message.image === undefined ? null : JSON.stringify(message.image),
      createdAt: Date.now(),
    })
    .returning()
    .get();
  return toMessage(row);
}

export function listMessages(db: Db, conversationId: number, after = 0): Message[] {
  return db
    .select()
    .from(messages)
    .where(and(eq(messages.conversationId, conversationId), gt(messages.id, after)))
    .orderBy(asc(messages.id))
    .all()
    .map(toMessage);
}

/** A window onto a thread: the newest `limit` messages, the ones just before `before`, or the
 * ones just after `after`. Ordered oldest first, like `listMessages`, so a reader can
 * concatenate pages as it walks back. `before` and `after` are alternatives, never both. */
export type MessagePage = { limit: number; before?: number; after?: number };

/**
 * What a reader gets. Deliberately not `listMessages` with a default: every caller inside the
 * daemon — the turn's high-water mark, the transcript, `repairInterruptedCalls`, `agentChain` —
 * is wrong on a truncated history, and a page boundary between an assistant message and the
 * tool results answering it is exactly the shape a strict endpoint rejects.
 *
 * A page is a window on the rows, not on the turns, so a boundary can land inside one and hand
 * a reader a tool result whose assistant message is on the page before it. Nothing here becomes
 * a model request, so that is a rendering problem: a reader that wants the other half asks for
 * the previous page, which it is walking back through anyway.
 */
export function pageMessages(db: Db, conversationId: number, page: MessagePage): Message[] {
  const mine = eq(messages.conversationId, conversationId);
  // Ascending from the mark rather than descending from the end: a reader watching a live
  // thread wants the rows it has not seen, and the newest `limit` above the mark would punch a
  // hole in its history the moment a turn writes more than one page between two polls.
  if (page.after !== undefined) {
    return db
      .select()
      .from(messages)
      .where(and(mine, gt(messages.id, page.after)))
      .orderBy(asc(messages.id))
      .limit(page.limit)
      .all()
      .map(toMessage);
  }
  const scope = page.before === undefined ? mine : and(mine, lt(messages.id, page.before));
  return db
    .select()
    .from(messages)
    .where(scope)
    .orderBy(desc(messages.id))
    .limit(page.limit)
    .all()
    .toReversed()
    .map(toMessage);
}

export type Summary = {
  id: number;
  content: string;
  fromMessageId: number;
  throughMessageId: number;
};

export type NewSummary = Omit<Summary, 'id'> & { conversationId: number; sender: string };

/** A shorter reading of a stretch of a thread, for one agent. Never an edit: the messages it
 * covers stay exactly as they were, and `listMessages` keeps returning all of them. */
export function appendSummary(db: Db, summary: NewSummary): void {
  db.insert(summaries)
    .values({
      conversationId: summary.conversationId,
      sender: summary.sender,
      content: summary.content,
      fromMessageId: summary.fromMessageId,
      throughMessageId: summary.throughMessageId,
      createdAt: Date.now(),
    })
    .run();
}

/** The newest summary written for this agent in this thread, which is the only one replayed:
 * each one covers everything the one before it did, plus what has happened since. */
export function latestSummary(
  db: Db,
  conversationId: number,
  sender: string,
): Summary | undefined {
  return db
    .select()
    .from(summaries)
    .where(and(eq(summaries.conversationId, conversationId), eq(summaries.sender, sender)))
    .orderBy(desc(summaries.id))
    .limit(1)
    .get();
}

/** The high-water mark a turn measures arrivals against. Message ids are one global sequence,
 * so one number covers every conversation an agent is in. */
export function lastMessageId(db: Db): number {
  return db.select({ value: max(messages.id) }).from(messages).get()?.value ?? 0;
}

/** The newest thing this agent wrote anywhere. Everything after it is something it never saw. */
export function lastMessageBy(db: Db, sender: string): number {
  return (
    db.select({ value: max(messages.id) }).from(messages).where(eq(messages.sender, sender)).get()
      ?.value ?? 0
  );
}

function notSentBy(name: string) {
  return or(isNull(messages.sender), ne(messages.sender, name));
}

/**
 * The conversation holding the oldest message addressed to this agent that no turn has covered:
 * newer than `since`, and newer than what `coveredUpTo` reports for its own thread. This is
 * what replaces the 409: a message for a busy agent is a row, and the turn that is running
 * looks here before it lets go of the agent. Normally only `user` rows count, because an
 * agent's answer is an `assistant` row and is addressed to nobody — but an agent that spent its
 * turn writing to another one is waiting for exactly that answer, and would otherwise miss a
 * reply that landed before it let go.
 */
export function pendingConversation(
  db: Db,
  agent: Agent,
  since: number,
  coveredUpTo: (conversationId: number) => number = () => since,
): number | undefined {
  const state = findAgent(db, agent.name)?.state ?? agent.state;
  const wakes = state === 'waiting_for_agent' ? ['user', 'assistant'] : ['user'];
  return db
    .select({ conversationId: messages.conversationId, id: messages.id })
    .from(messages)
    .innerJoin(
      conversationParticipants,
      eq(conversationParticipants.conversationId, messages.conversationId),
    )
    .where(
      and(
        eq(conversationParticipants.agentId, agent.id),
        gt(messages.id, since),
        inArray(messages.role, wakes),
        notSentBy(agent.name),
      ),
    )
    .orderBy(asc(messages.id))
    .all()
    .find((row) => row.id > coveredUpTo(row.conversationId))?.conversationId;
}

/**
 * How many messages agents have passed between themselves since the owner last spoke here. In a
 * shared thread an agent's reply is one of them: every other agent is shown it as a message and
 * answers it, which is how two agents kept reacting to each other under a cap that counted only
 * `send_message`.
 */
export function agentChain(db: Db, conversationId: number): number {
  // Not listMessages: this runs per send_message, and parsing every stored screenshot blocks the loop.
  const stored = db
    .select({ role: messages.role, sender: messages.sender, toolCalls: messages.toolCalls })
    .from(messages)
    .where(eq(messages.conversationId, conversationId))
    .orderBy(asc(messages.id))
    .all();
  const spoke = stored.findLastIndex((message) => message.role === 'user' && message.sender === null);
  const shared = participantAgents(db, conversationId).length > 1;
  return stored
    .slice(spoke + 1)
    .filter(
      (message) =>
        message.sender !== null &&
        (message.role === 'user' ||
          (shared && message.role === 'assistant' && message.toolCalls === null)),
    ).length;
}

export function parseSendMessage(
  body: Record<string, unknown>,
): { to: string; text: string } | { error: string } {
  const to = body['to'];
  if (typeof to !== 'string' || !AGENT_NAME.test(to)) {
    return { error: `to must be an agent name matching ${AGENT_NAME.source}` };
  }
  const text = body['text'];
  if (typeof text !== 'string' || text.trim() === '') {
    return { error: 'text must be a non-empty string' };
  }
  if (text.length > MAX_MESSAGE_CHARS) {
    return { error: `text must be at most ${MAX_MESSAGE_CHARS} characters` };
  }
  return { to, text };
}

/** Built from the constants `parseSendMessage` enforces, so the two cannot disagree. */
export function sendMessageToolDef(): ToolDef {
  return {
    name: 'send_message',
    description:
      'Write to another agent on this machine. The message arrives in the thread you two ' +
      'share and starts that agent working, even if it is already busy. Your turn keeps going ' +
      'after this; the reply arrives later and wakes you. Only for asking another agent to do ' +
      'or tell you something. Never to thank, confirm, acknowledge or report back: the owner ' +
      'and everyone in the thread already read your reply.',
    parameters: {
      type: 'object',
      properties: {
        to: { type: 'string', pattern: AGENT_NAME.source, description: 'the agent to write to' },
        text: { type: 'string', maxLength: MAX_MESSAGE_CHARS },
      },
      required: ['to', 'text'],
      additionalProperties: false,
    },
  };
}

const RESTART_OBSERVATION =
  'error: the daemon restarted before this tool call finished. It may not have run at all, and ' +
  'nothing of what it did was kept. Check the current state before trying it again.';

/**
 * An assistant message whose tool calls no `tool` message answers is not merely a stuck-looking
 * turn: a strict OpenAI-compatible endpoint rejects the whole request until every call id has a
 * result, so the conversation is unusable until each one gets one. Only the last assistant
 * message can be short an answer, because the loop writes each result before asking for more.
 * Scoped to one sender, because a shared conversation holds several agents' turns.
 * Returns the call ids it had to answer.
 */
export function repairInterruptedCalls(db: Db, conversationId: number, sender: string): string[] {
  const stored = listMessages(db, conversationId).filter((message) => message.sender === sender);
  const asked = stored.findLastIndex((message) => message.role === 'assistant');
  if (asked === -1) return [];

  const answered = new Set(stored.slice(asked + 1).map((message) => message.toolCallId));
  const unanswered = (stored[asked]?.toolCalls ?? []).filter((call) => !answered.has(call.id));
  for (const call of unanswered) {
    appendMessage(db, conversationId, {
      role: 'tool',
      content: RESTART_OBSERVATION,
      sender,
      toolCallId: call.id,
    });
  }
  return unanswered.map((call) => call.id);
}

/**
 * The durable record of what an agent did. Callers keep the payload small and free of both
 * secrets and model reasoning: an event says a screenshot was taken and how big it was, never
 * the pixels, and never why the model wanted one.
 */
export function recordEvent(
  db: Db,
  agentId: number,
  type: EventType,
  data: Record<string, unknown>,
): void {
  db.insert(events)
    .values({ agentId, type, data: JSON.stringify(data), createdAt: Date.now() })
    .run();
}

export const MAX_SEARCH_HITS = 50;
const SNIPPET_CHARS = 240;

/** A case-insensitive substring search over every thread, newest hits first. `LIKE` rather than
 * an index: a personal machine's threads are small enough, and a search is a human's request. */
export function searchMessages(db: Db, needle: string): SearchHit[] {
  const pattern = `%${needle.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
  const rows = db
    .select({
      id: messages.id,
      conversationId: messages.conversationId,
      role: messages.role,
      content: messages.content,
      sender: messages.sender,
      createdAt: messages.createdAt,
    })
    .from(messages)
    .where(sql`${messages.content} LIKE ${pattern} ESCAPE '\\'`)
    .orderBy(desc(messages.id))
    .limit(MAX_SEARCH_HITS)
    .all();
  const participants = new Map<number, string[]>();
  return rows.map((row) => {
    let names = participants.get(row.conversationId);
    if (names === undefined) {
      names = participantAgents(db, row.conversationId).map((agent) => agent.name);
      participants.set(row.conversationId, names);
    }
    return {
      conversationId: row.conversationId,
      participants: names,
      message: {
        id: row.id,
        role: row.role as MessageRole,
        content: snippet(row.content, needle),
        ...(row.sender === null ? {} : { sender: row.sender }),
        createdAt: row.createdAt,
      },
    };
  });
}

function snippet(content: string, needle: string): string {
  if (content.length <= SNIPPET_CHARS) return content;
  const at = Math.max(0, content.toLowerCase().indexOf(needle.toLowerCase()));
  const start = Math.max(0, at - SNIPPET_CHARS / 4);
  const piece = content.slice(start, start + SNIPPET_CHARS);
  return `${start > 0 ? '…' : ''}${piece}${start + SNIPPET_CHARS < content.length ? '…' : ''}`;
}

/** Oldest first. With a limit, the newest that many, still oldest first: a reader that shows
 * the tail of a log that grows for the life of the install asks for the tail, not the log. */
export function listEvents(db: Db, agentId: number, limit?: number): ExecutionEvent[] {
  const query = db.select().from(events).where(eq(events.agentId, agentId));
  const rows =
    limit === undefined
      ? query.orderBy(asc(events.id)).all()
      : query.orderBy(desc(events.id)).limit(limit).all().reverse();
  return rows.map((row) => ({
      id: row.id,
      type: row.type as EventType,
      data: JSON.parse(row.data) as Record<string, unknown>,
      createdAt: row.createdAt,
    }));
}
