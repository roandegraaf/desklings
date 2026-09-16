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
  findAgent,
  findAgentById,
  insertWorker,
  isWorker,
  listAgents,
  nextWorkerName,
  setAgentCosmetics,
  setAgentState,
} from './agents.ts';
import {
  MAX_AGENT_CHAIN,
  agentChain,
  appendMessage,
  appendSummary,
  conversationFor,
  conversationWith,
  lastMessageBy,
  lastMessageId,
  latestSummary,
  listConversations,
  listMessages,
  parseSendMessage,
  pendingConversation,
  participantAgents,
  recordEvent,
  repairInterruptedCalls,
  sendMessageToolDef,
} from './conversations.ts';
import {
  MAX_PENDING_APPROVALS,
  describeApproval,
  insertApproval,
  parseDeletionRequest,
  pendingCount,
  requestDeletionToolDef,
} from './approvals.ts';
import { browse, browserToolDef, cdpConnect, parseBrowserAction } from './browser.ts';
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
import { CONTROL_HELD, CONTROL_REFUSAL } from './control.ts';
import type { Control } from './control.ts';
import type { Screen } from './computer.ts';
import {
  cancelScheduleToolDef,
  deleteSchedule,
  findSchedule,
  insertSchedule,
  listSchedules,
  listSchedulesToolDef,
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
import type { Exec } from './exec.ts';
import type { ChatReply, Image, Provider, ProviderMessage } from './provider.ts';
import { log } from './log.ts';
import {
  liveWorkers,
  parseSpawnWorker,
  spawnWorkerToolDef,
  workerDir,
  workerPrompt,
} from './workers.ts';

// A turn is bounded so a model that keeps calling tools cannot run forever.
const MAX_STEPS = 200;

/** Replies still being streamed, by agent name. Process state: an agent is in `thinking` for
 * exactly as long as it has an entry here, and the stored message replaces it. */
const live = new Map<string, LiveReply>();

export function liveReply(name: string): LiveReply | undefined {
  return live.get(name);
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
    const calls = message.role === 'assistant' ? message.toolCalls : [];
    return total + message.text.length + calls.reduce((sum, c) => sum + c.arguments.length, 0);
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

function keepEnd(text: string, limit: number): string {
  return text.length <= limit ? text : `[earlier omitted]\n${text.slice(-limit)}`;
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
): Promise<Replay | undefined> {
  const previous = latestSummary(deps.db, conversationId, agent.name);
  const replay =
    previous === undefined
      ? undefined
      : { text: previous.content, throughId: previous.throughMessageId };
  if (projectedChars(transcript(agent.name, system, stored, replay)) <= MAX_TRANSCRIPT_CHARS) {
    return replay;
  }

  // Only what no summary covers yet, so a second pass never re-summarises the same messages.
  const live = stored.filter((message) => message.id > (previous?.throughMessageId ?? 0));
  // Raw content overstates what a trimmed observation costs, so the tail lands under the target
  // rather than over it. Where to cut is a judgement; whether to cut is the measurement above.
  const cost = live.map((message) => message.content.length);
  const tail = (from: number): number => cost.slice(from).reduce((sum, n) => sum + n, 0);
  const cuts = turnBoundaries(agent.name, live).filter((index) => index > 0);
  const cut = cuts.find((index) => tail(index) <= COMPACTION_TAIL_CHARS) ?? cuts.at(-1);
  if (cut === undefined) {
    log.info('nothing to compact: the thread is one turn', { agent: agent.name, conversationId });
    return replay;
  }

  return (await writeSummary(deps, agent, conversationId, live.slice(0, cut))) ?? replay;
}

/**
 * Writes one summary row standing for `covered`, which must be the rows straight after the newest
 * summary — that is what lets the previous summary be carried forward as the story so far rather
 * than re-read. Undefined when the model would not write one.
 */
async function writeSummary(
  deps: Pick<LoopDeps, 'db' | 'provider'>,
  agent: Agent,
  conversationId: number,
  covered: readonly Message[],
): Promise<Replay | undefined> {
  const previous = latestSummary(deps.db, conversationId, agent.name);
  const earlier = previous === undefined ? '' : `The story so far:\n${previous.content}\n\n`;
  const body = earlier + keepEnd(flatten(transcript(agent.name, '', covered)), MAX_TRANSCRIPT_CHARS);
  let summary: string;
  try {
    // No onDelta: this is not the agent speaking, and the live route would show it as its reply.
    const reply = await deps.provider(
      [
        { role: 'system', text: SUMMARY_PROMPT },
        { role: 'user', text: body },
      ],
      [],
    );
    summary = reply.text.trim();
  } catch (error) {
    log.error('summary failed, replaying the thread in full', { agent: agent.name, error });
    return undefined;
  }
  if (summary === '') {
    log.error('the model summarised to nothing', { agent: agent.name, conversationId });
    return undefined;
  }

  // Clipped like any other text the transcript carries: a model that answers with the whole
  // conversation back would otherwise ride in every later request and eat the budget itself.
  const content = clip(summary);
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
 * the whole stretch is one legal cut. Answers how many rows the new summary stands for.
 */
export async function compactNow(
  deps: Pick<LoopDeps, 'db' | 'provider'>,
  agent: Agent,
  conversationId: number,
): Promise<{ covered: number } | { error: string }> {
  const previous = latestSummary(deps.db, conversationId, agent.name);
  const live = listMessages(deps.db, conversationId).filter(
    (message) => message.id > (previous?.throughMessageId ?? 0),
  );
  if (live.length === 0) return { covered: 0 };
  const replay = await writeSummary(deps, agent, conversationId, live);
  return replay === undefined
    ? { error: `the model would not summarise the thread for ${agent.name}` }
    : { covered: live.length };
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

/** Starts turns. The loop needs it so `send_message` can put the agent it wrote to to work. */
export type Runner = {
  start(agent: Agent, conversationId: number): void;
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
   * process. */
  mcp: (agent: Agent) => Promise<McpSession | undefined>;
  screen: Screen;
  runner: Runner;
  control: Control;
  maxWorkers: number;
  /** Fires when the owner stops the turn. */
  signal?: AbortSignal;
  /** Moves an agent to the name it asked for with set_name, once its turn is over. */
  rename?: ((agent: Agent, name: string) => Promise<void>) | undefined;
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
  others: readonly string[],
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
    'text: a reply with no tool call ends your turn and everyone here can read it.',
    'The owner cannot reach your machine, so hand them every file you made for them as a card:',
    'write its path starting with ~/ alone on a line of its own, such as ~/workspace/report.xlsx,',
    'with no label, sentence or other path on that line, and one line per file. That line shows as',
    'a card they can open. A path inside a sentence shows only as a link, and a file outside your',
    'home cannot be opened at all, so save what you hand over in ~/workspace.',
    others.length === 0
      ? 'Nobody but you and the owner is in this conversation.'
      : `Also here: ${others.join(', ')}. Every message you are shown names who wrote it. ` +
        'Another agent\'s reply here is addressed to the owner, like yours: read it, but do not ' +
        'answer, thank or acknowledge it unless it asks you for something. When a message from ' +
        'another agent needs nothing from you, say so in one line and stop.',
  ].join(' ');
  return `${intro}\n\n${profilePrompt(agent.profile)}\n\n${home}`;
}

/**
 * Memory, the skills index and the agent's own schedules, read once per turn rather than once
 * per step, so the system text every step of a turn is handed is byte-identical and the prompt
 * cache holds. A home that cannot be read costs the agent its memory for this turn, not the turn
 * itself; the schedules come from the database and are always there.
 */
async function homeTail(deps: LoopDeps, agent: Agent): Promise<string> {
  const schedules = schedulePrompt(listSchedules(deps.db, agent));
  try {
    const home = await loadHome(deps.exec, await agentTarget(deps.exec, agent));
    return `${homePrompt(home)}\n\n${schedules}`;
  } catch (error) {
    log.error('home unreadable, running without memory', { agent: agent.name, error });
    return `${homePrompt({ memory: '', skills: [] })}\n\n${schedules}`;
  }
}

/**
 * One turn's MCP tools. A server that cannot be reached costs the agent that server's tools; a
 * configuration that cannot be read at all costs it every one of them, and neither costs it the
 * turn — the rule the home load and the schedules already follow.
 */
async function mcpSession(deps: LoopDeps, agent: Agent): Promise<McpSession | undefined> {
  try {
    return await deps.mcp(agent);
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
  stored: readonly Message[],
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
      const text =
        message.role === 'assistant'
          ? `${message.sender} said here, to the owner:\n${message.content}`
          : `Message from ${message.sender ?? 'the owner'}:\n${message.content}`;
      if (message.image === undefined) {
        pending.push({ role: 'user', text });
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
          visible.has(message.id)
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
    out.push({ role: 'assistant', text: message.content, toolCalls: message.toolCalls ?? [] });
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
  return { ...target, cwd: workerDir(target.home, agent.name) };
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
  return agentChain(db, conversationId) < MAX_AGENT_CHAIN
    ? undefined
    : `${MAX_AGENT_CHAIN} messages have passed between agents in this thread since the owner ` +
        'last spoke. Answer the owner instead.';
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

    const conversationId = conversationWith(deps.db, [agent.id, target.id]);
    if (agentChain(deps.db, conversationId) >= MAX_AGENT_CHAIN) {
      const error =
        `you and ${target.name} have passed ${MAX_AGENT_CHAIN} messages back and forth without ` +
        'the owner. Answer the owner instead.';
      return { text: `error: ${error}`, event: { ok: false, error: 'chain too long' } };
    }

    appendMessage(deps.db, conversationId, {
      role: 'user',
      content: request.text,
      sender: agent.name,
    });
    deps.runner.start(target, conversationId);
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

    const refused = (): string | undefined =>
      cappedWorkers(deps) ?? cappedChain(deps.db, conversationId) ?? deps.runner.atCapacity();
    const early = refused();
    if (early !== undefined) return { text: `error: ${early}`, event: { ok: false, error: early } };

    // The directory comes first: a worker whose --chdir does not exist turns every command it
    // runs into a confusing error, and a row created before the mkdir failed would outlive it.
    const target = await agentTarget(deps.exec, agent);
    const name = nextWorkerName(deps.db, agent);
    if (name === undefined) {
      const error = `no name is left for another worker of ${agent.name}`;
      return { text: `error: ${error}`, event: { ok: false, error } };
    }
    const dir = workerDir(target.home, name);
    const made = await deps.exec('sudo', asAgent(target, ['mkdir', '-p', dir]));
    if (made.code !== 0) {
      const error = `could not create ${dir}: ${made.stderr.trim()}`;
      return { text: `error: ${error}`, event: { ok: false, error: 'no working directory' } };
    }

    // Asked again, and synchronous from here to the start: two agents spawning in overlapping
    // turns both passed the check above before either of them took a slot, and a worker that
    // is created but refused a loop would wait for one forever.
    const late = refused();
    if (late !== undefined) return { text: `error: ${late}`, event: { ok: false, error: late } };

    const worker = insertWorker(deps.db, agent, name, conversationId);
    const thread = conversationFor(deps.db, worker.id);
    appendMessage(deps.db, thread, {
      role: 'user',
      content: `${request.brief}\n\nYour working directory is ${dir}; every command you run starts there.`,
      sender: agent.name,
    });
    deps.runner.start(worker, thread);
    return {
      text: `Task worker ${worker.name} is on it, in ${dir}. Its result arrives later as a message from it.`,
      event: { ok: true, worker: worker.name, dir },
    };
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
    const page = await browse(deps.exec, target, cdpConnect, request, MAX_OBSERVATION_CHARS);
    if ('error' in page) {
      return { text: `error: ${page.error}`, event: { ok: false, action: request.action, error: page.error } };
    }
    return {
      text: page.text,
      event: {
        ok: true,
        action: request.action,
        ...(page.url === '' ? {} : { host: new URL(page.url).host }),
        chars: page.text.length,
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

  // A worker asking to delete something would be asking about a machine it knows nothing
  // about: it has one brief and no view of the agents around it.
  if (call.name === 'request_deletion' && agent.parentId === undefined) {
    const request = parseDeletionRequest(deps.db, agent, args);
    if ('error' in request) {
      return { text: `error: ${request.error}`, event: { ok: false, error: request.error } };
    }
    if (pendingCount(deps.db) >= MAX_PENDING_APPROVALS) {
      const error = `${MAX_PENDING_APPROVALS} requests are already waiting for the owner`;
      return { text: `error: ${error}`, event: { ok: false, error } };
    }
    const asked = insertApproval(deps.db, agent, conversationId, {
      ...request,
      target: request.kind === 'conversation' ? String(conversationId) : request.target,
    });
    recordEvent(deps.db, agent.id, 'approval', {
      asked: asked.id,
      kind: asked.kind,
      target: asked.target,
    });
    deps.deliver?.(agent, conversationId, `Asks to ${describeApproval(asked)}: ${asked.reason}`, 'approval');
    return {
      text:
        `Asked the owner to ${describeApproval(asked)}. Nothing has been deleted. The answer ` +
        'arrives here as a message; carry on with the rest of your work, or end your turn.',
      event: { ok: true, approval: asked.id, kind: asked.kind, target: asked.target },
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
    return { text: schedulePrompt(held), event: { ok: true, schedules: held.length } };
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

/**
 * An answer is addressed to nobody, so it only wakes an agent standing in `waiting_for_agent`
 * for exactly this reply. Without that rule two agents in a group conversation would answer
 * each other forever off one message from the owner.
 */
export const WORKER_FAILED = 'I could not finish the job';
export const RUN_FAILED = 'I could not finish this turn';
export const STOPPED = 'I was stopped here by the owner and did not finish.';
const NOTHING_TO_REPORT = 'I finished, but the model answered with nothing.';

/**
 * A worker's last word is a message to its parent, in the thread the parent was in when it
 * spawned it. Delivery is the messaging path and nothing else: a parent that is mid-turn picks
 * the row up through the same drain a peer's message goes through, so a result that lands at a
 * busy moment waits rather than being lost.
 */
function report(deps: LoopDeps, worker: Agent, parent: Agent, text: string): void {
  const conversationId = worker.parentConversationId ?? conversationFor(deps.db, parent.id);
  appendMessage(deps.db, conversationId, { role: 'user', content: text, sender: worker.name });
  deps.runner.start(parent, conversationId);
}

function wake(deps: LoopDeps, conversationId: number, others: readonly Agent[]): void {
  for (const other of others) {
    if (findAgent(deps.db, other.name)?.state === 'waiting_for_agent') {
      deps.runner.start(other, conversationId);
    }
  }
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
  const others =
    parent === undefined
      ? participantAgents(db, conversationId).filter((other) => other.id !== agent.id)
      : [];
  // A worker shares its parent's X display, so giving it the computer tool would put two loops
  // on one mouse. It gets the terminal and nothing else, and it cannot spawn workers of its own.
  const builtin =
    parent === undefined
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
          requestDeletionToolDef(),
          askOwnerToolDef(),
          setProfileToolDef(),
          setNameToolDef(),
        ]
      : [commandToolDef(), webSearchToolDef(), webFetchToolDef()];
  // The row, not the argument: the profile is written mid-turn by set_profile, and the next
  // turn's prompt has to carry it.
  const system =
    parent === undefined
      ? systemPrompt(
          findAgent(db, agent.name) ?? agent,
          deps.screen,
          others.map((other) => other.name),
          await homeTail(deps, agent),
        )
      : workerPrompt(agent, parent.name);
  // Anything that lands after this belongs to the next turn. Splicing an arrival into a turn
  // already under way would answer it halfway through someone else's question; the runner
  // starts a fresh turn for it before it lets go of the agent.
  const history = listMessages(db, conversationId);
  const since = history.at(-1)?.id ?? 0;
  let seen = since;
  const started = (message: Message) => message.id <= since || message.sender === agent.name;
  // Decided here with the system text rather than between steps, for the same reason: every
  // step of this turn is handed the same request head, and the summariser runs at most once.
  const replay = await compact(
    deps,
    agent,
    conversationId,
    system,
    history,
  );
  // Connected here, with the system text and the replay, for the reason they are: every step of
  // this turn is handed the same tool list, so the request head the prompt cache keys on does
  // not change between steps. A worker gets none of them — it has no Linux user of its own, so a
  // stdio server would run as its parent, and it is one job that is never started again.
  const mcp = parent === undefined ? await mcpSession(deps, agent) : undefined;
  const tools = mcp === undefined ? builtin : [...builtin, ...mcp.tools];
  let wrote = false;
  let spawned = false;
  let refused = false;
  let asked = false;
  let rename: string | undefined;
  let steps = 0;
  const usage = { promptTokens: 0, completionTokens: 0 };
  let metered = false;
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
      let reply: ChatReply;
      try {
        reply = await deps.provider(
          transcript(agent.name, system, history, replay),
          tools,
          (partial) => live.set(agent.name, partial),
          deps.signal,
        );
      } catch (error) {
        // Nothing was stored for this step: the reply never arrived, so there is no call to
        // answer and the history ends at the last complete exchange.
        if (deps.signal?.aborted) return halt();
        throw error;
      } finally {
        live.delete(agent.name);
      }
      steps += 1;
      if (reply.usage !== undefined) {
        metered = true;
        usage.promptTokens += reply.usage.promptTokens;
        usage.completionTokens += reply.usage.completionTokens;
      }
      appendMessage(db, conversationId, {
        role: 'assistant',
        content: reply.text,
        sender: agent.name,
        ...(reply.toolCalls.length === 0 ? {} : { toolCalls: reply.toolCalls }),
      });

      if (reply.toolCalls.length === 0) {
        if (parent !== undefined) {
          transition(db, agent, 'completed');
          report(deps, agent, parent, reply.text.trim() === '' ? NOTHING_TO_REPORT : reply.text);
          return;
        }
        transition(db, agent, endState());
        wake(deps, conversationId, others);
        deps.deliver?.(agent, conversationId, reply.text, 'reply');
        return;
      }

      for (const call of reply.toolCalls) {
        recordEvent(db, agent.id, 'tool_call', summarise(call));
        const acting = STATE_FOR_TOOL[call.name];
        if (acting !== undefined) transition(db, agent, acting);
        const observation: Observation = await dispatch(deps, agent, call, conversationId, mcp).catch(
          (error: Error) => ({ text: `error: ${error.message}`, event: { ok: false, error: error.message } }),
        );
        if (observation.event['ok'] === true && call.name === 'send_message') wrote = true;
        if (observation.event['ok'] === true && call.name === 'spawn_task_worker') spawned = true;
        if (observation.event['ok'] === true && call.name === 'ask_owner') asked = true;
        if (observation.event['ok'] === true && call.name === 'set_name') rename = String(observation.event['name']);
        if (observation.event['error'] === CONTROL_HELD) refused = true;
        appendMessage(db, conversationId, {
          role: 'tool',
          content: observation.text,
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
    log.error('agent run failed', { agent: agent.name, error });
  } finally {
    // What the turn cost, on every way out. The tokens are only what the endpoint reported;
    // one that reports nothing leaves the count of model calls, which is still a cost.
    recordEvent(db, agent.id, 'turn', { steps, ...(metered ? usage : {}) });
    // Every way out of the turn, not only the last line of the happy one: a stdio session left
    // open is a child process that outlives the turn that started it.
    await mcp?.close();
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
  /** Undefined until the owner has stored a base url, a model and an api key. */
  provider: () => Provider | undefined;
  /** The web search endpoint and its key, or undefined while no key is stored. */
  search: () => SearchConfig | undefined;
  /** One turn's MCP tools, connected when the turn starts and dropped when it ends. */
  mcp: (agent: Agent) => Promise<McpSession | undefined>;
  /** Who holds each desktop's input. Process state, like the loop cap below it. */
  control: Control;
  /** How many turns may run at once in this process, and how many workers may be live at all. */
  maxLoops: number;
  maxWorkers: number;
  deliver?: NonNullable<LoopDeps['deliver']> | undefined;
  rename?: LoopDeps['rename'];
};

// One agent piling up messages faster than it answers them still has to let go eventually.
// Two agents writing to each other are stopped earlier, by MAX_AGENT_CHAIN.
const MAX_ROUNDS = 16;

/**
 * Owns the one-turn-per-agent rule, and is why a message to a busy agent is no longer a 409.
 * The message rows are the queue: a turn that is already running looks for arrivals before it
 * releases the agent, so nothing needs to retry and nothing is dropped.
 */
export function createRunner(deps: RunnerDeps): Runner {
  const busy = new Set<string>();
  /** One per turn in flight, so a stop reaches exactly the turn that is running now. */
  const stops = new Map<string, AbortController>();
  const runner: Runner = { start, atCapacity, running: (name) => busy.has(name), stop };

  function stop(name: string): boolean {
    const controller = stops.get(name);
    if (controller === undefined) return false;
    controller.abort(new Error('stopped by the owner'));
    return true;
  }

  function atCapacity(name?: string): string | undefined {
    if (name !== undefined && busy.has(name)) return undefined;
    return busy.size < deps.maxLoops
      ? undefined
      : `at most ${deps.maxLoops} agent loops can run at once; wait for one to finish`;
  }

  function start(agent: Agent, conversationId: number): void {
    // A busy agent is not refused. The message is already a row, and the drain below finds it.
    if (busy.has(agent.name)) return;
    const refusal = atCapacity(agent.name);
    if (refusal !== undefined) {
      // Callers that can answer somebody ask first. Getting here means nobody could be told, so
      // the row waits for the next turn this agent runs, or for the boot repair.
      log.error('loop cap reached, turn not started', { agent: agent.name, refusal });
      return;
    }
    busy.add(agent.name);
    void drain(agent, conversationId);
  }

  async function drain(agent: Agent, conversationId: number): Promise<void> {
    // A round covers its own thread up to the moment it started, and nothing in any other:
    // measuring every round against the global maximum left a second thread written to during
    // the first round unanswered until the owner spoke again.
    const since = lastMessageId(deps.db);
    const covered = new Map<number, number>();
    for (let round = 0; round < MAX_ROUNDS; round += 1) {
      covered.set(conversationId, lastMessageId(deps.db));
      const provider = deps.provider();
      if (provider === undefined) {
        log.error('no provider configured, turn dropped', { agent: agent.name });
        busy.delete(agent.name);
        return;
      }

      const controller = new AbortController();
      stops.set(agent.name, controller);
      try {
        await runAgent(
          { ...deps, provider, runner, signal: controller.signal },
          agent,
          conversationId,
        );
      } catch (error) {
        log.error('agent run threw', { agent: agent.name, error });
      } finally {
        stops.delete(agent.name);
      }

      // Synchronous from here to the release. An await in between opens a window in which a
      // message arrives, finds the agent busy, and is then never picked up by anyone.
      const next = pendingConversation(deps.db, agent, since, (id) => covered.get(id) ?? since);
      if (next === undefined) {
        busy.delete(agent.name);
        return;
      }
      conversationId = next;
    }

    busy.delete(agent.name);
    log.info('agent released with messages still waiting', { agent: agent.name });
  }

  return runner;
}

/** The states that mean a process was doing something, which after a restart nothing is. */
const INTERRUPTED_STATES: readonly AgentState[] = ['thinking', 'using_computer', 'using_terminal'];

/** The states in which what wakes an agent is another loop, which after a restart there is not:
 * the wake only ever fires from inside a live turn. */
const WAITING_ON_AN_AGENT: readonly AgentState[] = ['waiting_for_agent', 'waiting_for_task_worker'];

/**
 * Boot repair, the counterpart to `reconcileDesktops`. A daemon that died mid-turn left a row
 * claiming work no process is doing, and a transcript ending in tool calls nothing answered.
 * Runs before the server listens, so no reader ever sees the broken shape.
 *
 * A repaired agent waits for its owner rather than resuming by itself: a turn that killed the
 * daemon would be re-run on every boot, and resuming needs a provider configured at boot for
 * every agent at once. The synthetic observation is already in the transcript, so the next
 * message the owner sends carries the restart into the model call.
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
      // An agent waiting on another one is not mid-turn, but a reply that landed before the
      // daemon died will never reach it: the wake only ever fires from inside a live turn, and
      // no turn is running now. Hand it back to its owner rather than leave it waiting forever.
      const stranded =
        WAITING_ON_AN_AGENT.includes(agent.state) &&
        pendingConversation(db, agent, lastMessageBy(db, agent.name)) !== undefined;
      const acting = INTERRUPTED_STATES.includes(agent.state);
      if (!acting && !stranded && interrupted.length === 0) continue;
      recordEvent(db, agent.id, 'restart', { from: agent.state, interrupted });
      if (acting || stranded) transition(db, agent, 'waiting_for_user');
      log.info('agent reconciled', { agent: agent.name, from: agent.state, interrupted });
    } catch (error) {
      log.error('agent reconcile failed', { agent: agent.name, error });
    }
  }
}
