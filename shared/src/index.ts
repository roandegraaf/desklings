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

/** One configured MCP server as the owner's screen may see it: what it is and which secrets it
 * carries by name, never their values. The whole stored list is encrypted, so a `PUT` that
 * changes one server carries every secret again — the provider key's behaviour. */
export type McpServerSummary = {
  name: string;
  transport: 'stdio' | 'http';
  /** The stdio command line, joined; absent for an http server. */
  command?: string;
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

/** A screenshot travels as base64 in JSON; see docs/architecture.md for why. */
export type ComputerResult = {
  action: ComputerActionName;
  image?: { mediaType: 'image/png'; base64: string };
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
  image?: { mediaType: 'image/png'; base64: string };
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
  | 'approval';

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
