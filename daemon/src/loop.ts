import type {
  Agent,
  AgentState,
  CommandResult,
  LiveReply,
  Message,
  ToolCall,
} from '@schermes/shared';
import {
  AGENT_NAME,
  agentTarget,
  asAgent,
  deleteAgent,
  findAgent,
  findAgentById,
  forgetAgent,
  hasOwnScreen,
  insertAgent,
  insertWorker,
  isWorker,
  listAgents,
  nextDisplay,
  nextWorkerName,
  setAgentCosmetics,
  setAgentState,
} from './agents.ts';
import type { DesktopOps } from './agents.ts';
import {
  ADD_HELPER,
  MAX_HELPERS,
  UPDATE_GOAL,
  addHelperRow,
  addHelperToolDef,
  applyGoalUpdate,
  describeGoal,
  finishGoal,
  goalPrompt,
  helperCount,
  helperGoal,
  helperProfile,
  inheritFromLead,
  isHelper,
  leadGoal,
  nextHelperName,
  parseAddHelper,
  parseGoalUpdate,
  updateGoalToolDef,
} from './goals.ts';
import type { HelperRequest } from './goals.ts';
import {
  MAX_AGENT_CHAIN,
  agentChain,
  appendMessage,
  appendSummary,
  conversationFor,
  existingConversation,
  lastMessageId,
  latestSummary,
  listConversations,
  listMessages,
  markAnswered,
  owedRequests,
  listMessagesWithoutImages,
  parseSendMessage,
  pendingConversation,
  recordEvent,
  repairInterruptedCalls,
  awaitedAgents,
  sendMessageToolDef,
  threadFingerprint,
} from './conversations.ts';
import type { StoredMessage } from './conversations.ts';
import {
  MAX_PENDING_APPROVALS,
  describeApproval,
  insertApproval,
  parseApprovalRequest,
  parseDeletionRequest,
  pendingCount,
  requestApprovalToolDef,
  requestDeletionToolDef,
} from './approvals.ts';
import type { ApprovalRequest } from './approvals.ts';
import { browse, browserToolDef, cdpConnect, parseBrowserAction } from './browser.ts';
import type { BrowserTimings, Connect } from './browser.ts';
import { computerToolDef, parseComputerAction, performComputerAction } from './computer.ts';
import { homePrompt, loadHome, parseRemember, remember, rememberToolDef } from './home.ts';
import {
  askOwnerToolDef,
  setNameToolDef,
  parseAskOwner,
  parseProfile,
  profilePrompt,
  setProfileToolDef,
} from './interview.ts';
import { askForHandsToolDef, CONTROL_HELD, CONTROL_REFUSAL, parseHandsReason } from './control.ts';
import type { Control } from './control.ts';
import { captureForm, redactSecrets, requestFormToolDef } from './forms.ts';
import type { Screen } from './computer.ts';
import {
  cancelScheduleToolDef,
  deleteSchedule,
  findSchedule,
  insertSchedule,
  listSchedules,
  listSchedulesToolDef,
  nextRun,
  parseSchedule,
  parseScheduleId,
  pauseScheduleToolDef,
  schedulePrompt,
  scheduleTaskToolDef,
  setPaused,
} from './schedules.ts';
import { MCP_PREFIX } from './mcp.ts';
import type { McpSession } from './mcp.ts';
import { commandToolDef, parseCommand, runCommand } from './terminal.ts';
import { readTimezone } from './settings.ts';
import { LEAVE_NOTE, addIdleOutput, idleCommandRefusal, leaveNoteToolDef, parseNote } from './idle.ts';
import { PROPOSE_TRIGGER, parseTriggerProposal, proposeTrigger, proposeTriggerToolDef, triggerPrompt } from './triggers.ts';
import { guardCommand, readRules, rulesPrompt } from './rules.ts';
import {
  NO_SEARCH_KEY,
  fetchPage,
  parseWebFetch,
  parseWebSearch,
  searchPrompt,
  webFetchToolDef,
  webSearch,
  webSearchToolDef,
} from './web.ts';
import type { SearchConfig } from './web.ts';
import type { Db } from './db.ts';
import type { AgentTarget } from './agents.ts';
import { snapshotWorkspace } from './snapshots.ts';
import type { Exec } from './exec.ts';
import { ProviderError } from './provider.ts';
import type { ChatReply, Image, Provider, ProviderMessage, Usage } from './provider.ts';
import { contextWindowFor, modelIdFor } from './models.ts';
import { log } from './log.ts';
import { listNeedsYou } from './needs.ts';
import { dequeueTurn, enqueueTurn, isQueued, markRead, queuedTurns, readThrough } from './queue.ts';
import type { TurnKind } from './queue.ts';
import {
  liveWorkers,
  parseSpawnWorker,
  spawnWorkerToolDef,
  workerDir,
  workerPrompt,
} from './workers.ts';

// A turn is bounded so a model that keeps calling tools cannot run forever.
const MAX_STEPS = 200;

/** Replies still being streamed, by agent id so a rename mid-turn keeps its entry. Process
 * state: an agent is in `thinking` for exactly as long as it has an entry here, and the stored
 * message replaces it. */
const live = new Map<number, LiveReply>();

export function liveReply(agentId: number): LiveReply | undefined {
  return live.get(agentId);
}
const MAX_OBSERVATION_CHARS = 16_000;
/**
 * How many of an agent's own tool results a model call carries in full. Every step replayed
 * every output ever seen, so a thread that dumped a few logs early grew a request that got
 * slower with each call. Older results keep their head: enough to remember what happened, not
 * enough to reason from.
 */
export const MAX_FULL_OBSERVATIONS = 8;
const TRIMMED_OBSERVATION_CHARS = 400;
const TRIMMED_NOTE = '\n[older output shortened; run it again if you need the rest]';
/**
 * How many screenshots a model call carries. Replaying every one of them made the request grow
 * with the conversation, which a real endpoint eventually refuses; a desktop's recent history is
 * what an agent reasons from, and anything older is a picture of a screen that has since moved.
 */
export const MAX_REPLAYED_IMAGES = 3;

/**
 * When a thread is replayed as a summary plus a tail instead of in full, measured in the
 * characters `transcript` would actually send — after the trimming above, because trimmed is
 * what the request costs. Screenshot bytes are deliberately not counted: `MAX_REPLAYED_IMAGES`
 * already bounds them, and counting them would put every desktop-driving agent permanently over
 * a budget compaction cannot bring it back under.
 */
export const MAX_TRANSCRIPT_CHARS = 400_000;
/**
 * How much of the end of the thread is replayed verbatim behind the summary. It has to clear
 * what no cut can remove — the last `MAX_FULL_OBSERVATIONS` tool results, each of which
 * `describe` may have clipped stdout *and* stderr to `MAX_OBSERVATION_CHARS` — or compaction
 * would fire every turn and shrink nothing.
 */
export const COMPACTION_TAIL_CHARS = 260_000;

/**
 * Turns a model's context window, in tokens, into the character budgets above. Deliberately low:
 * English prose runs near 4 characters a token, but the JSON, paths, logs and code a desktop
 * agent replays tokenise denser, and an estimate that runs over costs a failed request.
 */
export const CHARS_PER_TOKEN = 3;
/** Kept free for the reply: a quarter of a small window, at most this. */
export const REPLY_RESERVE_TOKENS = 8_192;
/** Per replayed image. A 1280x800 PNG costs about 1,100 tokens at OpenAI's high detail and
 * more on some other vendors; the char budget never counts image bytes. */
export const IMAGE_RESERVE_TOKENS = 1_600;
/** The built-in tool schemas run near 19,500 characters (22 tools, in the JSON sent); the rest
 * is room for MCP tools. More than that falls to the overflow retry. */
export const TOOL_SCHEMA_RESERVE_CHARS = 24_000;
const MIN_TRANSCRIPT_CHARS = 8_000;

/** What one turn's compaction works to, in characters: the replay's ceiling, the tail kept
 * verbatim behind a summary, and the longest summary stored. */
export type Budget = { transcript: number; tail: number; summary: number };

/**
 * The window is a ceiling, not a target: a model with a million tokens still compacts at the
 * fixed budget, since replaying more makes every step slower and dearer without being asked
 * for. An unknown window is that fixed budget too. The tail keeps the fixed budget's share, so
 * a compacted thread has the same room to grow before the next pass.
 */
export function compactionBudget(contextWindow: number | null): Budget {
  if (contextWindow === null) {
    return { transcript: MAX_TRANSCRIPT_CHARS, tail: COMPACTION_TAIL_CHARS, summary: MAX_OBSERVATION_CHARS };
  }
  const reserve =
    Math.min(REPLY_RESERVE_TOKENS, Math.floor(contextWindow / 4)) + MAX_REPLAYED_IMAGES * IMAGE_RESERVE_TOKENS;
  const fits = (contextWindow - reserve) * CHARS_PER_TOKEN - TOOL_SCHEMA_RESERVE_CHARS;
  const transcript = Math.max(MIN_TRANSCRIPT_CHARS, Math.min(MAX_TRANSCRIPT_CHARS, fits));
  return {
    transcript,
    tail: Math.floor((transcript * COMPACTION_TAIL_CHARS) / MAX_TRANSCRIPT_CHARS),
    summary: Math.min(MAX_OBSERVATION_CHARS, Math.floor(transcript / 8)),
  };
}

/** What a context-overflow retry compacts to: the endpoint has just said the estimate was
 * wrong, so every part is a quarter of what it was. */
export function overflowBudget(budget: Budget): Budget {
  return {
    transcript: Math.floor(budget.transcript / 4),
    tail: Math.floor(budget.tail / 4),
    summary: Math.floor(budget.summary / 4),
  };
}

/** What the summariser is asked for. Its own system text, so it is not the agent. */
export const SUMMARY_PROMPT =
  'You are summarising the earlier part of a conversation for the AI agent that is still in ' +
  'it, so that it can keep working without being shown those messages again. Write prose, in ' +
  'the second person, covering: what was asked for, what the agent found out, what it did and ' +
  'what came of it, decisions and constraints it must keep, and anything still unfinished. ' +
  'Keep names, paths, commands, ids and numbers exactly as they appear. Leave out what no ' +
  'longer matters. Do not address the reader, do not comment on the summary, write only it.';

/** A compacted thread as one turn replays it: the summary, and the id it stands in for. */
export type Replay = { text: string; throughId: number };

/**
 * Which stretches of a thread may be cut at, as indices into `messages`. A cut is the point the
 * tail begins, so everything before it is replaced by the summary — and a tail that begins in
 * the middle of a turn hands a strict endpoint either an assistant message whose tool calls
 * nothing answers or a tool result answering nothing, and it rejects the whole request. Only
 * this agent's own calls matter: another agent's tool traffic never reaches the projection.
 */
function turnBoundaries(name: string, messages: readonly Message[]): number[] {
  const outstanding = new Set<string>();
  const cuts: number[] = [];
  messages.forEach((message, index) => {
    if (outstanding.size === 0) cuts.push(index);
    if (message.sender !== name) return;
    if (message.role === 'assistant') {
      for (const call of message.toolCalls ?? []) outstanding.add(call.id);
    }
    if (message.role === 'tool') outstanding.delete(message.toolCallId ?? '');
  });
  return cuts;
}

/** What a projected transcript costs, counting everything but the screenshots. */
function projectedChars(messages: readonly ProviderMessage[]): number {
  return messages.reduce((total, message) => {
    if (message.role !== 'assistant') return total + message.text.length;
    const calls = message.toolCalls.reduce((sum, c) => sum + c.arguments.length, 0);
    const { source: _, ...echoed } = message.echo ?? { source: '' };
    const echo = Object.keys(echoed).length === 0 ? 0 : JSON.stringify(echoed).length;
    return total + message.text.length + calls + echo;
  }, 0);
}

/** The covered messages as text for the summariser, reusing the projection so a tool result it
 * reads is the one the agent was shown. The system message is the caller's, not this one's. */
function flatten(messages: readonly ProviderMessage[]): string {
  return messages
    .filter((message) => message.role !== 'system')
    .map((message) => {
      if (message.role === 'tool') return `tool result: ${message.text}`;
      if (message.role !== 'assistant') return message.text;
      const calls = message.toolCalls.map((call) => `${call.name}(${call.arguments})`).join(', ');
      return `you: ${message.text}${calls === '' ? '' : `\n[you called ${calls}]`}`;
    })
    .join('\n\n');
}

const OMITTED = '[earlier omitted]\n';

/** The end of `text` in at most `limit` characters, the marker included. */
function keepEnd(text: string, limit: number): string {
  if (text.length <= limit) return text;
  const room = limit - OMITTED.length;
  return room <= 0 ? OMITTED : OMITTED + text.slice(-room);
}

function newestReplay(db: Db, conversationId: number, name: string): Replay | undefined {
  const summary = latestSummary(db, conversationId, name);
  return summary === undefined ? undefined : { text: summary.content, throughId: summary.throughMessageId };
}

/**
 * Once per turn, in front of the first step: a thread past the budget is replayed as the newest
 * summary covering its head plus a verbatim tail. Never a rewrite — the messages stay exactly as
 * they are and `listMessages` keeps returning all of them, so the UI is untouched.
 *
 * A summary that cannot be written costs the agent the compaction, not the turn: the same rule
 * the home load follows. The request that follows is oversized, which is the endpoint's answer
 * to give, and the next turn tries again.
 */
async function compact(
  deps: LoopDeps,
  agent: Agent,
  conversationId: number,
  system: string,
  stored: readonly Message[],
  budget: Budget,
  meter?: Meter,
): Promise<Replay | undefined> {
  const replay = newestReplay(deps.db, conversationId, agent.name);
  if (projectedChars(transcript(agent.name, system, stored, replay)) <= budget.transcript) {
    return replay;
  }
  return (await summariseHead(deps, agent, conversationId, system, stored, budget, undefined, meter)) ?? replay;
}

/**
 * Summarises the head of what no summary covers yet, cutting at the first turn boundary whose
 * tail fits `budget.tail` (the last boundary when none does). The tail's target also leaves room
 * for the system text and the summary itself, or a small window would be full again at once.
 * Only rows up to `through` may be covered: mid-turn, a row another sender wrote after the turn
 * began is not in `stored`, and a summary reaching past it would hide it from every later
 * replay. Undefined when there is no cut or the model would not summarise.
 */
async function summariseHead(
  deps: LoopDeps,
  agent: Agent,
  conversationId: number,
  system: string,
  stored: readonly Message[],
  budget: Budget,
  through = Number.POSITIVE_INFINITY,
  meter?: Meter,
): Promise<Replay | undefined> {
  const previous = latestSummary(deps.db, conversationId, agent.name);
  // Only what no summary covers yet, so a second pass never re-summarises the same messages.
  const live = stored.filter((message) => message.id > (previous?.throughMessageId ?? 0));
  // Raw content overstates what a trimmed observation costs, so the tail lands under the target
  // rather than over it. Where to cut is a judgement; whether to cut is the caller's measurement.
  const cost = live.map((message) => message.content.length);
  const tail = (from: number): number => cost.slice(from).reduce((sum, n) => sum + n, 0);
  const target = Math.min(budget.tail, budget.transcript - system.length - budget.summary);
  const cuts = turnBoundaries(agent.name, live).filter(
    (index) => index > 0 && (live[index - 1]?.id ?? 0) <= through,
  );
  const cut = cuts.find((index) => tail(index) <= target) ?? cuts.at(-1);
  if (cut === undefined) {
    log.info('nothing to compact: the thread is one turn', { agent: agent.name, conversationId });
    return undefined;
  }
  return writeSummary(deps, agent, conversationId, live.slice(0, cut), budget, meter);
}

/** How often `contextFullness` had to project a thread rather than answer from its memo. */
export const fullnessStats = { projections: 0 };

const projectedFullness = new WeakMap<Db, Map<number, { fingerprint: string; chars: number }>>();

/**
 * How close the agent's own thread is to compaction, 0–100: the measure `compact` takes, against
 * the budget it takes it against. The system text is left out; it is built from the home, which
 * is too slow to read on every poll of the agent list, and is small beside the budget.
 *
 * The agent list asks this for every agent on every poll, so the projected size is memoised per
 * thread under `threadFingerprint` and only recomputed once the thread changes. The budget is
 * not memoised: a model switch changes it without touching the thread.
 */
export function contextFullness(db: Db, agent: Agent): number {
  const conversationId = existingConversation(db, agent.id);
  if (conversationId === undefined) return 0;
  const fingerprint = threadFingerprint(db, conversationId, agent.name);
  const memo = projectedFullness.get(db) ?? new Map<number, { fingerprint: string; chars: number }>();
  projectedFullness.set(db, memo);
  const cached = memo.get(conversationId);
  let chars = cached?.fingerprint === fingerprint ? cached.chars : undefined;
  if (chars === undefined) {
    fullnessStats.projections += 1;
    const replay = newestReplay(db, conversationId, agent.name);
    const stored = listMessagesWithoutImages(db, conversationId, replay?.throughId ?? 0);
    chars = projectedChars(transcript(agent.name, '', stored, replay));
    memo.set(conversationId, { fingerprint, chars });
  }
  const budget = compactionBudget(contextWindowFor(db, agent));
  return Math.min(100, Math.round((chars / budget.transcript) * 100));
}

type Meter = (usage: Usage | undefined) => void;

/**
 * Writes one summary row standing for `covered`, which must be the rows straight after the newest
 * summary — that is what lets the previous summary be carried forward as the story so far rather
 * than re-read. Undefined when the model would not write one.
 */
async function writeSummary(
  deps: Pick<LoopDeps, 'db' | 'provider' | 'signal'>,
  agent: Agent,
  conversationId: number,
  covered: readonly Message[],
  budget: Budget,
  meter?: Meter,
): Promise<Replay | undefined> {
  const previous = latestSummary(deps.db, conversationId, agent.name);
  // A summary written under a larger budget (another model, or before an overflow) may not leave
  // room for anything else, so the story so far gets half of it at most.
  const story = previous?.content.slice(0, Math.floor(budget.transcript / 2));
  const earlier = story === undefined ? '' : `The story so far:\n${story}\n\n`;
  // The summariser's request has to fit the same window: no tools and no images ride on it, so
  // the replay budget is room enough for the prompt, the story so far and the stretch it covers.
  const room = Math.max(0, budget.transcript - SUMMARY_PROMPT.length - earlier.length);
  const body = earlier + keepEnd(flatten(transcript(agent.name, '', covered)), room);
  let summary: string;
  try {
    // No onDelta: this is not the agent speaking, and the live route would show it as its reply.
    const reply = await deps.provider(
      [
        { role: 'system', text: SUMMARY_PROMPT },
        { role: 'user', text: body },
      ],
      [],
      undefined,
      deps.signal,
    );
    meter?.(reply.usage);
    summary = reply.text.trim();
  } catch (error) {
    if (deps.signal?.aborted) {
      log.info('summary abandoned: the turn was stopped', { agent: agent.name });
    } else {
      log.error('summary failed, replaying the thread in full', { agent: agent.name, error });
    }
    return undefined;
  }
  if (summary === '') {
    log.error('the model summarised to nothing', { agent: agent.name, conversationId });
    return undefined;
  }

  // Clipped like any other text the transcript carries: a model that answers with the whole
  // conversation back would otherwise ride in every later request and eat the budget itself.
  const content =
    summary.length <= budget.summary ? summary : `${summary.slice(0, budget.summary)}\n[summary truncated]`;
  const throughId = covered.at(-1)?.id ?? 0;
  appendSummary(deps.db, {
    conversationId,
    sender: agent.name,
    content,
    fromMessageId: covered[0]?.id ?? 0,
    throughMessageId: throughId,
  });
  log.info('thread compacted', {
    agent: agent.name,
    conversationId,
    covered: covered.length,
    throughId,
  });
  return { text: content, throughId };
}

/**
 * The owner's compaction, budget or no budget: everything since the newest summary is folded
 * into the next one and nothing is kept verbatim, so the agent's next turn opens on the summary
 * and whatever the owner writes after it. Only between turns — the loop writes every result
 * before it asks for more, so with no turn running every call this agent made is answered and
 * the whole stretch is one legal cut. Answers how many rows the new summary stands for, and what
 * the summary cost when the endpoint said.
 */
export async function compactNow(
  deps: Pick<LoopDeps, 'db' | 'provider'>,
  agent: Agent,
  conversationId: number,
): Promise<{ covered: number; usage?: Usage } | { error: string }> {
  const previous = latestSummary(deps.db, conversationId, agent.name);
  const live = listMessages(deps.db, conversationId).filter(
    (message) => message.id > (previous?.throughMessageId ?? 0),
  );
  if (live.length === 0) return { covered: 0 };
  const budget = compactionBudget(contextWindowFor(deps.db, agent));
  let usage: Usage | undefined;
  const replay = await writeSummary(deps, agent, conversationId, live, budget, (spent) => {
    usage = spent;
  });
  if (replay === undefined) return { error: `the model would not summarise the thread for ${agent.name}` };
  return usage === undefined ? { covered: live.length } : { covered: live.length, usage };
}

/**
 * Which states can follow which. `failed` is reachable from everywhere so the catch that ends a
 * broken run never has to bypass this table. `completed` is where a task worker ends: it
 * answered its parent and nothing will start it again. A permanent agent finishes a turn in
 * `waiting_for_user`, or waiting on whoever it handed work to. A turn normally ends from
 * `thinking`, but a restart ends one from wherever the dead daemon was standing, and a held
 * desktop ends one straight after a tool call, which is why the acting states reach every
 * waiting state too.
 */
const WAITING = ['waiting_for_user', 'waiting_for_agent', 'waiting_for_task_worker'] as const;

export const TRANSITIONS = {
  idle: ['thinking', 'failed'],
  thinking: [
    'using_computer',
    'using_terminal',
    'waiting_for_user',
    'waiting_for_agent',
    'waiting_for_task_worker',
    'completed',
    'failed',
  ],
  using_computer: ['thinking', 'using_terminal', ...WAITING, 'failed'],
  using_terminal: ['thinking', 'using_computer', ...WAITING, 'failed'],
  waiting_for_user: ['thinking', 'failed'],
  waiting_for_agent: ['thinking', 'waiting_for_user', 'failed'],
  waiting_for_task_worker: ['thinking', 'waiting_for_user', 'failed'],
  failed: ['thinking'],
  completed: ['thinking', 'failed'],
} as const satisfies Record<AgentState, readonly AgentState[]>;

export function canTransition(from: AgentState, to: AgentState): boolean {
  return from === to || (TRANSITIONS[from] as readonly AgentState[]).includes(to);
}

/** What makes a turn an idle pass: its limits, and who hears when it is over. */
export type IdleTurn = {
  passId: number;
  modelId: number | null;
  turnCap: number;
  /** Tokens this pass may still spend today. */
  tokenLimit: number;
  /** The running total after every metered call, so a restart mid-pass cannot lose what it spent. */
  spent?: (tokens: number) => void;
  /** Called once the turn is over with what it spent, or with undefined when it never ran. */
  end: (tokens: number | undefined) => Promise<void>;
};

/** Starts turns. The loop needs it so `send_message` can put the agent it wrote to to work. */
export type Runner = {
  /** Starts a turn now, or queues it when every loop is taken. A busy agent's running turn
   * picks the new row up itself. `kind` only labels the queue entry. */
  start(agent: Agent, conversationId: number, idle?: IdleTurn, kind?: TurnKind): void;
  /**
   * Why no loop can start right now, or undefined when there is room. Naming the agent that
   * would run matters: one already running is not another loop, because its message is picked
   * up by the drain rather than by a turn of its own.
   */
  atCapacity(name?: string): string | undefined;
  /** Whether a turn is in flight for this agent. A delete asks, because pulling an agent's rows
   * out from under its own loop turns every write it makes next into a foreign-key failure. */
  running(name: string): boolean;
  /** Ends this agent's running turn at the next step boundary, or now if it is waiting on the
   * model. False when nothing was running. */
  stop(name: string): boolean;
};

export type LoopDeps = {
  db: Db;
  exec: Exec;
  provider: Provider;
  /** The search endpoint and its key, or undefined until the owner stores one. A function for
   * the same reason the provider is: the row can change between turns. */
  search: () => SearchConfig | undefined;
  /** This agent's MCP tools for one turn, or undefined when no server is configured. A function
   * taking the agent, so a turn with nothing configured resolves no Linux user and starts no
   * process. A server runs as the agent and may write into its home, so one that is configured
   * waits on `homeReady`, the turn's workspace snapshot, before it starts. */
  mcp: (agent: Agent, homeReady: () => Promise<void>) => Promise<McpSession | undefined>;
  screen: Screen;
  runner: Runner;
  control: Control;
  maxWorkers: number;
  /** How the browser tool reaches Chromium; tests hand in a fake page and short timeouts. */
  connect?: Connect;
  browserTimings?: BrowserTimings;
  /** Fires when the owner stops the turn. */
  signal?: AbortSignal;
  /** Set when this turn is an idle pass: a narrower tool set, a guard and limits. */
  idle?: IdleTurn;
  /** Moves an agent to the name it asked for with set_name, once its turn is over. */
  rename?: ((agent: Agent, name: string) => Promise<void>) | undefined;
  /** Starts and stops a goal helper's desktop; without it add_helper is refused. */
  desktop?: DesktopOps | undefined;
  /** Hears what a permanent agent said at the end of a turn, and why one failed: the seam a
   * messaging channel hangs off. The thread it happened in is passed so the channel can decide
   * whether it is one the owner reads there. */
  deliver?:
    | ((agent: Agent, conversationId: number, text: string, kind: 'reply' | 'failure' | 'approval') => void)
    | undefined;
};

/** Writes the transition the moment it happens; the row, not this process, is the truth. */
function transition(db: Db, agent: Agent, to: AgentState): void {
  const from = findAgent(db, agent.name)?.state ?? agent.state;
  if (from === to) return;
  if (!canTransition(from, to)) throw new Error(`illegal transition ${from} -> ${to}`);
  setAgentState(db, agent.name, to);
  recordEvent(db, agent.id, 'state', { from, to });
}

function systemPrompt(
  agent: Agent,
  screen: Screen,
  home: string,
): string {
  const intro = [
    `You are ${agent.name}, an AI agent with your own Linux desktop on this machine.`,
    `The computer tool drives your ${screen.width}x${screen.height} X display; run_command runs`,
    'shell commands as your own Linux user, starting in your home directory; send_message writes',
    'to another agent, who works on it and replies to you later; spawn_task_worker hands a',
    'self-contained job to a throwaway worker that runs as you and reports its result back.',
    'Keep your files in ~/workspace. web_search finds pages and web_fetch reads one as text:',
    'reach for those first. When a page builds or filters its content with scripts, or needs',
    'your login, use the browser tool: it opens the URL in your own Chromium and returns the',
    'rendered text, and evaluate runs JavaScript in the page for links, forms and clicks.',
    'Take a screenshot only when you need to see the page; when curl, an API or a command',
    'line tool gets the same information, prefer it over clicking.',
    'When something you tried has no effect, such as a parameter a site ignores, stop after',
    'the second variation and find out what works instead: from what the response itself',
    'reports back, the requests the page makes, a web search, or doing it once in the browser.',
    'Take a screenshot when you need to see what is on screen. The owner sees none of them unless',
    'you pass show: true, which puts that screenshot inside your reply. Pass it only when the image',
    'itself is what the owner needs: they asked to see the screen, or the answer is something only a',
    'picture shows. Never pass it on a check, or to present a file you made: hand over the file.',
    'At most once a turn, as your last step, and say in your reply what it shows. Only your last',
    `${MAX_FULL_OBSERVATIONS} tool results are shown in full; older ones are shortened.`,
    'The moment you have what was asked for, answer: state the result and stop, rather than',
    'checking it again or polishing. When the data is imperfect, answer with the best result',
    'and say what is uncertain; the owner can ask for more. When you are done, reply in plain',
    'text: a reply with no tool call ends your turn and the owner reads it.',
    'The owner reads your reply in a chat app, where each paragraph shows as its own message.',
    'Write the way a person texts: short, casual messages of one thought each, separated by a',
    'blank line, two or three for most replies and a single one when that is all it takes. No',
    'preamble, no closing offer of more help, no headings. A list, a table or a code block stays',
    'one message. So does anything between two lines of ---: put those around something meant',
    'to be read as one piece, such as a story, a poem or a draft.',
    'The owner cannot reach your machine, so hand them every file you made for them as a card:',
    'write its path starting with ~/ alone on a line of its own, such as ~/workspace/report.xlsx,',
    'with no label, sentence or other path on that line, and one line per file. That line shows as',
    'a card they can open. A path inside a sentence shows only as a link, and a file outside your',
    'home cannot be opened at all, so save what you hand over in ~/workspace.',
    'Every message you are shown names who wrote it. When another agent writes to you, your',
    'final reply goes back to it on its own: answer it there, never with send_message. When an',
    'agent\'s answer to something you asked needs nothing more from you, carry on with what the',
    'owner wanted rather than answering it.',
  ].join(' ');
  return `${intro}\n\n${profilePrompt(agent.profile)}\n\n${home}`;
}

/**
 * The rules, memory, the skills index and the agent's own schedules, read once per turn rather than once
 * per step, so the system text every step of a turn is handed is byte-identical and the prompt
 * cache holds. A home that cannot be read costs the agent its memory for this turn, not the turn
 * itself; the rules and the schedules come from the database and are always there.
 */
async function homeTail(deps: LoopDeps, agent: Agent): Promise<string> {
  const schedules = schedulePrompt(listSchedules(deps.db, agent), readTimezone(deps.db));
  const standing =
    agent.parentId === undefined
      ? `${schedules}\n\n${triggerPrompt(deps.db, agent)}\n\n${goalPrompt(deps.db, agent)}`
      : schedules;
  const rules = rulesPrompt(readRules(deps.db, agent));
  try {
    const home = await loadHome(deps.exec, await agentTarget(deps.exec, agent));
    return `${rules}\n\n${homePrompt(home)}\n\n${standing}`;
  } catch (error) {
    log.error('home unreadable, running without memory', { agent: agent.name, error });
    return `${rules}\n\n${homePrompt({ memory: '', skills: [] })}\n\n${standing}`;
  }
}

/**
 * One turn's MCP tools. A server that cannot be reached costs the agent that server's tools; a
 * configuration that cannot be read at all costs it every one of them, and neither costs it the
 * turn — the rule the home load and the schedules already follow.
 */
async function mcpSession(deps: LoopDeps, agent: Agent, homeReady: () => Promise<void>): Promise<McpSession | undefined> {
  try {
    return await deps.mcp(agent, homeReady);
  } catch (error) {
    log.error('no MCP tools this turn', { agent: agent.name, error });
    return undefined;
  }
}

/**
 * The conversation as this agent sees it. Every message names who wrote it, and everything the
 * agent did not write itself is buffered until the transcript is between turns rather than
 * inside one: an assistant message with tool calls must be followed immediately by one tool
 * message per call id, so neither a screenshot nor another agent's message may land in between.
 * Another agent's tool traffic is dropped along with the calls that asked for it.
 *
 * Only the last `MAX_REPLAYED_IMAGES` screenshots are sent. The older ones stay in the
 * transcript as text saying they are no longer visible, so the agent knows the screen it is
 * reasoning about is stale rather than silently reasoning about a picture it can no longer see.
 * The tool result naming each one is never dropped: what the call did is small and is the only
 * record that it happened.
 *
 * A compacted thread replaces everything through `replay.throughId` with the summary standing in
 * for it. The summary is a message of its own after the system text rather than part of it, so
 * the system text a turn is handed stays what it was: only what is injected per turn moves.
 */
export function transcript(
  name: string,
  system: string,
  stored: readonly StoredMessage[],
  replay?: Replay,
): ProviderMessage[] {
  const out: ProviderMessage[] = [{ role: 'system', text: system }];
  let pending: ProviderMessage[] = [];
  if (replay !== undefined) {
    out.push({
      role: 'user',
      text: `Everything said in this conversation before this point, summarised:\n${replay.text}`,
    });
  }
  const kept =
    replay === undefined
      ? stored
      : stored.filter((message) => message.id > replay.throughId);
  const own = kept.filter((message) => message.sender === name && message.role === 'tool');
  // Screenshots and pictures the owner sent share one window: both are bytes in the request.
  const visible = new Set(
    kept
      .filter(
        (message) =>
          message.image !== undefined &&
          message.image.expired !== true &&
          (message.role === 'user' || (message.sender === name && message.role === 'tool')),
      )
      .slice(-MAX_REPLAYED_IMAGES)
      .map((message) => message.id),
  );
  const full = new Set(own.slice(-MAX_FULL_OBSERVATIONS).map((message) => message.id));
  const observation = (message: Message): string =>
    full.has(message.id) || message.content.length <= TRIMMED_OBSERVATION_CHARS
      ? message.content
      : message.content.slice(0, TRIMMED_OBSERVATION_CHARS) + TRIMMED_NOTE;

  const flush = () => {
    out.push(...pending);
    pending = [];
  };

  for (const message of kept) {
    if (message.sender !== name) {
      if (message.role === 'tool' || (message.content === '' && message.image === undefined)) continue;
      const text = `Message from ${message.sender ?? 'the owner'}:\n${message.content}`;
      if (message.image === undefined) {
        pending.push({ role: 'user', text });
      } else if (message.image.expired === true) {
        pending.push({ role: 'user', text: `${text}\n[the picture that came with this has expired and was deleted]` });
      } else if (visible.has(message.id)) {
        pending.push({ role: 'user', text: `${text}\n[with a picture]`, image: message.image });
      } else {
        pending.push({
          role: 'user',
          text: `${text}\n[the picture that came with this is no longer shown: only the last ${MAX_REPLAYED_IMAGES} images are kept in view]`,
        });
      }
      continue;
    }

    if (message.role === 'tool') {
      out.push({ role: 'tool', toolCallId: message.toolCallId ?? '', text: observation(message) });
      if (message.image !== undefined) {
        const call = message.toolCallId ?? '';
        pending.push(
          message.image.expired === true
            ? {
                role: 'user',
                text: `The screenshot from tool call ${call} has expired and was deleted. Take a new one to see the screen.`,
              }
            : visible.has(message.id)
            ? { role: 'user', text: `Screenshot from tool call ${call}.`, image: message.image }
            : {
                role: 'user',
                text:
                  `The screenshot from tool call ${call} is no longer shown: only the last ` +
                  `${MAX_REPLAYED_IMAGES} are kept in view. Take a new one to see the screen.`,
              },
        );
      }
      continue;
    }

    flush();
    out.push({
      role: 'assistant',
      text: message.content,
      toolCalls: message.toolCalls ?? [],
      ...(message.echo === undefined ? {} : { echo: message.echo }),
    });
  }

  flush();
  return out;
}

function clip(text: string): string {
  return text.length <= MAX_OBSERVATION_CHARS
    ? text
    : `${text.slice(0, MAX_OBSERVATION_CHARS)}\n[output truncated]`;
}

/**
 * What the agent is told a command did. Each stream is clipped on its own: clipping the joined
 * text would let a large stdout push stderr out of the observation entirely, which is exactly
 * where the reason a command failed lives.
 */
export function describe(result: CommandResult): string {
  const parts = [`exit code ${result.exitCode}${result.timedOut ? ' (timed out)' : ''}`];
  if (result.background) parts.push('started in the background');
  if (result.stdout !== '') parts.push(`stdout:\n${clip(result.stdout)}`);
  if (result.stderr !== '') parts.push(`stderr:\n${clip(result.stderr)}`);
  return parts.join('\n');
}

type Observation = { text: string; image?: Image; event: Record<string, unknown> };

/**
 * Who a tool call runs as. A task worker has no Linux user of its own: it runs as the agent
 * that spawned it, in the directory that agent made for it, which is why it needs no new
 * sudoers rule and no display.
 */
async function toolTarget(deps: LoopDeps, agent: Agent): Promise<AgentTarget> {
  if (agent.parentId === undefined) return agentTarget(deps.exec, agent);
  const parent = findAgentById(deps.db, agent.parentId);
  if (parent === undefined) throw new Error(`${agent.name} has no parent to run as`);
  const target = await agentTarget(deps.exec, parent);
  return { ...target, cwd: workerDir(target.home, agent.name), ...(hasOwnScreen(agent) ? { display: agent.display } : {}) };
}

/** Why no more workers may be spawned right now, or undefined. Live means neither `completed`
 * nor `failed`: those are rows, not loops. */
function cappedWorkers(deps: LoopDeps): string | undefined {
  const live = liveWorkers(deps.db).length;
  return live < deps.maxWorkers
    ? undefined
    : `at most ${deps.maxWorkers} task workers can be live at once (${live} right now); ` +
        'wait for one to report back';
}

/** The runaway guard `send_message` uses, applied to the other way an agent multiplies. A
 * worker's result is an agent-authored message like any other, so it counts here too. */
function cappedChain(db: Db, conversationId: number): string | undefined {
  return agentChain(db, [conversationId]) < MAX_AGENT_CHAIN
    ? undefined
    : `${MAX_AGENT_CHAIN} messages have passed between agents in this thread since the owner ` +
        'last spoke. Answer the owner instead.';
}

const refusal = (error: string): Observation => ({ text: `error: ${error}`, event: { ok: false, error } });

/** `helper` makes it a goal's screen worker: an Xvnc display of its own on the lead's user. */
async function spawnWorker(
  deps: LoopDeps,
  agent: Agent,
  conversationId: number,
  brief: string,
  helper?: { goalId: number; reason: string; desktop: DesktopOps },
): Promise<Observation> {
  const refused = (): string | undefined =>
    cappedWorkers(deps) ?? cappedChain(deps.db, conversationId) ?? deps.runner.atCapacity();
  const early = refused();
  if (early !== undefined) return refusal(early);

  // The directory comes first: a worker whose --chdir does not exist turns every command it
  // runs into a confusing error, and a row created before the mkdir failed would outlive it.
  const target = await agentTarget(deps.exec, agent);
  const name = nextWorkerName(deps.db, agent);
  if (name === undefined) return refusal(`no name is left for another worker of ${agent.name}`);
  const dir = workerDir(target.home, name);
  const made = await deps.exec('sudo', asAgent(target, ['mkdir', '-p', dir]));
  if (made.code !== 0) {
    const error = `could not create ${dir}: ${made.stderr.trim()}`;
    return { text: `error: ${error}`, event: { ok: false, error: 'no working directory' } };
  }

  // Asked again, and synchronous from here to the start: two agents spawning in overlapping
  // turns both passed the check above before either of them took a slot, and a spawn is
  // refused at the cap rather than queued.
  const late = refused();
  if (late !== undefined) return refusal(late);

  const display = helper === undefined ? undefined : nextDisplay(listAgents(deps.db).map((other) => other.display));
  const worker = insertWorker(deps.db, agent, name, conversationId, display);
  if (helper !== undefined && display !== undefined) {
    addHelperRow(deps.db, helper.goalId, worker, 'worker', helper.reason);
    const undo = async (error: string): Promise<Observation> => {
      await helper.desktop.stopDisplay(agent.name, display).catch(() => undefined);
      forgetAgent(deps.db, worker.name);
      return refusal(error);
    };
    try {
      await helper.desktop.ensure(agent.name, display, worker.name);
    } catch (error) {
      log.error('helper screen did not start', { worker: worker.name, display, error });
      return undo(`the helper's screen did not start: ${(error as Error).message}`);
    }
    // The await above let other turns take the last loop, and a spawn is refused at the cap.
    const full = deps.runner.atCapacity();
    if (full !== undefined) return undo(full);
  }
  const thread = conversationFor(deps.db, worker.id);
  appendMessage(deps.db, thread, {
    role: 'user',
    content: `${brief}\n\nYour working directory is ${dir}; every command you run starts there.`,
    sender: agent.name,
  });
  deps.runner.start(worker, thread);
  const screen = display === undefined ? '' : `, with its own screen :${display}`;
  return {
    text: `Task worker ${worker.name} is on it, in ${dir}${screen}. Its result arrives later as a message from it.`,
    event: { ok: true, worker: worker.name, dir, ...(helper === undefined ? {} : { helper: 'worker' }) },
  };
}

function updateGoal(deps: LoopDeps, agent: Agent, args: Record<string, unknown>): Observation | Promise<Observation> {
  if (isHelper(deps.db, agent)) return refusal('you are a helper on a goal; its lead keeps the plan');
  const update = parseGoalUpdate(args);
  if ('error' in update) return refusal(update.error);
  if (update.finish && deps.desktop === undefined) return refusal('goals cannot be finished here');
  const goal = applyGoalUpdate(deps.db, agent, update);
  if ('error' in goal) return refusal(goal.error);
  if (!update.finish || deps.desktop === undefined) {
    return { text: describeGoal(goal), event: { ok: true, goal: goal.id } };
  }
  return finishGoal({ db: deps.db, desktop: deps.desktop, runner: deps.runner }, goal.id).then((done) =>
    'error' in done
      ? refusal(`the rest is saved, but the goal is not finished: ${done.error}`)
      : { text: describeGoal(done), event: { ok: true, goal: done.id, finished: true } },
  );
}

async function addHelper(deps: LoopDeps, agent: Agent, conversationId: number, request: HelperRequest): Promise<Observation> {
  if (isHelper(deps.db, agent)) return refusal('a helper does not bring in helpers of its own; ask your lead');
  const goal = leadGoal(deps.db, agent, request.goal);
  if ('error' in goal) return refusal(goal.error);
  const desktop = deps.desktop;
  if (desktop === undefined) return refusal('helpers cannot be started here');
  if (helperCount(deps.db, goal.id) >= MAX_HELPERS) {
    return refusal(`goal ${goal.id} already has ${MAX_HELPERS} helpers`);
  }
  if (request.kind === 'worker') {
    return spawnWorker(deps, agent, conversationId, request.brief, { goalId: goal.id, reason: request.reason, desktop });
  }

  const capped = deps.runner.atCapacity();
  if (capped !== undefined) return refusal(capped);
  const name = nextHelperName(deps.db, agent, goal);
  if (!AGENT_NAME.test(name)) return refusal(`no name is left for a helper of ${agent.name}`);
  const helper = insertAgent(deps.db, name, agent.look === undefined ? {} : { look: agent.look });
  if (helper === undefined) return refusal(`${name} already exists`);
  setAgentCosmetics(deps.db, name, { profile: helperProfile(agent, goal, request.reason) });
  inheritFromLead(deps.db, agent, helper);
  addHelperRow(deps.db, goal.id, helper, 'agent', request.reason);
  const undo = async (error: string): Promise<Observation> => {
    await desktop.remove(helper.name).catch((error: unknown) => log.error('helper user would not go', { agent: helper.name, error }));
    deleteAgent(deps.db, helper);
    return refusal(error);
  };
  try {
    await desktop.ensure(helper.name, helper.display);
  } catch (error) {
    log.error('helper desktop did not start', { helper: name, error });
    return undo(`the helper's desktop did not start: ${(error as Error).message}`);
  }
  const full = deps.runner.atCapacity();
  if (full !== undefined) return undo(full);
  const thread = conversationFor(deps.db, helper.id);
  appendMessage(deps.db, thread, { role: 'user', content: request.brief, sender: agent.name, kind: 'request' });
  deps.runner.start(helper, thread, undefined, 'request');
  return {
    text:
      `Temporary agent ${name} is on it, with its own Linux user and desktop. Its reply arrives later as a message ` +
      'from it; write to it with send_message.',
    event: { ok: true, helper: 'agent', agent: name, conversationId: thread },
  };
}

/**
 * Runs one tool call. A tool that refuses or fails becomes an observation the agent can react
 * to, not an end to the run: only the model itself failing does that.
 */
async function dispatch(
  deps: LoopDeps,
  agent: Agent,
  call: ToolCall,
  conversationId: number,
  mcp: McpSession | undefined,
): Promise<Observation> {
  let args: Record<string, unknown>;
  try {
    const parsed: unknown = JSON.parse(call.arguments);
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new Error('arguments must be a JSON object');
    }
    args = parsed as Record<string, unknown>;
  } catch (error) {
    const text = `error: could not read the arguments (${(error as Error).message})`;
    return { text, event: { ok: false, error: 'malformed arguments' } };
  }

  if (call.name === 'computer') {
    const action = parseComputerAction(args, deps.screen);
    if ('error' in action) {
      return { text: `error: ${action.error}`, event: { ok: false, error: action.error } };
    }
    const target = await toolTarget(deps, agent);
    // One gate, at the seam every X action goes through; the `/computer` route holds the other
    // half. A refusal is an observation like any other, so the turn ends rather than fails.
    if (deps.control.held(target.display)) {
      return { text: `error: ${CONTROL_REFUSAL}`, event: { ok: false, error: CONTROL_HELD } };
    }
    const result = await performComputerAction(deps.exec, target, action, deps.screen);
    if (result.image !== undefined) {
      return {
        text: 'Screenshot taken; it is in the next message.',
        image: result.image,
        event: { ok: true, action: action.action, imageBytes: result.image.base64.length },
      };
    }
    return {
      text: result.text ?? `${action.action} done`,
      event: { ok: true, action: action.action },
    };
  }

  if (call.name === 'run_command') {
    const request = parseCommand(args);
    if ('error' in request) {
      return { text: `error: ${request.error}`, event: { ok: false, error: request.error } };
    }
    const refused = guardCommand(deps.db, agent, request.command);
    if (refused !== undefined) {
      return { text: `error: ${refused}`, event: { ok: false, error: 'refused by the rules' } };
    }
    const target = await toolTarget(deps, agent);
    // The one tool a stop reaches into: a command can run for minutes, and an owner who
    // pressed stop is not waiting that out.
    const result = await runCommand(deps.exec, target, request, deps.signal);
    return {
      text: describe(result),
      event: { ok: true, exitCode: result.exitCode, timedOut: result.timedOut },
    };
  }

  if (call.name === 'send_message') {
    const request = parseSendMessage(args);
    if ('error' in request) {
      return { text: `error: ${request.error}`, event: { ok: false, error: request.error } };
    }
    // A task worker is an agent row, but it is nobody's correspondent: it reads one brief,
    // does the job and answers its parent. Writing to one would start a turn it cannot use.
    const target = findAgent(deps.db, request.to);
    if (target === undefined || target.id === agent.id || isWorker(target)) {
      const error =
        target === undefined || isWorker(target)
          ? `no agent named ${request.to}`
          : 'you cannot message yourself';
      return { text: `error: ${error}`, event: { ok: false, error } };
    }

    const conversationId = conversationFor(deps.db, target.id);
    if (agentChain(deps.db, [conversationFor(deps.db, agent.id), conversationId]) >= MAX_AGENT_CHAIN) {
      const error =
        `you and ${target.name} have passed ${MAX_AGENT_CHAIN} messages back and forth without ` +
        'the owner. Answer the owner instead.';
      return { text: `error: ${error}`, event: { ok: false, error: 'chain too long' } };
    }

    appendMessage(deps.db, conversationId, {
      role: 'user',
      content: request.text,
      sender: agent.name,
      kind: 'request',
    });
    deps.runner.start(target, conversationId, undefined, 'request');
    return {
      text: `Delivered to ${target.name}, which is now working on it. Its reply arrives later.`,
      event: { ok: true, to: target.name, conversationId },
    };
  }

  if (call.name === 'spawn_task_worker') {
    const request = parseSpawnWorker(args);
    if ('error' in request) {
      return { text: `error: ${request.error}`, event: { ok: false, error: request.error } };
    }
    return spawnWorker(deps, agent, conversationId, request.brief);
  }

  if (call.name === UPDATE_GOAL) return updateGoal(deps, agent, args);

  if (call.name === ADD_HELPER) {
    const request = parseAddHelper(args);
    if ('error' in request) return { text: `error: ${request.error}`, event: { ok: false, error: request.error } };
    return addHelper(deps, agent, conversationId, request);
  }

  // The two web tools are the only ones a task worker shares with a permanent agent. Neither
  // needs a home or a display, which is the only reason the rest are withheld, and "go read
  // this and report" is the job a worker exists for.
  if (call.name === 'web_search') {
    const request = parseWebSearch(args);
    if ('error' in request) {
      return { text: `error: ${request.error}`, event: { ok: false, error: request.error } };
    }
    const config = deps.search();
    if (config === undefined) {
      return { text: `error: ${NO_SEARCH_KEY}`, event: { ok: false, error: 'no search key' } };
    }
    const found = await webSearch(config, request.query);
    if ('error' in found) {
      // The agent gets the endpoint's own words, stripped of the key by `webSearch`; the event
      // gets none of them, because an echoed request body has no business in the log.
      return { text: `error: ${found.error}`, event: { ok: false, error: 'search failed' } };
    }
    return {
      text: searchPrompt(request.query, found.results),
      event: { ok: true, host: new URL(config.url).host, results: found.results.length },
    };
  }

  if (call.name === 'web_fetch') {
    const request = parseWebFetch(args);
    if ('error' in request) {
      return { text: `error: ${request.error}`, event: { ok: false, error: request.error } };
    }
    const page = await fetchPage(request.url, MAX_OBSERVATION_CHARS);
    if ('error' in page) {
      return { text: `error: ${page.error}`, event: { ok: false, error: page.error } };
    }
    return {
      text: page.text === '' ? 'The page has no readable text.' : page.text,
      // The host and the status, never the page: an event is a trace, not a second transcript.
      event: { ok: true, host: new URL(page.url).host, status: page.status, chars: page.text.length },
    };
  }

  // A worker shares its parent's Chromium, and two loops steering one tab is the same problem
  // as two loops on one mouse, so like the computer tool this is a permanent agent's only.
  if (call.name === 'browser' && agent.parentId === undefined) {
    const request = parseBrowserAction(args);
    if ('error' in request) {
      return { text: `error: ${request.error}`, event: { ok: false, error: request.error } };
    }
    const target = await agentTarget(deps.exec, agent);
    const page = await browse(deps.exec, target, deps.connect ?? cdpConnect, request, MAX_OBSERVATION_CHARS, deps.browserTimings);
    const restarted = page.restarted === true ? { restarted: true } : {};
    if ('error' in page) {
      const hung = page.hung === true ? { hung: true } : {};
      return {
        text: page.hung === true ? `error: ${page.error}. The owner has been asked to look at it; stop here.` : `error: ${page.error}`,
        event: { ok: false, action: request.action, error: page.error, ...restarted, ...hung },
      };
    }
    return {
      text: page.text,
      event: {
        ok: true,
        action: request.action,
        ...(page.url === '' ? {} : { host: new URL(page.url).host }),
        chars: page.text.length,
        ...restarted,
      },
    };
  }

  // A task worker is never offered this and falls through to the unknown-tool answer: it has no
  // Linux user, no home and no memory of its own, and it knows only the brief it was given.
  if (call.name === 'remember' && agent.parentId === undefined) {
    const request = parseRemember(args);
    if ('error' in request) {
      return { text: `error: ${request.error}`, event: { ok: false, error: request.error } };
    }
    const written = await remember(deps.exec, await agentTarget(deps.exec, agent), request);
    if ('error' in written) {
      return { text: `error: ${written.error}`, event: { ok: false, error: 'memory not written' } };
    }
    return {
      text: `Written to ${written.path}.`,
      event: { ok: true, scope: request.scope },
    };
  }

  // The questions travel in the call's own arguments, which the transcript already stores: the
  // client reads them from there and answers as an ordinary owner message. Nothing is queued.
  if (call.name === 'ask_owner' && agent.parentId === undefined) {
    const questions = parseAskOwner(args);
    if ('error' in questions) {
      return { text: `error: ${questions.error}`, event: { ok: false, error: questions.error } };
    }
    return {
      text:
        `Asked the owner ${questions.length} question${questions.length === 1 ? '' : 's'}. ` +
        'Your turn ends here; the answers arrive as their next message.',
      event: { ok: true, questions: questions.length },
    };
  }

  // Like `ask_owner`, the reason travels in the call's own arguments; Needs you and the chat
  // card read it from there, and giving the screen back is the owner's next message.
  if (call.name === 'ask_for_hands' && agent.parentId === undefined) {
    const reason = parseHandsReason(args);
    if (typeof reason !== 'string') {
      return { text: `error: ${reason.error}`, event: { ok: false, error: reason.error } };
    }
    return {
      text: 'Asked the owner to take the screen. Your turn ends here; you hear from them when they give it back.',
      event: { ok: true },
    };
  }

  // The daemon reads the form, not the model, so the origin the owner is shown is the page's own.
  if (call.name === 'request_form' && agent.parentId === undefined) {
    const reason = parseHandsReason(args);
    if (typeof reason !== 'string') {
      return { text: `error: ${reason.error}`, event: { ok: false, error: reason.error } };
    }
    const form = await captureForm(
      deps.db,
      deps.connect ?? cdpConnect,
      { agentId: agent.id, display: agent.display, conversationId, callId: call.id, reason },
      deps.browserTimings,
    );
    if ('error' in form) return { text: `error: ${form.error}`, event: { ok: false, error: form.error } };
    const fields = form.fields.map((f) => f.label).join(', ');
    const screen = form.unfillable.map((f) => f.label).join(', ');
    return {
      text:
        `Asked the owner to fill the form on ${form.origin}` +
        (fields === '' ? '' : `: ${fields}`) +
        (screen === '' ? '.' : `. They do these on your screen: ${screen}.`) +
        ' Your turn ends here; you hear from them when it is filled.',
      event: { ok: true, origin: form.origin, fields: form.fields.length, unfillable: form.unfillable.length },
    };
  }

  // Not now: this turn runs as the current user, and the desktop has to be down for the Linux
  // user to move. The runner does it after the turn, so the check here is only the name.
  if (call.name === 'set_name' && agent.parentId === undefined) {
    const name = args['name'];
    const error =
      typeof name !== 'string' || !AGENT_NAME.test(name)
        ? `name must match ${AGENT_NAME.source}`
        : name === agent.name
          ? `you are already ${name}`
          : findAgent(deps.db, name) !== undefined
            ? `${name} is taken`
            : deps.rename === undefined
              ? 'renaming is not available here'
              : workersBusy(deps.db, deps.runner, agent)
                ? 'a task worker of yours is still running as you; wait for its result first'
                : undefined;
    if (error !== undefined) return { text: `error: ${error}`, event: { ok: false, error } };
    return {
      text: `You will be ${name} from your next turn on; finish this one as ${agent.name}.`,
      event: { ok: true, name },
    };
  }

  if (call.name === 'set_profile' && agent.parentId === undefined) {
    const profile = parseProfile(args);
    if (typeof profile !== 'string') {
      return { text: `error: ${profile.error}`, event: { ok: false, error: profile.error } };
    }
    setAgentCosmetics(deps.db, agent.name, { profile });
    return {
      text: 'Profile saved. It is in your system prompt from your next turn on.',
      event: { ok: true, chars: profile.length },
    };
  }

  // A worker asking the owner would be asking about a machine it knows nothing about: it has
  // one brief and no view of the agents around it.
  if (call.name === 'request_deletion' && agent.parentId === undefined) {
    const request = parseDeletionRequest(deps.db, agent, args);
    if ('error' in request) {
      return { text: `error: ${request.error}`, event: { ok: false, error: request.error } };
    }
    return standingRequest(deps, agent, conversationId, call.id, {
      ...request,
      target: request.kind === 'conversation' ? String(conversationId) : request.target,
    });
  }

  if (call.name === 'request_approval' && agent.parentId === undefined) {
    const request = parseApprovalRequest(args);
    if ('error' in request) {
      return { text: `error: ${request.error}`, event: { ok: false, error: request.error } };
    }
    return standingRequest(deps, agent, conversationId, call.id, request);
  }

  if (call.name === PROPOSE_TRIGGER && agent.parentId === undefined) {
    const proposal = parseTriggerProposal(args);
    const created = 'error' in proposal ? proposal : proposeTrigger(deps.db, agent, proposal, Date.now());
    if ('error' in created) return { text: `error: ${created.error}`, event: { ok: false, error: created.error } };
    return {
      text:
        `Proposed as trigger ${created.id}. ` +
        (created.kind === 'imap' ? 'The owner enters the mailbox login in a form you never see. ' : '') +
        'Nothing fires until the owner turns it on; ask them to, and once it is on, offer to test it together.',
      event: { ok: true, trigger: created.id, kind: created.kind },
    };
  }

  // Scheduling is a permanent agent's business too: a worker is one job that reports back and
  // is then never started again, so a standing job of its own would fire into nothing.
  if (SCHEDULE_TOOLS.has(call.name) && agent.parentId === undefined) {
    return schedule(deps, agent, call.name, args);
  }

  // An MCP server's tool. The routing is the session's own map rather than a split on the name:
  // a server called `a__b` or a tool called `get__all` makes the namespace ambiguous to parse
  // and never ambiguous to look up.
  if (call.name.startsWith(MCP_PREFIX)) {
    if (mcp === undefined) {
      const error = 'no MCP server is connected for this turn';
      return { text: `error: ${error}`, event: { ok: false, error } };
    }
    const result = await mcp.call(call.name, args, MAX_OBSERVATION_CHARS);
    if ('error' in result) {
      return { text: `error: ${result.error}`, event: { ok: false, error: 'mcp call failed' } };
    }
    return {
      text: result.text === '' ? 'The tool returned nothing.' : result.text,
      // The size, never the answer: an event is a trace, not a second transcript.
      event: { ok: true, chars: result.text.length },
    };
  }

  return { text: `error: no tool named ${call.name}`, event: { ok: false, error: 'unknown tool' } };
}

/** What an idle pass may call. Everything that sends, spends, clicks or runs someone else's
 * code (computer, browser, web, MCP, messages, workers) is withheld. */
const IDLE_TOOLS = new Set([
  'run_command',
  'remember',
  'schedule_task',
  'list_schedules',
  'request_deletion',
  'request_approval',
  LEAVE_NOTE,
]);

function idleToolDefs() {
  return [
    commandToolDef(),
    rememberToolDef(),
    scheduleTaskToolDef(),
    listSchedulesToolDef(),
    requestDeletionToolDef(),
    requestApprovalToolDef(),
    leaveNoteToolDef(),
  ];
}

/** An idle pass's tool call: refused unless it is one of the four outputs or a read. */
async function idleDispatch(
  deps: LoopDeps,
  agent: Agent,
  call: ToolCall,
  conversationId: number,
  idle: IdleTurn,
): Promise<Observation> {
  const refuse = (error: string): Observation => ({
    text: `error: ${error}`,
    event: { ok: false, error: 'refused during idle work' },
  });
  if (!IDLE_TOOLS.has(call.name)) {
    return refuse(`${call.name} is not available during idle work, which never sends, deletes, spends or installs`);
  }
  let args: Record<string, unknown>;
  try {
    args = JSON.parse(call.arguments) as Record<string, unknown>;
    if (args === null || typeof args !== 'object' || Array.isArray(args)) throw new Error();
  } catch {
    return dispatch(deps, agent, call, conversationId, undefined);
  }

  if (call.name === LEAVE_NOTE) {
    const text = parseNote(args);
    if (typeof text !== 'string') return { text: `error: ${text.error}`, event: { ok: false, error: text.error } };
    addIdleOutput(deps.db, idle.passId, { kind: 'note', text });
    return { text: 'Left for the owner to read in the morning.', event: { ok: true } };
  }
  if (call.name === 'schedule_task') {
    const request = parseSchedule(args);
    const error =
      'error' in request ? request.error : nextRun(request.cron, Date.now()) === undefined ? `${request.cron} has no next run` : undefined;
    if (error !== undefined || 'error' in request) return { text: `error: ${error}`, event: { ok: false, error } };
    addIdleOutput(deps.db, idle.passId, { kind: 'routine', cron: request.cron, prompt: request.prompt });
    return {
      text: 'Suggested to the owner. It is not scheduled: it runs only once they turn it on.',
      event: { ok: true, suggested: true },
    };
  }
  if (call.name === 'run_command') {
    const command = args['command'];
    const refused = typeof command === 'string' ? idleCommandRefusal(command) : undefined;
    if (refused !== undefined) return refuse(refused);
  }
  if (call.name === 'remember' && args['scope'] !== 'lasting') {
    return refuse('during idle work only lasting memory is written, so the owner can undo it');
  }
  if (call.name === 'request_approval' && args['category'] !== 'delete_files') {
    return refuse('during idle work the only thing to ask for is a cleanup: category delete_files, or request_deletion');
  }

  const observation = await dispatch(deps, agent, call, conversationId, undefined);
  const approval = observation.event['approval'];
  if (observation.event['ok'] === true && typeof approval === 'number') {
    addIdleOutput(deps.db, idle.passId, { kind: 'cleanup', approvalId: approval });
  }
  return observation;
}

function standingRequest(
  deps: LoopDeps,
  agent: Agent,
  conversationId: number,
  callId: string,
  request: ApprovalRequest,
): Observation {
  if (pendingCount(deps.db) >= MAX_PENDING_APPROVALS) {
    const error = `${MAX_PENDING_APPROVALS} requests are already waiting for the owner`;
    return { text: `error: ${error}`, event: { ok: false, error } };
  }
  const asked = insertApproval(deps.db, agent, conversationId, request, callId);
  recordEvent(deps.db, agent.id, 'approval', {
    asked: asked.id,
    kind: asked.kind,
    category: asked.category,
    target: asked.target,
  });
  deps.deliver?.(agent, conversationId, `Asks to ${describeApproval(asked)}: ${asked.reason}`, 'approval');
  const nothingYet = asked.kind === 'action' ? 'Do not do it yet.' : 'Nothing has been deleted.';
  return {
    text:
      `Request ${asked.id} to ${describeApproval(asked)} is waiting for the owner, shown to them ` +
      `in this thread and in Needs you. ${nothingYet} The answer arrives here as a message; ` +
      'carry on with the rest of your work, or end your turn.',
    event: { ok: true, approval: asked.id, kind: asked.kind, category: asked.category, target: asked.target },
  };
}

const SCHEDULE_TOOLS = new Set(['schedule_task', 'list_schedules', 'pause_schedule', 'cancel_schedule']);

/** The four schedule tools. Every one of them looks the row up as this agent's, so an id the
 * model guessed is a refusal rather than another agent's job. */
function schedule(
  deps: LoopDeps,
  agent: Agent,
  name: string,
  args: Record<string, unknown>,
): Observation {
  if (name === 'list_schedules') {
    const held = listSchedules(deps.db, agent);
    return { text: schedulePrompt(held, readTimezone(deps.db)), event: { ok: true, schedules: held.length } };
  }

  if (name === 'schedule_task') {
    const request = parseSchedule(args);
    if ('error' in request) {
      return { text: `error: ${request.error}`, event: { ok: false, error: request.error } };
    }
    const created = insertSchedule(deps.db, agent, request, Date.now());
    if ('error' in created) {
      return { text: `error: ${created.error}`, event: { ok: false, error: created.error } };
    }
    return {
      text: `Scheduled as ${created.id}; it next runs at ${new Date(created.nextRunAt).toISOString()}.`,
      event: { ok: true, schedule: created.id, cron: created.cron },
    };
  }

  const id = parseScheduleId(args);
  if (typeof id !== 'number') return { text: `error: ${id.error}`, event: { ok: false, error: id.error } };
  const found = findSchedule(deps.db, agent, id);
  if (found === undefined) {
    const error = `you have no schedule ${id}`;
    return { text: `error: ${error}`, event: { ok: false, error } };
  }

  if (name === 'cancel_schedule') {
    deleteSchedule(deps.db, found);
    return { text: `Schedule ${id} is gone.`, event: { ok: true, schedule: id } };
  }

  const paused = args['paused'];
  if (typeof paused !== 'boolean') {
    const error = 'paused must be true or false';
    return { text: `error: ${error}`, event: { ok: false, error } };
  }
  const updated = setPaused(deps.db, found, paused, Date.now());
  return {
    text: paused
      ? `Schedule ${id} is paused and will not fire until you start it again.`
      : `Schedule ${id} is running again; it next runs at ${new Date(updated.nextRunAt).toISOString()}.`,
    event: { ok: true, schedule: id, paused },
  };
}

/** What a tool call looks like in the event log: what was asked for, never why. */
function summarise(call: ToolCall): Record<string, unknown> {
  let args: Record<string, unknown> = {};
  try {
    args = JSON.parse(call.arguments) as Record<string, unknown>;
  } catch {
    // A malformed call still deserves an event; dispatch turns it into an observation.
  }
  const action = args['action'];
  const command = args['command'];
  return {
    callId: call.id,
    tool: call.name,
    ...(typeof action === 'string' ? { action } : {}),
    ...(typeof command === 'string' ? { command } : {}),
  };
}

const STATE_FOR_TOOL: Record<string, AgentState> = {
  computer: 'using_computer',
  run_command: 'using_terminal',
};

export const WORKER_FAILED = 'I could not finish the job';
export const RUN_FAILED = 'I could not finish this turn';
export const STOPPED = 'I was stopped here by the owner and did not finish.';
const NOTHING_TO_REPORT = 'I finished, but the model answered with nothing.';
export const CUT_OFF = "\n\n[cut off: this reply reached the model's output token limit]";
export const CALL_CUT_OFF =
  'error: your reply was cut off at the output token limit before this call was complete, so it ' +
  'was not run. Ask again with shorter arguments, or split the work into smaller steps.';
export const CUT_OFF_AGAIN = "the model's reply was cut off at its output token limit a second time this turn";

/**
 * A worker's last word is a message to its parent, in the thread the parent was in when it
 * spawned it. Delivery is the messaging path and nothing else: a parent that is mid-turn picks
 * the row up through the same drain a peer's message goes through, so a result that lands at a
 * busy moment waits rather than being lost.
 */
function report(deps: LoopDeps, worker: Agent, parent: Agent, text: string): void {
  const conversationId = worker.parentConversationId ?? conversationFor(deps.db, parent.id);
  appendMessage(deps.db, conversationId, { role: 'user', content: text, sender: worker.name });
  deps.runner.start(parent, conversationId, undefined, 'report');
}

/**
 * A turn's last word goes back to every agent whose request it covered, into that agent's own
 * thread. A reply is never a request, so the agent it wakes answers the owner, not this one.
 */
function answerRequests(deps: LoopDeps, agent: Agent, owed: readonly { id: number; sender: string }[], text: string): void {
  if (owed.length === 0) return;
  for (const name of new Set(owed.map((request) => request.sender))) {
    const asker = findAgent(deps.db, name);
    if (asker === undefined || isWorker(asker)) continue;
    const thread = conversationFor(deps.db, asker.id);
    appendMessage(deps.db, thread, { role: 'user', content: text, sender: agent.name, kind: 'reply' });
    deps.runner.start(asker, thread, undefined, 'reply');
  }
  markAnswered(deps.db, agent.id, owed.at(-1)!.id);
}

/** How long a stopped turn waits for its killed snapshot to exit before it lets go of the agent. */
const STOPPED_SNAPSHOT_GRACE_MS = 2_000;

/** Settles with `work`, or rejects with the stop as soon as `signal` fires. */
function untilStopped(work: Promise<void>, signal: AbortSignal | undefined): Promise<void> {
  if (signal === undefined) return work;
  if (signal.aborted) return Promise.reject(signal.reason as Error);
  return new Promise((resolve, reject) => {
    const stopped = () => reject(signal.reason as Error);
    signal.addEventListener('abort', stopped, { once: true });
    void work.then(() => {
      signal.removeEventListener('abort', stopped);
      resolve();
    });
  });
}

function within(work: Promise<void>, ms: number): Promise<void> {
  let timer: NodeJS.Timeout | undefined;
  const elapsed = new Promise<void>((done) => {
    timer = setTimeout(done, ms);
  });
  return Promise.race([work, elapsed]).finally(() => clearTimeout(timer));
}

/**
 * One turn: think, act, observe, repeat until the model answers without asking for a tool.
 * In-process and async; everything it decides is written down as it happens, so a reader — or
 * a later daemon — sees the same history this loop does.
 */
export async function runAgent(
  deps: LoopDeps,
  agent: Agent,
  conversationId: number,
): Promise<void> {
  const { db } = deps;
  const parent = agent.parentId === undefined ? undefined : findAgentById(db, agent.parentId);
  // A worker shares its parent's X display, so giving it the computer tool would put two loops
  // on one mouse. It gets the terminal and nothing else, and it cannot spawn workers of its own.
  const builtin =
    deps.idle !== undefined
      ? idleToolDefs()
      : parent === undefined
      ? [
          computerToolDef(deps.screen),
          commandToolDef(),
          sendMessageToolDef(),
          spawnWorkerToolDef(),
          rememberToolDef(),
          scheduleTaskToolDef(),
          listSchedulesToolDef(),
          pauseScheduleToolDef(),
          cancelScheduleToolDef(),
          webSearchToolDef(),
          webFetchToolDef(),
          browserToolDef(),
          requestApprovalToolDef(),
          requestDeletionToolDef(),
          askOwnerToolDef(),
          askForHandsToolDef(),
          requestFormToolDef(),
          proposeTriggerToolDef(),
          updateGoalToolDef(),
          addHelperToolDef(),
          setProfileToolDef(),
          setNameToolDef(),
        ]
      : hasOwnScreen(agent)
      ? [computerToolDef(deps.screen), commandToolDef(), webSearchToolDef(), webFetchToolDef()]
      : [commandToolDef(), webSearchToolDef(), webFetchToolDef()];
  // Not awaited before the first model call, only before anything that can write into the home:
  // every tool call and the MCP start. Restoring files relies on the snapshot showing the home
  // as it was before this turn touched it.
  let snapshotted = false;
  const snapshot =
    parent === undefined
      ? snapshotWorkspace(deps.exec, agent, lastMessageId(db), Date.now(), deps.signal).finally(() => {
          snapshotted = true;
        })
      : undefined;
  const homeReady = (): Promise<void> =>
    snapshot === undefined || snapshotted ? Promise.resolve() : untilStopped(snapshot, deps.signal);
  // The row, not the argument: the profile is written mid-turn by set_profile, and the next
  // turn's prompt has to carry it.
  const system =
    parent === undefined
      ? systemPrompt(
          findAgent(db, agent.name) ?? agent,
          deps.screen,
          await homeTail(deps, agent),
        )
      : workerPrompt(agent, parent.name, helperGoal(db, agent));
  // Anything that lands after this belongs to the next turn. Splicing an arrival into a turn
  // already under way would answer it halfway through someone else's question; the runner
  // starts a fresh turn for it before it lets go of the agent.
  const history = listMessages(db, conversationId);
  const since = history.at(-1)?.id ?? 0;
  let seen = since;
  const started = (message: Message) => message.id <= since || message.sender === agent.name;
  const answers = parent === undefined && deps.idle === undefined;
  const owed = answers ? owedRequests(db, agent.id, conversationId, since) : [];
  const lastOwn = history.findLast((message) => message.sender === agent.name)?.id ?? 0;
  const requestIds = new Set(owed.map((request) => request.id));
  // Asked only by other agents: the answer goes back to them, and the owner reads it in the
  // thread without a push on top of the one the asking agent's own answer will send.
  const onlyAgentsAsked =
    owed.length > 0 &&
    history.every((message) => message.id <= lastOwn || message.role !== 'user' || requestIds.has(message.id));
  // Decided here with the system text rather than between steps, for the same reason: every
  // step of this turn is handed the same request head, and the summariser runs at most once.
  const usage = { promptTokens: 0, completionTokens: 0 };
  let metered = false;
  let summaries = 0;
  const meter: Meter = (spent) => {
    if (spent === undefined) return;
    metered = true;
    usage.promptTokens += spent.promptTokens;
    usage.completionTokens += spent.completionTokens;
    deps.idle?.spent?.(usage.promptTokens + usage.completionTokens);
  };
  const summarised: Meter = (spent) => {
    summaries += 1;
    meter(spent);
  };
  // The budget belongs to the model that answers, which "Use backup model" can change mid-turn.
  let budgetModel = deps.idle?.modelId ?? modelIdFor(db, agent);
  let budget = compactionBudget(contextWindowFor(db, agent, budgetModel));
  const follow = (modelId: number | undefined): boolean => {
    if (modelId === undefined || modelId === budgetModel) return false;
    budgetModel = modelId;
    budget = compactionBudget(contextWindowFor(db, agent, modelId));
    return true;
  };
  let switched = false;
  let replay = await compact(deps, agent, conversationId, system, history, budget, summarised);
  let shrunk = false;
  let cutOffs = 0;
  // Connected here, with the system text and the replay, for the reason they are: every step of
  // this turn is handed the same tool list, so the request head the prompt cache keys on does
  // not change between steps. A worker gets none of them — it has no Linux user of its own, so a
  // stdio server would run as its parent, and it is one job that is never started again.
  const mcp =
    parent === undefined && deps.idle === undefined && deps.signal?.aborted !== true
      ? await mcpSession(deps, agent, homeReady)
      : undefined;
  const tools = mcp === undefined ? builtin : [...builtin, ...mcp.tools];
  let wrote = false;
  let spawned = false;
  let refused = false;
  let asked = false;
  let stuck = false;
  let hands: string | undefined;
  let formOn: string | undefined;
  let rename: string | undefined;
  let steps = 0;
  /** Where a finished turn stands: waiting on whoever it handed work to, else on the owner. */
  const endState = (): AgentState =>
    spawned ? 'waiting_for_task_worker' : wrote ? 'waiting_for_agent' : 'waiting_for_user';
  /**
   * The owner pulled the plug. Every call in the last reply already has its result — the check
   * sits between steps, never between a call and its answer — so the transcript is one the
   * next turn can be built on. A permanent agent waits for the owner who stopped it; a worker
   * reports the stop as the failure its parent is waiting on.
   */
  const halt = (): void => {
    appendMessage(db, conversationId, { role: 'assistant', content: STOPPED, sender: agent.name });
    recordEvent(db, agent.id, 'stop', {});
    if (parent === undefined) {
      transition(db, agent, 'waiting_for_user');
    } else {
      transition(db, agent, 'failed');
      report(deps, agent, parent, `${WORKER_FAILED}: stopped by the owner`);
    }
  };

  try {
    for (let step = 0; step < MAX_STEPS; step += 1) {
      transition(db, agent, 'thinking');
      if (deps.signal?.aborted) return halt();
      // Rows are never edited and mid-turn deletes are refused, so reading only new ones is exact.
      const fresh = listMessages(db, conversationId, seen);
      seen = fresh.at(-1)?.id ?? seen;
      history.push(...fresh.filter(started));
      if (switched) {
        switched = false;
        if (projectedChars(transcript(agent.name, system, history, replay)) > budget.transcript) {
          replay = (await summariseHead(deps, agent, conversationId, system, history, budget, since, summarised)) ?? replay;
          if (deps.signal?.aborted) return halt();
        }
      }
      let reply: ChatReply;
      try {
        reply = await deps.provider(
          transcript(agent.name, system, history, replay),
          tools,
          (partial) => live.set(agent.id, partial),
          deps.signal,
        );
      } catch (error) {
        // Nothing was stored for this step: the reply never arrived, so there is no call to
        // answer and the history ends at the last complete exchange.
        if (deps.signal?.aborted) return halt();
        // The window estimate was wrong, or the turn grew past it. Once a turn: compact harder,
        // between turns only, and ask the same step again. A second overflow fails the turn.
        if (!shrunk && error instanceof ProviderError && error.overflow) {
          shrunk = true;
          follow(error.modelId);
          log.info('context overflow, compacting and asking again', { agent: agent.name, conversationId });
          const smaller = await summariseHead(
            deps,
            agent,
            conversationId,
            system,
            history,
            overflowBudget(budget),
            since,
            summarised,
          );
          if (deps.signal?.aborted) return halt();
          if (smaller !== undefined) {
            replay = smaller;
            step -= 1;
            continue;
          }
        }
        throw error;
      } finally {
        live.delete(agent.id);
      }
      steps += 1;
      meter(reply.usage);
      switched = follow(reply.modelId);
      // A reply cut off at the output token limit: its text is kept and marked, and a tool call
      // in it is never run, since its arguments are whatever the model got out before the cut.
      const cutOff = reply.finish === 'length';
      const text = cutOff && reply.toolCalls.length === 0 ? `${reply.text}${CUT_OFF}` : reply.text;
      appendMessage(db, conversationId, {
        role: 'assistant',
        content: text,
        sender: agent.name,
        ...(reply.toolCalls.length === 0
          ? {}
          : { toolCalls: cutOff ? reply.toolCalls.map((call) => ({ ...call, arguments: '{}' })) : reply.toolCalls }),
        ...(reply.echo === undefined ? {} : { echo: reply.echo }),
      });

      if (reply.toolCalls.length === 0) {
        if (parent !== undefined) {
          transition(db, agent, 'completed');
          report(deps, agent, parent, text.trim() === '' ? NOTHING_TO_REPORT : text);
          return;
        }
        const ending = endState();
        transition(db, agent, ending);
        if (ending === 'waiting_for_user') {
          answerRequests(deps, agent, owed, text.trim() === '' ? NOTHING_TO_REPORT : text);
        }
        if (!onlyAgentsAsked) deps.deliver?.(agent, conversationId, text, 'reply');
        return;
      }

      if (cutOff) {
        for (const call of reply.toolCalls) {
          recordEvent(db, agent.id, 'tool_call', summarise(call));
          appendMessage(db, conversationId, { role: 'tool', content: CALL_CUT_OFF, sender: agent.name, toolCallId: call.id });
          recordEvent(db, agent.id, 'tool_result', { callId: call.id, ok: false, error: 'cut off' });
        }
        cutOffs += 1;
        if (cutOffs > 1) throw new Error(CUT_OFF_AGAIN);
      }

      for (const call of cutOff ? [] : reply.toolCalls) {
        recordEvent(db, agent.id, 'tool_call', summarise(call));
        const acting = Object.hasOwn(STATE_FOR_TOOL, call.name) ? STATE_FOR_TOOL[call.name] : undefined;
        if (acting !== undefined) transition(db, agent, acting);
        const observation: Observation = await homeReady()
          .then(() =>
            deps.idle === undefined
              ? dispatch(deps, agent, call, conversationId, mcp)
              : idleDispatch(deps, agent, call, conversationId, deps.idle),
          )
          .catch(
          (error: Error) => ({ text: `error: ${error.message}`, event: { ok: false, error: error.message } }),
        );
        if (observation.event['ok'] === true && call.name === 'send_message') wrote = true;
        if (observation.event['ok'] === true && call.name === 'spawn_task_worker') spawned = true;
        if (observation.event['helper'] === 'worker') spawned = true;
        if (observation.event['helper'] === 'agent') wrote = true;
        if (observation.event['ok'] === true && call.name === 'ask_owner') asked = true;
        if (observation.event['hung'] === true && call.name === 'browser') stuck = true;
        if (observation.event['ok'] === true && call.name === 'ask_for_hands') {
          hands = parseHandsReason(JSON.parse(call.arguments) as Record<string, unknown>) as string;
        }
        if (observation.event['ok'] === true && call.name === 'request_form') formOn = String(observation.event['origin']);
        if (observation.event['ok'] === true && call.name === 'set_name') rename = String(observation.event['name']);
        if (observation.event['error'] === CONTROL_HELD) refused = true;
        appendMessage(db, conversationId, {
          role: 'tool',
          // Whatever a tool reads back, a value the owner typed into a secret field is not in it.
          content: redactSecrets(db, (parent ?? agent).id, observation.text),
          sender: agent.name,
          toolCallId: call.id,
          ...(observation.image === undefined ? {} : { image: observation.image }),
        });
        recordEvent(db, agent.id, 'tool_result', { callId: call.id, ...observation.event });
      }

      // A human took the mouse. Every call in this reply still got its result — a reply asking
      // for three tools and answered by one is the broken shape the boot repair exists to fix —
      // but there is nothing to think about until the desktop comes back.
      if (refused && parent === undefined) {
        transition(db, agent, endState());
        return;
      }
      // A question to the owner is the turn's last word whatever else the reply asked for: the
      // model cannot go on without the answer, and a model told so in the tool text still
      // sometimes tries. The owner's reply is the next turn.
      if (asked && parent === undefined) {
        transition(db, agent, 'waiting_for_user');
        deps.deliver?.(agent, conversationId, reply.text.trim() || 'Has questions for you.', 'reply');
        return;
      }
      if (hands !== undefined && parent === undefined) {
        transition(db, agent, 'waiting_for_user');
        deps.deliver?.(agent, conversationId, `Asks you to take the screen: ${hands}`, 'reply');
        return;
      }
      if (formOn !== undefined && parent === undefined) {
        transition(db, agent, 'waiting_for_user');
        deps.deliver?.(agent, conversationId, `Asks you to fill a form on ${formOn}`, 'reply');
        return;
      }
      // The browser did not come back after its restart: the owner's three ways out are on a
      // card in the chat and in Needs you, and nothing the model tries next can reach the page.
      if (stuck && parent === undefined) {
        transition(db, agent, 'waiting_for_user');
        deps.deliver?.(agent, conversationId, 'Its browser stopped answering.', 'reply');
        return;
      }
      if (
        deps.idle !== undefined &&
        (steps >= deps.idle.turnCap || usage.promptTokens + usage.completionTokens >= deps.idle.tokenLimit)
      ) {
        transition(db, agent, 'waiting_for_user');
        return;
      }
      if (deps.signal?.aborted) return halt();
    }

    throw new Error(`gave up after ${MAX_STEPS} steps without answering`);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    recordEvent(db, agent.id, 'failure', { message });
    // In the thread, not only in the event log: the owner sees why it stopped, and the next
    // turn's model call carries the failure instead of a transcript that just trails off.
    appendMessage(db, conversationId, {
      role: 'assistant',
      content: `${RUN_FAILED}: ${message}`,
      sender: agent.name,
    });
    transition(db, agent, 'failed');
    // A worker that dies silently leaves its parent waiting for a result nothing will ever
    // send, so the failure travels the same path the result would have.
    if (parent !== undefined) report(deps, agent, parent, `${WORKER_FAILED}: ${message}`);
    else deps.deliver?.(agent, conversationId, `${RUN_FAILED}: ${message}`, 'failure');
    answerRequests(deps, agent, owed, `${RUN_FAILED}: ${message}`);
    log.error('agent run failed', { agent: agent.name, error });
  } finally {
    // What the turn cost, on every way out. The tokens are only what the endpoint reported;
    // one that reports nothing leaves the count of model calls, which is still a cost.
    recordEvent(db, agent.id, 'turn', { steps, ...(summaries === 0 ? {} : { summaries }), ...(metered ? usage : {}) });
    await deps.idle?.end(usage.promptTokens + usage.completionTokens);
    // Every way out of the turn, not only the last line of the happy one: a stdio session left
    // open is a child process that outlives the turn that started it.
    await mcp?.close();
    // A reply with no tool call can end the turn while the snapshot still runs, and the next
    // round's snapshot or a rename must not overlap it. A stop kills it; a stuck one gets a grace.
    if (snapshot !== undefined) {
      await untilStopped(snapshot, deps.signal).catch(() => within(snapshot, STOPPED_SNAPSHOT_GRACE_MS));
    }
    // Last, with nothing of the turn still running as the old user. The failure is logged and
    // not thrown: the turn itself succeeded, and the next one runs under the name that stuck.
    if (rename !== undefined) {
      await deps.rename?.(agent, rename).catch((error: unknown) => {
        log.error('agent rename failed', { agent: agent.name, to: rename, error });
      });
    }
  }
}

/** A worker runs as its parent's Linux user, so stopping that user's processes stops the worker. */
export function workersBusy(db: Db, runner: Runner, agent: Agent): boolean {
  return listAgents(db).some((other) => other.parentId === agent.id && runner.running(other.name));
}

export type RunnerDeps = {
  db: Db;
  exec: Exec;
  screen: Screen;
  /** Undefined until the owner has stored a base url, a model and an api key. `modelId` picks a
   * registry model other than the agent's own. */
  provider: (agent: Agent, modelId?: number) => Provider | undefined;
  /** The web search endpoint and its key, or undefined while no key is stored. */
  search: () => SearchConfig | undefined;
  /** One turn's MCP tools, connected when the turn starts and dropped when it ends. */
  mcp: LoopDeps['mcp'];
  /** Who holds each desktop's input. Process state, like the loop cap below it. */
  control: Control;
  /** How many turns may run at once in this process, and how many workers may be live at all. */
  maxLoops: number;
  maxWorkers: number;
  deliver?: NonNullable<LoopDeps['deliver']> | undefined;
  rename?: LoopDeps['rename'];
  desktop?: DesktopOps | undefined;
  connect?: Connect;
  browserTimings?: BrowserTimings;
};

// One agent piling up messages faster than it answers them still has to let go eventually.
// Two agents writing to each other are stopped earlier, by MAX_AGENT_CHAIN.
const MAX_ROUNDS = 16;

/** How often the runner looks for unread input and agents left waiting on nobody. */
export const SWEEP_MS = 60_000;

export type TurnRunner = Runner & {
  /** Repairs agents waiting on nobody, queues every thread with unread input, then fills free
   * loops from the queue. Run at boot and on a timer. */
  sweep(): void;
};

/**
 * Owns the one-turn-per-agent rule and the loop cap. A message to a busy agent is a row its
 * running turn picks up before it releases the agent. A turn that finds every loop taken waits
 * in `turn_queue`, and each freed loop starts the oldest waiting entry, so nothing is dropped
 * and one chatty agent cannot starve the others.
 */
export function createRunner(deps: RunnerDeps): TurnRunner {
  // By id, not name: set_name renames the agent at the end of a turn while its drain still holds
  // the loop, and a start under the new name must find it busy.
  const busy = new Set<number>();
  /** One per turn in flight, so a stop reaches exactly the turn that is running now. */
  const stops = new Map<number, AbortController>();
  const idOf = (name: string): number | undefined => findAgent(deps.db, name)?.id;
  const busyNamed = (name: string): boolean => {
    const id = idOf(name);
    return id !== undefined && busy.has(id);
  };
  const runner: TurnRunner = { start, atCapacity, running: busyNamed, stop, sweep };

  function stop(name: string): boolean {
    const id = idOf(name);
    const controller = id === undefined ? undefined : stops.get(id);
    if (controller === undefined) return false;
    controller.abort(new Error('stopped by the owner'));
    return true;
  }

  function atCapacity(name?: string): string | undefined {
    if (name !== undefined && busyNamed(name)) return undefined;
    return busy.size < deps.maxLoops
      ? undefined
      : `at most ${deps.maxLoops} agent loops can run at once; wait for one to finish`;
  }

  function start(agent: Agent, conversationId: number, idle?: IdleTurn, kind: TurnKind = 'message'): void {
    // An idle pass carries callbacks a row cannot hold, so it never waits in line: the idle tick
    // checks for room first and keeps the pass due when there is none.
    if (idle !== undefined) {
      if (busy.has(agent.id) || busy.size >= deps.maxLoops || isQueued(deps.db, agent.id)) {
        void idle.end(undefined);
        return;
      }
      launch(agent, conversationId, idle);
      return;
    }
    if (busy.has(agent.id)) return;
    if (busy.size < deps.maxLoops && queuedTurns(deps.db).length === 0) {
      launch(agent, conversationId);
      return;
    }
    enqueueTurn(deps.db, agent.id, conversationId, kind);
    log.info('turn queued at the loop cap', { agent: agent.name, kind });
    pump();
  }

  function launch(agent: Agent, conversationId: number, idle?: IdleTurn): void {
    busy.add(agent.id);
    void drain(agent.id, conversationId, idle);
  }

  /** Synchronous, like every release that calls it: an await here would let two freed loops
   * start the same entry. */
  function pump(): void {
    for (const entry of queuedTurns(deps.db)) {
      if (busy.size >= deps.maxLoops) return;
      if (busy.has(entry.agentId)) continue;
      const agent = findAgentById(deps.db, entry.agentId);
      dequeueTurn(deps.db, entry.id);
      if (agent === undefined) continue;
      // A rewind or a clear while it waited can leave nothing to read, and a turn on nothing
      // would answer an old message twice. A retry asks again on purpose.
      const unread =
        entry.kind === 'retry'
          ? entry.conversationId
          : pendingConversation(deps.db, agent, readThrough(deps.db, agent.id, agent.name));
      if (unread === undefined) continue;
      log.info('queued turn started', { agent: agent.name, kind: entry.kind, waitedMs: Date.now() - entry.createdAt });
      launch(agent, unread);
    }
  }

  function release(agentId: number): void {
    busy.delete(agentId);
    pump();
  }

  function sweep(): void {
    const live = (agent: Agent): boolean => busy.has(agent.id) || isQueued(deps.db, agent.id);
    repairWaiting(deps.db, live);
    for (const agent of listAgents(deps.db)) {
      if (live(agent) || deps.provider(agent) === undefined) continue;
      const unread = pendingConversation(deps.db, agent, readThrough(deps.db, agent.id, agent.name));
      if (unread === undefined) continue;
      log.info('unread input queued by the sweep', { agent: agent.name, conversation: unread });
      enqueueTurn(deps.db, agent.id, unread, 'requeue');
    }
    pump();
  }

  /** `idle` shapes the first round only; what arrives meanwhile gets an ordinary turn. The row is
   * read again around every round, because a round can end in a rename. */
  async function drain(agentId: number, conversationId: number, idle?: IdleTurn): Promise<void> {
    // A round covers its own thread up to the moment it started, and nothing in any other:
    // measuring every round against the global maximum left a second thread written to during
    // the first round unanswered until the owner spoke again.
    const since = lastMessageId(deps.db);
    const covered = new Map<number, number>();
    for (let round = 0; round < MAX_ROUNDS; round += 1) {
      const through = lastMessageId(deps.db);
      covered.set(conversationId, through);
      const turnIdle = round === 0 ? idle : undefined;
      const agent = findAgentById(deps.db, agentId);
      const provider = agent === undefined ? undefined : deps.provider(agent, turnIdle?.modelId ?? undefined);
      if (agent === undefined || provider === undefined) {
        if (agent !== undefined) log.error('no provider configured, turn not run', { agent: agent.name });
        release(agentId);
        void turnIdle?.end(undefined);
        return;
      }
      markRead(deps.db, agentId, through);

      const controller = new AbortController();
      stops.set(agentId, controller);
      try {
        // An idle pass tells nobody anything: no push for its reply or its cleanup requests.
        await runAgent(
          {
            ...deps,
            provider,
            runner,
            signal: controller.signal,
            ...(turnIdle === undefined ? {} : { idle: turnIdle, deliver: undefined }),
          },
          agent,
          conversationId,
        );
      } catch (error) {
        log.error('agent run threw', { agent: agent.name, error });
      } finally {
        stops.delete(agentId);
      }

      // Synchronous from here to the release. An await in between opens a window in which a
      // message arrives, finds the agent busy, and is then never picked up by anyone.
      const after = findAgentById(deps.db, agentId);
      const next = after === undefined ? undefined : pendingConversation(deps.db, after, since, (id) => covered.get(id) ?? since);
      if (next === undefined) {
        release(agentId);
        return;
      }
      conversationId = next;
    }

    // To the back of the line, so the others get a loop before this agent's next round.
    busy.delete(agentId);
    enqueueTurn(deps.db, agentId, conversationId, 'requeue');
    log.info('agent released with messages still waiting; requeued', { agentId });
    pump();
  }

  return runner;
}

/** One pass now, so the queue a restart left behind is drained at boot, then every `SWEEP_MS`. */
export function startSweeper(runner: TurnRunner): () => void {
  const pass = () => {
    try {
      runner.sweep();
    } catch (error) {
      log.error('turn sweep failed', { error });
    }
  };
  pass();
  const timer = setInterval(pass, SWEEP_MS);
  timer.unref();
  return () => clearInterval(timer);
}

/** The states that mean a process was doing something, which after a restart nothing is. */
const INTERRUPTED_STATES: readonly AgentState[] = ['thinking', 'using_computer', 'using_terminal'];

/**
 * An agent waiting on another agent or on a worker that is no longer on it would wait forever:
 * its wake only ever fires from inside a live turn. Hands it back to its owner. Waiting on an
 * agent counts only while one it asked has not answered and is still on it: running, queued,
 * waiting itself, or waiting on the owner for a question, form, hand-over or approval. A stopped
 * turn never answers. Waiting on workers counts while one is live. The reply
 * or report still wakes it whatever state it is in.
 */
/** Unread input counts: the sweep queues it, and that turn is the one that answers. */
function onIt(db: Db, agent: Agent, live: (agent: Agent) => boolean): boolean {
  if (live(agent) || agent.state === 'waiting_for_agent' || agent.state === 'waiting_for_task_worker') return true;
  if (pendingConversation(db, agent, readThrough(db, agent.id, agent.name)) !== undefined) return true;
  return listNeedsYou(db).some((item) => item.agent === agent.name && item.kind !== 'failure');
}

export function repairWaiting(db: Db, live: (agent: Agent) => boolean): Agent[] {
  const repaired: Agent[] = [];
  for (const agent of listAgents(db)) {
    if (agent.state !== 'waiting_for_agent' && agent.state !== 'waiting_for_task_worker') continue;
    if (live(agent)) continue;
    try {
      const pending =
        agent.state === 'waiting_for_task_worker'
          ? liveWorkers(db).some((worker) => worker.parentId === agent.id)
          : awaitedAgents(db, agent.name).some((id) => {
              const target = findAgentById(db, id);
              return target !== undefined && onIt(db, target, live);
            });
      if (pending) continue;
      transition(db, agent, 'waiting_for_user');
      repaired.push(agent);
      log.info('agent was waiting on nobody', { agent: agent.name, from: agent.state });
    } catch (error) {
      log.error('waiting repair failed', { agent: agent.name, error });
    }
  }
  return repaired;
}

/**
 * Boot repair, the counterpart to `reconcileDesktops`. A daemon that died mid-turn left a row
 * claiming work no process is doing, and a transcript ending in tool calls nothing answered.
 * Runs before the server listens, so no reader ever sees the broken shape.
 *
 * A repaired agent does not resume the turn it was in: a turn that killed the daemon would be
 * re-run on every boot. That turn marked its input read when it started, so the boot sweep only
 * runs what arrived after it.
 */
export function reconcileAgents(db: Db): void {
  // Workers first: a parent is only stranded once the worker it waits on has been given up on,
  // and the message that says so is what the pass below looks for.
  for (const worker of liveWorkers(db)) {
    try {
      const parent = worker.parentId === undefined ? undefined : findAgentById(db, worker.parentId);
      recordEvent(db, worker.id, 'restart', { from: worker.state, worker: true });
      setAgentState(db, worker.name, 'failed');
      if (parent !== undefined && worker.parentConversationId !== undefined) {
        appendMessage(db, worker.parentConversationId, {
          role: 'user',
          content: `${WORKER_FAILED}: the daemon restarted while I was working, and nothing of what I did was kept.`,
          sender: worker.name,
        });
      }
      log.info('task worker reconciled', { worker: worker.name, from: worker.state });
    } catch (error) {
      log.error('task worker reconcile failed', { worker: worker.name, error });
    }
  }

  for (const agent of listAgents(db)) {
    try {
      const interrupted = listConversations(db, agent.id).flatMap((conversation) =>
        repairInterruptedCalls(db, conversation.id, agent.name),
      );
      const acting = INTERRUPTED_STATES.includes(agent.state);
      if (!acting && interrupted.length === 0) continue;
      recordEvent(db, agent.id, 'restart', { from: agent.state, interrupted });
      if (acting) transition(db, agent, 'waiting_for_user');
      log.info('agent reconciled', { agent: agent.name, from: agent.state, interrupted });
    } catch (error) {
      log.error('agent reconcile failed', { agent: agent.name, error });
    }
  }

  // After every interrupted agent has come to rest: whether an asker is stranded depends on
  // where the agent it asked was left. Nothing runs or waits in line before the runner exists.
  for (const agent of repairWaiting(db, () => false)) {
    recordEvent(db, agent.id, 'restart', { from: agent.state, interrupted: [] });
  }
}
