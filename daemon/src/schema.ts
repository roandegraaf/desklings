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

/** The owner's model endpoints. Which one is the default and which the backup are two settings
 * keys, `models.default` and `models.backup`, holding an id. */
export const models = sqliteTable('models', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  name: text('name').notNull(),
  baseUrl: text('base_url').notNull(),
  model: text('model').notNull(),
  // Encrypted with the master key, like every other secret in `settings`.
  apiKey: text('api_key'),
  // A JSON object merged under every request body, or empty.
  extraBody: text('extra_body').notNull().default(''),
  createdAt: integer('created_at').notNull(),
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
  // JSON: the owner's rule levels and pre-approved list (`StoredRules`); null is every default.
  rules: text('rules'),
  // JSON: approved deletes and installs not yet used, each good for one matching command.
  grants: text('grants'),
  // JSON: the owner's idle work settings (`IdleSettings`); null is off with every default.
  idle: text('idle'),
  // Null is the default model; a worker always uses its parent's.
  modelId: integer('model_id').references(() => models.id),
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
  // 'agent', 'conversation' or 'action'.
  kind: text('kind').notNull(),
  // An ApprovalCategory; every deletion is 'delete_files'.
  category: text('category').notNull().default('delete_files'),
  // An agent's name, a conversation id written out, or what an action acts on.
  target: text('target').notNull(),
  amount: text('amount'),
  origin: text('origin'),
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

/** An iPhone's Live Activity tokens: `start` is the phone's push-to-start token, `update` one
 * running activity's, for the agent it shows. Dropped when Apple says the token is gone. */
export const liveActivityTokens = sqliteTable('live_activity_tokens', {
  token: text('token').primaryKey(),
  kind: text('kind').notNull(),
  agent: text('agent'),
  createdAt: integer('created_at').notNull(),
});

/** A `request_form` call's form, as the daemon read it from the page. Pending while the call is,
 * by the transcript rule every Needs you item uses; the row itself is never cleared. */
export const forms = sqliteTable('forms', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  agentId: integer('agent_id')
    .notNull()
    .references(() => agents.id),
  conversationId: integer('conversation_id')
    .notNull()
    .references(() => conversations.id),
  callId: text('call_id').notNull(),
  // From CDP, never from the model.
  origin: text('origin').notNull(),
  reason: text('reason').notNull(),
  // JSON: the fields (without `saved`, which is read from the vault) and the unfillable list.
  fields: text('fields').notNull(),
  unfillable: text('unfillable').notNull(),
  createdAt: integer('created_at').notNull(),
  // Set on a form the daemon writes itself for a trigger's login: no page, and filling it stores
  // the values on the trigger instead of typing them anywhere.
  triggerId: integer('trigger_id').references(() => triggers.id),
});

/** Values the owner asked to remember for a site, per agent. `keys` is plain so Needs you can say
 * which fields are saved without decrypting; `values` is a JSON map encrypted with the master key. */
export const formVault = sqliteTable(
  'form_vault',
  {
    agentId: integer('agent_id')
      .notNull()
      .references(() => agents.id),
    origin: text('origin').notNull(),
    keys: text('keys').notNull(),
    values: text('values').notNull(),
    updatedAt: integer('updated_at').notNull(),
  },
  (table) => [primaryKey({ columns: [table.agentId, table.origin] })],
);

/** The owner's thumbs on an agent's reply: one row per message, replaced on change. `created_at`
 * is the last change, so a pass that looks for new feedback finds a changed mind too. */
export const feedback = sqliteTable('feedback', {
  messageId: integer('message_id')
    .primaryKey()
    .references(() => messages.id, { onDelete: 'cascade' }),
  // 'up' or 'down'.
  rating: text('rating').notNull(),
  reason: text('reason'),
  createdAt: integer('created_at').notNull(),
});

/** One night's idle check for an agent: which pre-check conditions matched and what came of it.
 * The newest row's `started_at` is the `since` of the next check. */
export const idlePasses = sqliteTable(
  'idle_passes',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    agentId: integer('agent_id')
      .notNull()
      .references(() => agents.id, { onDelete: 'cascade' }),
    startedAt: integer('started_at').notNull(),
    // JSON: the IdleCondition list that matched, empty for a skip.
    matched: text('matched').notNull(),
    // An IdlePassOutcome.
    outcome: text('outcome').notNull(),
    tokens: integer('tokens').notNull().default(0),
    endedAt: integer('ended_at'),
    // Why a matched pass did not run.
    reason: text('reason'),
  },
  (table) => [index('idle_passes_agent_id_idx').on(table.agentId)],
);

/** A trigger an agent proposed. `cursor` is what the last check saw: a folder's check time, a
 * command's output hash; null until the first check sets the baseline. */
export const triggers = sqliteTable(
  'triggers',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    agentId: integer('agent_id')
      .notNull()
      .references(() => agents.id, { onDelete: 'cascade' }),
    // A TriggerKind; `config` is its TriggerConfig as JSON.
    kind: text('kind').notNull(),
    config: text('config').notNull(),
    reason: text('reason').notNull(),
    // A TriggerState.
    state: text('state').notNull().default('proposed'),
    // A webhook's URL token and its secret (encrypted with the master key), minted on first turn-on.
    token: text('token').unique(),
    secret: text('secret'),
    // imap: `{username, password}` as JSON, encrypted with the master key; null until the owner fills it.
    login: text('login'),
    maxPerHour: integer('max_per_hour').notNull(),
    windowStartedAt: integer('window_started_at'),
    firedInWindow: integer('fired_in_window').notNull().default(0),
    dropped: integer('dropped').notNull().default(0),
    cursor: text('cursor'),
    checkedAt: integer('checked_at'),
    lastFiredAt: integer('last_fired_at'),
    // Why the newest folder, command or mailbox check failed; cleared by the next good one.
    lastError: text('last_error'),
    createdAt: integer('created_at').notNull(),
  },
  (table) => [index('triggers_agent_id_idx').on(table.agentId)],
);

export const idleOutputs = sqliteTable(
  'idle_outputs',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    passId: integer('pass_id')
      .notNull()
      .references(() => idlePasses.id, { onDelete: 'cascade' }),
    // An IdleOutputKind; `body` is that kind's fields as JSON.
    kind: text('kind').notNull(),
    body: text('body').notNull(),
    createdAt: integer('created_at').notNull(),
    // An IdleOutputResolution, null while open.
    resolved: text('resolved'),
  },
  (table) => [index('idle_outputs_pass_id_idx').on(table.passId)],
);

/** A goal a lead agent keeps up through `update_goal`. `steps`, `results` and `next_from_you` are
 * JSON lists the lead replaces or appends to; `helpers_made` only grows, so helper names never repeat. */
export const goals = sqliteTable(
  'goals',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    leadId: integer('lead_id')
      .notNull()
      .references(() => agents.id, { onDelete: 'cascade' }),
    title: text('title').notNull(),
    // A GoalState.
    state: text('state').notNull().default('open'),
    steps: text('steps').notNull().default('[]'),
    results: text('results').notNull().default('[]'),
    nextFromYou: text('next_from_you').notNull().default('[]'),
    // When `next_from_you` last changed: the Needs you item's time.
    nextAt: integer('next_at'),
    helpersMade: integer('helpers_made').notNull().default(0),
    createdAt: integer('created_at').notNull(),
    updatedAt: integer('updated_at').notNull(),
    doneAt: integer('done_at'),
  },
  (table) => [index('goals_lead_id_idx').on(table.leadId)],
);

/** An agent row working for a goal. The row goes with the agent, and "Keep as agent" sets `kept_at`
 * so finishing the goal leaves that one alone. */
export const goalHelpers = sqliteTable('goal_helpers', {
  agentId: integer('agent_id')
    .primaryKey()
    .references(() => agents.id, { onDelete: 'cascade' }),
  goalId: integer('goal_id')
    .notNull()
    .references(() => goals.id, { onDelete: 'cascade' }),
  // A HelperKind.
  kind: text('kind').notNull(),
  reason: text('reason').notNull(),
  keptAt: integer('kept_at'),
  createdAt: integer('created_at').notNull(),
});
