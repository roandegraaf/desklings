import { index, integer, primaryKey, sqliteTable, text, uniqueIndex } from 'drizzle-orm/sqlite-core';

/** Single-row table: schermes has one owner, not a user list. */
export const owner = sqliteTable('owner', {
  id: integer('id').primaryKey(),
  passwordHash: text('password_hash').notNull(),
  createdAt: integer('created_at').notNull(),
  /** Encrypted with the master key, like every other secret. */
  totpSecret: text('totp_secret'),
  /** An enrolment not yet confirmed with a code; never used to log in. */
  totpPending: text('totp_pending'),
  /** The newest 30 s step a code was accepted for, so no step is accepted twice. */
  totpLastStep: integer('totp_last_step'),
});

/** SHA-256 of each unspent recovery code. A spent one is deleted. */
export const recoveryCodes = sqliteTable('recovery_codes', {
  hash: text('hash').primaryKey(),
  createdAt: integer('created_at').notNull(),
});

export const auditEvents = sqliteTable(
  'audit_events',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    at: integer('at').notNull(),
    action: text('action').notNull(),
    ip: text('ip'),
    userAgent: text('user_agent'),
    /** Small JSON: names and handles, never a value the owner typed. */
    detail: text('detail'),
  },
  (table) => [index('audit_events_at').on(table.at)],
);

export const sessions = sqliteTable('sessions', {
  id: text('id').primaryKey(),
  createdAt: integer('created_at').notNull(),
  expiresAt: integer('expires_at').notNull(),
  lastSeenAt: integer('last_seen_at'),
  userAgent: text('user_agent'),
});

export const settings = sqliteTable('settings', {
  key: text('key').primaryKey(),
  value: text('value').notNull(),
  encrypted: integer('encrypted', { mode: 'boolean' }).notNull().default(false),
});

/** An endpoint and the key it takes, shared by every model served from it. */
export const providers = sqliteTable('providers', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  name: text('name').notNull(),
  baseUrl: text('base_url').notNull(),
  // Encrypted with the master key, like every other secret in `settings`.
  apiKey: text('api_key'),
  createdAt: integer('created_at').notNull(),
});

/** The owner's models. Which one is the default and which the backup are two settings keys,
 * `models.default` and `models.backup`, holding an id. */
export const models = sqliteTable('models', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  name: text('name').notNull(),
  providerId: integer('provider_id').references(() => providers.id),
  // From before providers: moved into one by `migrateModelProviders` at boot and blank after.
  // Kept until a later migration drops them, so that move runs after the SQL migrations.
  legacyBaseUrl: text('base_url').notNull(),
  legacyApiKey: text('api_key'),
  model: text('model').notNull(),
  // A JSON object merged under every request body, or empty.
  extraBody: text('extra_body').notNull().default(''),
  // In tokens; null is unknown, and compaction then falls back to its fixed character budget.
  contextWindow: integer('context_window'),
  vision: integer('vision', { mode: 'boolean' }).notNull().default(true),
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
  answeredThrough: integer('answered_through').notNull().default(0),
  // The newest message id a turn of this agent has started from. What lies past it, and past
  // the agent's own last word, is input nobody has read yet.
  readThrough: integer('read_through').notNull().default(0),
  createdAt: integer('created_at').notNull(),
});

/** Turns waiting for a free loop. Keyed by the agent's id, so a rename cannot strand one. */
export const turnQueue = sqliteTable(
  'turn_queue',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    agentId: integer('agent_id')
      .notNull()
      .references(() => agents.id),
    conversationId: integer('conversation_id')
      .notNull()
      .references(() => conversations.id),
    kind: text('kind').notNull(),
    createdAt: integer('created_at').notNull(),
  },
  (table) => [uniqueIndex('turn_queue_agent_conversation_idx').on(table.agentId, table.conversationId)],
);

/** A thread: one agent and the owner. The agent lives in `conversation_participants`. */
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
    // Legacy JSON `{mediaType, base64}`, from before images moved to files. Nulled by the boot move.
    image: text('image'),
    // JSON `{mediaType, sha256}` naming a file under the data volume's `images/`, or
    // `{mediaType, expired: true}` once pruned. At most one of `image` and `image_ref` is set.
    imageRef: text('image_ref'),
    kind: text('kind'),
    // JSON: what the endpoint wants back verbatim on a replayed assistant row, never sent to clients.
    echo: text('echo'),
    createdAt: integer('created_at').notNull(),
  },
  (table) => [index('messages_conversation_id_idx').on(table.conversationId), index('messages_sender_idx').on(table.sender)],
);

/**
 * What a compacted stretch of a thread is replayed as. A summary stands in for the messages
 * between `from_message_id` and `through_message_id`, which stay in `messages` untouched: this
 * table is a second, shorter reading of the same rows, never a rewrite of them.
 *
 * `sender` is the agent the summary was written for.
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
  callId: text('call_id'),
  // An ApprovalOutcome; null while it waits for the owner.
  outcome: text('outcome'),
  decidedAt: integer('decided_at'),
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

/** Secret values the owner typed into a form for an agent, newest last, kept so they stay hidden
 * from its tool results across a restart. A JSON array encrypted with the master key; never read
 * back by a route or used to fill anything. */
export const hiddenValues = sqliteTable('hidden_values', {
  agentId: integer('agent_id')
    .primaryKey()
    .references(() => agents.id),
  values: text('values').notNull(),
  updatedAt: integer('updated_at').notNull(),
});

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

/** The newest message the owner has read per thread, shared so every device agrees on unread. */
export const readMarks = sqliteTable('read_marks', {
  thread: text('thread').primaryKey(),
  messageId: integer('message_id').notNull(),
});
