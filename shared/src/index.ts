export type HealthResponse = {
  status: 'ok';
  setupRequired: boolean;
};

export type ProviderSettings = {
  baseUrl: string;
  model: string;
  apiKeySet: boolean;
  /** A JSON object merged under every model request, or empty. */
  extraBody: string;
};

export type ProviderSettingsUpdate = {
  baseUrl?: string;
  model?: string;
  apiKey?: string;
  extraBody?: string;
};

/** The web half of the same settings row set. The search key is reported as present or absent,
 * never echoed, exactly like the provider key. An empty `searchUrl` means the built-in default. */
export type WebSettings = {
  searchUrl: string;
  searchKeySet: boolean;
};

export type WebSettingsUpdate = {
  searchUrl?: string;
  searchKey?: string;
};

/** The push half of the settings. The `.p8` key is reported as present or absent like the other
 * keys. Pushes go straight to Apple from the daemon; nothing else is in between. */
export type PushSettings = {
  keyId: string;
  teamId: string;
  bundleId: string;
  keySet: boolean;
  sandbox: boolean;
};

export type PushSettingsUpdate = {
  pushKeyId?: string;
  pushTeamId?: string;
  pushBundleId?: string;
  /** The `.p8` PEM text. Empty clears it. */
  pushKey?: string;
  pushSandbox?: boolean;
};

/** A device the app registered for push, by its APNs token. */
export type Device = {
  token: string;
  platform: 'ios' | 'macos';
  createdAt: number;
};

export type PushTestResult = {
  ok: boolean;
  sent: number;
  error?: string;
};

/** The APNs `category` of a push about a Needs you item; the app registers the same ids with
 * their buttons. Each button's identifier is the `NeedsYouAction` it sends. */
export type PushCategory = 'needs.approval' | 'needs.delete' | 'needs.yours' | 'needs.watch' | 'needs.open';

/** `POST /api/needs-you/:id/action`: what a notification button answers, without the app open. */
export type NeedsYouActionRequest = { action: NeedsYouAction };

/** The Live Activity's fixed part, the app's `AgentActivityAttributes`. `look` is `Agent.look`;
 * without it the widget draws the agent's standard colour. The keys must match the Swift
 * property names exactly: ActivityKit decodes them with a default decoder and shows nothing
 * on a mismatch. */
export type LiveActivityAttributes = { agent: string; label: string; look?: string };

/** The Live Activity's changing part, the app's `AgentActivityAttributes.ContentState`. `title` is
 * the goal the agent leads or helps with, else the owner's last line to it; `state` an
 * `AgentState`. */
export type LiveActivityState = {
  title: string;
  stepsDone: number;
  stepsTotal: number;
  needsYou: number;
  state: string;
};

/** `POST /api/live-activities`: the phone's push-to-start token, or one running activity's
 * update token and the agent it shows. */
export type LiveActivityTokenRequest = { token: string; kind: 'start' | 'update'; agent?: string };

/** One configured MCP server as the owner's screen may see it: what it is and which secrets it
 * carries by name, never their values — the provider key's behaviour. A screen that never sees a
 * value cannot send one back, so on `PUT /api/mcp/servers/<name>` a secret sent blank keeps the
 * stored one and a key left out is removed. */
export type McpServerSummary = {
  name: string;
  transport: 'stdio' | 'http';
  /** The stdio executable, bare; absent for an http server. */
  command?: string;
  /** Its arguments, so a screen can round-trip one; absent for an http server. */
  args?: string[];
  /** The http endpoint; absent for a stdio server. */
  url?: string;
  /** The environment variables or headers it carries, by name only. */
  secretKeys: string[];
};

/** What testing one server's connection came back with. A server that could not be reached is a
 * successful test with `ok` false, not a failed request. */
export type McpTestResult = {
  ok: boolean;
  tools: string[];
  error?: string;
};

export type ApiError = {
  error: string;
};

/** What one model call against the stored provider settings came back with. An endpoint that
 * could not be reached is a successful test with `ok` false, like an MCP test. */
/** One entry of the model registry. The key is reported as present or absent, never echoed. At
 * most one entry is the default (what an agent without its own model runs on) and one the
 * backup. `PUT /api/settings` provider fields read and write the default entry. */
export type ModelEntry = {
  id: number;
  name: string;
  baseUrl: string;
  model: string;
  apiKeySet: boolean;
  /** A JSON object merged under every request to this model, or empty. */
  extraBody: string;
  isDefault: boolean;
  isBackup: boolean;
  createdAt: number;
};

/** `POST /api/models` needs name, baseUrl and model; `PUT /api/models/:id` takes any of them.
 * An empty `apiKey` removes the key. */
export type ModelUpdate = {
  name?: string;
  baseUrl?: string;
  model?: string;
  apiKey?: string;
  extraBody?: string;
};

export type ProviderTestResult = {
  ok: boolean;
  /** The first line of what the model answered, when it answered. */
  reply?: string;
  error?: string;
};

/** An agent's memory files as the owner may read and edit them. `today` is the daily note the
 * agent appends to and is read-only here; `lasting` is `MEMORY.md`, which the owner may rewrite. */
export type MemoryFiles = {
  lasting: string;
  today: string;
};

export const SEARCH_KINDS = ['message', 'file', 'screenshot'] as const;
export type SearchKind = (typeof SEARCH_KINDS)[number];

/** What a question to `POST /api/search` was read as. `from`/`to` are epoch ms, inclusive. */
export type SearchFilters = {
  kinds: SearchKind[];
  agent?: string;
  from?: number;
  to?: number;
  words: string[];
};

/** One hit and where it came from: a message or screenshot has its thread, a file its path. */
export type SearchResult = {
  kind: SearchKind;
  /** The agent whose home holds the file, or who wrote the message; absent for the owner. */
  agent?: string;
  conversationId?: number;
  participants?: string[];
  messageId?: number;
  path?: string;
  at: number;
  snippet: string;
};

export type SearchAnswer = {
  /** The filters as the owner would read them, one line each. */
  understoodAs: string[];
  filters: SearchFilters;
  /** False when no model read the question and it went to plain text search. */
  byModel: boolean;
  hits: SearchResult[];
};

/** How an agent's files differ now from its snapshot before the rewound point. Paths are relative
 * to its home; dot entries and `node_modules` are never snapshotted. */
export type FileChanges = {
  agent: string;
  /** When the snapshot was taken, epoch ms. */
  takenAt: number;
  added: string[];
  changed: string[];
  removed: string[];
};

export const CANT_UNDO_KINDS = ['message', 'mail', 'install', 'approval', 'trigger', 'form'] as const;
export type CantUndoKind = (typeof CANT_UNDO_KINDS)[number];

/** Something in the rewound rows that restoring files does not take back. */
export type CantUndo = { messageId: number; kind: CantUndoKind; text: string };

/** `GET .../rewind?from=`: what a rewind from that row would take away and what it can't. */
export type RewindPreview = {
  /** Rows the rewind deletes. */
  removed: number;
  files: FileChanges[];
  /** Agents in the thread with no snapshot from before that point (none taken, or older than 7 days). */
  noSnapshot: string[];
  cantUndo: CantUndo[];
};

/** What the owner's `POST .../compact` did: for each agent in the thread, how many rows its new
 * summary stands for. Zero is an agent with nothing since its last summary, and no model call. */
export type CompactResult = {
  compacted: Record<string, number>;
};

/** A file from an agent's home, fetched so the owner can open or keep it. */
export type AgentFile = {
  name: string;
  bytes: number;
  base64: string;
};

/** Where a file the owner handed to an agent landed, inside that agent's home. */
export type UploadResult = {
  path: string;
  bytes: number;
};

/** Something the owner passes on to another agent: a message, a file from an agent's home, or
 * both, with a note of their own. The target gets it all in its own thread and a turn. */
export type ForwardRequest = {
  messageId?: number;
  file?: { agent: string; path: string };
  note?: string;
};

export type ForwardResult = {
  message: Message;
  file?: UploadResult;
};

/** The bloub catalogue a look token (`shape:colour`) is drawn from. The app's `BloubShapeId` and
 * `BloubColorId` mirror these. */
export const BLOUB_SHAPES = ['circle', 'pebble', 'squircle', 'capsule', 'triangle', 'hexagon', 'cloud', 'droplet'] as const;
export const BLOUB_COLORS = [
  'ink',
  'brown',
  'red',
  'orange',
  'amber',
  'green',
  'teal',
  'blue',
  'violet',
  'pink',
  'grey',
  'cream',
] as const;

/** `POST /api/agents/suggest`: what the owner wants a new agent for, in their words. */
export type AgentSuggestRequest = { description: string };

/** A starting point for a new agent, every field editable before it is created. `name` is free
 * when suggested; `tagline` is the one-line label its profile will open with. Without a model,
 * or when its reply is unusable, `byModel` is false and `look` is left to the client. */
export type AgentSuggestion = {
  name: string;
  label: string;
  tagline: string;
  look?: string;
  levels: Record<ApprovalCategory, RuleLevel>;
  routine?: { cron: string; prompt: string };
  byModel: boolean;
};

/** `POST /api/agents`. With a `description` the interview starts from it at once, the rules and
 * routine are in place for its first turn, and the desktop starts in the background. */
export type AgentCreateRequest = {
  name: string;
  label?: string;
  look?: string;
  profile?: string;
  description?: string;
  tagline?: string;
  levels?: Partial<Record<ApprovalCategory, RuleLevel>>;
  routine?: { cron: string; prompt: string };
};

export const MIN_PASSWORD_LENGTH = 8;

/** Every state an agent can be in. `completed` is where a task worker ends: it did its job and
 * nothing will start it again. A permanent agent ends a turn in `waiting_for_user`, or in
 * `waiting_for_agent` / `waiting_for_task_worker` when it spent the turn handing work to
 * someone else and what comes back is what will wake it. */
export const AGENT_STATES = [
  'idle',
  'thinking',
  'using_computer',
  'using_terminal',
  'waiting_for_user',
  'waiting_for_agent',
  'waiting_for_task_worker',
  'failed',
  'completed',
] as const;

export type AgentState = (typeof AGENT_STATES)[number];

/** What a model has said so far in a reply still being streamed. Process state, gone the moment
 * the reply is stored as a message. */
/**
 * A model call waiting to be asked again after a rate limit, a server error or a dropped
 * connection. Gone once the call answers, fails for good or the turn is stopped.
 */
export type RetryState = {
  /** The attempt that comes next, counting the first call as 1. */
  attempt: number;
  of: number;
  /** When it goes, in epoch milliseconds; "Retry now" does not wait for it. */
  retryAt: number;
  error: string;
  /** The name of the model in use. */
  model: string;
  /** The backup's name, while switching to it is still possible for this turn. */
  backup?: string;
};

export type LiveReply = { text: string; reasoning: string; retry?: RetryState };

/** A permanent agent, or — when `parentId` is set — a task worker one of them spawned. */
export type Agent = {
  id: number;
  name: string;
  /** What the owner calls it, free text. Cosmetic only: `name` is what runs, is addressed and is
   * routed to, and a label is never any of those. Absent on a task worker. A name changes only by
   * a move: `PATCH` with a `name`, or the agent's own `set_name`. */
  label?: string;
  /** How a client draws it: an opaque token the daemon stores so every device shows the same
   * avatar. Absent until a client sets one. */
  look?: string;
  /** Who it is, in Markdown: what it is for, how it works, what it stays out of. Written by the
   * agent after it interviews the owner, or by the owner; part of its system prompt. Absent
   * until one of them writes it, and on a task worker. */
  profile?: string;
  /** The X display this agent drives. A worker shares its parent's and drives nothing, so its
   * own number is a placeholder above the range a desktop can use. */
  display: number;
  state: AgentState;
  /** The agent that spawned this one. Only a task worker has it. */
  parentId?: number;
  /** The thread a worker reports its result into: the one its parent was in when it spawned. */
  parentConversationId?: number;
  /** The model it runs on. Absent means the default; a worker runs on its parent's. */
  modelId?: number;
  createdAt: number;
  /** How full its own thread is, 0–100, against the point where the daemon compacts it. Only on
   * `GET /api/agents`, which is the list a client polls. */
  contextFullness?: number;
};

export const COMPUTER_ACTIONS = [
  'screenshot',
  'move',
  'click',
  'drag',
  'scroll',
  'type',
  'key',
  'clipboard_read',
  'clipboard_write',
] as const;

export type ComputerActionName = (typeof COMPUTER_ACTIONS)[number];

export type ScrollDirection = 'up' | 'down' | 'left' | 'right';

export type ComputerAction =
  | { action: 'screenshot' }
  | { action: 'clipboard_read' }
  | { action: 'move'; x: number; y: number }
  | { action: 'click'; x: number; y: number; button: number }
  | { action: 'drag'; x: number; y: number; toX: number; toY: number; button: number }
  | { action: 'scroll'; x: number; y: number; direction: ScrollDirection; amount: number }
  | { action: 'type'; text: string }
  | { action: 'key'; keys: string }
  | { action: 'clipboard_write'; text: string };

/** An image on the wire: a screenshot the daemon took, or a picture the owner sent. */
export type ImageAttachment = { mediaType: 'image/png' | 'image/jpeg'; base64: string };

/** A screenshot travels as base64 in JSON; see docs/architecture.md for why. */
export type ComputerResult = {
  action: ComputerActionName;
  image?: ImageAttachment;
  text?: string;
};

export type CommandRequest = {
  command: string;
  timeoutMs?: number;
  background?: boolean;
};

export type CommandResult = {
  exitCode: number;
  stdout: string;
  stderr: string;
  timedOut: boolean;
  background: boolean;
};

export type ToolCall = { id: string; name: string; arguments: string };

export type MessageRole = 'user' | 'assistant' | 'tool';

/** One turn of a conversation. A screenshot observation carries its image here so the
 * transcript survives a restart; see docs/architecture.md for why it is not a tool-role image.
 * `sender` names the agent that wrote it; absent means the owner. */
export type Message = {
  id: number;
  role: MessageRole;
  content: string;
  sender?: string;
  toolCalls?: ToolCall[];
  toolCallId?: string;
  image?: ImageAttachment;
  /** The owner's thumbs, on an agent's reply only. */
  feedback?: MessageFeedback;
  createdAt: number;
};

export type FeedbackRating = 'up' | 'down';
export type MessageFeedback = { rating: FeedbackRating; reason?: string };

/** A thread, identified by the agents in it. One participant is an agent's owner thread; two
 * or more is a group. The owner is in every conversation and is never listed. */
export type Conversation = {
  id: number;
  participants: string[];
  createdAt: number;
};

/** A standing job: a cron expression and the prompt a due run starts a turn with, in the
 * agent's own thread with the owner. `nextRunAt` is when it is due; a paused row keeps it but
 * never fires, and resuming recomputes it from now. */
export type Schedule = {
  id: number;
  agent: string;
  cron: string;
  prompt: string;
  paused: boolean;
  nextRunAt: number;
  /** When it last fired, absent until it has. */
  lastRunAt?: number;
  createdAt: number;
};

/** `schedule_dropped` is the tick throwing a row away because its cron has no next run left.
 * The tick's other drop — a row whose agent is gone — has no event and can have none:
 * `events.agent_id` is NOT NULL and references `agents`, so there is nothing to hang it on. */
export type EventType =
  | 'tool_call'
  | 'tool_result'
  | 'state'
  | 'failure'
  | 'restart'
  | 'control'
  | 'schedule_dropped'
  | 'approval'
  | 'stop'
  | 'turn';

/** The structured record of what an agent did. No chain-of-thought, no secrets, no payloads. */
export type ExecutionEvent = {
  id: number;
  type: EventType;
  data: Record<string, unknown>;
  createdAt: number;
};

/** What an agent may ask the owner to destroy. `conversation` is always the thread the asking
 * agent was in when it asked: an agent never sees a conversation id, so it cannot name another. */
export type ApprovalKind = 'agent' | 'conversation' | 'action';

/** The eight rule categories an action falls into, plus passwords and security, which is never
 * delegated and always goes to the owner. */
export const APPROVAL_CATEGORIES = [
  'browse',
  'run_commands',
  'write_files',
  'delete_files',
  'send_messages',
  'spend_money',
  'install_software',
  'share_outside',
  'passwords_security',
] as const;

export type ApprovalCategory = (typeof APPROVAL_CATEGORIES)[number];

/** The rules ladder, loosest first. `if_pre_approved` goes ahead for what is on the agent's
 * pre-approved list and asks for the rest; `hand_to_you` leaves the thing to the owner. */
export const RULE_LEVELS = ['on_its_own', 'if_pre_approved', 'ask_first', 'hand_to_you'] as const;

export type RuleLevel = (typeof RULE_LEVELS)[number];

/** One agent's rules. `passwords_security` is always `hand_to_you`. */
export type AgentRules = {
  levels: Record<ApprovalCategory, RuleLevel>;
  /** Per category: the domains, recipients or packages the agent may act on without asking. */
  preApproved: Partial<Record<ApprovalCategory, string[]>>;
};

/** `PUT /api/agents/:name/rules`: what is left out keeps its value. */
export type AgentRulesUpdate = {
  levels?: Partial<Record<ApprovalCategory, RuleLevel>>;
  /** A category given here has its list replaced; an empty list clears it. */
  preApproved?: Partial<Record<ApprovalCategory, string[]>>;
};

/** What makes a night's idle pass worth a model call. Checked without one. */
export const IDLE_CONDITIONS = ['new_messages', 'new_feedback', 'memory_size', 'stale_files'] as const;

export type IdleCondition = (typeof IDLE_CONDITIONS)[number];

/** One permanent agent's idle work. Hours are the daemon's local time; a window may wrap
 * midnight, and equal hours mean the whole day. */
export type IdleSettings = {
  enabled: boolean;
  conditions: IdleCondition[];
  dailyTokens: number;
  turnCap: number;
  /** A model from the registry; null is the agent's own model. */
  modelId: number | null;
  startHour: number;
  endHour: number;
  /** Why the daemon switched idle work off (back-off); cleared when the owner turns it on. */
  pausedReason: string | null;
};

/** `PUT /api/agents/:name/idle`: what is left out keeps its value. */
export type IdleSettingsUpdate = Partial<Omit<IdleSettings, 'pausedReason'>>;

/** `due` is a pass whose pre-check matched and that has not run yet. */
export type IdlePassOutcome = 'skipped' | 'due' | 'ran' | 'wasted';

export type IdlePass = {
  id: number;
  agent: string;
  startedAt: number;
  matched: IdleCondition[];
  outcome: IdlePassOutcome;
  tokens: number;
  endedAt: number | null;
  /** Why a matched pass did not run (budget, busy, no model). */
  reason: string | null;
  outputs: IdleOutput[];
};

export type IdleOutputResolution = 'dismissed' | 'undone' | 'accepted';

/** What an idle pass may leave behind; nothing else it does outlives the turn. */
export type IdleOutput = { id: number; createdAt: number; resolved: IdleOutputResolution | null } & (
  | { kind: 'memory'; before: string; after: string }
  | { kind: 'routine'; cron: string; prompt: string }
  | { kind: 'note'; text: string }
  | { kind: 'cleanup'; approvalId: number }
);

export type IdleOutputKind = IdleOutput['kind'];

/** `POST /api/idle/outputs/:id`: undo a memory diff, turn a routine on, or dismiss a note or routine. */
export type IdleOutputAction = 'undo' | 'accept' | 'dismiss';

/** Cron is not a trigger kind: it stays `schedule_task`. */
export const TRIGGER_KINDS = ['webhook', 'folder', 'command', 'imap'] as const;

export type TriggerKind = (typeof TRIGGER_KINDS)[number];

/** An agent proposes, the owner turns it on; nothing fires while `proposed` or `off`. */
export type TriggerState = 'proposed' | 'on' | 'off';

/** folder: `path` relative to the agent's home. command: `command`, run as the agent. imap:
 * `host`, `port` and `mailbox`, over TLS; the login is never in here. All three are checked every
 * `everyMinutes`. A webhook has no config. */
export type TriggerConfig = {
  path?: string;
  command?: string;
  host?: string;
  port?: number;
  mailbox?: string;
  everyMinutes?: number;
};

export type Trigger = {
  id: number;
  agent: string;
  kind: TriggerKind;
  config: TriggerConfig;
  reason: string;
  state: TriggerState;
  maxPerHour: number;
  /** Fires refused by the rate limit, ever. */
  dropped: number;
  lastFiredAt: number | null;
  /** Why the newest folder, command or mailbox check failed; null once a check goes through. */
  lastError: string | null;
  createdAt: number;
  /** Minted on the first turn-on. POST to `path` with the secret in the `X-Schermes-Secret` header. */
  webhook?: { path: string; secret: string };
  /** imap only: whether the owner has entered the mailbox login. It cannot be turned on until then. */
  hasLogin?: boolean;
};

/** `POST /api/triggers/:id`: turning on is the owner's confirmation. */
export type TriggerAction = 'on' | 'off' | 'delete';

/**
 * A destructive change an agent has asked for and the owner has not answered yet. Nothing is
 * deleted while one of these stands: the daemon keeps the request and performs it only when the
 * owner approves, then writes the outcome back into the thread the request came from.
 */
export type Approval = {
  id: number;
  /** The agent that asked. */
  agent: string;
  /** The thread it asked in, which is where the answer is written back. */
  conversationId: number;
  kind: ApprovalKind;
  /** Deletions are `delete_files`. */
  category: ApprovalCategory;
  /** An agent's name, or a conversation id as a string; for an `action`, what it acts on, or
   * empty. */
  target: string;
  /** Only on an `action`, when the agent gave one: what it costs, as the agent wrote it. */
  amount?: string;
  /** Only on an `action`, when the agent gave one: the site or service it concerns. */
  origin?: string;
  /** The agents in the thread a `conversation` request names, so the owner is told what they
   * are deleting rather than a number. Empty for an `agent` request. */
  participants: string[];
  reason: string;
  createdAt: number;
};

export type NeedsYouKind = 'approval' | 'question' | 'failure' | 'provider_auth' | 'browser_hung' | 'hand_over' | 'form' | 'goal';

/** `answer` and `open` happen in the thread; `retry` is the thread's retry of the failed turn;
 * `always` approves and puts the approval's origin or recipient on the pre-approved list;
 * `settings` opens the model settings, where a refused key is fixed; `restart_browser` and
 * `restart_desktop` go to `POST /api/agents/:name/browser/restart`; `screen` opens the agent's screen;
 * `take_screen` takes control (`POST /api/agents/:name/control`) and opens it; `fill` sends the
 * form's values to `POST /api/agents/:name/forms/:id`. */
export type NeedsYouAction =
  | 'approve'
  | 'always'
  | 'deny'
  | 'answer'
  | 'retry'
  | 'open'
  | 'settings'
  | 'restart_browser'
  | 'restart_desktop'
  | 'screen'
  | 'take_screen'
  | 'fill';

/** `GET`/`POST`/`DELETE /api/agents/:name/control`. `handOver`: the agent asked for hands and is
 * waiting; giving the screen back tells it and starts its turn. */
export type ControlState = { held: boolean; handOver?: boolean; recording?: RecordingState };

/**
 * "Show the agent how", present only while one runs. `POST /api/agents/:name/recording` takes the
 * screen and starts it, `PUT` `{secret}` marks what the owner types next as secret, and giving
 * the screen back (`DELETE …/control`) ends it and hands it to the agent in its own thread.
 */
export type RecordingState = { startedAt: number; steps: number; shots: number; secret: boolean; truncated?: boolean };

/**
 * One thing waiting on the owner. It stays listed until it is resolved, from wherever: an
 * answered approval, the owner's reply to a question, a new turn after a failure.
 */
export type NeedsYouItem = {
  /** Stable across polls: `approval:<id>`, `question:<message id>`, `failure:<message id>`,
   * `provider-auth:<model id>`, `browser:<tool row id>`, `hands:<message id>`, `form:<form id>`,
   * `goal:<goal id>`. */
  id: string;
  kind: NeedsYouKind;
  /** For `provider_auth`, one item for every agent on that model: the first that was refused. */
  agent: string;
  conversationId: number;
  title: string;
  /** The approval's reason, or the rest of a failure's message. */
  detail?: string;
  /** The message the item hangs off: the `ask_owner` or `ask_for_hands` call, or the failure line. */
  messageId?: number;
  approval?: Approval;
  form?: FormRequest;
  /** A trigger's login form: the trigger it is for. */
  triggerId?: number;
  /** `goal`: the goal whose "next from you" this is; `detail` holds the list, one per line. */
  goalId?: number;
  createdAt: number;
  actions: NeedsYouAction[];
};

/** One control of a form the daemon read from the agent's page. `type` is the input's type, or
 * `select`, `textarea`, `radio`. A `secret` field's value never reaches the model or the transcript. */
export type FormField = {
  /** What the fill route takes the value under. */
  id: string;
  label: string;
  type: string;
  autocomplete?: string;
  required: boolean;
  /** For `select` and `radio`. */
  options?: { value: string; label: string }[];
  secret: boolean;
  /** A value remembered for this site; the fill uses it when the owner sends none. */
  saved: boolean;
};

/** Why a control goes to the agent's screen instead: `cross_origin_frame`, `captcha`,
 * `unknown_widget`, `file`, or `insecure` (a secret field on a page that is not HTTPS or loopback). */
export type UnfillableField = { label: string; reason: string };

/** `request_form`: the fields and origin come from the page over CDP, never from the model. */
export type FormRequest = {
  id: number;
  origin: string;
  /** HTTPS or loopback. */
  secure: boolean;
  reason: string;
  fields: FormField[];
  unfillable: UnfillableField[];
  createdAt: number;
};

/** `POST /api/agents/:name/forms/:id`. Values by field id; `remember` saves them for the origin. */
export type FormFill = { values: Record<string, string>; remember?: boolean };

export const GOAL_STEP_STATES = ['todo', 'doing', 'done', 'blocked'] as const;
export type GoalStepState = (typeof GOAL_STEP_STATES)[number];
export type GoalState = 'open' | 'done';

/** `worker`: a task worker on the lead's Linux user with an Xvnc display of its own.
 * `agent`: a temporary agent with its own Linux user and desktop. */
export const HELPER_KINDS = ['worker', 'agent'] as const;
export type HelperKind = (typeof HELPER_KINDS)[number];

/** `owner` is the agent doing the step: the lead or one of the goal's helpers. */
export type GoalStep = { text: string; owner: string; state: GoalStepState };

/** `keptAt`: the owner chose "Keep as agent"; finishing the goal leaves it as a normal agent. */
export type GoalHelper = {
  name: string;
  kind: HelperKind;
  reason: string;
  state: AgentState;
  keptAt?: number;
  createdAt: number;
};

/** `GET /api/goals`, `GET /api/goals/:id`. Kept up by its lead through `update_goal`. */
export type Goal = {
  id: number;
  title: string;
  lead: string;
  state: GoalState;
  steps: GoalStep[];
  results: string[];
  /** What the owner still has to do; also a Needs you item while not empty. */
  nextFromYou: string[];
  helpers: GoalHelper[];
  createdAt: number;
  updatedAt: number;
  doneAt?: number;
};
