import {
  and,
  asc,
  count,
  desc,
  eq,
  getTableColumns,
  gt,
  gte,
  inArray,
  isNull,
  lt,
  lte,
  max,
  ne,
  or,
  sql,
} from 'drizzle-orm';
import type {
  Agent,
  Conversation,
  EventType,
  ExecutionEvent,
  Message,
  MessageRole,
  ToolCall,
} from '@schermes/shared';
import { AGENT_NAME, findAgent, listAgents } from './agents.ts';
import type { Db } from './db.ts';
import { imageEpoch, resolveImage, storeImage } from './images.ts';
import type { Echo, Image, ToolDef } from './provider.ts';
import {
  agents,
  approvals,
  conversationParticipants,
  conversations,
  events,
  forms,
  messages,
  summaries,
  turnQueue,
} from './schema.ts';

const MAX_MESSAGE_CHARS = 8_192;

/**
 * How many messages agents may pass between themselves before one of them has to answer the
 * owner. Two agents that keep writing to each other would otherwise never stop, and nothing in
 * a turn is expensive enough to notice the runaway on its own.
 *
 * ponytail: two agents hit this ceiling permanently until the owner posts to either of them. A
 * decay rule can wait until anyone wants one.
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
  kind?: MessageKind;
  echo?: Echo;
};

/** A row as the loop replays it: with what the endpoint wants back, which no client is sent. */
export type StoredMessage = Message & { echo?: Echo };

export type MessageKind = 'request' | 'reply';

function participantRows(db: Db): { conversationId: number; agentId: number }[] {
  return db.select().from(conversationParticipants).all();
}

/** `conversationFor` without the create, for a reader that must not make threads appear. */
export function existingConversation(db: Db, agentId: number): number | undefined {
  return db
    .select({ id: conversationParticipants.conversationId })
    .from(conversationParticipants)
    .where(eq(conversationParticipants.agentId, agentId))
    .get()?.id;
}

/** The agent's thread with the owner, find-or-create: the one thread it has. */
export function conversationFor(db: Db, agentId: number): number {
  const found = existingConversation(db, agentId);
  if (found !== undefined) return found;
  const created = db.insert(conversations).values({ createdAt: Date.now() }).returning().get();
  db.insert(conversationParticipants).values({ conversationId: created.id, agentId }).run();
  return created.id;
}

/**
 * A thread and everything written in it. The agent stays; find-or-create brings its thread
 * back empty the next time anyone writes to it, which is what makes this "clear this thread".
 */
export function deleteConversation(db: Db, conversationId: number): void {
  db.delete(approvals).where(eq(approvals.conversationId, conversationId)).run();
  db.delete(forms).where(eq(forms.conversationId, conversationId)).run();
  db.delete(messages).where(eq(messages.conversationId, conversationId)).run();
  db.delete(summaries).where(eq(summaries.conversationId, conversationId)).run();
  db.delete(turnQueue).where(eq(turnQueue.conversationId, conversationId)).run();
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
export function rewoundRows(stored: readonly Message[], fromId: number): Message[] {
  const asked = new Set(
    stored.filter((m) => m.id < fromId).flatMap((m) => (m.toolCalls ?? []).map((call) => call.id)),
  );
  return stored.filter((m) => m.id >= fromId && !(m.role === 'tool' && asked.has(m.toolCallId ?? '')));
}

export function rewindConversation(db: Db, conversationId: number, fromId: number): void {
  const gone = rewoundRows(listMessages(db, conversationId), fromId);
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

function toMessage(db: Db, row: typeof messages.$inferSelect): Message {
  const toolCalls = parse<ToolCall[]>(row.toolCalls);
  const image = resolveImage(db, row.image, row.imageRef);
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

function toStored(db: Db, row: typeof messages.$inferSelect): StoredMessage {
  const echo = parse<Echo>(row.echo);
  return echo === undefined ? toMessage(db, row) : { ...toMessage(db, row), echo };
}

/** Who the daemon's own lines are from: not the owner, so they answer nothing that waits on the owner. */
export const SYSTEM_SENDER = 'System';

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
      imageRef: message.image === undefined ? null : storeImage(db, message.image),
      kind: message.kind ?? null,
      echo: message.echo === undefined ? null : JSON.stringify(message.echo),
      createdAt: Date.now(),
    })
    .returning()
    .get();
  return toMessage(db, row);
}

export function findMessage(db: Db, id: number): Message | undefined {
  const row = db.select().from(messages).where(eq(messages.id, id)).get();
  return row === undefined ? undefined : toMessage(db, row);
}

export function listMessages(db: Db, conversationId: number, after = 0): StoredMessage[] {
  return db
    .select()
    .from(messages)
    .where(and(eq(messages.conversationId, conversationId), gt(messages.id, after)))
    .orderBy(asc(messages.id))
    .all()
    .map((row) => toStored(db, row));
}

/**
 * `listMessages` for a measurement polled with the agent list: an image keeps its presence and
 * whether it expired, which change the text a transcript carries, but not its bytes, which
 * nothing measured counts.
 */
export function listMessagesWithoutImages(db: Db, conversationId: number, after = 0): Message[] {
  return db
    .select({
      ...getTableColumns(messages),
      marker: sql<string | null>`CASE
        WHEN ${messages.image} IS NOT NULL THEN '{}'
        WHEN ${messages.imageRef} IS NULL THEN NULL
        WHEN json_extract(${messages.imageRef}, '$.expired') IS NOT NULL THEN '{"expired":true}'
        ELSE '{}' END`,
    })
    .from(messages)
    .where(and(eq(messages.conversationId, conversationId), gt(messages.id, after)))
    .orderBy(asc(messages.id))
    .all()
    .map(({ marker, ...row }) => {
      const message = toMessage(db, { ...row, image: null, imageRef: null });
      return marker === null ? message : { ...message, image: JSON.parse(marker) as Image };
    });
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
      .map((row) => toMessage(db, row));
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
    .map((row) => toMessage(db, row));
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

/**
 * Changes whenever what `sender`'s reading of a thread can project to changes: a row added or
 * removed (ids are AUTOINCREMENT, so a cleared thread never repeats one), a summary written or
 * dropped, any agent renamed, since other agents' names are part of the text, or a screenshot in
 * it expired. Rows are edited in place only by that rename, by an expiry (counted per thread by
 * `imageEpoch`), and by the move of a picture's bytes into a file, which leaves the transcript's
 * text as it was.
 */
export function threadFingerprint(db: Db, conversationId: number, sender: string): string {
  const rows = db
    .select({ newest: max(messages.id), total: count() })
    .from(messages)
    .where(eq(messages.conversationId, conversationId))
    .get();
  const summary = latestSummary(db, conversationId, sender)?.id ?? 0;
  const names = db.select({ id: agents.id, name: agents.name }).from(agents).orderBy(asc(agents.id)).all();
  return JSON.stringify([
    rows?.newest ?? 0,
    rows?.total ?? 0,
    summary,
    imageEpoch(db, conversationId),
    names.map((a) => `${a.id}:${a.name}`),
  ]);
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
 * looks here before it lets go of the agent. Only `user` rows count: another agent's answer
 * arrives as one, routed into this agent's thread.
 */
export function pendingConversation(
  db: Db,
  agent: Agent,
  since: number,
  coveredUpTo: (conversationId: number) => number = () => since,
): number | undefined {
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
        eq(messages.role, 'user'),
        notSentBy(agent.name),
      ),
    )
    .orderBy(asc(messages.id))
    .all()
    .find((row) => row.id > coveredUpTo(row.conversationId))?.conversationId;
}

/**
 * How many messages agents have passed between themselves in these threads since the owner last
 * posted in any of them: requests, the replies routed back, and workers' reports. `send_message`
 * hands it both agents' threads, because a request lands in one and its reply in the other.
 */
export function agentChain(db: Db, conversationIds: readonly number[]): number {
  const spoke =
    db
      .select({ id: max(messages.id) })
      .from(messages)
      .where(
        and(
          inArray(messages.conversationId, conversationIds),
          eq(messages.role, 'user'),
          isNull(messages.sender),
        ),
      )
      .get()?.id ?? 0;
  // Not listMessages: this runs per send_message, and parsing every stored screenshot blocks the loop.
  return db
    .select({ sender: messages.sender })
    .from(messages)
    .where(
      and(
        inArray(messages.conversationId, conversationIds),
        gt(messages.id, spoke),
        eq(messages.role, 'user'),
      ),
    )
    .all()
    // Only agents: a trigger firing or an idle note is not one agent answering another.
    .filter((message) => message.sender !== null && AGENT_NAME.test(message.sender)).length;
}

/** The mark lives on the agent, not in the asker's thread, so clearing or rewinding that thread
 * cannot make an old request look unanswered. */
export function owedRequests(
  db: Db,
  agentId: number,
  conversationId: number,
  through: number,
): { id: number; sender: string }[] {
  const answered = db.select({ id: agents.answeredThrough }).from(agents).where(eq(agents.id, agentId)).get()?.id ?? 0;
  return db
    .select({ id: messages.id, sender: messages.sender })
    .from(messages)
    .where(
      and(
        eq(messages.conversationId, conversationId),
        eq(messages.kind, 'request'),
        gt(messages.id, answered),
        lte(messages.id, through),
      ),
    )
    .orderBy(asc(messages.id))
    .all()
    .flatMap((row) => (row.sender === null ? [] : [{ id: row.id, sender: row.sender }]));
}

export function markAnswered(db: Db, agentId: number, through: number): void {
  db.update(agents).set({ answeredThrough: through }).where(eq(agents.id, agentId)).run();
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
      'Ask another agent on this machine to do or tell you something. The message lands in ' +
      'its thread with the owner and starts it working, even if it is already busy. Your turn ' +
      'keeps going after this; its final answer comes back to you as a message from it and ' +
      'wakes you. Never use this to answer a message from another agent, or to thank, confirm ' +
      'or acknowledge: your final answer to a request goes back to whoever sent it on its own.',
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

/** The agents still owing this one an answer: a request it sent sits past their answered mark. */
export function awaitedAgents(db: Db, sender: string): number[] {
  return [
    ...new Set(
      db
        .select({ agentId: agents.id })
        .from(messages)
        .innerJoin(
          conversationParticipants,
          eq(conversationParticipants.conversationId, messages.conversationId),
        )
        .innerJoin(agents, eq(agents.id, conversationParticipants.agentId))
        .where(and(eq(messages.kind, 'request'), eq(messages.sender, sender), gt(messages.id, agents.answeredThrough)))
        .all()
        .map((row) => row.agentId),
    ),
  ];
}
