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

/** One row a search across every thread found: where it is, who is in that thread, and the
 * row without its image and tool calls, clipped to a snippet around the match. */
export type SearchHit = {
  conversationId: number;
  participants: string[];
  message: Pick<Message, 'id' | 'role' | 'content' | 'sender' | 'createdAt'>;
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
export type LiveReply = { text: string; reasoning: string };

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
  createdAt: number;
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
  createdAt: number;
};

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
export type ApprovalKind = 'agent' | 'conversation';

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
  /** An agent's name, or a conversation id as a string. */
  target: string;
  /** The agents in the thread a `conversation` request names, so the owner is told what they
   * are deleting rather than a number. Empty for an `agent` request. */
  participants: string[];
  reason: string;
  createdAt: number;
};
