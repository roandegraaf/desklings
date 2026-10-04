import assert from 'node:assert/strict';
import test from 'node:test';
import { resolve } from 'node:path';
import { sql } from 'drizzle-orm';
import { AGENT_STATES } from '@schermes/shared';
import type { Agent, Message, Schedule } from '@schermes/shared';
import { openDb } from './db.ts';
import { insertApproval, listApprovals } from './approvals.ts';
import { grantOnce, readRules, updateRules } from './rules.ts';
import { listGoals } from './goals.ts';
import { findAgent, insertAgent, insertWorker, listAgents, renameAgent, setAgentState } from './agents.ts';
import {
  MAX_AGENT_CHAIN,
  agentChain,
  appendMessage,
  appendSummary,
  conversationFor,
  deleteConversation,
  existingConversation,
  lastMessageId,
  latestSummary,
  listConversations,
  listEvents,
  listMessages,
  SYSTEM_SENDER,
} from './conversations.ts';
import type { Db } from './db.ts';
import {
  CALL_CUT_OFF,
  CHARS_PER_TOKEN,
  COMPACTION_TAIL_CHARS,
  CUT_OFF,
  CUT_OFF_AGAIN,
  IMAGE_RESERVE_TOKENS,
  MAX_FULL_OBSERVATIONS,
  MAX_REPLAYED_IMAGES,
  MAX_TRANSCRIPT_CHARS,
  RUN_FAILED,
  SUMMARY_PROMPT,
  TRANSITIONS,
  canTransition,
  compactNow,
  compactionBudget,
  contextFullness,
  overflowBudget,
  createRunner,
  describe,
  reconcileAgents,
  runAgent,
  transcript,
} from './loop.ts';
import type { LoopDeps, RunnerDeps, TurnRunner } from './loop.ts';
import type { McpSession } from './mcp.ts';
import { CONTROL_HELD, createControl } from './control.ts';
import {
  MAX_SCHEDULES,
  insertSchedule,
  listSchedules,
  runDue,
  setPaused,
} from './schedules.ts';
import { HOME_APPEND, HOME_LOAD, homePrompt, parseHome } from './home.ts';
import { SNAPSHOTS } from './snapshots.ts';
import { NO_VISION, ProviderError, openAiProvider, withoutKey } from './provider.ts';
import { randomBytes } from 'node:crypto';
import { assignModel, createModel, createProvider, modelConfig } from './models.ts';
import { STOPPED, WORKER_FAILED } from './loop.ts';
import { workerPrompt } from './workers.ts';
import { enqueueTurn, queuedTurns } from './queue.ts';
import type { ChatReply, Provider, ProviderMessage, ToolDef } from './provider.ts';
import type { Exec } from './exec.ts';
import { BROWSER_HUNG } from './browser.ts';
import type { Session } from './browser.ts';
import { listNeedsYou } from './needs.ts';

const MIGRATIONS = resolve(import.meta.dirname, '../migrations');
const SCREEN = { width: 1280, height: 800, display: { width: 1280, height: 800 } };
const PNG = Buffer.from('\x89PNG\r\n\x1a\nfake', 'binary');
const CAPS = { maxLoops: 4, maxWorkers: 2 };
const SYSTEM = 'You are alpha, an AI agent.';

const screenshotCall = { id: 'c1', name: 'computer', arguments: '{"action":"screenshot"}' };
const commandCall = { id: 'c2', name: 'run_command', arguments: '{"command":"uname -a"}' };

/** Which agent the daemon told the model it was. The smoke stub keys off the same line. */
function askedAgent(messages: readonly ProviderMessage[]): string {
  const system = messages[0];
  const text = system?.role === 'system' ? system.text : '';
  return /You are (\S+),/.exec(text)?.[1] ?? '';
}

const SUMMARY = 'You were asked to read the logs, you read them, and nothing was wrong.';

/** Answers with a scripted reply per call per agent, and keeps every transcript it was handed.
 * A compaction asks the same provider with its own system text; `summarised` holds what it was
 * given to summarise, so a test can count those calls apart from the agent's own. */
function scriptedProvider(script: Record<string, readonly Partial<ChatReply>[]>) {
  const seen: ProviderMessage[][] = [];
  const offered: string[][] = [];
  const summarised: string[] = [];
  const used = new Map<string, number>();
  const provider: Provider = (messages, tools) => {
    if (messages[0]?.role === 'system' && messages[0].text === SUMMARY_PROMPT) {
      summarised.push(messages[1]?.text ?? '');
      return Promise.resolve({ text: SUMMARY, toolCalls: [] });
    }
    seen.push([...messages]);
    offered.push(tools.map((tool) => tool.name));
    const name = askedAgent(messages);
    const index = used.get(name) ?? 0;
    used.set(name, index + 1);
    const reply = script[name]?.[index];
    if (reply === undefined) return Promise.reject(new Error('the script ran out of replies'));
    return Promise.resolve({ ...reply, text: reply.text ?? '', toolCalls: reply.toolCalls ?? [] });
  };
  return { provider, seen, offered, summarised };
}

function fakeExec(ran: string[][]): Exec {
  return (file, args) => {
    ran.push([file, ...args]);
    const stdout =
      file === 'getent'
        ? Buffer.from(`${String(args[1])}:x:1001:1001::/home/${String(args[1])}:/bin/bash\n`)
        : PNG;
    return Promise.resolve({ code: 0, stdout, stderr: '', truncated: false });
  };
}

/**
 * What a turn ran beyond reading the agent's home. Every turn opens with a `getent`, a workspace
 * snapshot and one `sudo` that reads memory and the skills index, which is not what any
 * assertion about tools is looking at.
 */
function tooling(ran: readonly string[][]): string[][] {
  return ran.filter((argv) => argv[0] !== 'getent' && !argv.includes(HOME_LOAD) && !argv.includes(SNAPSHOTS));
}

const tick = () => new Promise((done) => setTimeout(done, 5));

/** No search key stored, which is what every test that is not about the web tools wants. */
const noSearch = () => undefined;

/** No MCP server configured, which is what every test that is not about them wants. */
const noMcp = () => Promise.resolve(undefined);

/** Turns outlive the call that starts them, so tests wait for the whole exchange to stop. */
async function quiet(db: Db): Promise<void> {
  const resting = ['idle', 'waiting_for_user', 'waiting_for_agent', 'failed', 'completed'];
  let previous = -1;
  for (let attempt = 0; attempt < 400; attempt += 1) {
    await tick();
    const now = lastMessageId(db);
    if (now === previous && listAgents(db).every((agent) => resting.includes(agent.state))) return;
    previous = now;
  }
  throw new Error('the agents never went quiet');
}

function fixture(
  replies: readonly Partial<ChatReply>[],
  search: LoopDeps['search'] = noSearch,
  mcp: LoopDeps['mcp'] = noMcp,
  onExec?: (argv: readonly string[]) => void,
) {
  const db = openDb(':memory:', MIGRATIONS);
  const agent = insertAgent(db, 'alpha') as Agent;
  const ran: string[][] = [];
  const fake = fakeExec(ran);
  const exec: Exec = (file, args, options) => {
    onExec?.([file, ...args]);
    return fake(file, args, options);
  };

  const { provider, seen, offered, summarised } = scriptedProvider({ alpha: replies });
  const control = createControl();
  const runner = createRunner({ db, exec, screen: SCREEN, provider: () => provider, control, search, mcp, ...CAPS });
  const conversationId = conversationFor(db, agent.id);
  const ask = (text: string) => appendMessage(db, conversationId, { role: 'user', content: text });

  return {
    db,
    agent,
    conversationId,
    ran,
    seen,
    offered,
    summarised,
    ask,
    runner,
    control,
    deps: { db, exec, provider, screen: SCREEN, runner, control, search, mcp, maxWorkers: CAPS.maxWorkers },
    state: () => findAgent(db, 'alpha')?.state,
    messages: () => listMessages(db, conversationId),
    events: () => listEvents(db, agent.id),
  };
}

const ALPHA: Agent = { id: 1, name: 'alpha', display: 1, state: 'thinking', createdAt: 0 };

/** One stored turn of alpha's: two tool calls in a reply, then both results, one with an image. */
function ownTurn(): Message[] {
  return [
    { id: 1, role: 'user', content: 'go', createdAt: 0 },
    { id: 2, role: 'assistant', content: '', toolCalls: [screenshotCall, commandCall], sender: 'alpha', createdAt: 0 },
    {
      id: 3,
      role: 'tool',
      content: 'shot',
      toolCallId: 'c1',
      sender: 'alpha',
      image: { mediaType: 'image/png', base64: 'AAA' },
      createdAt: 0,
    },
    { id: 4, role: 'tool', content: 'exit code 0', toolCallId: 'c2', sender: 'alpha', createdAt: 0 },
  ];
}

/** The rule a strict OpenAI-compatible endpoint enforces on a request it is handed. */
function assertEveryCallAnswered(messages: readonly ProviderMessage[]): void {
  messages.forEach((message, index) => {
    if (message.role !== 'assistant' || message.toolCalls.length === 0) return;
    const answers = messages.slice(index + 1, index + 1 + message.toolCalls.length);
    assert.deepEqual(
      answers.map((m) => (m.role === 'tool' ? m.toolCallId : m.role)),
      message.toolCalls.map((call) => call.id),
      'every tool call must be answered by a tool message immediately after it',
    );
  });
}

test('the state machine allows only the transitions a turn can make', () => {
  assert.deepEqual(Object.keys(TRANSITIONS).sort(), [...AGENT_STATES].sort());

  assert.ok(canTransition('idle', 'thinking'));
  assert.ok(!canTransition('idle', 'using_computer'), 'an idle agent cannot act without thinking');
  assert.ok(canTransition('thinking', 'using_computer'));
  assert.ok(canTransition('using_computer', 'using_terminal'), 'two tools in one turn');
  // Only a restart ends a turn from an acting state; the loop itself always ends from thinking.
  assert.ok(canTransition('using_terminal', 'waiting_for_user'), 'a restart ends a turn mid tool');

  // A finished or broken turn can be started again, which is what lets an owner send a second
  // message and what makes the smoke run repeatable.
  assert.ok(canTransition('waiting_for_user', 'thinking'));
  assert.ok(canTransition('failed', 'thinking'));
  assert.ok(canTransition('completed', 'thinking'));

  // Failure is reachable from anywhere the loop can be standing when something throws.
  for (const from of ['idle', 'thinking', 'using_computer', 'using_terminal', 'waiting_for_user', 'completed'] as const) {
    assert.ok(canTransition(from, 'failed'), `${from} -> failed`);
  }

  // An agent that wrote to another one ends its turn there and is woken by the reply.
  assert.ok(canTransition('thinking', 'waiting_for_agent'));
  assert.ok(canTransition('waiting_for_agent', 'thinking'));
  assert.ok(!canTransition('waiting_for_agent', 'using_computer'), 'a reply starts a fresh turn');
});

test('a turn calls a tool, feeds the result back, and ends waiting for the user', async () => {
  const f = fixture([
    { toolCalls: [screenshotCall] },
    { toolCalls: [commandCall] },
    { text: 'I looked and I ran uname.' },
  ]);
  f.ask('what machine is this?');
  await runAgent(f.deps, f.agent, f.conversationId);

  assert.equal(f.state(), 'waiting_for_user');
  assert.deepEqual(
    f.messages().map((m: Message) => m.role),
    ['user', 'assistant', 'tool', 'assistant', 'tool', 'assistant'],
  );

  const [, , shot, , ran, answer] = f.messages();
  assert.equal(shot?.toolCallId, 'c1');
  assert.equal(shot?.image?.base64, PNG.toString('base64'));
  assert.equal(ran?.toolCallId, 'c2');
  assert.match(String(ran?.content), /exit code 0/);
  assert.equal(answer?.content, 'I looked and I ran uname.');

  // Both tool calls actually reached the spawn boundary as the agent.
  const sudoed = tooling(f.ran).filter(([file]) => file === 'sudo');
  assert.equal(sudoed.length, 2);
  assert.match(String(sudoed[0]?.at(-1)), /^scrot -o -F/);
  assert.deepEqual(sudoed[1]?.slice(-3), ['bash', '-c', 'uname -a']);

  const events = f.events();
  assert.deepEqual(
    events.filter((e) => e.type === 'state').map((e) => e.data['to']),
    ['thinking', 'using_computer', 'thinking', 'using_terminal', 'thinking', 'waiting_for_user'],
  );
  assert.deepEqual(
    events.filter((e) => e.type === 'tool_call').map((e) => [e.data['tool'], e.data['action'] ?? e.data['command']]),
    [['computer', 'screenshot'], ['run_command', 'uname -a']],
  );
  // A screenshot event records its size, never its pixels.
  const shotResult = events.find((e) => e.type === 'tool_result');
  assert.equal(shotResult?.data['imageBytes'], PNG.toString('base64').length);
  assert.doesNotMatch(JSON.stringify(events), /iVBOR|PNG/);
});

test('the second model call gets the tool result before the image it refers to', async () => {
  const f = fixture([{ toolCalls: [screenshotCall] }, { text: 'done' }]);
  f.ask('look at the screen');
  await runAgent(f.deps, f.agent, f.conversationId);

  const second = f.seen[1] as ProviderMessage[];
  assert.deepEqual(
    second.map((m) => m.role),
    ['system', 'user', 'assistant', 'tool', 'user'],
  );

  const assistant = second[2];
  assert.ok(assistant?.role === 'assistant' && assistant.toolCalls[0]?.id === 'c1');
  // A tool message must follow its assistant message immediately, so the image rides in a
  // separate user message placed after every tool result rather than between them.
  const tool = second[3];
  assert.ok(tool?.role === 'tool' && tool.toolCallId === 'c1');
  const image = second[4];
  assert.ok(image?.role === 'user' && image.image?.base64 === PNG.toString('base64'));
});

test('two tool calls in one reply keep every result ahead of the image', () => {
  assert.deepEqual(
    transcript('alpha', SYSTEM, ownTurn()).map((m) => m.role),
    ['system', 'user', 'assistant', 'tool', 'tool', 'user'],
  );
});

test('nothing another agent wrote can split an assistant message from its tool results', () => {
  const intruder = (id: number): Message => ({
    id,
    role: 'user',
    content: 'hey alpha, drop everything',
    sender: 'bravo',
    createdAt: 0,
  });

  // Delivery to a busy agent means a foreign row can be stored at any point of a turn, and
  // stays there. Every one of those positions has to survive being read back.
  for (const at of [0, 1, 2, 3, 4]) {
    const stored = [...ownTurn()];
    stored.splice(at, 0, intruder(100 + at));
    const projected = transcript('alpha', SYSTEM, stored);
    assertEveryCallAnswered(projected);
    assert.equal(
      projected.filter((m) => m.role === 'user' && m.text.includes('drop everything')).length,
      1,
      `the message stored at position ${at} is still shown`,
    );
  }
});

test('a long transcript keeps only the last few screenshots and says so', () => {
  const shots = MAX_REPLAYED_IMAGES + 4;
  const stored: Message[] = [{ id: 1, role: 'user', content: 'watch the screen', createdAt: 0 }];
  for (let shot = 0; shot < shots; shot += 1) {
    const call = { id: `s${shot}`, name: 'computer', arguments: '{"action":"screenshot"}' };
    stored.push(
      { id: 100 + shot * 2, role: 'assistant', content: '', toolCalls: [call], sender: 'alpha', createdAt: 0 },
      {
        id: 101 + shot * 2,
        role: 'tool',
        content: `Screenshot taken; it is in the next message. (${shot})`,
        toolCallId: call.id,
        sender: 'alpha',
        image: { mediaType: 'image/png', base64: PNG.toString('base64') },
        createdAt: 0,
      },
    );
  }

  const projected = transcript('alpha', SYSTEM, stored);
  assertEveryCallAnswered(projected);

  // Only the newest few pictures ride along, and they are the newest ones.
  const carried = projected.filter((m) => m.role === 'user' && m.image !== undefined);
  assert.equal(carried.length, MAX_REPLAYED_IMAGES);
  assert.deepEqual(
    carried.map((m) => /tool call (s\d+)/.exec(m.text)?.[1]),
    ['s4', 's5', 's6'],
  );

  // The dropped ones are named rather than silently missing, and every tool result that says a
  // screenshot was taken is still there: what the call did is the record that it happened.
  const dropped = projected.filter((m) => m.role === 'user' && /no longer shown/.test(m.text));
  assert.equal(dropped.length, shots - MAX_REPLAYED_IMAGES);
  assert.equal(projected.filter((m) => m.role === 'tool').length, shots);
  for (let shot = 0; shot < shots; shot += 1) {
    assert.ok(
      projected.some((m) => m.role === 'tool' && m.text.endsWith(`(${shot})`)),
      `the tool result naming screenshot ${shot} survived`,
    );
  }
});

test('the transcript names who wrote every message and hides another agent tool traffic', () => {
  const stored: Message[] = [
    { id: 1, role: 'user', content: 'you two sort it out', createdAt: 0 },
    { id: 2, role: 'user', content: 'what is your hostname?', sender: 'bravo', createdAt: 0 },
    { id: 3, role: 'assistant', content: '', toolCalls: [commandCall], sender: 'bravo', createdAt: 0 },
    { id: 4, role: 'tool', content: 'exit code 0', toolCallId: 'c2', sender: 'bravo', createdAt: 0 },
    { id: 5, role: 'assistant', content: 'mine is bravo-box', sender: 'bravo', createdAt: 0 },
    { id: 6, role: 'assistant', content: 'noted', sender: 'alpha', createdAt: 0 },
  ];

  const projected = transcript('alpha', SYSTEM, stored);
  assert.deepEqual(projected.map((m) => m.role), ['system', 'user', 'user', 'user', 'assistant']);
  const said = projected.filter((m) => m.role === 'user').map((m) => m.text);
  assert.match(String(said[0]), /^Message from the owner:\nyou two sort it out$/);
  assert.match(String(said[1]), /^Message from bravo:\nwhat is your hostname\?$/);
  assert.match(String(said[2]), /^Message from bravo:\nmine is bravo-box$/);
  // bravo's tool call and its result are dropped together, or the pair would be half a turn.
  assert.doesNotMatch(JSON.stringify(projected), /exit code 0/);
});

test('a provider that fails ends the run as failed instead of hanging', async () => {
  const f = fixture([]);
  f.ask('hello');
  await runAgent(f.deps, f.agent, f.conversationId);

  assert.equal(f.state(), 'failed');
  const failure = f.events().find((e) => e.type === 'failure');
  assert.match(String(failure?.data['message']), /ran out of replies/);
  // The thread says so too, in the agent's own voice, so the owner and the next model call
  // both see why it stopped; nothing else is invented.
  assert.deepEqual(f.messages().map((m) => m.role), ['user', 'assistant']);
  const note = f.messages().at(-1);
  assert.equal(note?.sender, 'alpha');
  assert.match(String(note?.content), new RegExp(`^${RUN_FAILED}: .*ran out of replies`));
});

test('older tool outputs are shortened and the newest kept whole', () => {
  const steps = MAX_FULL_OBSERVATIONS + 3;
  const stored: Message[] = [{ id: 1, role: 'user', content: 'go', createdAt: 0 }];
  for (let step = 0; step < steps; step += 1) {
    const call = { id: `k${step}`, name: 'run_command', arguments: '{"command":"cat log"}' };
    stored.push(
      { id: 100 + step * 2, role: 'assistant', content: '', toolCalls: [call], sender: 'alpha', createdAt: 0 },
      { id: 101 + step * 2, role: 'tool', content: `(${step}) ${'x'.repeat(5_000)}`, toolCallId: call.id, sender: 'alpha', createdAt: 0 },
    );
  }

  const results = transcript('alpha', SYSTEM, stored).filter((m) => m.role === 'tool');
  assert.equal(results.length, steps, 'every call is still answered');
  const whole = results.filter((m) => m.text.length > 5_000);
  assert.equal(whole.length, MAX_FULL_OBSERVATIONS);
  assert.equal(whole[0]?.text.slice(0, 3), '(3)', 'the whole ones are the newest');
  const cut = results.filter((m) => m.text.length <= 5_000);
  assert.equal(cut.length, steps - MAX_FULL_OBSERVATIONS);
  for (const result of cut) assert.match(result.text, /^\(\d\) x+\n\[older output shortened/);
});

test('a tool that refuses becomes an observation, not the end of the run', async () => {
  const f = fixture([
    { toolCalls: [{ id: 'c1', name: 'computer', arguments: '{"action":"move","x":99999,"y":0}' }] },
    { toolCalls: [{ id: 'c2', name: 'nonsense', arguments: 'not json' }] },
    { text: 'I will stop trying that.' },
  ]);
  f.ask('click somewhere impossible');
  await runAgent(f.deps, f.agent, f.conversationId);

  assert.equal(f.state(), 'waiting_for_user');
  const observations = f.messages().filter((m) => m.role === 'tool');
  assert.match(String(observations[0]?.content), /^error: .*outside the 1280x800 screen/);
  assert.match(String(observations[1]?.content), /^error: could not read the arguments/);
  assert.deepEqual(tooling(f.ran), [], 'neither call reached a shell');
});

test('a tool named after an Object.prototype member is an unknown tool, not a crash', async () => {
  const names = Object.getOwnPropertyNames(Object.prototype);
  const f = fixture([
    { toolCalls: names.map((name, i) => ({ id: `p${i}`, name, arguments: '{}' })) },
    { text: 'done' },
  ]);
  f.ask('go');
  await runAgent(f.deps, f.agent, f.conversationId);

  assert.equal(f.state(), 'waiting_for_user');
  assert.equal(f.messages().filter((m) => m.role === 'tool').length, names.length, 'every call is answered');
});

test('the owner holding control refuses the agent the display and ends its turn', async () => {
  const f = fixture([
    { toolCalls: [screenshotCall, commandCall] },
    { toolCalls: [screenshotCall] },
    { text: 'I can see it again.' },
  ]);
  f.control.hold(f.agent.display);
  f.ask('look at the screen');
  await runAgent(f.deps, f.agent, f.conversationId);

  assert.equal(f.state(), 'waiting_for_user', 'the agent waits for the owner to give it back');
  const observations = f.messages().filter((m) => m.role === 'tool');
  // Every call in the reply still got its result: a reply answered by fewer tool messages than
  // it asked for is exactly the shape a strict endpoint rejects.
  assert.deepEqual(observations.map((m) => m.toolCallId), ['c1', 'c2']);
  assert.match(String(observations[0]?.content), /^error: the owner has taken control/);
  assert.match(String(observations[1]?.content), /exit code 0/, 'the terminal is not the display');
  assert.deepEqual(
    f.ran.filter(([, , , argv]) => String(argv).startsWith('scrot')),
    [],
    'nothing reached the X display',
  );
  assert.equal(f.seen.length, 1, 'the turn did not think again against a locked desktop');
  assert.ok(
    f.events().some((e) => e.type === 'tool_result' && e.data['error'] === CONTROL_HELD),
    'the refusal is in the history',
  );

  f.control.release(f.agent.display);
  await runAgent(f.deps, f.agent, f.conversationId);
  assert.equal(f.state(), 'waiting_for_user');
  const shot = f.messages().filter((m) => m.role === 'tool').at(-1);
  assert.equal(shot?.image?.base64, PNG.toString('base64'), 'the display is the agent\'s again');
});

test('a daemon that died holding control comes back with the desktop free', async () => {
  const f = fixture([
    { toolCalls: [screenshotCall] },
    { toolCalls: [screenshotCall] },
    { text: 'nobody is holding it now.' },
  ]);
  f.control.hold(f.agent.display);
  f.ask('look at the screen');
  await runAgent(f.deps, f.agent, f.conversationId);
  assert.equal(f.state(), 'waiting_for_user');

  // A hold is a live person at a live socket, so a new process starts with none. What the
  // restart inherits is the agent's side of it: the refusal in the transcript and the state.
  const restarted = { ...f.deps, control: createControl() };
  reconcileAgents(f.db);
  assert.equal(f.state(), 'waiting_for_user', 'nothing was left claiming work');
  assert.deepEqual(
    f.events().filter((e) => e.type === 'restart'),
    [],
    'a gated agent is not an interrupted one',
  );

  await runAgent(restarted, f.agent, f.conversationId);
  assert.equal(f.state(), 'waiting_for_user');
  const shot = f.messages().filter((m) => m.role === 'tool').at(-1);
  assert.equal(shot?.image?.base64, PNG.toString('base64'), 'the agent can drive it again');
});

test('a model that never answers is cut off rather than looping forever', async () => {
  const f = fixture(Array.from({ length: 250 }, () => ({ toolCalls: [commandCall] })));
  f.ask('keep going');
  await runAgent(f.deps, f.agent, f.conversationId);

  assert.equal(f.state(), 'failed');
  assert.match(String(f.events().find((e) => e.type === 'failure')?.data['message']), /gave up after/);
  assert.ok(f.seen.length < 250, `stopped after ${f.seen.length} model calls`);
});

test('a huge stdout cannot push stderr out of the observation', () => {
  const observation = describe({
    exitCode: 1,
    stdout: 'x'.repeat(200_000),
    stderr: 'ld: symbol not found',
    timedOut: false,
    background: false,
  });
  assert.match(observation, /\[output truncated\]/, 'the agent is told the output is partial');
  assert.match(observation, /ld: symbol not found/, 'the reason it failed is still reachable');
  assert.match(observation, /^exit code 1/);
});

test('an error body from the provider never carries the api key', () => {
  const echoed = '{"error":"invalid api key sk-live-secret","sent":"Bearer sk-live-secret"}';
  const cleaned = withoutKey(echoed, 'sk-live-secret');
  assert.doesNotMatch(cleaned, /sk-live-secret/);
  assert.match(cleaned, /invalid api key \[redacted\]/);
  // An empty key would otherwise match between every character and shred the diagnostic.
  assert.equal(withoutKey(echoed, ''), echoed);
});

test('a turn cut off mid tool call is repaired into a transcript a model will accept', () => {
  const f = fixture([]);
  f.ask('take a look and check the kernel');
  // What a daemon killed between the second tool result and the first leaves behind.
  appendMessage(f.db, f.conversationId, {
    role: 'assistant',
    content: '',
    sender: 'alpha',
    toolCalls: [screenshotCall, commandCall],
  });
  appendMessage(f.db, f.conversationId, {
    role: 'tool',
    content: 'shot',
    sender: 'alpha',
    toolCallId: 'c1',
  });
  setAgentState(f.db, 'alpha', 'using_terminal');

  assert.throws(
    () => assertEveryCallAnswered(transcript('alpha', SYSTEM, f.messages())),
    'the stored transcript really is the shape an endpoint rejects',
  );

  reconcileAgents(f.db);

  assert.equal(f.state(), 'waiting_for_user', 'the agent can be spoken to again');
  assertEveryCallAnswered(transcript('alpha', SYSTEM, f.messages()));

  const repaired = f.messages().at(-1);
  assert.equal(repaired?.role, 'tool');
  assert.equal(repaired?.toolCallId, 'c2');
  assert.match(String(repaired?.content), /daemon restarted/);

  const restart = f.events().find((e) => e.type === 'restart');
  assert.equal(restart?.data['from'], 'using_terminal');
  assert.deepEqual(restart?.data['interrupted'], ['c2']);
});

test('a conversation that lost nothing is left exactly as it was', async () => {
  const f = fixture([{ toolCalls: [screenshotCall] }, { text: 'done' }]);
  f.ask('look at the screen');
  await runAgent(f.deps, f.agent, f.conversationId);
  const before = f.messages();

  reconcileAgents(f.db);

  assert.deepEqual(f.messages(), before, 'no message nobody wrote was added');
  assert.equal(f.state(), 'waiting_for_user');
  assert.deepEqual(f.events().filter((e) => e.type === 'restart'), []);
});

test('the boot reconcile moves every interrupted agent, and every one waiting on nobody, and no settled one', () => {
  const db = openDb(':memory:', MIGRATIONS);
  // Nothing was asked and no worker exists, so the two waiting states wait on nobody.
  const interrupted = ['thinking', 'using_computer', 'using_terminal', 'waiting_for_agent', 'waiting_for_task_worker'];
  const nameFor = (state: string) => state.replaceAll('_', '-');

  for (const state of AGENT_STATES) {
    insertAgent(db, nameFor(state));
    setAgentState(db, nameFor(state), state);
  }

  reconcileAgents(db);

  for (const state of AGENT_STATES) {
    assert.equal(
      findAgent(db, nameFor(state))?.state,
      interrupted.includes(state) ? 'waiting_for_user' : state,
      `an agent left in ${state}`,
    );
  }
});

function pair(script: Record<string, readonly Partial<ChatReply>[]>, caps: typeof CAPS & Pick<RunnerDeps, 'desktop'> = CAPS) {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  const bravo = insertAgent(db, 'bravo') as Agent;
  const ran: string[][] = [];
  const { provider, seen, offered, summarised } = scriptedProvider(script);
  const control = createControl();
  const runner = createRunner({
    db,
    exec: fakeExec(ran),
    screen: SCREEN,
    provider: () => provider,
    control,
    search: noSearch,
    mcp: noMcp,
    ...caps,
  });
  return {
    db,
    alpha,
    bravo,
    runner,
    control,
    seen,
    offered,
    summarised,
    ran,
    state: (name: string) => findAgent(db, name)?.state,
  };
}

const sendCall = (id: string, to: string, text: string) => ({
  id,
  name: 'send_message',
  arguments: JSON.stringify({ to, text }),
});

test('an agent writes to another one, which replies and wakes it', async () => {
  const p = pair({
    alpha: [
      { toolCalls: [sendCall('m1', 'bravo', 'what is your hostname?')] },
      { text: 'I asked bravo; waiting for it.' },
      { text: 'bravo says it is bravo-box.' },
    ],
    bravo: [{ text: 'my hostname is bravo-box' }],
  });

  const owner = conversationFor(p.db, p.alpha.id);
  appendMessage(p.db, owner, { role: 'user', content: 'ask bravo for its hostname' });
  p.runner.start(p.alpha, owner);
  await quiet(p.db);

  const theirs = conversationFor(p.db, p.bravo.id);
  assert.deepEqual(
    listMessages(p.db, theirs).map((m) => [m.role, m.sender, m.content]),
    [
      ['user', 'alpha', 'what is your hostname?'],
      ['assistant', 'bravo', 'my hostname is bravo-box'],
    ],
  );
  assert.deepEqual(
    listMessages(p.db, owner)
      .filter((m) => m.role !== 'tool' && m.toolCalls === undefined)
      .map((m) => [m.role, m.sender, m.content]),
    [
      ['user', undefined, 'ask bravo for its hostname'],
      ['assistant', 'alpha', 'I asked bravo; waiting for it.'],
      ['user', 'bravo', 'my hostname is bravo-box'],
      ['assistant', 'alpha', 'bravo says it is bravo-box.'],
    ],
  );

  // No thread of their own: each one only ever has the one it shares with the owner.
  assert.deepEqual(listConversations(p.db, p.bravo.id).map((c) => c.participants), [['bravo']]);
  assert.equal(p.seen.length, 4, 'the reply alpha answered was not sent back to bravo');
  assert.equal(p.state('alpha'), 'waiting_for_user', 'the reply arrived and alpha answered it');
  assert.equal(p.state('bravo'), 'waiting_for_user');
});

test('an answer goes back once, pushes only for the owner, and a cleared thread brings nothing back', async () => {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  const bravo = insertAgent(db, 'bravo') as Agent;
  const { provider, seen } = scriptedProvider({
    alpha: [
      { toolCalls: [sendCall('m1', 'bravo', 'hostname?')] },
      { text: 'asked bravo' },
      { text: 'it is bravo-box' },
    ],
    bravo: [{ text: 'bravo-box' }, { text: 'still here' }],
  });
  const pushed: string[] = [];
  const runner = createRunner({
    db,
    exec: fakeExec([]),
    screen: SCREEN,
    provider: () => provider,
    control: createControl(),
    search: noSearch,
    mcp: noMcp,
    ...CAPS,
    deliver: (agent, _conversation, text) => pushed.push(`${agent.name}: ${text}`),
  });
  const mine = conversationFor(db, alpha.id);
  appendMessage(db, mine, { role: 'user', content: 'ask bravo' });
  runner.start(alpha, mine);
  await quiet(db);

  assert.deepEqual(pushed, ['alpha: asked bravo', 'alpha: it is bravo-box'], 'bravo answering alpha is no push of its own');

  // Clearing alpha's thread takes the reply with it, and must not make bravo's old request look unanswered.
  deleteConversation(db, mine);
  const theirs = conversationFor(db, bravo.id);
  appendMessage(db, theirs, { role: 'user', content: 'you there?' });
  runner.start(bravo, theirs);
  await quiet(db);

  assert.equal(existingConversation(db, alpha.id), undefined, 'nothing was sent back to alpha');
  assert.deepEqual(pushed.at(-1), 'bravo: still here', 'the owner asked, so the owner hears it');
  assert.equal(seen.length, 5);
});

test('writing to an agent that does not exist is an observation, not a failed turn', async () => {
  const p = pair({
    alpha: [
      { toolCalls: [sendCall('m1', 'charlie', 'hello?')] },
      { text: 'There is no charlie here.' },
    ],
  });
  const owner = conversationFor(p.db, p.alpha.id);
  appendMessage(p.db, owner, { role: 'user', content: 'ask charlie' });
  p.runner.start(p.alpha, owner);
  await quiet(p.db);

  assert.equal(p.state('alpha'), 'waiting_for_user', 'not waiting_for_agent: nothing was sent');
  const observation = listMessages(p.db, owner).find((m) => m.role === 'tool');
  assert.match(String(observation?.content), /^error: no agent named charlie/);
});

test('a held desktop ends a turn that already wrote to a peer without failing it', async () => {
  const p = pair({
    alpha: [
      { toolCalls: [sendCall('m1', 'bravo', 'what is your hostname?')] },
      { toolCalls: [screenshotCall] },
      { text: 'bravo says it is bravo-box.' },
    ],
    bravo: [{ text: 'my hostname is bravo-box' }],
  });
  p.control.hold(p.alpha.display);
  const owner = conversationFor(p.db, p.alpha.id);
  appendMessage(p.db, owner, { role: 'user', content: 'ask bravo, then look at the screen' });
  p.runner.start(p.alpha, owner);
  await quiet(p.db);

  assert.deepEqual(
    listEvents(p.db, p.alpha.id).filter((e) => e.type === 'failure'),
    [],
    'using_computer -> waiting_for_agent is a legal end of a turn',
  );
  assert.equal(p.state('alpha'), 'waiting_for_user', 'bravo answered and alpha finished');
});

test('a message that lands mid-turn is picked up instead of refused', async () => {
  let release: () => void = () => {};
  const held = new Promise<void>((done) => {
    release = () => done();
  });
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  const asked: string[][] = [];
  const provider: Provider = async (messages) => {
    asked.push(messages.flatMap((m) => (m.role === 'user' ? [m.text] : [])));
    if (asked.length === 1) await held;
    return { text: `answer ${asked.length}`, toolCalls: [] };
  };
  // maxLoops 1, so this also proves the cap does not refuse a second message to a busy agent:
  // it is not a second loop, it is a row the running one picks up.
  const runner = createRunner({
    db,
    exec: fakeExec([]),
    screen: SCREEN,
    provider: () => provider,
    control: createControl(),
    search: noSearch,
    mcp: noMcp,
    maxLoops: 1,
    maxWorkers: 1,
  });
  const owner = conversationFor(db, alpha.id);

  appendMessage(db, owner, { role: 'user', content: 'first' });
  runner.start(alpha, owner);
  await tick();

  appendMessage(db, owner, { role: 'user', content: 'second' });
  runner.start(alpha, owner);
  assert.equal(asked.length, 1, 'a busy agent does not start a second turn on top of the first');
  release();
  await quiet(db);

  assert.equal(asked.length, 2, 'the message that arrived mid-turn got its own turn');
  assert.ok(!String(asked[0]).includes('second'), 'it was not spliced into the turn under way');
  assert.ok(String(asked[1]).includes('second'));
  // Stored the moment it arrived, ahead of the answer to the message before it: the row is the
  // queue, and only the transcript the running turn was handed ignores it.
  assert.deepEqual(
    listMessages(db, owner).map((m) => m.content),
    ['first', 'second', 'answer 1', 'answer 2'],
  );
});

test('a message that lands between steps stays out of the turn while its own results come in', async () => {
  let release: () => void = () => {};
  const held = new Promise<void>((done) => {
    release = () => done();
  });
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  const asked: ProviderMessage[][] = [];
  const provider: Provider = async (messages) => {
    asked.push([...messages]);
    if (asked.length === 1) {
      await held;
      return { text: '', toolCalls: [commandCall] };
    }
    return { text: `answer ${asked.length}`, toolCalls: [] };
  };
  const runner = createRunner({
    db,
    exec: fakeExec([]),
    screen: SCREEN,
    provider: () => provider,
    control: createControl(),
    search: noSearch,
    mcp: noMcp,
    ...CAPS,
  });
  const owner = conversationFor(db, alpha.id);

  appendMessage(db, owner, { role: 'user', content: 'first' });
  runner.start(alpha, owner);
  await tick();
  appendMessage(db, owner, { role: 'user', content: 'second' });
  release();
  await quiet(db);

  assert.equal(asked.length, 3);
  const step = asked[1] ?? [];
  assert.ok(step.some((m) => m.role === 'tool' && m.toolCallId === commandCall.id), 'its own result is in');
  const heard = (messages: readonly ProviderMessage[]) =>
    messages.some((m) => m.role === 'user' && m.text.includes('second'));
  assert.ok(!heard(step), 'the arrival is not spliced into the turn');
  assertEveryCallAnswered(step);
  assert.ok(heard(asked[2] ?? []), 'the next turn carries it');
});

test('two agents that only write to each other are stopped', async () => {
  const pingPong = (other: string) =>
    Array.from({ length: 40 }, (_unused, index) =>
      index % 2 === 0
        ? { toolCalls: [sendCall(`m${index}`, other, 'your turn')] }
        : { text: 'passed it on' },
    );
  const p = pair({ alpha: pingPong('bravo'), bravo: pingPong('alpha') });

  const owner = conversationFor(p.db, p.alpha.id);
  appendMessage(p.db, owner, { role: 'user', content: 'start talking to bravo' });
  p.runner.start(p.alpha, owner);
  await quiet(p.db);

  const threads = [owner, conversationFor(p.db, p.bravo.id)];
  const passed = threads.flatMap((id) => listMessages(p.db, id)).filter((m) => m.role === 'user' && m.sender !== undefined);
  assert.equal(passed.filter((m) => m.content === 'your turn').length, MAX_AGENT_CHAIN, 'no request got past the cap');
  // After the refusal each answers the last request it was sent, once, and that is the end of it.
  assert.equal(passed.filter((m) => m.content === 'passed it on').length, 2);
  assert.ok(agentChain(p.db, threads) >= MAX_AGENT_CHAIN, 'the chain stopped at the cap');
  assert.equal(p.state('alpha'), 'waiting_for_user');
  assert.equal(p.state('bravo'), 'waiting_for_user');
  const refusal = threads.flatMap((id) => listMessages(p.db, id)).find((m) => m.content.includes('back and forth'));
  assert.ok(refusal !== undefined, 'the agent was told why, in a message it can act on');
});

test('requests and the replies routed back count as messages between agents; tool steps do not', () => {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  const bravo = insertAgent(db, 'bravo') as Agent;
  const mine = conversationFor(db, alpha.id);
  const theirs = conversationFor(db, bravo.id);
  appendMessage(db, mine, { role: 'user', content: 'go' });
  appendMessage(db, mine, { role: 'assistant', content: '', sender: 'alpha', toolCalls: [commandCall] });
  appendMessage(db, mine, { role: 'tool', content: 'exit code 0', sender: 'alpha', toolCallId: 'c2' });
  appendMessage(db, theirs, { role: 'user', content: 'hostname?', sender: 'alpha', kind: 'request' });
  appendMessage(db, theirs, { role: 'assistant', content: 'bravo-box', sender: 'bravo' });
  appendMessage(db, mine, { role: 'user', content: 'bravo-box', sender: 'bravo', kind: 'reply' });
  appendMessage(db, mine, { role: 'assistant', content: 'done', sender: 'alpha' });
  assert.equal(agentChain(db, [mine, theirs]), 2, 'the request and the reply, not the tool step or the answers');
  assert.equal(agentChain(db, [mine]), 1);
});

test('the owner writing to either agent resets the chain', () => {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  const bravo = insertAgent(db, 'bravo') as Agent;
  const charlie = insertAgent(db, 'charlie') as Agent;
  const threads = [conversationFor(db, alpha.id), conversationFor(db, bravo.id)];
  for (let i = 0; i < MAX_AGENT_CHAIN; i++) {
    appendMessage(db, threads[i % 2]!, { role: 'user', content: 'again', sender: i % 2 ? 'alpha' : 'bravo' });
  }
  assert.equal(agentChain(db, threads), MAX_AGENT_CHAIN);
  appendMessage(db, conversationFor(db, charlie.id), { role: 'user', content: 'unrelated' });
  assert.equal(agentChain(db, threads), MAX_AGENT_CHAIN, 'a post to a stranger is not the owner joining in');
  appendMessage(db, threads[1]!, { role: 'user', content: 'go ahead' });
  assert.equal(agentChain(db, threads), 0, 'a post in either agent\'s thread resets it');
  appendMessage(db, threads[1]!, { role: 'user', content: 'again', sender: 'alpha' });
  assert.equal(agentChain(db, threads), 1);
});

test('a restart hands back an agent whose reply landed before the daemon died', () => {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  const bravo = insertAgent(db, 'bravo') as Agent;

  // What a daemon killed after bravo answered leaves behind: alpha wrote to bravo, ended its
  // turn waiting, and bravo's answer is stored. The wake only ever fires from inside a live
  // turn, so without a repair nothing would ever start alpha again.
  const mine = conversationFor(db, alpha.id);
  const theirs = conversationFor(db, bravo.id);
  appendMessage(db, theirs, { role: 'user', content: 'hostname?', sender: 'alpha', kind: 'request' });
  appendMessage(db, mine, { role: 'assistant', content: 'asked bravo', sender: 'alpha' });
  appendMessage(db, theirs, { role: 'assistant', content: 'bravo-box', sender: 'bravo' });
  appendMessage(db, mine, { role: 'user', content: 'bravo-box', sender: 'bravo', kind: 'reply' });
  setAgentState(db, 'alpha', 'waiting_for_agent');
  setAgentState(db, 'bravo', 'waiting_for_user');

  reconcileAgents(db);

  assert.equal(findAgent(db, 'alpha')?.state, 'waiting_for_user', 'alpha can be spoken to again');
  assert.equal(findAgent(db, 'bravo')?.state, 'waiting_for_user', 'bravo was not waiting');
  const restart = listEvents(db, alpha.id).find((e) => e.type === 'restart');
  assert.equal(restart?.data['from'], 'waiting_for_agent');
});

test('a restart leaves an agent still genuinely waiting where it stands', () => {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  const bravo = insertAgent(db, 'bravo') as Agent;

  // Same shape, minus the answer: bravo has not replied yet, so alpha is waiting for something
  // that can still arrive, and moving it would throw away the state that lets the reply wake it.
  appendMessage(db, conversationFor(db, bravo.id), { role: 'user', content: 'hostname?', sender: 'alpha', kind: 'request' });
  setAgentState(db, 'alpha', 'waiting_for_agent');

  reconcileAgents(db);

  assert.equal(findAgent(db, 'alpha')?.state, 'waiting_for_agent');
  assert.deepEqual(listEvents(db, alpha.id), []);
});

// ---------------------------------------------------------------- task workers

const spawnCall = (id: string, brief: string) => ({
  id,
  name: 'spawn_task_worker',
  arguments: JSON.stringify({ brief }),
});

const WORKER_DIR = '/home/agent-alpha/workspace/workers/alpha-w1';

test('a worker does the job as its parent, in its own directory, and reports back', async () => {
  const p = pair({
    alpha: [
      { toolCalls: [spawnCall('s1', 'count the files in the workspace')] },
      { text: 'A worker is on it.' },
      { text: 'The worker counted three files.' },
    ],
    'alpha-w1': [{ toolCalls: [commandCall] }, { text: 'there are three files' }],
  });

  const owner = conversationFor(p.db, p.alpha.id);
  appendMessage(p.db, owner, { role: 'user', content: 'how many files are in the workspace?' });
  p.runner.start(p.alpha, owner);
  await quiet(p.db);

  const worker = findAgent(p.db, 'alpha-w1') as Agent;
  assert.equal(worker.parentId, p.alpha.id, 'a worker is an agent row belonging to its parent');
  assert.equal(worker.parentConversationId, owner, 'and it knows which thread it owes an answer');
  assert.equal(worker.state, 'completed', 'which is where a worker that answered ends');
  assert.ok(worker.display > 999, 'and it holds no display a desktop could ever want');

  // The directory exists before the row does, so no worker can be left pointing at nothing.
  assert.ok(
    p.ran.some((argv) => argv.includes('mkdir') && argv.includes(WORKER_DIR)),
    'the working directory was created for it',
  );
  const command = p.ran.find((argv) => argv.includes('uname -a')) ?? [];
  assert.ok(command.includes('agent-alpha'), 'the worker runs as its parent, not as a user of its own');
  assert.ok(command.includes(`--chdir=${WORKER_DIR}`), 'and its commands start in its own directory');

  // Its brief is the first message in a thread of its own: it never sees the owner's.
  const thread = conversationFor(p.db, worker.id);
  const brief = listMessages(p.db, thread)[0];
  assert.equal(brief?.sender, 'alpha');
  assert.match(String(brief?.content), /count the files in the workspace/);
  assert.match(String(brief?.content), new RegExp(WORKER_DIR));

  const asWorker = p.seen.findIndex((messages) => askedAgent(messages) === 'alpha-w1');
  assert.deepEqual(p.offered[asWorker], ['run_command', 'web_search', 'web_fetch'], 'one display, one mouse: no computer tool');

  // The result travels the messaging path, into the thread the parent was in when it spawned.
  const delivered = listMessages(p.db, owner).find((m) => m.sender === 'alpha-w1');
  assert.deepEqual(
    [delivered?.role, delivered?.content],
    ['user', 'there are three files'],
    'the worker answers as itself, in a row its parent picks up like any other message',
  );
  const states = listEvents(p.db, p.alpha.id)
    .filter((event) => event.type === 'state')
    .map((event) => event.data['to']);
  assert.ok(states.includes('waiting_for_task_worker'), 'the parent ended that turn waiting');
  assert.equal(p.state('alpha'), 'waiting_for_user', 'and answered the owner once woken');
  assert.equal(listMessages(p.db, owner).at(-1)?.content, 'The worker counted three files.');
});

test('a result that lands while the parent is mid-turn is picked up, not lost', async () => {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  let release: () => void = () => {};
  const held = new Promise<void>((done) => {
    release = () => done();
  });

  const asked: string[] = [];
  const provider: Provider = async (messages) => {
    const who = askedAgent(messages);
    asked.push(who);
    if (who !== 'alpha') return { text: 'the worker is done', toolCalls: [] };
    const turn = asked.filter((name) => name === 'alpha').length;
    if (turn === 1) return { text: '', toolCalls: [spawnCall('s1', 'do the job')] };
    // The turn that spawned the worker is still running here, and stays running until the
    // result has landed. Nothing may start a second turn for alpha in the meantime.
    if (turn === 2) {
      await held;
      return { text: 'I am waiting on the worker.', toolCalls: [] };
    }
    const heard = messages.flatMap((m) => (m.role === 'user' ? [m.text] : []));
    return { text: `heard ${heard.join(' / ')}`, toolCalls: [] };
  };
  const runner = createRunner({
    db,
    exec: fakeExec([]),
    screen: SCREEN,
    provider: () => provider,
    control: createControl(),
    search: noSearch,
    mcp: noMcp,
    ...CAPS,
  });

  const owner = conversationFor(db, alpha.id);
  appendMessage(db, owner, { role: 'user', content: 'get it done' });
  runner.start(alpha, owner);

  const landed = () => listMessages(db, owner).some((m) => m.sender === 'alpha-w1');
  for (let attempt = 0; attempt < 400 && !landed(); attempt += 1) await tick();
  assert.ok(landed(), 'the worker reported while its parent was still inside its own turn');
  assert.equal(findAgent(db, 'alpha')?.state, 'thinking', 'and the parent was busy when it did');

  release();
  await quiet(db);

  assert.equal(asked.filter((name) => name === 'alpha').length, 3, 'the result got its own turn');
  assert.match(String(listMessages(db, owner).at(-1)?.content), /the worker is done/);
  assert.equal(findAgent(db, 'alpha')?.state, 'waiting_for_user');
});

test('a worker that fails tells its parent why instead of leaving it waiting', async () => {
  // No script for the worker, so its very first model call rejects: a provider that is down
  // looks exactly like this, and it is the case that would otherwise hang the parent.
  const p = pair({
    alpha: [
      { toolCalls: [spawnCall('s1', 'do the impossible')] },
      { text: 'A worker is on it.' },
      { text: 'The worker says it could not.' },
    ],
  });

  const owner = conversationFor(p.db, p.alpha.id);
  appendMessage(p.db, owner, { role: 'user', content: 'do the impossible' });
  p.runner.start(p.alpha, owner);
  await quiet(p.db);

  assert.equal(p.state('alpha-w1'), 'failed');
  const told = listMessages(p.db, owner).find((m) => m.sender === 'alpha-w1');
  assert.match(String(told?.content), /could not finish the job/);
  assert.equal(p.state('alpha'), 'waiting_for_user', 'the parent was woken, not left waiting');
  assert.equal(listMessages(p.db, owner).at(-1)?.content, 'The worker says it could not.');
});

test('a spawn above the worker cap is refused with a message that names the cap', async () => {
  const p = pair(
    { alpha: [{ toolCalls: [spawnCall('s1', 'job two')] }, { text: 'There was no room.' }] },
    { maxLoops: 4, maxWorkers: 1 },
  );
  const owner = conversationFor(p.db, p.alpha.id);
  // One worker already alive, so the cap is full before the turn starts.
  insertWorker(p.db, p.alpha, 'alpha-w1', owner);

  appendMessage(p.db, owner, { role: 'user', content: 'spawn another one' });
  p.runner.start(p.alpha, owner);
  await quiet(p.db);

  const refusal = listMessages(p.db, owner).find((m) => m.role === 'tool');
  assert.match(String(refusal?.content), /at most 1 task workers can be live at once/);
  assert.equal(findAgent(p.db, 'alpha-w2'), undefined, 'nothing was created for the refused one');
  assert.equal(p.state('alpha'), 'waiting_for_user', 'a refused tool is an observation, not a failure');
});

test('a turn above the loop cap waits in the queue instead of running', async () => {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  const bravo = insertAgent(db, 'bravo') as Agent;
  // A turn that never finishes, so the one loop this runner allows stays taken.
  const runner = createRunner({
    db,
    exec: fakeExec([]),
    screen: SCREEN,
    provider: () => () => new Promise(() => {}),
    control: createControl(),
    search: noSearch,
    mcp: noMcp,
    maxLoops: 1,
    maxWorkers: 1,
  });

  assert.equal(runner.atCapacity('alpha'), undefined, 'nothing is running yet');
  appendMessage(db, conversationFor(db, alpha.id), { role: 'user', content: 'go' });
  runner.start(alpha, conversationFor(db, alpha.id));
  assert.equal(runner.atCapacity('alpha'), undefined, 'an agent already running is not a new loop');
  assert.match(String(runner.atCapacity('bravo')), /at most 1 agent loops can run at once/);
  assert.match(String(runner.atCapacity()), /at most 1 agent loops can run at once/);

  appendMessage(db, conversationFor(db, bravo.id), { role: 'user', content: 'and you' });
  runner.start(bravo, conversationFor(db, bravo.id), undefined, 'schedule');
  await tick();
  assert.equal(runner.running('bravo'), false);
  assert.deepEqual(
    queuedTurns(db).map((entry) => [entry.agentId, entry.kind]),
    [[bravo.id, 'schedule']],
  );
});

/** A runner on one loop whose agents answer from a script, and whose `gated` agents' first
 * call waits for `open()`. Every request is counted by agent. */
function capped(db: Db, script: Record<string, readonly Partial<ChatReply>[]>, gated: readonly string[] = []) {
  const { provider: scripted } = scriptedProvider(script);
  const calls = new Map<string, number>();
  let open: () => void = () => {};
  const gate = new Promise<void>((done) => {
    open = () => done();
  });
  const provider: Provider = async (messages, tools, onDelta, signal) => {
    const name = askedAgent(messages);
    const count = (calls.get(name) ?? 0) + 1;
    calls.set(name, count);
    if (count === 1 && gated.includes(name)) await gate;
    return scripted(messages, tools, onDelta, signal);
  };
  const runner = createRunner({
    db,
    exec: fakeExec([]),
    screen: SCREEN,
    provider: () => provider,
    control: createControl(),
    search: noSearch,
    mcp: noMcp,
    maxLoops: 1,
    maxWorkers: 2,
  });
  return { runner, calls, open };
}

const WAITING_STATES = ['waiting_for_agent', 'waiting_for_task_worker'];

test('at a loop cap of 1, every turn started past the cap runs eventually and nobody is left waiting', async () => {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  const bravo = insertAgent(db, 'bravo') as Agent;
  const charlie = insertAgent(db, 'charlie') as Agent;
  const delta = insertAgent(db, 'delta') as Agent;
  const echo = insertAgent(db, 'echo') as Agent;
  const { runner, calls, open } = capped(
    db,
    {
      alpha: [{ text: 'the worker says 42' }],
      bravo: [{ text: 'bravo here' }],
      charlie: [{ text: 'charlie here' }],
      delta: [{ text: 'report written' }],
      echo: [{ text: 'echo done' }],
      'alpha-w1': [{ text: '42' }],
    },
    ['echo'],
  );

  appendMessage(db, conversationFor(db, echo.id), { role: 'user', content: 'take the loop' });
  runner.start(echo, conversationFor(db, echo.id));
  await tick();
  assert.equal(runner.running('echo'), true, 'echo holds the only loop');

  // Two owner messages, a worker, and a schedule, all while the loop is taken.
  appendMessage(db, conversationFor(db, bravo.id), { role: 'user', content: 'hello bravo' });
  runner.start(bravo, conversationFor(db, bravo.id));
  appendMessage(db, conversationFor(db, charlie.id), { role: 'user', content: 'hello charlie' });
  runner.start(charlie, conversationFor(db, charlie.id));
  // Where a spawning turn leaves its agent. Spawning at the cap is refused before a worker
  // exists, so this one is made the way a spawn in a freer moment would have: its brief stored
  // and its start asked for. When it runs it holds the only loop, so its report's start on
  // alpha is the one that used to be dropped.
  const mine = conversationFor(db, alpha.id);
  setAgentState(db, 'alpha', 'waiting_for_task_worker');
  const worker = insertWorker(db, alpha, 'alpha-w1', mine);
  appendMessage(db, conversationFor(db, worker.id), { role: 'user', content: 'count them', sender: 'alpha' });
  runner.start(worker, conversationFor(db, worker.id));
  const job = insertSchedule(db, delta, { cron: '0 8 * * *', prompt: 'write the report' }, Date.now()) as Schedule;
  assert.equal(runDue(db, runner, job.nextRunAt), 1);
  assert.deepEqual(queuedTurns(db).map((entry) => entry.kind), ['message', 'message', 'message', 'schedule']);

  open();
  await quiet(db);

  assert.deepEqual(queuedTurns(db), []);
  assert.equal(findAgent(db, 'alpha-w1')?.state, 'completed');
  const said = (agent: Agent) => listMessages(db, conversationFor(db, agent.id)).filter((m) => m.sender === agent.name).map((m) => m.content);
  assert.deepEqual(said(alpha), ['the worker says 42'], "the worker's report got a turn of its own");
  assert.deepEqual(said(bravo), ['bravo here']);
  assert.deepEqual(said(charlie), ['charlie here']);
  assert.deepEqual(said(delta), ['report written'], 'the schedule got its turn');
  assert.deepEqual(said(echo), ['echo done']);
  for (const agent of listAgents(db)) {
    assert.ok(!WAITING_STATES.includes(agent.state), `${agent.name} was left ${agent.state}`);
  }
  assert.equal(findAgent(db, 'alpha')?.state, 'waiting_for_user');
  assert.equal(calls.get('alpha'), 1);
});

test('a queued turn survives a restart, and a turn the restart killed is not run again', async () => {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  const bravo = insertAgent(db, 'bravo') as Agent;
  const charlie = insertAgent(db, 'charlie') as Agent;

  // First daemon: alpha's turn never ends; bravo and charlie wait in line behind it.
  const first = capped(db, {}, ['alpha']);
  appendMessage(db, conversationFor(db, alpha.id), { role: 'user', content: 'crash me' });
  first.runner.start(alpha, conversationFor(db, alpha.id));
  appendMessage(db, conversationFor(db, bravo.id), { role: 'user', content: 'for bravo' });
  first.runner.start(bravo, conversationFor(db, bravo.id));
  appendMessage(db, conversationFor(db, charlie.id), { role: 'user', content: 'for charlie' });
  first.runner.start(charlie, conversationFor(db, charlie.id));
  await tick();
  assert.equal(queuedTurns(db).length, 2);

  // Second daemon: the boot sweep pops bravo, whose turn dies with this daemon too.
  reconcileAgents(db);
  const second = capped(db, {}, ['bravo']);
  second.runner.sweep();
  await tick();
  assert.equal(second.runner.running('bravo'), true, 'the oldest entry got the loop');
  assert.equal(second.calls.get('alpha'), undefined, 'the turn the restart killed is not re-run');

  // Third daemon: charlie is still queued; neither killed turn comes back.
  reconcileAgents(db);
  const third = capped(db, { charlie: [{ text: 'charlie answers' }] });
  third.runner.sweep();
  await quiet(db);
  assert.deepEqual([...third.calls.keys()], ['charlie']);
  assert.equal(listMessages(db, conversationFor(db, charlie.id)).at(-1)?.content, 'charlie answers');
  assert.deepEqual(queuedTurns(db), []);
  assert.equal(findAgent(db, 'alpha')?.state, 'waiting_for_user');
  assert.equal(findAgent(db, 'bravo')?.state, 'waiting_for_user');
});

test('the sweep queues unread input, skips an agent with no model, and drops an entry with nothing to read', async () => {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  const bravo = insertAgent(db, 'bravo') as Agent;
  const charlie = insertAgent(db, 'charlie') as Agent;
  const { provider } = scriptedProvider({ alpha: [{ text: 'read it' }] });
  const runner = createRunner({
    db,
    exec: fakeExec([]),
    screen: SCREEN,
    provider: (agent) => (agent.name === 'bravo' ? undefined : provider),
    control: createControl(),
    search: noSearch,
    mcp: noMcp,
    maxLoops: 1,
    maxWorkers: 1,
  });
  // Stored with no start, the way a dropped turn left it.
  appendMessage(db, conversationFor(db, alpha.id), { role: 'user', content: 'nobody read this' });
  appendMessage(db, conversationFor(db, bravo.id), { role: 'user', content: 'no model yet' });
  // Queued, then its thread cleared while it waited.
  enqueueTurn(db, charlie.id, conversationFor(db, charlie.id), 'message');

  runner.sweep();
  await quiet(db);

  assert.equal(listMessages(db, conversationFor(db, alpha.id)).at(-1)?.content, 'read it');
  assert.equal(findAgent(db, 'bravo')?.state, 'idle', 'no model, no turn: it waits for one');
  assert.deepEqual(queuedTurns(db), []);
  assert.equal(findAgent(db, 'charlie')?.state, 'idle', 'nothing to read, so no turn');

  // Read means read: a second sweep over the same rows starts nothing.
  runner.sweep();
  await quiet(db);
  assert.equal(listMessages(db, conversationFor(db, alpha.id)).length, 2);
});

test('the sweep hands back an agent waiting on nobody and leaves one still waited on', () => {
  const db = openDb(':memory:', MIGRATIONS);
  insertAgent(db, 'asker');
  const stopped = insertAgent(db, 'stopped') as Agent;
  insertAgent(db, 'patient');
  const busy = insertAgent(db, 'busy') as Agent;
  const parent = insertAgent(db, 'parent') as Agent;
  const done = insertAgent(db, 'done') as Agent;
  const { runner } = capped(db, {});

  // asker wrote to stopped, whose turn was stopped and never answered.
  appendMessage(db, conversationFor(db, stopped.id), { role: 'user', content: 'q', sender: 'asker', kind: 'request' });
  appendMessage(db, conversationFor(db, stopped.id), { role: 'assistant', content: STOPPED, sender: 'stopped' });
  setAgentState(db, 'asker', 'waiting_for_agent');
  setAgentState(db, 'stopped', 'waiting_for_user');
  // patient wrote to busy, which is itself waiting on its worker.
  appendMessage(db, conversationFor(db, busy.id), { role: 'user', content: 'q', sender: 'patient', kind: 'request' });
  appendMessage(db, conversationFor(db, busy.id), { role: 'assistant', content: 'on it', sender: 'busy' });
  setAgentState(db, 'patient', 'waiting_for_agent');
  setAgentState(db, 'busy', 'waiting_for_task_worker');
  const working = insertWorker(db, busy, 'busy-w1', conversationFor(db, busy.id));
  setAgentState(db, working.name, 'using_terminal');
  // parent's worker is still live; done's worker finished.
  insertWorker(db, parent, 'parent-w1', conversationFor(db, parent.id));
  setAgentState(db, 'parent', 'waiting_for_task_worker');
  const finished = insertWorker(db, done, 'done-w1', conversationFor(db, done.id));
  setAgentState(db, finished.name, 'completed');
  setAgentState(db, 'done', 'waiting_for_task_worker');

  runner.sweep();

  assert.equal(findAgent(db, 'asker')?.state, 'waiting_for_user', 'a stopped turn will never answer');
  assert.equal(findAgent(db, 'patient')?.state, 'waiting_for_agent');
  assert.equal(findAgent(db, 'busy')?.state, 'waiting_for_task_worker');
  assert.equal(findAgent(db, 'parent')?.state, 'waiting_for_task_worker');
  assert.equal(findAgent(db, 'done')?.state, 'waiting_for_user', 'its worker is done');
});

test('an idle pass that finds the loop taken is ended unrun, never queued', async () => {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  const bravo = insertAgent(db, 'bravo') as Agent;
  const { runner } = capped(db, {}, ['alpha']);
  appendMessage(db, conversationFor(db, alpha.id), { role: 'user', content: 'hold the loop' });
  runner.start(alpha, conversationFor(db, alpha.id));
  const ended: (number | undefined)[] = [];
  runner.start(bravo, conversationFor(db, bravo.id), {
    passId: 1,
    modelId: null,
    turnCap: 1,
    tokenLimit: 1,
    end: (tokens) => {
      ended.push(tokens);
      return Promise.resolve();
    },
  });
  await tick();
  assert.deepEqual(ended, [undefined]);
  assert.deepEqual(queuedTurns(db), []);
});

test('a restart marks a running worker failed and tells its parent', () => {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  const owner = conversationFor(db, alpha.id);
  const worker = insertWorker(db, alpha, 'alpha-w1', owner);

  // What a daemon killed with a worker running leaves behind: a row claiming work no process is
  // doing, and a parent waiting for a result that will never be written.
  setAgentState(db, worker.name, 'using_terminal');
  setAgentState(db, alpha.name, 'waiting_for_task_worker');
  appendMessage(db, owner, { role: 'user', content: 'count the files' });
  appendMessage(db, owner, { role: 'assistant', content: 'a worker is on it', sender: 'alpha' });

  reconcileAgents(db);

  assert.equal(findAgent(db, 'alpha-w1')?.state, 'failed');
  const told = listMessages(db, owner).at(-1);
  assert.equal(told?.sender, 'alpha-w1', 'the parent was told by the worker itself');
  assert.match(String(told?.content), /daemon restarted/);
  assert.equal(findAgent(db, 'alpha')?.state, 'waiting_for_user', 'and is answerable again');
  assert.ok(listEvents(db, worker.id).some((event) => event.type === 'restart'));
});

test('a worker prompt names the worker the way the scripted endpoint reads it', () => {
  const worker: Agent = { ...ALPHA, id: 2, name: 'alpha-w1', parentId: 1, parentConversationId: 1 };
  const prompt = workerPrompt(worker, 'alpha');

  assert.match(prompt, /^You are alpha-w1,/, 'the line every transcript is keyed off');
  assert.match(prompt, /task worker/, 'and how the smoke stub tells a worker from an agent');
});

// ---------------------------------------------------------------- memory and skills

const SKILL_PATH = '/home/agent-alpha/skills/deploy/SKILL.md';
const SKILL_FILE = '---\nname: deploy\ndescription: how we ship\n---\n\nRun the deploy script.';

/**
 * A spawn boundary with a home behind it: the append script's stdin lands in a map and the load
 * script reads it back in the shape the real `head -c` pass prints, so a line remembered in one
 * turn is a line the next turn's load finds on disk.
 */
function homeExec(ran: string[][]): Exec {
  const files = new Map<string, string>();
  return (file, args, options = {}) => {
    ran.push([file, ...args]);
    const answer = (stdout: Buffer) => Promise.resolve({ code: 0, stdout, stderr: '', truncated: false });
    if (file === 'getent') {
      const user = String(args[1]);
      return answer(Buffer.from(`${user}:x:1001:1001::/home/${user}:/bin/bash\n`));
    }
    if (args.includes(HOME_APPEND)) {
      const name = String(args.at(-1));
      files.set(name, (files.get(name) ?? '') + (options.input ?? ''));
      return answer(Buffer.alloc(0));
    }
    if (args.includes(HOME_LOAD)) {
      const mark = String(args.at(-1));
      const memory = files.get('MEMORY.md') ?? '';
      return answer(
        Buffer.from(`\n${mark} memory\n${memory}\n${mark} skill ${SKILL_PATH}\n${SKILL_FILE}`),
      );
    }
    return answer(PNG);
  };
}

const rememberCall = (id: string, text: string, scope: string) => ({
  id,
  name: 'remember',
  arguments: JSON.stringify({ text, scope }),
});

function systemOf(messages: readonly ProviderMessage[] | undefined): string {
  const system = messages?.[0];
  return system?.role === 'system' ? system.text : '';
}

test('a line remembered in one conversation is in the system prompt of the next', async () => {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  const bravo = insertAgent(db, 'bravo') as Agent;
  const ran: string[][] = [];
  const exec = homeExec(ran);
  const { provider, seen, offered } = scriptedProvider({
    alpha: [
      { toolCalls: [rememberCall('r1', 'the owner is called Roan', 'lasting')] },
      { text: 'Noted.' },
      { text: 'You are Roan.' },
    ],
  });
  const control = createControl();
  const runner = createRunner({ db, exec, screen: SCREEN, provider: () => provider, control, search: noSearch, mcp: noMcp, ...CAPS });
  const deps = { db, exec, provider, screen: SCREEN, runner, control, search: noSearch, mcp: noMcp, maxWorkers: CAPS.maxWorkers };

  const owner = conversationFor(db, alpha.id);
  appendMessage(db, owner, { role: 'user', content: 'I am Roan' });
  await runAgent(deps, alpha, owner);

  assert.ok(offered[0]?.includes('remember'), 'a permanent agent is offered the tool');
  assert.doesNotMatch(systemOf(seen[0]), /Roan/, 'nothing was remembered when the turn started');
  const written = listMessages(db, owner).find((message) => message.toolCallId === 'r1');
  assert.equal(written?.content, 'Written to /home/agent-alpha/memory/MEMORY.md.');

  // A cleared thread: nothing but the loaded file can carry the fact into it.
  deleteConversation(db, owner);
  const fresh = conversationFor(db, alpha.id);
  appendMessage(db, fresh, { role: 'user', content: 'who am I?' });
  await runAgent(deps, alpha, fresh);

  const later = systemOf(seen.at(-1));
  assert.match(later, /- the owner is called Roan/, 'the remembered line reached the next turn');
  assert.match(later, /deploy: how we ship/, 'and so did the skills index');
  assert.match(later, new RegExp(SKILL_PATH), 'with the path to read for the rest of it');
  assert.doesNotMatch(later, /Run the deploy script/, 'but never the body');
});

test('a question to the owner ends the turn, and the profile written after the answer is in the next prompt', async () => {
  const askCall = {
    id: 'q1',
    name: 'ask_owner',
    arguments: JSON.stringify({
      questions: [{ question: 'What am I for?', header: 'Purpose', options: [{ label: 'Spreadsheets' }, { label: 'Email' }] }],
    }),
  };
  const profileCall = {
    id: 'p1',
    name: 'set_profile',
    arguments: JSON.stringify({ profile: '# Excel\nBuilds spreadsheets for the owner.' }),
  };
  const f = fixture([
    // Asked alongside another call: both get their result, and the turn still ends there.
    { text: 'Hi, a question first.', toolCalls: [askCall, commandCall] },
    { toolCalls: [profileCall] },
    { text: 'Written down.' },
    { text: 'I build spreadsheets.' },
  ]);

  f.ask('I just created you.');
  await runAgent(f.deps, f.agent, f.conversationId);
  assert.equal(f.state(), 'waiting_for_user');
  assert.match(systemOf(f.seen[0]), /no profile yet/);
  assert.ok(f.offered[0]?.includes('ask_owner') && f.offered[0]?.includes('set_profile'));
  assert.deepEqual(f.messages().map((m) => m.role), ['user', 'assistant', 'tool', 'tool']);
  assert.match(String(f.messages().find((m) => m.toolCallId === 'q1')?.content), /Asked the owner 1 question/);
  assert.equal(f.seen.length, 1, 'no second model call after the question');

  f.ask('Purpose: What am I for?\n— Spreadsheets');
  await runAgent(f.deps, f.agent, f.conversationId);
  assert.equal(findAgent(f.db, 'alpha')?.profile, '# Excel\nBuilds spreadsheets for the owner.');
  assert.equal(f.state(), 'waiting_for_user');

  f.ask('what are you?');
  await runAgent(f.deps, f.agent, f.conversationId);
  const later = systemOf(f.seen.at(-1));
  assert.match(later, /Builds spreadsheets for the owner/);
  assert.doesNotMatch(later, /no profile yet/);
});

test('request_approval and request_deletion both leave a standing request and change nothing else', async () => {
  const f = fixture([
    {
      toolCalls: [
        {
          id: 'a1',
          name: 'request_approval',
          arguments: JSON.stringify({ category: 'install_software', reason: 'needs jq', target: 'jq' }),
        },
        { id: 'd1', name: 'request_deletion', arguments: JSON.stringify({ what: 'conversation', reason: 'done here' }) },
        { id: 'a2', name: 'request_approval', arguments: JSON.stringify({ category: 'nonsense', reason: 'x' }) },
      ],
    },
    { text: 'Waiting on the owner.' },
  ]);
  const delivered: string[] = [];
  f.ask('tidy up');
  await runAgent(
    { ...f.deps, deliver: (_agent, _conversation, text, kind) => delivered.push(`${kind}: ${text}`) },
    f.agent,
    f.conversationId,
  );

  assert.ok(f.offered[0]?.includes('request_approval') && f.offered[0]?.includes('request_deletion'));
  assert.deepEqual(
    listApprovals(f.db).map((a) => [a.kind, a.category, a.target]),
    [
      ['action', 'install_software', 'jq'],
      ['conversation', 'delete_files', String(f.conversationId)],
    ],
  );
  const result = (id: string) => String(f.messages().find((m) => m.toolCallId === id)?.content);
  assert.match(result('a1'), /Request 1 to install software: jq is waiting for the owner, shown to them in this thread and in Needs you\. Do not do it yet\./);
  assert.match(result('d1'), /Nothing has been deleted/);
  assert.match(result('a2'), /^error: category must be one of/);
  assert.deepEqual(delivered.slice(0, 2), [
    'approval: Asks to install software: jq: needs jq',
    'approval: Asks to delete the thread it asked in: done here',
  ]);
  assert.equal(
    f.events().filter((e) => e.type === 'approval').map((e) => e.data['category']).join(),
    'install_software,delete_files',
  );
});

test('the home is read once per turn, however many steps the turn takes', async () => {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  const ran: string[][] = [];
  const exec = homeExec(ran);
  const { provider, seen } = scriptedProvider({
    alpha: [
      { toolCalls: [rememberCall('r1', 'first', 'today')] },
      { toolCalls: [rememberCall('r2', 'second', 'lasting')] },
      { text: 'Both written.' },
    ],
  });
  const control = createControl();
  const runner = createRunner({ db, exec, screen: SCREEN, provider: () => provider, control, search: noSearch, mcp: noMcp, ...CAPS });
  const deps = { db, exec, provider, screen: SCREEN, runner, control, search: noSearch, mcp: noMcp, maxWorkers: CAPS.maxWorkers };

  const owner = conversationFor(db, alpha.id);
  appendMessage(db, owner, { role: 'user', content: 'write both down' });
  await runAgent(deps, alpha, owner);

  assert.equal(ran.filter((argv) => argv.includes(HOME_LOAD)).length, 1, 'one load, three steps');
  const texts = new Set(seen.map(systemOf));
  assert.equal(texts.size, 1, 'so every step of the turn was handed the same system text');

  // The daily note is a different file, and neither path ever came from the model.
  const appends = ran.filter((argv) => argv.includes(HOME_APPEND)).map((argv) => argv.at(-1));
  assert.equal(appends[1], 'MEMORY.md');
  assert.match(String(appends[0]), /^\d{4}-\d{2}-\d{2}\.md$/);
});

test('a task worker gets neither memory nor skills, and cannot remember', async () => {
  const p = pair({
    alpha: [
      { toolCalls: [spawnCall('s1', 'count the files')] },
      { text: 'A worker is on it.' },
      { text: 'It counted three.' },
    ],
    'alpha-w1': [
      { toolCalls: [rememberCall('r1', 'I counted three files', 'lasting')] },
      { text: 'there are three files' },
    ],
  });

  const owner = conversationFor(p.db, p.alpha.id);
  appendMessage(p.db, owner, { role: 'user', content: 'how many files?' });
  p.runner.start(p.alpha, owner);
  await quiet(p.db);

  const asWorker = p.seen.findIndex((messages) => askedAgent(messages) === 'alpha-w1');
  assert.deepEqual(p.offered[asWorker], ['run_command', 'web_search', 'web_fetch'], 'the tool is not on its list');
  assert.doesNotMatch(systemOf(p.seen[asWorker]), /Your memory/, 'and no memory is in its prompt');

  const worker = findAgent(p.db, 'alpha-w1') as Agent;
  const refused = listMessages(p.db, conversationFor(p.db, worker.id)).find(
    (message) => message.toolCallId === 'r1',
  );
  assert.equal(refused?.content, 'error: no tool named remember');
  assert.equal(p.ran.filter((argv) => argv.includes(HOME_APPEND)).length, 0, 'nothing was written');
});

test('a home that cannot be read costs the agent its memory, not its turn', async () => {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  const exec: Exec = (file) =>
    file === 'getent'
      ? Promise.reject(new Error('no such user'))
      : Promise.resolve({ code: 0, stdout: PNG, stderr: '', truncated: false });
  const { provider, seen } = scriptedProvider({ alpha: [{ text: 'I am here.' }] });
  const control = createControl();
  const runner = createRunner({ db, exec, screen: SCREEN, provider: () => provider, control, search: noSearch, mcp: noMcp, ...CAPS });

  const owner = conversationFor(db, alpha.id);
  appendMessage(db, owner, { role: 'user', content: 'hello' });
  await runAgent(
    { db, exec, provider, screen: SCREEN, runner, control, search: noSearch, mcp: noMcp, maxWorkers: CAPS.maxWorkers },
    alpha,
    owner,
  );

  assert.equal(findAgent(db, 'alpha')?.state, 'waiting_for_user');
  assert.match(systemOf(seen[0]), /Your memory/, 'the tail is there, saying the file is empty');
  assert.match(systemOf(seen[0]), /\(empty\)/);
});

test('what the loader parses is what the home printed', () => {
  const mark = 'abc-123';
  const raw =
    `\n${mark} memory\n- one\n- two\n` +
    `\n${mark} skill /home/agent-alpha/skills/deploy/SKILL.md\n` +
    '---\nname: deploy\ndescription: how we ship\n---\nbody\n' +
    `\n${mark} skill /srv/schermes/shared/skills/notes/SKILL.md\nno frontmatter at all\n`;
  const home = parseHome(raw, mark);

  assert.equal(home.memory, '- one\n- two');
  assert.deepEqual(home.skills[0], {
    name: 'deploy',
    description: 'how we ship',
    path: '/home/agent-alpha/skills/deploy/SKILL.md',
  });
  // A skill with no frontmatter is still a skill: its folder names it and the agent reads it.
  assert.equal(home.skills[1]?.name, 'notes');
  assert.equal(home.skills[1]?.description, '');

  // A file that prints the marker cannot forge a section: the marker is new on every load.
  const forged = parseHome(`\n${mark} memory\n- one\nfake-mark skill /etc/shadow\nx`, mark);
  assert.equal(forged.skills.length, 0);

  const bare = parseHome('', mark);
  assert.equal(bare.memory, '');
  assert.match(homePrompt(bare), /no skills yet/);
});

// ---------------------------------------------------------------- compaction

/**
 * A thread of complete turns: an assistant message with a tool call, then its result. What
 * grows is the assistant text, because a tool result older than the newest few is trimmed and a
 * transcript therefore cannot be pushed past the budget with tool output alone.
 */
function longThread(
  db: Db,
  conversationId: number,
  turns: number,
  chars: number,
  options: { perTurn?: number; label?: string; sender?: string } = {},
): void {
  const { perTurn = 1, label = 'A', sender = 'alpha' } = options;
  appendMessage(db, conversationId, { role: 'user', content: 'read the logs' });
  for (let turn = 0; turn < turns; turn += 1) {
    const calls = Array.from({ length: perTurn }, (_unused, index) => ({
      id: `t${label}-${turn}-${index}`,
      name: 'run_command',
      arguments: '{"command":"cat log"}',
    }));
    appendMessage(db, conversationId, {
      role: 'assistant',
      content: `(${label}${turn}) ${'x'.repeat(chars)}`,
      sender,
      toolCalls: calls,
    });
    for (const call of calls) {
      appendMessage(db, conversationId, {
        role: 'tool',
        content: `exit code 0 (${label}${turn})`,
        sender,
        toolCallId: call.id,
      });
    }
  }
}

/** Turns of this size, so the thread is past the budget and the tail is several turns short of
 * it: both sides of the cut have to hold something for the test to mean anything. */
const TURN_CHARS = 30_000;
const LONG_TURNS = Math.ceil(MAX_TRANSCRIPT_CHARS / TURN_CHARS) + 2;

/**
 * The other half of the rule `assertEveryCallAnswered` enforces. A cut that lands inside a turn
 * leaves a tool result whose assistant message is gone, and a strict endpoint rejects that
 * request exactly as it rejects a call nothing answered.
 */
function assertNoOrphanResult(messages: readonly ProviderMessage[]): void {
  const asked = new Set<string>();
  for (const message of messages) {
    if (message.role === 'assistant') for (const call of message.toolCalls) asked.add(call.id);
    if (message.role === 'tool') {
      assert.ok(asked.has(message.toolCallId), `${message.toolCallId} answers a call nothing made`);
    }
  }
}

/** What one model call was handed, minus the system message. */
function replayed(messages: readonly ProviderMessage[] | undefined): ProviderMessage[] {
  return (messages ?? []).slice(1);
}

test('a thread past the budget is replayed as a summary and a tail, and loses no history', async () => {
  const f = fixture([{ text: 'nothing was wrong.' }]);
  longThread(f.db, f.conversationId, LONG_TURNS, TURN_CHARS);
  const stored = f.messages().length;

  await runAgent(f.deps, f.agent, f.conversationId);

  assert.equal(f.summarised.length, 1, 'the thread was over the budget and was compacted');
  const asked = f.seen[0] as ProviderMessage[];
  assertEveryCallAnswered(asked);
  assertNoOrphanResult(asked);

  // The summary is its own message after the system text, not part of it.
  assert.equal(asked[0]?.role, 'system');
  assert.match(String(asked[1]?.text), new RegExp(`summarised:\\n${SUMMARY}$`));
  assert.equal(asked[2]?.role, 'assistant', 'and the tail begins at the start of a turn');

  // Shorter than the thread it stands for, and long enough to still be the thread.
  const turns = replayed(asked).filter((m) => m.role === 'assistant').length;
  assert.ok(turns > 0 && turns < LONG_TURNS, `${turns} of ${LONG_TURNS} turns replayed verbatim`);
  const tail = replayed(asked).reduce((total, m) => total + m.text.length, 0);
  assert.ok(tail <= MAX_TRANSCRIPT_CHARS, `the request is back under the budget (${tail})`);

  // The newest turns are the ones kept, and the oldest are the ones the summary stands for.
  assert.ok(
    replayed(asked).some((m) => m.role === 'assistant' && m.text.startsWith(`(A${LONG_TURNS - 1})`)),
    'the last turn is in the tail',
  );
  assert.ok(
    !replayed(asked).some((m) => m.role === 'assistant' && m.text.startsWith('(A0)')),
    'the first one is not',
  );

  // Nothing was rewritten: the rows the UI reads are the ones that were always there, plus the
  // answer this turn wrote.
  assert.equal(f.messages().length, stored + 1);
  assert.ok(f.messages().some((m) => m.content.startsWith('(A0) ')), 'including the summarised ones');

  const summary = latestSummary(f.db, f.conversationId, 'alpha');
  assert.equal(summary?.content, SUMMARY);
  assert.equal(summary?.fromMessageId, f.messages()[0]?.id, 'it covers the thread from its start');
  assert.ok(
    Number(summary?.throughMessageId) < Number(f.messages().at(-2)?.id),
    'and stops short of the tail',
  );
});

test('the summary is written once per turn, however many steps the turn takes', async () => {
  const f = fixture([
    { toolCalls: [commandCall] },
    { toolCalls: [commandCall] },
    { text: 'still nothing wrong.' },
  ]);
  longThread(f.db, f.conversationId, LONG_TURNS, TURN_CHARS);

  await runAgent(f.deps, f.agent, f.conversationId);

  assert.equal(f.seen.length, 3, 'three steps');
  assert.equal(f.summarised.length, 1, 'and one summary, decided before the first of them');
  assert.equal(
    new Set(f.seen.map((messages) => messages[1]?.text)).size,
    1,
    'so every step was handed the same summary, byte for byte',
  );
  assert.equal(new Set(f.seen.map(systemOf)).size, 1, 'and the same system text');

  const rows = f.messages().filter((m) => m.toolCallId === commandCall.id);
  assert.equal(rows.length, 2, 'the turn itself ran normally, twice through the terminal');
});

test('a second compaction summarises what happened since the first, not the thread again', async () => {
  const f = fixture([{ text: 'first answer.' }, { text: 'second answer.' }]);
  longThread(f.db, f.conversationId, LONG_TURNS, TURN_CHARS);
  await runAgent(f.deps, f.agent, f.conversationId);
  const first = latestSummary(f.db, f.conversationId, 'alpha');

  // Enough new work to pass the budget again on top of the tail the first pass kept.
  longThread(f.db, f.conversationId, LONG_TURNS, TURN_CHARS, { label: 'B' });
  await runAgent(f.deps, f.agent, f.conversationId);
  const second = latestSummary(f.db, f.conversationId, 'alpha');

  assert.equal(f.summarised.length, 2);
  assert.ok(Number(second?.id) > Number(first?.id), 'a second summary row, not an edited first');
  assert.equal(
    second?.fromMessageId,
    Number(first?.throughMessageId) + 1,
    'it starts where the first one stopped',
  );

  // The messages the first summary already stands for are not sent to be summarised twice; what
  // carries their content forward is the summary itself.
  const input = String(f.summarised[1]);
  assert.match(input, new RegExp(`^The story so far:\\n${SUMMARY}`));
  assert.equal(input.split(SUMMARY).length - 1, 1, 'the story so far is told once');
  assert.ok(!input.includes('(A0) '), 'what the first summary already stands for is not re-read');
  assert.ok(input.includes('(B0) '), 'but what happened since it is');
});

test('a thread under the budget is replayed whole and costs no summary call', async () => {
  const f = fixture([{ text: 'short and sweet.' }]);
  longThread(f.db, f.conversationId, 2, 1_000);

  await runAgent(f.deps, f.agent, f.conversationId);

  assert.deepEqual(f.summarised, [], 'nothing was summarised');
  assert.equal(latestSummary(f.db, f.conversationId, 'alpha'), undefined, 'and nothing was stored');
  const asked = f.seen[0] as ProviderMessage[];
  assert.equal(asked[1]?.role, 'user', 'the thread starts with what the owner said');
  assert.match(String(asked[1]?.text), /read the logs/);
});

test('the cut lands between turns, never inside one', async () => {
  // Two tool calls per turn, so there are two places inside every turn a cut chosen by
  // character count alone could land, and one place it may.
  const f = fixture([{ text: 'done.' }]);
  longThread(f.db, f.conversationId, LONG_TURNS, TURN_CHARS, { perTurn: 2 });

  await runAgent(f.deps, f.agent, f.conversationId);

  assert.equal(f.summarised.length, 1);
  const asked = f.seen[0] as ProviderMessage[];
  assertEveryCallAnswered(asked);
  assertNoOrphanResult(asked);
  assert.equal(asked[2]?.role, 'assistant', 'the tail begins with a turn, not with half of one');

  // The two assertions above have teeth: cutting one message further on, which is inside the
  // turn the tail begins with, is exactly the shape they reject.
  const through = Number(latestSummary(f.db, f.conversationId, 'alpha')?.throughMessageId);
  const inside = f.messages().find((m) => m.id > through)?.id ?? 0;
  assert.throws(() =>
    assertNoOrphanResult(transcript('alpha', SYSTEM, f.messages(), { text: SUMMARY, throughId: inside })),
  );
  assert.ok(COMPACTION_TAIL_CHARS < MAX_TRANSCRIPT_CHARS, 'a compacted thread is a smaller one');
});

test('a forced compaction covers everything since the last summary, and the next turn opens on it', async () => {
  const f = fixture([{ text: 'first answer.' }, { text: 'second answer.' }]);
  longThread(f.db, f.conversationId, 2, 1_000);
  await runAgent(f.deps, f.agent, f.conversationId);
  assert.deepEqual(f.summarised, [], 'well under the budget, so the turn compacted nothing');
  const stored = f.messages().length;

  assert.deepEqual(await compactNow(f.deps, f.agent, f.conversationId), { covered: stored });
  assert.equal(f.summarised.length, 1);
  assert.match(String(f.summarised[0]), /first answer\./, 'the whole thread went to the summariser');
  const summary = latestSummary(f.db, f.conversationId, 'alpha');
  assert.equal(summary?.throughMessageId, f.messages().at(-1)?.id, 'and nothing is kept verbatim');
  assert.equal(f.messages().length, stored, 'nothing was rewritten');

  // A second forced pass has nothing to fold and asks the model for nothing.
  assert.deepEqual(await compactNow(f.deps, f.agent, f.conversationId), { covered: 0 });
  assert.equal(f.summarised.length, 1);

  // The next turn is handed the summary and the owner's new message, and none of the old rows.
  f.ask('and now?');
  await runAgent(f.deps, f.agent, f.conversationId);
  const asked = replayed(f.seen[1]);
  assert.match(String(asked[0]?.text), new RegExp(`summarised:\\n${SUMMARY}$`));
  assert.match(String(asked[1]?.text), /and now\?$/);
  assert.equal(asked.length, 2);
  assertEveryCallAnswered(f.seen[1] as ProviderMessage[]);
});

test('a forced compaction the model refuses is an error and writes no summary', async () => {
  const f = fixture([]);
  longThread(f.db, f.conversationId, 1, 100);
  const deps = { ...f.deps, provider: () => Promise.reject(new Error('endpoint down')) };
  assert.deepEqual(await compactNow(deps, f.agent, f.conversationId), {
    error: 'the model would not summarise the thread for alpha',
  });
  assert.equal(latestSummary(f.db, f.conversationId, 'alpha'), undefined);
});

// ---------------------------------------------------------------- model capabilities

/** Characters a request puts on the wire as text: every message and the tool schemas as sent. */
function requestChars(messages: readonly ProviderMessage[], tools: readonly ToolDef[]): number {
  const text = messages.reduce(
    (total, m) => total + m.text.length + (m.role === 'assistant' ? JSON.stringify(m.toolCalls).length : 0),
    0,
  );
  return text + JSON.stringify(tools.map((tool) => ({ type: 'function', function: tool }))).length;
}

test('a model with a 32k context window gets a transcript that fits, and an unknown window keeps the fixed budget', async () => {
  const WINDOW = 32_768;
  const run = async (contextWindow: number | null) => {
    const f = fixture([]);
    createModel(f.db, { name: 'small', model: 'small', contextWindow });
    longThread(f.db, f.conversationId, 40, 3_000);
    const asked: { messages: ProviderMessage[]; tools: readonly ToolDef[] }[] = [];
    const summarised: string[] = [];
    const provider: Provider = (messages, tools) => {
      if (messages[0]?.role === 'system' && messages[0].text === SUMMARY_PROMPT) {
        summarised.push(messages.map((m) => m.text).join(''));
        return Promise.resolve({ text: SUMMARY, toolCalls: [] });
      }
      asked.push({ messages: [...messages], tools });
      return Promise.resolve({ text: 'the logs are fine.', toolCalls: [] });
    };
    await runAgent({ ...f.deps, provider }, f.agent, f.conversationId);
    return { f, asked, summarised };
  };

  const small = await run(WINDOW);
  assert.equal(small.summarised.length, 1, 'a 120k-character thread does not fit 32k tokens, so it was compacted');
  const request = small.asked[0];
  assert.ok(request !== undefined);
  assertEveryCallAnswered(request.messages);
  const tokens =
    requestChars(request.messages, request.tools) / CHARS_PER_TOKEN + 8_192 + MAX_REPLAYED_IMAGES * IMAGE_RESERVE_TOKENS;
  assert.ok(tokens <= WINDOW, `the request, its tools and the reply reserve fit the window (${Math.round(tokens)})`);
  assert.ok(
    String(small.summarised[0]).length / CHARS_PER_TOKEN + 8_192 <= WINDOW,
    'and so does the summariser request',
  );
  const budget = compactionBudget(WINDOW);
  assert.ok(budget.transcript < MAX_TRANSCRIPT_CHARS && budget.tail < budget.transcript);
  assert.ok(contextFullness(small.f.db, small.f.agent) <= 100);

  const unknown = await run(null);
  assert.deepEqual(unknown.summarised, [], 'the same thread is well under the fixed budget');
  assert.deepEqual(compactionBudget(null), {
    transcript: MAX_TRANSCRIPT_CHARS,
    tail: COMPACTION_TAIL_CHARS,
    summary: 16_000,
  });
  assert.equal(compactionBudget(10_000_000).transcript, MAX_TRANSCRIPT_CHARS, 'a huge window is capped');
});

test('a context overflow compacts between turns, asks again, and keeps a message that landed mid-turn', async () => {
  // Two steps before the overflow, so there is a boundary inside this turn, after the arrival,
  // that a cut chosen on size alone would take on a window this small.
  const diskCall = { id: 'c3', name: 'run_command', arguments: '{"command":"df -h"}' };
  let calls = 0;
  const summarised: string[] = [];
  const asked: ProviderMessage[][] = [];
  const provider: Provider = (messages) => {
    if (messages[0]?.role === 'system' && messages[0].text === SUMMARY_PROMPT) {
      summarised.push(messages[1]?.text ?? '');
      return Promise.resolve({ text: SUMMARY, toolCalls: [] });
    }
    calls += 1;
    asked.push([...messages]);
    if (calls === 1) return Promise.resolve({ text: '', toolCalls: [commandCall] });
    if (calls === 2) return Promise.resolve({ text: '', toolCalls: [diskCall] });
    if (calls === 3) {
      return Promise.reject(
        new ProviderError('provider returned HTTP 400: context_length_exceeded', false, 400, undefined, true),
      );
    }
    return Promise.resolve({ text: 'done.', toolCalls: [] });
  };
  let landed = false;
  const f = fixture([], noSearch, noMcp, (argv) => {
    if (!landed && argv.includes('uname -a')) {
      landed = true;
      appendMessage(f.db, f.conversationId, { role: 'user', content: 'also check the disk' });
    }
  });
  createModel(f.db, { name: 'small', model: 'small', contextWindow: 16_000 });
  longThread(f.db, f.conversationId, 6, 1_000);
  f.ask('go on');
  const since = lastMessageId(f.db);

  await runAgent({ ...f.deps, provider }, f.agent, f.conversationId);

  assert.equal(calls, 4, 'the overflowing step was asked once more');
  assert.equal(summarised.length, 2, 'the turn-start compaction, then one forced one');
  assert.equal(f.messages().at(-1)?.content, 'done.');
  assert.equal(f.state(), 'waiting_for_user');
  const retry = asked[3] as ProviderMessage[];
  assert.match(String(retry[1]?.text), new RegExp(`summarised:\\n${SUMMARY}$`));
  assertEveryCallAnswered(retry);
  assertNoOrphanResult(retry);
  assert.ok(
    retry.some((m) => m.role === 'tool' && m.toolCallId === commandCall.id) &&
      retry.some((m) => m.role === 'tool' && m.toolCallId === diskCall.id),
    "the turn's own calls and results stay in the tail",
  );

  const summary = latestSummary(f.db, f.conversationId, 'alpha');
  assert.ok(Number(summary?.throughMessageId) <= since, 'the cut is before this turn began');
  assert.ok(landed);
  f.ask('anything else?');
  const next = scriptedProvider({ alpha: [{ text: 'disk is fine.' }] });
  await runAgent({ ...f.deps, provider: next.provider }, f.agent, f.conversationId);
  assert.ok(
    (next.seen[0] ?? []).some((m) => m.text.includes('also check the disk')),
    'the message that landed mid-turn is still replayed',
  );
});

test('a second context overflow in one turn fails it, after a single forced compaction', async () => {
  const f = fixture([]);
  longThread(f.db, f.conversationId, 6, 1_000);
  f.ask('go on');
  let summaries = 0;
  const provider: Provider = (messages) => {
    if (messages[0]?.role === 'system' && messages[0].text === SUMMARY_PROMPT) {
      summaries += 1;
      return Promise.resolve({ text: SUMMARY, toolCalls: [] });
    }
    return Promise.reject(new ProviderError('maximum context length', false, 400, undefined, true));
  };

  await runAgent({ ...f.deps, provider }, f.agent, f.conversationId);

  assert.equal(summaries, 1);
  assert.equal(f.state(), 'failed');
  assert.match(String(f.messages().at(-1)?.content), new RegExp(`^${RUN_FAILED}: maximum context length`));
});

test('a summary written under a bigger budget still leaves the summariser request inside a small window', async () => {
  const f = fixture([]);
  createModel(f.db, { name: 'small', model: 'small', contextWindow: 32_768 });
  longThread(f.db, f.conversationId, 3, 1_000);
  appendSummary(f.db, {
    conversationId: f.conversationId,
    sender: 'alpha',
    content: 'y'.repeat(16_000),
    fromMessageId: 1,
    throughMessageId: lastMessageId(f.db),
  });
  longThread(f.db, f.conversationId, 6, 1_000, { label: 'B' });
  f.ask('go on');
  const bodies: string[] = [];
  let calls = 0;
  const provider: Provider = (messages) => {
    if (messages[0]?.role === 'system' && messages[0].text === SUMMARY_PROMPT) {
      bodies.push(messages.map((m) => m.text).join(''));
      return Promise.resolve({ text: SUMMARY, toolCalls: [] });
    }
    calls += 1;
    return calls === 1
      ? Promise.reject(new ProviderError('context_length_exceeded', false, 400, undefined, true))
      : Promise.resolve({ text: 'done.', toolCalls: [] });
  };

  await runAgent({ ...f.deps, provider }, f.agent, f.conversationId);

  const forced = overflowBudget(compactionBudget(32_768));
  assert.equal(bodies.length, 1);
  assert.ok(String(bodies[0]).length <= forced.transcript, `${String(bodies[0]).length} <= ${forced.transcript}`);
  assert.equal(f.messages().at(-1)?.content, 'done.');
});

test('an agent with screenshots in its history keeps working after it switches to a model without vision', async () => {
  const f = fixture([]);
  const key = randomBytes(32);
  const endpoint = createProvider(f.db, key, { name: 'stub', baseUrl: 'http://stub/v1', apiKey: 'k' });
  const sees = createModel(f.db, { name: 'sees', providerId: endpoint.id, model: 'sees' });
  const blind = createModel(f.db, { name: 'blind', providerId: endpoint.id, model: 'blind', vision: false });
  assignModel(f.db, 'alpha', sees.id);

  type Body = { model: string; messages: { content: unknown }[] };
  const bodies: Body[] = [];
  const hasImage = (body: Body) =>
    body.messages.some((m) => Array.isArray(m.content) && m.content.some((part: { type?: string }) => part.type === 'image_url'));
  const json = (status: number, payload: unknown) =>
    new Response(JSON.stringify(payload), { status, headers: { 'content-type': 'application/json' } });
  const original = globalThis.fetch;
  globalThis.fetch = (_url, init) => {
    const body = JSON.parse(String(init?.body)) as Body;
    bodies.push(body);
    if (body.model === 'blind' && hasImage(body)) {
      return Promise.resolve(json(400, { error: { message: 'this model does not support image input' } }));
    }
    const shoot = body.messages.length === 2;
    const message = shoot
      ? { content: '', tool_calls: [{ id: 'shot', type: 'function', function: { name: 'computer', arguments: '{"action":"screenshot"}' } }] }
      : { content: 'looked.' };
    return Promise.resolve(json(200, { choices: [{ message }] }));
  };
  try {
    const turn = async (id: number) => {
      const settings = modelConfig(f.db, key, id);
      assert.ok(settings !== undefined);
      await runAgent({ ...f.deps, provider: openAiProvider(settings) }, f.agent, f.conversationId);
    };
    f.ask('look at the screen');
    await turn(sees.id);
    assert.equal(f.messages().at(-1)?.content, 'looked.');
    assert.ok(hasImage(bodies.at(-1) as Body), 'a model that sees is sent the screenshot');

    assert.equal(modelConfig(f.db, key, blind.id)?.vision, false);
    assignModel(f.db, 'alpha', blind.id);
    f.ask('and now?');
    const before = bodies.length;
    await turn(blind.id);

    assert.equal(f.state(), 'waiting_for_user');
    assert.equal(f.messages().at(-1)?.content, 'looked.');
    const sent = bodies.slice(before);
    assert.ok(sent.length > 0 && sent.every((body) => body.model === 'blind' && !hasImage(body)), 'no image_url part');
    assert.ok(
      sent[0]?.messages.some((m) => typeof m.content === 'string' && m.content.includes(NO_VISION)),
      'the screenshot is a line of text saying why it is missing',
    );
  } finally {
    globalThis.fetch = original;
  }
});

// ---------------------------------------------------------------- scheduled tasks

const scheduleCall = (id: string, cron: string, prompt: string) => ({
  id,
  name: 'schedule_task',
  arguments: JSON.stringify({ cron, prompt }),
});

const scheduleTool = (id: string, name: string, args: Record<string, unknown>) => ({
  id,
  name,
  arguments: JSON.stringify(args),
});

/** The tools a permanent agent is offered for its schedules. */
const SCHEDULE_TOOLS = ['cancel_schedule', 'list_schedules', 'pause_schedule', 'schedule_task'];

function scheduled(db: Db, agent: Agent) {
  return listSchedules(db, agent);
}

test('a cron expression creates a row, and a due row starts a turn in the owner thread', async () => {
  const f = fixture([
    { toolCalls: [scheduleCall('s1', '0 7 * * *', 'check the overnight logs')] },
    { text: 'Set up.' },
    { text: 'The logs are clean.' },
  ]);
  f.ask('check the logs every morning');
  await runAgent(f.deps, f.agent, f.conversationId);

  for (const name of SCHEDULE_TOOLS) {
    assert.ok(f.offered[0]?.includes(name), `a permanent agent is offered ${name}`);
  }
  const [job] = scheduled(f.db, f.agent);
  assert.ok(job !== undefined, 'the tool wrote a row');
  assert.equal(job.cron, '0 7 * * *');
  assert.equal(job.prompt, 'check the overnight logs');
  assert.equal(job.paused, false);
  assert.ok(job.nextRunAt > Date.now(), 'and it is due in the future, not now');
  assert.match(
    String(f.messages().find((m: Message) => m.toolCallId === 's1')?.content),
    new RegExp(`Scheduled as ${job.id}`),
  );

  // Due, and the tick delivers it through the ordinary messaging path.
  assert.equal(runDue(f.db, f.runner, job.nextRunAt), 1);
  await quiet(f.db);

  const delivered = f.messages().find((m: Message) => m.content.includes('check the overnight logs'));
  assert.equal(delivered?.role, 'user');
  assert.equal(delivered?.sender, SYSTEM_SENDER, 'not the owner, so a waiting question stays');
  assert.equal(f.messages().at(-1)?.content, 'The logs are clean.', 'the answer lands in the thread');
  assert.equal(f.state(), 'waiting_for_user');

  const fired = scheduled(f.db, f.agent)[0];
  assert.ok((fired?.nextRunAt ?? 0) > job.nextRunAt, 'and the row moved on to its next slot');
  assert.equal(fired?.lastRunAt, job.nextRunAt);
});

test('a run missed while the daemon was down fires once, not once per missed slot', async () => {
  const f = fixture([{ text: 'Caught up.' }]);
  const created = insertSchedule(f.db, f.agent, { cron: '*/5 * * * *', prompt: 'sweep' }, 0);
  assert.ok(!('error' in created));

  // A weekend of missed slots: hundreds of them for this expression.
  const monday = created.nextRunAt + 3 * 24 * 3_600_000;
  assert.equal(runDue(f.db, f.runner, monday), 1, 'one turn, however many slots went by');
  assert.equal(runDue(f.db, f.runner, monday), 0, 'and the row is no longer due');
  await quiet(f.db);

  assert.equal(f.messages().filter((m: Message) => m.content.includes('sweep')).length, 1);
  assert.ok((scheduled(f.db, f.agent)[0]?.nextRunAt ?? 0) > monday, 'next run is measured from now');
});

test('pause stops a schedule firing, and resuming it does not make up the missed runs', () => {
  const f = fixture([]);
  const created = insertSchedule(f.db, f.agent, { cron: '*/5 * * * *', prompt: 'sweep' }, 0);
  assert.ok(!('error' in created));

  const paused = setPaused(f.db, created, true, 0);
  const later = paused.nextRunAt + 24 * 3_600_000;
  assert.equal(runDue(f.db, f.runner, later), 0, 'a paused row is not due, however overdue it is');
  assert.equal(f.messages().length, 0);

  const resumed = setPaused(f.db, paused, false, later);
  assert.ok(resumed.nextRunAt > later, 'resuming measures the next run from now');
  assert.equal(runDue(f.db, f.runner, later), 0, 'so it does not fire the instant it comes back');
});

test('the schedule tools refuse another agent\'s id and cancel removes the row', async () => {
  const p = pair({
    alpha: [
      { toolCalls: [scheduleCall('s1', '0 7 * * *', 'mine')] },
      { toolCalls: [scheduleTool('s2', 'list_schedules', {})] },
      { toolCalls: [scheduleTool('s3', 'pause_schedule', { id: 9999, paused: true })] },
      // Bravo's row, which alpha can name because an id is a small number it can guess.
      { toolCalls: [scheduleTool('s4', 'cancel_schedule', { id: 1 })] },
      { toolCalls: [scheduleTool('s5', 'cancel_schedule', { id: 2 })] },
      { text: 'Done.' },
    ],
  });
  const bravoJob = insertSchedule(p.db, p.bravo, { cron: '0 8 * * *', prompt: 'theirs' }, Date.now());
  assert.ok(!('error' in bravoJob) && bravoJob.id === 1, 'bravo holds the first id');

  const owner = conversationFor(p.db, p.alpha.id);
  appendMessage(p.db, owner, { role: 'user', content: 'set one up and then drop it' });
  p.runner.start(p.alpha, owner);
  await quiet(p.db);

  const result = (id: string) =>
    String(listMessages(p.db, owner).find((message) => message.toolCallId === id)?.content);
  assert.match(result('s2'), /mine/, 'list_schedules answers with its own jobs');
  assert.ok(!result('s2').includes('theirs'), 'and never another agent\'s');
  assert.match(result('s3'), /error: you have no schedule 9999/);
  assert.match(result('s4'), /error: you have no schedule 1/, 'bravo\'s row is not alpha\'s to touch');
  assert.match(result('s5'), /Schedule 2 is gone/);

  assert.equal(scheduled(p.db, p.alpha).length, 0, 'cancel removed its own row');
  assert.equal(scheduled(p.db, p.bravo).length, 1, 'and left bravo\'s alone');
});

test('an agent is shown its own schedules once per turn, and a task worker gets none', async () => {
  const p = pair({
    alpha: [
      { toolCalls: [spawnCall('w1', 'count the files')] },
      { text: 'A worker is on it.' },
      { text: 'It counted three.' },
    ],
    'alpha-w1': [
      { toolCalls: [scheduleCall('s1', '0 7 * * *', 'keep counting')] },
      { text: 'there are three files' },
    ],
  });
  const created = insertSchedule(p.db, p.alpha, { cron: '0 7 * * *', prompt: 'sweep the disk' }, Date.now());
  assert.ok(!('error' in created));

  const owner = conversationFor(p.db, p.alpha.id);
  appendMessage(p.db, owner, { role: 'user', content: 'how many files?' });
  p.runner.start(p.alpha, owner);
  await quiet(p.db);

  assert.match(systemOf(p.seen[0]), /Your scheduled tasks/);
  assert.match(systemOf(p.seen[0]), new RegExp(`- ${created.id}: 0 7 \\* \\* \\* — sweep the disk`));

  const asWorker = p.seen.findIndex((messages) => askedAgent(messages) === 'alpha-w1');
  assert.deepEqual(p.offered[asWorker], ['run_command', 'web_search', 'web_fetch'], 'a worker is offered none of them');
  assert.doesNotMatch(systemOf(p.seen[asWorker]), /scheduled task/i, 'nor told about any');
  const worker = findAgent(p.db, 'alpha-w1') as Agent;
  const refused = listMessages(p.db, conversationFor(p.db, worker.id)).find(
    (message) => message.toolCallId === 's1',
  );
  assert.equal(refused?.content, 'error: no tool named schedule_task');
  assert.equal(scheduled(p.db, p.alpha).length, 1, 'and wrote nothing');
});

test('a schedule whose agent or next run is gone is dropped rather than fired forever', () => {
  const f = fixture([]);
  const created = insertSchedule(f.db, f.agent, { cron: '*/5 * * * *', prompt: 'sweep' }, 0);
  assert.ok(!('error' in created));
  // What a hand-edited row, or a pattern that ran out of years, looks like to the tick.
  f.db.run(sql`UPDATE schedules SET cron = '0 0 1 1 2020' WHERE id = ${created.id}`);

  assert.equal(runDue(f.db, f.runner, created.nextRunAt), 0, 'nothing was started');
  assert.equal(scheduled(f.db, f.agent).length, 0, 'and the row is gone rather than due forever');

  const dropped = listEvents(f.db, f.agent.id).find((e) => e.type === 'schedule_dropped');
  assert.equal(dropped?.data['schedule'], created.id, 'the owner has a trace of what went');
});

test('an agent cannot hold more schedules than the cap', () => {
  const f = fixture([]);
  for (let n = 0; n < MAX_SCHEDULES; n += 1) {
    assert.ok(!('error' in insertSchedule(f.db, f.agent, { cron: '0 7 * * *', prompt: `job ${n}` }, 0)));
  }
  const refused = insertSchedule(f.db, f.agent, { cron: '0 7 * * *', prompt: 'one too many' }, 0);
  assert.ok('error' in refused);
  assert.match(refused.error, new RegExp(String(MAX_SCHEDULES)));
});

// --- web search and page fetch ---------------------------------------------------------------

const SEARCH_KEY = 'brave-shouldnevershowup';
const SEARCH = () => ({ url: 'https://search.example/res/v1/web/search', apiKey: SEARCH_KEY });

const fetchCall = (id: string, url: string) => ({
  id,
  name: 'web_fetch',
  arguments: JSON.stringify({ url }),
});
const searchCall = (id: string, query: string) => ({
  id,
  name: 'web_search',
  arguments: JSON.stringify({ query }),
});

/** Stands in for the internet for the length of one turn. */
async function withFetch<T>(reply: () => Response, run: () => Promise<T>): Promise<T> {
  const original = globalThis.fetch;
  globalThis.fetch = () => Promise.resolve(reply());
  try {
    return await run();
  } finally {
    globalThis.fetch = original;
  }
}

test('both web tools are offered to a permanent agent', async () => {
  const f = fixture([{ text: 'nothing to look up.' }]);
  f.ask('hello');
  await runAgent(f.deps, f.agent, f.conversationId);
  for (const name of ['web_search', 'web_fetch']) {
    assert.ok(f.offered[0]?.includes(name), `a permanent agent is offered ${name}`);
  }
});

test('web_search with no key configured is an observation, not a failed turn', async () => {
  const f = fixture([{ toolCalls: [searchCall('w1', 'cron syntax')] }, { text: 'I could not look it up.' }]);
  f.ask('what is the cron syntax?');
  await runAgent(f.deps, f.agent, f.conversationId);

  assert.equal(f.state(), 'waiting_for_user', 'the turn ended normally');
  const observation = f.messages().find((m) => m.toolCallId === 'w1');
  assert.match(String(observation?.content), /no web search key is configured/);
  const event = f.events().find((e) => e.type === 'tool_result' && e.data['error'] === 'no search key');
  assert.ok(event !== undefined, 'and the refusal is in the event log');
});

test('a search returns titled results and the key reaches no event and no log line', async () => {
  const f = fixture(
    [{ toolCalls: [searchCall('w1', 'schermes')] }, { text: 'Found it.' }],
    SEARCH,
  );
  f.ask('find the page');

  const written: string[] = [];
  const out = process.stdout.write.bind(process.stdout);
  const err = process.stderr.write.bind(process.stderr);
  process.stdout.write = (chunk: string | Uint8Array) => (written.push(String(chunk)), true);
  process.stderr.write = (chunk: string | Uint8Array) => (written.push(String(chunk)), true);
  try {
    await withFetch(
      () =>
        new Response(
          JSON.stringify({ web: { results: [{ title: 'Schermes', url: 'https://example.com/s', description: 'agents' }] } }),
          { status: 200, headers: { 'content-type': 'application/json' } },
        ),
      () => runAgent(f.deps, f.agent, f.conversationId),
    );
  } finally {
    process.stdout.write = out;
    process.stderr.write = err;
  }

  const observation = f.messages().find((m) => m.toolCallId === 'w1');
  assert.match(String(observation?.content), /1\. Schermes — https:\/\/example\.com\/s/);

  const events = JSON.stringify(f.events());
  assert.ok(!events.includes(SEARCH_KEY), 'the key reached an event');
  assert.ok(!written.join('').includes(SEARCH_KEY), 'the key reached a log line');
  assert.ok(!JSON.stringify(f.messages()).includes(SEARCH_KEY), 'the key reached the transcript');
  const result = f.events().find((e) => e.type === 'tool_result' && e.data['results'] === 1);
  assert.equal(result?.data['host'], 'search.example');
});

test('a failing search does not hand the key on either', async () => {
  const f = fixture([{ toolCalls: [searchCall('w1', 'x')] }, { text: 'No luck.' }], SEARCH);
  f.ask('find it');
  await withFetch(
    () => new Response(`denied for x-subscription-token ${SEARCH_KEY}`, { status: 403 }),
    () => runAgent(f.deps, f.agent, f.conversationId),
  );

  const observation = String(f.messages().find((m) => m.toolCallId === 'w1')?.content);
  assert.match(observation, /HTTP 403/);
  assert.ok(!observation.includes(SEARCH_KEY), 'the echoed key reached the agent');
  assert.ok(!JSON.stringify(f.events()).includes(SEARCH_KEY), 'the echoed key reached an event');
});

test('a fetched page is text in the transcript and a host and status in the event', async () => {
  // An address rather than a name, so the guard short-circuits and the test needs no resolver.
  const f = fixture([
    { toolCalls: [fetchCall('w1', 'http://93.184.216.34/doc')] },
    { text: 'The page says hello.' },
  ]);
  f.ask('read that page');
  await withFetch(
    () =>
      new Response('<html><body><nav>menu</nav><h1>Title</h1><p>Hello there.</p></body></html>', {
        status: 200,
        headers: { 'content-type': 'text/html' },
      }),
    () => runAgent(f.deps, f.agent, f.conversationId),
  );

  const observation = String(f.messages().find((m) => m.toolCallId === 'w1')?.content);
  assert.match(observation, /Title/);
  assert.match(observation, /Hello there\./);
  assert.ok(!observation.includes('<p>'), 'markup reached the agent');

  const event = f.events().find((e) => e.type === 'tool_result' && e.data['host'] === '93.184.216.34');
  assert.equal(event?.data['status'], 200);
  assert.ok(!JSON.stringify(event).includes('Hello there'), 'the page itself went into the event');
});

test('a loopback url is refused without a request and the turn carries on', async () => {
  const f = fixture([
    { toolCalls: [fetchCall('w1', 'http://127.0.0.1:7777/api/agents')] },
    { text: 'I cannot reach that.' },
  ]);
  f.ask('read the daemon api');
  let requests = 0;
  await withFetch(
    () => {
      requests += 1;
      return new Response('{"agents":[]}', { status: 200 });
    },
    () => runAgent(f.deps, f.agent, f.conversationId),
  );

  assert.equal(requests, 0, 'the daemon made the request anyway');
  assert.match(
    String(f.messages().find((m) => m.toolCallId === 'w1')?.content),
    /loopback, link-local or private address/,
  );
  assert.equal(f.state(), 'waiting_for_user');
});

/** An MCP session as the loop sees it. The protocol itself is covered in `mcp.test.ts`; what
 * matters here is that the tools reach the model, a call becomes an observation and the session
 * is closed however the turn ends. */
function fakeMcp(log: { calls: string[]; closed: number }): LoopDeps['mcp'] {
  const session: McpSession = {
    tools: [
      { name: 'mcp__files__read', description: 'Read a file', parameters: { type: 'object' } },
    ],
    failures: [],
    call: (name, args) => {
      log.calls.push(name);
      return Promise.resolve({ text: `read ${JSON.stringify(args)}` });
    },
    close: () => {
      log.closed += 1;
      return Promise.resolve();
    },
  };
  return () => Promise.resolve(session);
}

const mcpCall = { id: 'm1', name: 'mcp__files__read', arguments: '{"path":"/etc/hostname"}' };

test('a configured MCP server is offered to the model after the built-in tools', async () => {
  const log = { calls: [], closed: 0 };
  const f = fixture([{ text: 'nothing to do.' }], noSearch, fakeMcp(log));
  f.ask('hello');
  await runAgent(f.deps, f.agent, f.conversationId);

  assert.deepEqual(
    f.offered[0]?.slice(-1),
    ['mcp__files__read'],
    'the MCP tools come last, so the built-in list stays where it was',
  );
  assert.ok(f.offered[0]?.includes('run_command'), 'and the built-in tools are still there');
  assert.equal(log.closed, 1, 'the session is dropped when the turn ends');
});

test('an MCP tool call round-trips into an observation', async () => {
  const log = { calls: [], closed: 0 };
  const f = fixture([{ toolCalls: [mcpCall] }, { text: 'it is schermes.' }], noSearch, fakeMcp(log));
  f.ask('what is the hostname?');
  await runAgent(f.deps, f.agent, f.conversationId);

  assert.deepEqual(log.calls, ['mcp__files__read']);
  const observation = f.messages().find((m) => m.toolCallId === 'm1');
  assert.equal(observation?.content, 'read {"path":"/etc/hostname"}');
  const event = f.events().find((e) => e.type === 'tool_result' && e.data['callId'] === 'm1');
  assert.equal(event?.data['ok'], true);
  assert.equal(f.state(), 'waiting_for_user');
});

test('a turn that fails still drops its MCP session', async () => {
  const log = { calls: [], closed: 0 };
  // The script runs out after the first reply, so the second step throws and the turn fails.
  const f = fixture([{ toolCalls: [mcpCall] }], noSearch, fakeMcp(log));
  f.ask('what is the hostname?');
  await runAgent(f.deps, f.agent, f.conversationId);

  assert.equal(f.state(), 'failed');
  assert.equal(log.closed, 1, 'a failed turn leaks no stdio child process');
});

test('an MCP tool with no session behind it is an observation, not a failed turn', async () => {
  const f = fixture([{ toolCalls: [mcpCall] }, { text: 'I could not reach it.' }]);
  f.ask('what is the hostname?');
  await runAgent(f.deps, f.agent, f.conversationId);

  assert.equal(f.state(), 'waiting_for_user', 'the turn ended normally');
  const observation = f.messages().find((m) => m.toolCallId === 'm1');
  assert.match(String(observation?.content), /no MCP server is connected/);
});

test('a task worker is offered no MCP tools', async () => {
  const log = { calls: [], closed: 0 };
  const f = fixture([{ text: 'done.' }], noSearch, fakeMcp(log));
  const worker = insertWorker(f.db, f.agent, `${f.agent.name}-w1`, f.conversationId);
  const thread = conversationFor(f.db, worker.id);
  appendMessage(f.db, thread, { role: 'user', content: 'go', sender: f.agent.name });

  await runAgent(f.deps, worker, thread);

  assert.deepEqual(f.offered[0], ['run_command', 'web_search', 'web_fetch']);
  assert.equal(log.closed, 0, 'and no session was opened for it');
});

test('a stop lands between steps, after every call in the reply has its result', async () => {
  let runner: ReturnType<typeof createRunner> | undefined;
  const f = fixture([{ toolCalls: [commandCall] }, { text: 'never asked for' }], noSearch, noMcp, (argv) => {
    if (argv.includes('uname -a')) runner?.stop('alpha');
  });
  runner = f.runner;
  f.ask('go');
  f.runner.start(f.agent, f.conversationId);
  await quiet(f.db);

  assert.equal(f.state(), 'waiting_for_user');
  const rows = f.messages();
  assert.deepEqual(rows.map((m) => m.role), ['user', 'assistant', 'tool', 'assistant']);
  assert.equal(rows.at(-1)?.content, STOPPED);
  assertEveryCallAnswered(transcript('alpha', SYSTEM, rows));
  assert.equal(f.seen.length, 1, 'the model was not asked again');
  assert.deepEqual(
    f.events().filter((e) => e.type === 'stop' || e.type === 'turn').map((e) => [e.type, e.data]),
    [['stop', {}], ['turn', { steps: 1 }]],
  );
  assert.equal(f.runner.stop('alpha'), false, 'nothing left to stop');
});

test('a stop while the model is still writing ends the turn at the last complete exchange', async () => {
  const f = fixture([]);
  const controller = new AbortController();
  const provider: Provider = (_m, _t, _d, signal) =>
    new Promise((_, reject) => signal?.addEventListener('abort', () => reject(signal.reason), { once: true }));
  f.ask('go');
  const turn = runAgent({ ...f.deps, provider, signal: controller.signal }, f.agent, f.conversationId);
  await tick();
  assert.equal(f.state(), 'thinking');
  controller.abort(new Error('stopped by the owner'));
  await turn;

  assert.equal(f.state(), 'waiting_for_user');
  assert.deepEqual(f.messages().map((m) => [m.role, m.content]), [['user', 'go'], ['assistant', STOPPED]]);
  assert.ok(f.events().some((e) => e.type === 'stop'));
  assert.ok(!f.events().some((e) => e.type === 'failure'), 'a stop is not a failure');
});

test('a stopped worker reports the stop to its parent as the failure it is waiting on', async () => {
  const f = fixture([{ toolCalls: [{ id: 's1', name: 'spawn_task_worker', arguments: '{"brief":"count the files"}' }] }]);
  const stopAt = (argv: readonly string[]) => argv.includes('ls');
  const worker: Provider = (messages, _t, _d, signal) => {
    if (askedAgent(messages) === 'alpha') return f.deps.provider(messages, _t);
    // The worker's first call is answered with a command; the exec below stops it while it runs.
    return new Promise((resolve, reject) => {
      signal?.addEventListener('abort', () => reject(signal.reason), { once: true });
      resolve({ text: '', toolCalls: [{ id: 'w1', name: 'run_command', arguments: '{"command":"ls"}' }] });
    });
  };
  const exec: Exec = (file, args, options) => {
    if (stopAt([file, ...args])) {
      const name = listAgents(f.db).find((a) => a.parentId !== undefined)?.name;
      if (name !== undefined) runner.stop(name);
    }
    return f.deps.exec(file, args, options);
  };
  const runner = createRunner({ ...f.deps, exec, provider: () => worker, maxLoops: 4 });
  f.ask('go');
  runner.start(f.agent, f.conversationId);
  await quiet(f.db);

  const spawned = listAgents(f.db).find((a) => a.parentId !== undefined);
  assert.ok(spawned);
  assert.equal(spawned.state, 'failed');
  const reported = f.messages().find((m) => m.sender === spawned.name && m.role === 'user');
  assert.ok(reported, 'the parent was written to');
  assert.match(reported.content, new RegExp(`^${WORKER_FAILED}: stopped by the owner`));
});

test('a turn records what it cost when the endpoint says', async () => {
  const usage = { promptTokens: 100, completionTokens: 7 };
  const f = fixture([{ toolCalls: [commandCall], usage }, { text: 'done', usage }]);
  f.ask('go');
  f.runner.start(f.agent, f.conversationId);
  await quiet(f.db);
  const turn = f.events().find((e) => e.type === 'turn');
  assert.deepEqual(turn?.data, { steps: 2, promptTokens: 200, completionTokens: 14 });
});

test("the owner's pictures reach the model as user images and share the replay window with screenshots", async () => {
  const picture = (n: number) => ({ mediaType: 'image/jpeg' as const, base64: `pic${n}` });
  const f = fixture([{ text: 'seen' }]);
  f.ask('look at these');
  const first = appendMessage(f.db, f.conversationId, { role: 'user', content: '', image: picture(1) });
  appendMessage(f.db, f.conversationId, { role: 'user', content: 'and this', image: picture(2) });
  appendMessage(f.db, f.conversationId, { role: 'user', content: 'and this', image: picture(3) });
  appendMessage(f.db, f.conversationId, { role: 'user', content: 'and this', image: picture(4) });
  f.runner.start(f.agent, f.conversationId);
  await quiet(f.db);

  const sent = f.seen[0] ?? [];
  const users = sent.filter((m) => m.role === 'user');
  assert.equal(users.filter((m) => 'image' in m && m.image !== undefined).length, MAX_REPLAYED_IMAGES);
  const withPictures = users.map((m) => ('image' in m ? m.image?.base64 : undefined));
  assert.ok(!withPictures.includes('pic1') && withPictures.includes('pic4'), 'the oldest is out of the window');
  const dropped = users.find((m) => m.text.includes('no longer shown'));
  assert.ok(dropped, 'and the model is told so');
  assert.match(sent.find((m) => 'image' in m && m.image?.base64 === 'pic2')?.text ?? '', /Message from the owner:\n/);
  assert.ok(first.image?.mediaType === 'image/jpeg');
});

test('set_name moves the agent only once its turn is over, and only to a free valid name', async () => {
  const renames: [string, string][] = [];
  const rename = (agent: Agent, name: string) => {
    renames.push([agent.name, name]);
    return Promise.resolve();
  };
  const nameCall = (id: string, name: string) => ({ id, name: 'set_name', arguments: JSON.stringify({ name }) });
  const f = fixture([
    { toolCalls: [nameCall('n1', 'Bravo'), nameCall('n2', 'alpha'), nameCall('n3', 'bravo')] },
    { toolCalls: [commandCall] },
    { text: 'Done.' },
  ]);
  insertAgent(f.db, 'taken');
  const seenBeforeEnd = () => renames.length;
  const deps = { ...f.deps, rename, exec: (file: string, args: readonly string[], options?: unknown) => {
    assert.equal(seenBeforeEnd(), 0, 'the turn still runs as alpha');
    return f.deps.exec(file, args, options as never);
  } };

  f.ask('Call yourself bravo.');
  await runAgent(deps, f.agent, f.conversationId);
  assert.ok(f.offered[0]?.includes('set_name'));
  const results = f.messages().filter((m) => m.role === 'tool');
  assert.match(String(results.find((m) => m.toolCallId === 'n1')?.content), /must match/);
  assert.match(String(results.find((m) => m.toolCallId === 'n2')?.content), /already alpha/);
  assert.match(String(results.find((m) => m.toolCallId === 'n3')?.content), /from your next turn on/);
  assert.deepEqual(renames, [['alpha', 'bravo']]);

  const g = fixture([{ toolCalls: [nameCall('n4', 'taken')] }, { text: 'Oh.' }]);
  insertAgent(g.db, 'taken');
  g.ask('Be taken.');
  await runAgent({ ...g.deps, rename }, g.agent, g.conversationId);
  assert.match(String(g.messages().find((m) => m.toolCallId === 'n4')?.content), /taken is taken/);
  assert.equal(renames.length, 1);
});

test('the rules are in the system prompt, naming request_approval and the pre-approved list', async () => {
  const f = fixture([{ text: 'Noted.' }, { text: 'Noted again.' }]);
  f.ask('hello');
  await runAgent(f.deps, f.agent, f.conversationId);
  const before = systemOf(f.seen.at(-1));
  assert.match(before, /Ask first with request_approval[^\n]*: delete files; spend money; install software/);
  assert.match(before, /Go ahead when the domain or recipient is on the pre-approved list for that kind of action[^\n]*: send a message\./);
  assert.match(before, /Never do these yourself[^\n]*: change a password or security setting\./);
  assert.match(before, /Pre-approved to send a message: nothing yet\./);

  updateRules(f.db, f.agent, { levels: { spend_money: 'if_pre_approved' }, preApproved: { spend_money: ['FlyTap.com'] } });
  f.ask('and now?');
  await runAgent(f.deps, f.agent, f.conversationId);
  const after = systemOf(f.seen.at(-1));
  assert.match(after, /pre-approved list[^\n]*: send a message; spend money\./);
  assert.match(after, /Pre-approved to spend money: flytap\.com\./);
  assert.match(after, /Pre-approved to send a message: nothing yet\./);
});

test('under Ask first a delete or install through run_command is refused, and runs once after approval', async () => {
  const rm = (id: string) => ({ id, name: 'run_command', arguments: JSON.stringify({ command: 'rm -f ~/workspace/old.txt' }) });
  const install = { id: 'i1', name: 'run_command', arguments: JSON.stringify({ command: 'sudo apt-get install -y jq' }) };
  const f = fixture([
    { toolCalls: [rm('r1'), install] },
    { text: 'I will ask.' },
    { toolCalls: [rm('r2')] },
    { toolCalls: [rm('r3')] },
    { text: 'Deleted once.' },
  ]);
  const ranRm = () => tooling(f.ran).filter((argv) => argv.some((arg) => arg.includes('rm -f ~/workspace/old.txt'))).length;
  const result = (id: string) => String(f.messages().find((m) => m.toolCallId === id)?.content);

  f.ask('clean up and install jq');
  await runAgent(f.deps, f.agent, f.conversationId);
  assert.equal(ranRm(), 0);
  assert.ok(!tooling(f.ran).some((argv) => argv.some((arg) => arg.includes('apt-get'))));
  assert.match(result('r1'), /^error: your rules say to ask the owner before you delete files \(~\/workspace\/old\.txt\)\. Nothing was run\. Ask with request_approval, category delete_files, target "~\/workspace\/old\.txt"/);
  assert.match(result('i1'), /install software \(jq\)/);

  const asked = insertApproval(f.db, f.agent, f.conversationId, {
    kind: 'action',
    category: 'delete_files',
    target: '~/workspace/old.txt',
    reason: 'stale',
  });
  grantOnce(f.db, f.agent, asked);
  f.ask('approved');
  await runAgent(f.deps, f.agent, f.conversationId);
  assert.equal(ranRm(), 1, 'the approval lets exactly one matching call through');
  assert.match(result('r3'), /^error: your rules say to ask/);
});

test('a browser that stays hung after its restart ends the turn waiting on the owner, with a Needs you item', async () => {
  const browserCall = { id: 'b1', name: 'browser', arguments: '{"action":"read"}' };
  const f = fixture([{ text: 'Reading the page.', toolCalls: [browserCall] }, { text: 'should never be asked' }]);
  const hung: Session = { send: () => new Promise(() => undefined), once: () => new Promise(() => undefined), close: () => undefined };
  f.ask('what does the page say?');
  await runAgent(
    { ...f.deps, connect: () => Promise.resolve(hung), browserTimings: { probeMs: 10, startMs: 40, pollMs: 5 } },
    f.agent,
    f.conversationId,
  );
  assert.equal(f.state(), 'waiting_for_user');
  assert.equal(f.seen.length, 1, 'no model call after the hang');
  const row = f.messages().find((m) => m.toolCallId === 'b1');
  assert.ok(row?.content.startsWith(`error: ${BROWSER_HUNG}`), row?.content);
  const result = f.events().find((e) => e.type === 'tool_result' && e.data['callId'] === 'b1');
  assert.equal(result?.data['hung'], true);
  assert.equal(result?.data['restarted'], true, 'the automatic restart is on the record');
  assert.equal(tooling(f.ran).filter((argv) => /pkill -KILL/.test(argv.at(-1) ?? '')).length, 1);
  const item = listNeedsYou(f.db).find((entry) => entry.kind === 'browser_hung');
  assert.equal(item?.id, `browser:${row?.id}`);
  assert.deepEqual(item?.actions, ['screen', 'restart_desktop', 'restart_browser']);

  f.ask('I restarted your browser. Try again.');
  assert.equal(listNeedsYou(f.db).filter((entry) => entry.kind === 'browser_hung').length, 0, 'the owner line clears it');
});

test('asking for hands ends the turn waiting on the owner, with a hand-over in Needs you', async () => {
  const hands = { id: 'h1', name: 'ask_for_hands', arguments: JSON.stringify({ reason: 'Solve the CAPTCHA on the login page.' }) };
  const empty = { id: 'h0', name: 'ask_for_hands', arguments: JSON.stringify({ reason: ' ' }) };
  const f = fixture([
    { toolCalls: [empty] },
    { text: 'I need you on the screen.', toolCalls: [hands, commandCall] },
    { text: 'should never be asked' },
  ]);
  f.ask('log in for me');
  await runAgent(f.deps, f.agent, f.conversationId);
  assert.equal(f.state(), 'waiting_for_user');
  assert.ok(f.offered[0]?.includes('ask_for_hands'));
  assert.equal(f.seen.length, 2, 'a refused call goes on; an accepted one is the last model call');
  assert.match(String(f.messages().find((m) => m.toolCallId === 'h0')?.content), /^error: reason is required/);
  const [item] = listNeedsYou(f.db).filter((entry) => entry.kind === 'hand_over');
  const asking = f.messages().find((m) => m.toolCalls?.some((c) => c.id === 'h1'));
  assert.deepEqual(
    [item?.id, item?.detail, item?.actions],
    [`hands:${asking?.id}`, 'Solve the CAPTCHA on the login page.', ['open', 'take_screen']],
  );

  f.ask('The owner gave the screen back.');
  assert.equal(listNeedsYou(f.db).filter((entry) => entry.kind === 'hand_over').length, 0, 'the owner line clears it');
});

// ---------------------------------------------------------------- goals and helpers

const call = (id: string, name: string, args: unknown) => ({ id, name, arguments: JSON.stringify(args) });

test('a lead keeps a goal, brings in both kinds of helper, and finishing removes them', async () => {
  const desktop: string[] = [];
  const ops = {
    ensure: (name: string, display: number, tag?: string) => {
      desktop.push(`ensure ${name} :${display}${tag === undefined ? '' : ` ${tag}`}`);
      return Promise.resolve('started' as const);
    },
    stop: (name: string) => (desktop.push(`stop ${name}`), Promise.resolve()),
    remove: (name: string) => (desktop.push(`remove ${name}`), Promise.resolve()),
    stopDisplay: (name: string, display: number) => (desktop.push(`stopDisplay ${name} :${display}`), Promise.resolve()),
    rename: () => Promise.resolve(),
  };
  const helper = 'alpha-g1-1';
  const p = pair(
    {
      alpha: [
        {
          toolCalls: [
            call('g0', 'update_goal', { title: 'Ship the site', steps: [{ text: 'Later', owner: 'helper-to-be', state: 'todo' }] }),
            call('g1', 'update_goal', { title: 'Ship the site', steps: [{ text: 'Write the copy', state: 'doing' }] }),
          ],
        },
        { text: 'Started.' },
        { toolCalls: [call('h1', 'add_helper', { goal: 1, kind: 'worker', reason: 'Needs a browser of its own.', brief: 'Check the page.' })] },
        { text: 'A worker is on it.' },
        { text: 'The page is fine.' },
        { toolCalls: [call('h2', 'add_helper', { goal: 1, kind: 'agent', reason: 'Long copy work.', brief: 'Draft the copy.' })] },
        { text: 'A helper is on it.' },
        { text: 'Got the draft.' },
        {
          toolCalls: [
            call('u1', 'update_goal', { goal: 1, steps: [{ text: 'x', owner: 'nobody', state: 'todo' }] }),
            call('u2', 'update_goal', {
              goal: 1,
              steps: [
                { text: 'Write the copy', owner: helper, state: 'done' },
                { text: 'Publish', state: 'todo' },
              ],
              addResults: ['Copy drafted'],
              nextFromYou: ['Approve the copy'],
            }),
          ],
        },
        { text: 'Updated.' },
        { toolCalls: [call('f1', 'update_goal', { goal: 1, finish: true })] },
        { text: 'Done.' },
      ],
      'alpha-w1': [{ text: 'the page loads' }],
      [helper]: [
        { toolCalls: [call('x1', 'add_helper', { goal: 1, kind: 'agent', reason: 'r', brief: 'b' })] },
        { text: 'drafted' },
      ],
    },
    { ...CAPS, desktop: ops },
  );
  const owner = conversationFor(p.db, p.alpha.id);
  const ask = async (text: string) => {
    appendMessage(p.db, owner, { role: 'user', content: text });
    p.runner.start(findAgent(p.db, 'alpha') as Agent, owner);
    await quiet(p.db);
  };

  await ask('ship the site');
  const created = listMessages(p.db, owner).find((m) => m.toolCallId === 'g1');
  assert.match(String(created?.content), /^Goal 1: Ship the site \(open\), led by alpha\.\nPlan:\n- \[doing\] Write the copy \(alpha\)/);
  assert.ok(p.offered[0]?.includes('update_goal') && p.offered[0].includes('add_helper'));
  assert.match(String(listMessages(p.db, owner).find((m) => m.toolCallId === 'g0')?.content), /^error: helper-to-be is neither you/);
  assert.deepEqual(listGoals(p.db).map((goal) => goal.id), [1], 'a refused create leaves no goal behind');

  await ask('check the page');
  const worker = findAgent(p.db, 'alpha-w1') as Agent;
  assert.ok(worker.display <= 999, 'a screen helper holds a real display');
  assert.ok(desktop.includes(`ensure alpha :${worker.display} alpha-w1`), 'on the lead\'s user, tagged with its own name');
  const asWorker = p.seen.findIndex((messages) => askedAgent(messages) === 'alpha-w1');
  assert.deepEqual(p.offered[asWorker], ['computer', 'run_command', 'web_search', 'web_fetch']);
  assert.match(String(p.seen[asWorker]?.[0]?.text), /You are a helper on this goal:\nGoal 1: Ship the site/);

  updateRules(p.db, p.alpha, { levels: { delete_files: 'hand_to_you' }, preApproved: { send_messages: ['example.com'] } });
  await ask('draft the copy');
  const temp = findAgent(p.db, helper) as Agent;
  assert.deepEqual(readRules(p.db, temp), readRules(p.db, p.alpha), 'a helper is held to its lead\'s rules');
  assert.equal(temp.parentId, undefined, 'a temporary agent is an agent of its own');
  assert.match(String(temp.profile), /helper of alpha on the goal "Ship the site"/);
  assert.ok(desktop.includes(`ensure ${helper} :${temp.display}`));
  const helperThread = conversationFor(p.db, temp.id);
  assert.deepEqual(
    listMessages(p.db, helperThread).filter((m) => m.role !== 'tool' && m.toolCalls === undefined).map((m) => [m.sender, m.content]),
    [['alpha', 'Draft the copy.'], [helper, 'drafted']],
  );
  assert.ok(listMessages(p.db, helperThread).some((m) => m.content === 'error: a helper does not bring in helpers of its own; ask your lead'));
  assert.deepEqual(
    listMessages(p.db, owner).filter((m) => m.sender === helper).map((m) => [m.role, m.content]),
    [['user', 'drafted']],
    'its answer came back to the lead\'s own thread',
  );
  const asHelper = p.seen.findIndex((messages) => askedAgent(messages) === helper);
  assert.match(String(p.seen[asHelper]?.[0]?.text), /You are a helper on it\. Report to alpha/);

  await ask('mark it');
  assert.ok(listMessages(p.db, owner).some((m) => m.content === 'error: nobody is neither you nor a helper on this goal; add it with add_helper first'));
  const [item] = listNeedsYou(p.db).filter((needs) => needs.kind === 'goal');
  assert.deepEqual([item?.id, item?.goalId, item?.detail, item?.conversationId], ['goal:1', 1, 'Approve the copy', owner]);
  const lastPrompt = p.seen.findLast((messages) => askedAgent(messages) === 'alpha');
  assert.match(String(lastPrompt?.[0]?.text), new RegExp(`Helper ${helper}, temporary agent: Long copy work\\.`));

  await ask('finish it');
  assert.equal(findAgent(p.db, helper), undefined, 'the temporary agent is gone');
  assert.ok(listMessages(p.db, owner).some((m) => m.sender === helper && m.content === 'drafted'), 'its answer stays in the lead\'s thread');
  assert.ok(desktop.includes(`remove ${helper}`));
  assert.ok(desktop.includes(`stopDisplay alpha :${worker.display}`), 'only the worker\'s own display is stopped');
  assert.ok(!desktop.includes('stop alpha'));
  const kept = findAgent(p.db, 'alpha-w1') as Agent;
  assert.ok(kept.display > 999, 'the worker stays as a finished worker, its display handed back');
  assert.ok(listMessages(p.db, owner).some((m) => m.sender === 'alpha-w1' && m.content === 'the page loads'), 'its report stays in the lead\'s thread');
  assert.match(String(listMessages(p.db, owner).find((m) => m.toolCallId === 'f1')?.content), /^Goal 1: Ship the site \(done\)/);
  assert.deepEqual(listNeedsYou(p.db).filter((needs) => needs.kind === 'goal'), [], 'a done goal needs nothing');
});

/** Rejects when `work` has not settled within `ms`, so a turn that ignores a stop fails the test
 * instead of hanging the run. */
async function settlesWithin<T>(work: Promise<T>, ms: number): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const late = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`still running after ${ms} ms`)), ms);
  });
  try {
    return await Promise.race([work, late]);
  } finally {
    clearTimeout(timer);
  }
}

/** A provider call that only ends when the turn is stopped. */
const untilAborted = (signal: AbortSignal | undefined): Promise<ChatReply> =>
  new Promise((_, reject) => signal?.addEventListener('abort', () => reject(signal.reason), { once: true }));

test('a set_name rename mid-drain runs the next round under the new name and never a second turn', async () => {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  const conversationId = conversationFor(db, alpha.id);
  const { provider: scripted, seen } = scriptedProvider({
    alpha: [{ toolCalls: [{ id: 'n1', name: 'set_name', arguments: '{"name":"bravo"}' }] }, { text: 'From now on, bravo.' }],
    bravo: [{ text: 'Bravo here.' }],
  });
  let inFlight = 0;
  let most = 0;
  let calls = 0;
  const provider: Provider = async (messages, tools, onDelta, signal) => {
    calls += 1;
    if (calls === 1) appendMessage(db, conversationId, { role: 'user', content: 'Still there?' });
    inFlight += 1;
    most = Math.max(most, inFlight);
    await tick();
    try {
      return await scripted(messages, tools, onDelta, signal);
    } finally {
      inFlight -= 1;
    }
  };
  let runner: TurnRunner | undefined;
  let startedUnderNewName = false;
  const rename = (agent: Agent, name: string): Promise<void> => {
    const moved = renameAgent(db, agent, name);
    assert.equal(runner?.running('bravo'), true, 'the turn in flight is found under the new name');
    runner?.start(moved, conversationId);
    startedUnderNewName = true;
    return Promise.resolve();
  };
  runner = createRunner({
    db,
    exec: fakeExec([]),
    screen: SCREEN,
    provider: () => provider,
    control: createControl(),
    search: noSearch,
    mcp: noMcp,
    rename,
    ...CAPS,
  });
  appendMessage(db, conversationId, { role: 'user', content: 'Call yourself bravo.' });
  runner.start(alpha, conversationId);
  await quiet(db);

  assert.ok(startedUnderNewName);
  assert.equal(most, 1, 'one turn at a time');
  assert.equal(askedAgent(seen.at(-1) ?? []), 'bravo', "the next round's system prompt carries the new name");
  assert.deepEqual(
    listMessages(db, conversationId).filter((m) => m.role === 'assistant').map((m) => [m.sender, m.content]),
    [['bravo', ''], ['bravo', 'From now on, bravo.'], ['bravo', 'Bravo here.']],
  );
  assert.equal(findAgent(db, 'bravo')?.state, 'waiting_for_user');
  assert.equal(runner.running('bravo'), false);
  assert.deepEqual(queuedTurns(db), []);
});

test('a stop while the summariser is writing ends the turn within moments and stores no summary', async () => {
  const f = fixture([]);
  longThread(f.db, f.conversationId, LONG_TURNS, TURN_CHARS);
  f.ask('and now?');
  let summarising: () => void = () => {};
  const asked = new Promise<void>((done) => {
    summarising = done;
  });
  let agentCalls = 0;
  const provider: Provider = (messages, _t, _d, signal) => {
    if (messages[0]?.role === 'system' && messages[0].text === SUMMARY_PROMPT) {
      summarising();
      return untilAborted(signal);
    }
    agentCalls += 1;
    return Promise.resolve({ text: 'never asked for', toolCalls: [] });
  };
  const controller = new AbortController();
  const turn = runAgent({ ...f.deps, provider, signal: controller.signal }, f.agent, f.conversationId);
  await settlesWithin(asked, 2_000);
  controller.abort(new Error('stopped by the owner'));
  await settlesWithin(turn, 2_000);

  assert.equal(f.state(), 'waiting_for_user');
  assert.equal(f.messages().at(-1)?.content, STOPPED);
  assert.equal(latestSummary(f.db, f.conversationId, 'alpha'), undefined, 'no summary row, half-written or whole');
  assert.equal(agentCalls, 0, 'the model was never asked to go on');
  assert.ok(f.events().some((e) => e.type === 'stop'));
  assert.ok(!f.events().some((e) => e.type === 'failure'));
});

/** An exec whose workspace snapshot only finishes on `finish()`, or never when it is not called;
 * it ignores the stop, the worst case for a turn waiting on it. Everything else runs at once. */
function slowSnapshot(ran: string[][], order: string[]) {
  let finish: () => void = () => {};
  const done = new Promise<void>((resolve) => {
    finish = resolve;
  });
  const fast = fakeExec(ran);
  const exec: Exec = async (file, args, options) => {
    if (args.includes(SNAPSHOTS)) {
      order.push('snapshot started');
      await done;
      order.push('snapshot done');
      return { code: 0, stdout: Buffer.alloc(0), stderr: '', truncated: false };
    }
    if (args.some((arg) => arg.includes('uname -a'))) order.push('run_command');
    return fast(file, args, options);
  };
  return { exec, finish };
}

test('the first model call does not wait for the snapshot, and the first tool call does', async () => {
  const f = fixture([]);
  const order: string[] = [];
  const { exec, finish } = slowSnapshot(f.ran, order);
  const { provider: scripted } = scriptedProvider({ alpha: [{ toolCalls: [commandCall] }, { text: 'done' }] });
  const provider: Provider = (messages, tools, onDelta, signal) => {
    order.push('model');
    return scripted(messages, tools, onDelta, signal);
  };
  f.ask('go');
  const turn = runAgent({ ...f.deps, exec, provider }, f.agent, f.conversationId);
  for (let attempt = 0; attempt < 100 && !order.includes('model'); attempt += 1) await tick();
  await tick();
  assert.deepEqual(order, ['snapshot started', 'model'], 'the model was asked while the snapshot ran, and no tool ran yet');
  finish();
  await settlesWithin(turn, 2_000);

  assert.deepEqual(order, ['snapshot started', 'model', 'snapshot done', 'run_command', 'model']);
  assert.equal(f.state(), 'waiting_for_user');
});

test('a configured MCP server starts only once the snapshot is done', async () => {
  const order: string[] = [];
  const mcp: LoopDeps['mcp'] = async (_agent, homeReady) => {
    await homeReady();
    order.push('mcp started');
    return undefined;
  };
  const f = fixture([{ text: 'done' }], noSearch, mcp);
  const { exec, finish } = slowSnapshot(f.ran, order);
  f.ask('go');
  const turn = runAgent({ ...f.deps, exec }, f.agent, f.conversationId);
  await tick();
  assert.deepEqual(order, ['snapshot started']);
  finish();
  await settlesWithin(turn, 2_000);
  assert.deepEqual(order, ['snapshot started', 'snapshot done', 'mcp started']);
});

test('a stop while a tool waits on a snapshot that never returns lands within seconds', async () => {
  const f = fixture([]);
  const order: string[] = [];
  const { exec } = slowSnapshot(f.ran, order);
  let runner: TurnRunner | undefined;
  const { provider: scripted } = scriptedProvider({ alpha: [{ toolCalls: [commandCall] }, { text: 'never asked for' }] });
  const provider: Provider = async (messages, tools, onDelta, signal) => {
    const reply = await scripted(messages, tools, onDelta, signal);
    setTimeout(() => runner?.stop('alpha'), 20);
    return reply;
  };
  runner = createRunner({ ...f.deps, exec, provider: () => provider, maxLoops: 4 });
  f.ask('go');
  const started = Date.now();
  runner.start(f.agent, f.conversationId);
  while (runner.running('alpha') && Date.now() - started < 4_000) await tick();

  assert.equal(runner.running('alpha'), false, 'the loop was let go within seconds');
  assert.equal(f.state(), 'waiting_for_user');
  const rows = f.messages();
  assert.deepEqual(rows.map((m) => m.role), ['user', 'assistant', 'tool', 'assistant']);
  assert.equal(rows[2]?.content, 'error: stopped by the owner');
  assert.equal(rows.at(-1)?.content, STOPPED);
  assert.ok(!order.includes('run_command'), 'the command never ran over a home with no snapshot');
  assert.ok(!f.events().some((e) => e.type === 'failure'));
});

test('a reply cut off at the token limit is kept, marked and delivered as cut off', async () => {
  const f = fixture([{ text: 'The three causes are: first', finish: 'length' }]);
  const delivered: string[] = [];
  f.ask('why did it fail?');
  await runAgent({ ...f.deps, deliver: (_agent, _thread, text) => delivered.push(text) }, f.agent, f.conversationId);
  assert.equal(f.messages().at(-1)?.content, `The three causes are: first${CUT_OFF}`);
  assert.deepEqual(delivered, [`The three causes are: first${CUT_OFF}`]);
  assert.equal(f.state(), 'waiting_for_user');

  const empty = fixture([{ text: '', finish: 'length' }]);
  empty.ask('think hard');
  await runAgent(empty.deps, empty.agent, empty.conversationId);
  assert.equal(empty.messages().at(-1)?.content, CUT_OFF, 'a reasoning model that spent it all thinking is cut off, not silent');
});

const halfCall = { id: 'c9', name: 'run_command', arguments: '{"command":"rm -rf /tmp/scratch' };

test('a tool call cut off at the token limit is answered but never run, and the model is asked again', async () => {
  const f = fixture([{ toolCalls: [halfCall], finish: 'length' }, { toolCalls: [commandCall] }, { text: 'done.' }]);
  f.ask('clean up');
  await runAgent(f.deps, f.agent, f.conversationId);

  assert.ok(!f.ran.some((argv) => argv.join(' ').includes('rm -rf')), 'the cut-off call never ran');
  assert.ok(tooling(f.ran).some((argv) => argv.join(' ').includes('uname -a')), 'the one asked next did');
  const stored = f.messages();
  const asked = stored.find((m) => m.toolCalls?.[0]?.id === halfCall.id);
  assert.equal(asked?.toolCalls?.[0]?.arguments, '{}', 'no partial JSON is replayed');
  assert.equal(stored.find((m) => m.toolCallId === halfCall.id)?.content, CALL_CUT_OFF);
  const retry = f.seen[1] as ProviderMessage[];
  assertEveryCallAnswered(retry);
  assert.ok(retry.some((m) => m.role === 'tool' && m.text === CALL_CUT_OFF));
  assert.ok(f.events().some((e) => e.type === 'tool_result' && e.data['callId'] === halfCall.id && e.data['ok'] === false));
  assert.equal(stored.at(-1)?.content, 'done.');
  assert.equal(f.state(), 'waiting_for_user');
});

test('a second cut-off tool call in one turn fails it, with every call still answered', async () => {
  const f = fixture([
    { toolCalls: [halfCall], finish: 'length' },
    { toolCalls: [{ ...halfCall, id: 'c10' }], finish: 'length' },
  ]);
  f.ask('clean up');
  await runAgent(f.deps, f.agent, f.conversationId);

  assert.equal(f.seen.length, 2, 'asked again once, not a third time');
  assert.ok(!f.ran.some((argv) => argv.join(' ').includes('rm -rf')));
  assert.equal(f.state(), 'failed');
  const stored = f.messages();
  assert.equal(stored.at(-1)?.content, `${RUN_FAILED}: ${CUT_OFF_AGAIN}`);
  assert.deepEqual(
    stored.slice(-3, -1).map((m) => [m.role, m.toolCalls?.[0]?.id ?? m.toolCallId]),
    [['assistant', 'c10'], ['tool', 'c10']],
  );
});

test('summariser tokens count toward the turn and the idle budget, from both summaries a turn can write', async () => {
  const f = fixture([]);
  createModel(f.db, { name: 'small', model: 'small', contextWindow: 16_000 });
  longThread(f.db, f.conversationId, 6, 1_000);
  f.ask('go on');
  let calls = 0;
  let summaries = 0;
  const provider: Provider = (messages) => {
    if (messages[0]?.role === 'system' && messages[0].text === SUMMARY_PROMPT) {
      summaries += 1;
      return Promise.resolve({ text: SUMMARY, toolCalls: [], usage: { promptTokens: 1_000, completionTokens: 100 } });
    }
    calls += 1;
    const usage = { promptTokens: 50, completionTokens: 5 };
    if (calls === 1) return Promise.resolve({ text: '', toolCalls: [commandCall], usage });
    if (calls === 2) return Promise.reject(new ProviderError('context_length_exceeded', false, 400, undefined, true));
    return Promise.resolve({ text: 'done.', toolCalls: [], usage });
  };
  let ended: number | undefined;
  const idle = { passId: 0, modelId: null, turnCap: 10, tokenLimit: 1_000_000, end: (tokens: number | undefined) => {
    ended = tokens;
    return Promise.resolve();
  } };

  await runAgent({ ...f.deps, provider, idle }, f.agent, f.conversationId);

  assert.equal(summaries, 2, 'the turn-start compaction, then the forced one');
  const turn = f.events().findLast((e) => e.type === 'turn');
  assert.deepEqual(turn?.data, { steps: 2, summaries: 2, promptTokens: 2_100, completionTokens: 210 });
  assert.equal(ended, 2_310);
});

test("the owner's compaction answers what its summary cost", async () => {
  const f = fixture([]);
  longThread(f.db, f.conversationId, 3, 100);
  const provider: Provider = () =>
    Promise.resolve({ text: SUMMARY, toolCalls: [], usage: { promptTokens: 700, completionTokens: 70 } });
  const result = await compactNow({ db: f.db, provider }, f.agent, f.conversationId);
  assert.deepEqual(result, { covered: f.messages().length, usage: { promptTokens: 700, completionTokens: 70 } });
});

test('a mid-turn switch to a backup with a smaller window compacts to the backup budget before the next step', async () => {
  const run = async (backup: boolean) => {
    const f = fixture([]);
    createModel(f.db, { name: 'big', model: 'big', contextWindow: null });
    const small = createModel(f.db, { name: 'small', model: 'small', contextWindow: 16_000 });
    longThread(f.db, f.conversationId, 6, 1_000);
    f.ask('go on');
    const asked: ProviderMessage[][] = [];
    let summaries = 0;
    const tag = backup ? { modelId: small.id } : {};
    const provider: Provider = (messages) => {
      if (messages[0]?.role === 'system' && messages[0].text === SUMMARY_PROMPT) {
        summaries += 1;
        return Promise.resolve({ text: SUMMARY, toolCalls: [] });
      }
      asked.push([...messages]);
      return Promise.resolve(
        asked.length === 1 ? { text: '', toolCalls: [commandCall], ...tag } : { text: 'done.', toolCalls: [], ...tag },
      );
    };
    await runAgent({ ...f.deps, provider }, f.agent, f.conversationId);
    return { f, asked, summaries };
  };

  const switched = await run(true);
  assert.equal(switched.summaries, 1, 'the big default needed none, the small backup did');
  assert.doesNotMatch(String(switched.asked[0]?.[1]?.text), /summarised:/);
  assert.match(String(switched.asked[1]?.[1]?.text), new RegExp(`summarised:\\n${SUMMARY}$`));
  assertEveryCallAnswered(switched.asked[1] as ProviderMessage[]);
  assert.equal(switched.f.messages().at(-1)?.content, 'done.');

  const stayed = await run(false);
  assert.equal(stayed.summaries, 0, 'without a switch the big budget holds');
});

test("an overflow on the backup's first call compacts to the backup's budget, not a quarter of the primary's", async () => {
  const run = async (tagged: boolean) => {
    const f = fixture([]);
    createModel(f.db, { name: 'big', model: 'big', contextWindow: null });
    const small = createModel(f.db, { name: 'small', model: 'small', contextWindow: 16_000 });
    longThread(f.db, f.conversationId, 6, 1_000);
    f.ask('go on');
    const asked: ProviderMessage[][] = [];
    const provider: Provider = (messages) => {
      if (messages[0]?.role === 'system' && messages[0].text === SUMMARY_PROMPT) {
        return Promise.resolve({ text: SUMMARY, toolCalls: [] });
      }
      asked.push([...messages]);
      if (asked.length === 1) {
        const refused = new ProviderError('context_length_exceeded', false, 400, undefined, true);
        if (tagged) refused.modelId = small.id;
        return Promise.reject(refused);
      }
      return Promise.resolve({ text: 'done.', toolCalls: [] });
    };
    await runAgent({ ...f.deps, provider }, f.agent, f.conversationId);
    const verbatim = (asked[1] ?? []).filter((m) => m.role === 'assistant' && m.text.startsWith('(A')).length;
    return { f, verbatim };
  };

  const backup = await run(true);
  assert.equal(backup.f.messages().at(-1)?.content, 'done.');
  assert.ok(backup.verbatim <= 1, `the small window keeps at most the last turn verbatim (${backup.verbatim})`);
  const primary = await run(false);
  assert.ok(primary.verbatim > backup.verbatim, `a quarter of the big budget keeps more (${primary.verbatim})`);
});
