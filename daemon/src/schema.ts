import { index, integer, primaryKey, sqliteTable, text } from 'drizzle-orm/sqlite-core';

/** Single-row table: schermes has one owner, not a user list. */
export const owner = sqliteTable('owner', {
  id: integer('id').primaryKey(),
  passwordHash: text('password_hash').notNull(),
  createdAt: integer('created_at').notNull(),
});

export const sessions = sqliteTable('sessions', {
  id: text('id').primaryKey(),
  createdAt: integer('created_at').notNull(),
  expiresAt: integer('expires_at').notNull(),
});

export const settings = sqliteTable('settings', {
  key: text('key').primaryKey(),
  value: text('value').notNull(),
  encrypted: integer('encrypted', { mode: 'boolean' }).notNull().default(false),
});

export const agents = sqliteTable('agents', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  name: text('name').notNull().unique(),
  // What the owner calls this agent, free text. Cosmetic: `name` stays the system identity, so
  // nothing addresses, routes or runs as a label.
  label: text('label'),
  // How a client draws it, an opaque token the daemon stores so every device shows the same
  // avatar. The client owns the format.
  look: text('look'),
  // Who this agent is, in Markdown: what it is for, how it works, what it stays out of. Written
  // by the agent itself after interviewing the owner, or by the owner; in its system prompt.
  profile: text('profile'),
  display: integer('display').notNull().unique(),
  // Durable agent state: the loop is a process, this column is the truth.
  state: text('state').notNull().default('idle'),
  // Set on a task worker, null on a permanent agent: who spawned it, and the thread it owes a
  // result to. A worker is an agent row so the loop, the event log and the conversations work
  // on it unchanged; what it is not is a Linux user with a desktop.
  parentId: integer('parent_id'),
  parentConversationId: integer('parent_conversation_id'),
  createdAt: integer('created_at').notNull(),
});

/** A thread. Who is in it lives in `conversation_participants`, not here: one agent is that
 * agent's owner thread, two or more is a group. The owner is in every one implicitly. */
export const conversations = sqliteTable('conversations', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  createdAt: integer('created_at').notNull(),
});

export const conversationParticipants = sqliteTable(
  'conversation_participants',
  {
    conversationId: integer('conversation_id')
      .notNull()
      .references(() => conversations.id),
    agentId: integer('agent_id')
      .notNull()
      .references(() => agents.id),
  },
  (table) => [primaryKey({ columns: [table.conversationId, table.agentId] })],
);

export const messages = sqliteTable(
  'messages',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    conversationId: integer('conversation_id')
      .notNull()
      .references(() => conversations.id),
    role: text('role').notNull(),
    content: text('content').notNull(),
    // The agent that wrote it. Null is the owner, who has no agent row.
    sender: text('sender'),
    // JSON, written only on assistant rows that asked for tools.
    toolCalls: text('tool_calls'),
    toolCallId: text('tool_call_id'),
    // JSON: the base64 PNG a screenshot observation carries.
    image: text('image'),
    createdAt: integer('created_at').notNull(),
  },
  (table) => [index('messages_conversation_id_idx').on(table.conversationId)],
);

/**
 * What a compacted stretch of a thread is replayed as. A summary stands in for the messages
 * between `from_message_id` and `through_message_id`, which stay in `messages` untouched: this
 * table is a second, shorter reading of the same rows, never a rewrite of them.
 *
 * `sender` is the agent the summary was written for. Each agent in a group thread sees its own
 * projection — its own tool traffic, nobody else's — so one shared summary would replay another
 * agent's work as this one's.
 */
export const summaries = sqliteTable(
  'summaries',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    conversationId: integer('conversation_id')
      .notNull()
      .references(() => conversations.id),
    sender: text('sender').notNull(),
    content: text('content').notNull(),
    fromMessageId: integer('from_message_id').notNull(),
    throughMessageId: integer('through_message_id').notNull(),
    createdAt: integer('created_at').notNull(),
  },
  (table) => [index('summaries_conversation_id_sender_idx').on(table.conversationId, table.sender)],
);

/**
 * A standing job for one agent. `next_run_at` is the whole clock: the tick fires every row that
 * is due and then advances the column from *now*, never from the slot it missed, so a daemon
 * that was down over a weekend wakes its agents once rather than once per missed slot.
 */
export const schedules = sqliteTable('schedules', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  agentId: integer('agent_id')
    .notNull()
    .references(() => agents.id),
  cron: text('cron').notNull(),
  prompt: text('prompt').notNull(),
  paused: integer('paused', { mode: 'boolean' }).notNull().default(false),
  nextRunAt: integer('next_run_at').notNull(),
  lastRunAt: integer('last_run_at'),
  createdAt: integer('created_at').notNull(),
});

export const events = sqliteTable(
  'events',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    agentId: integer('agent_id')
      .notNull()
      .references(() => agents.id),
    type: text('type').notNull(),
    data: text('data').notNull(),
    createdAt: integer('created_at').notNull(),
  },
  (table) => [index('events_agent_id_idx').on(table.agentId)],
);

/**
 * A destructive change an agent has asked the owner for. Only pending requests live here: a
 * decision performs the change (or does not) and drops the row, because the event log is where
 * what happened is kept and this table is only the queue in front of it.
 */
export const approvals = sqliteTable('approvals', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  agentId: integer('agent_id')
    .notNull()
    .references(() => agents.id),
  conversationId: integer('conversation_id')
    .notNull()
    .references(() => conversations.id),
  // 'agent' or 'conversation'.
  kind: text('kind').notNull(),
  // An agent's name, or a conversation id written out.
  target: text('target').notNull(),
  reason: text('reason').notNull(),
  createdAt: integer('created_at').notNull(),
});

/** A device the app registered for push, by its APNs token. One row per token, whichever
 * platform: a token that stops working is dropped when Apple says so. */
export const devices = sqliteTable('devices', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  token: text('token').notNull().unique(),
  // 'ios' or 'macos'.
  platform: text('platform').notNull(),
  createdAt: integer('created_at').notNull(),
});
