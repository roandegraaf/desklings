import assert from 'node:assert/strict';
import test from 'node:test';
import { resolve } from 'node:path';
import { sql } from 'drizzle-orm';
import { AGENT_STATES } from '@schermes/shared';
import type { Agent, Message } from '@schermes/shared';
import { openDb } from './db.ts';
import { findAgent, insertAgent, insertWorker, listAgents, setAgentState } from './agents.ts';
import {
  MAX_AGENT_CHAIN,
  agentChain,
  appendMessage,
  conversationFor,
  conversationWith,
  lastMessageId,
  latestSummary,
  listConversations,
  listEvents,
  listMessages,
} from './conversations.ts';
import type { Db } from './db.ts';
import {
  COMPACTION_TAIL_CHARS,
  MAX_FULL_OBSERVATIONS,
  MAX_REPLAYED_IMAGES,
  MAX_TRANSCRIPT_CHARS,
  RUN_FAILED,
  SUMMARY_PROMPT,
  TRANSITIONS,
  canTransition,
  compactNow,
  createRunner,
  describe,
  reconcileAgents,
  runAgent,
  transcript,
} from './loop.ts';
import type { LoopDeps } from './loop.ts';
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
import { withoutKey } from './provider.ts';
import { STOPPED, WORKER_FAILED } from './loop.ts';
import { workerPrompt } from './workers.ts';
import type { ChatReply, Provider, ProviderMessage } from './provider.ts';
import type { Exec } from './exec.ts';

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
    return Promise.resolve({
      text: reply.text ?? '',
      toolCalls: reply.toolCalls ?? [],
      ...(reply.usage === undefined ? {} : { usage: reply.usage }),
    });
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
 * What a turn ran beyond reading the agent's home. Every turn opens with a `getent` and one
 * `sudo` that reads memory and the skills index, which is not what any assertion about tools is
 * looking at.
 */
function tooling(ran: readonly string[][]): string[][] {
  return ran.filter((argv) => argv[0] !== 'getent' && !argv.includes(HOME_LOAD));
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
  assert.match(String(said[2]), /^bravo said here, to the owner:\nmine is bravo-box$/);
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

test('the boot reconcile moves every interrupted agent and no settled one', () => {
  const db = openDb(':memory:', MIGRATIONS);
  const interrupted = ['thinking', 'using_computer', 'using_terminal'];
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

function pair(script: Record<string, readonly Partial<ChatReply>[]>, caps = CAPS) {
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

  const shared = conversationWith(p.db, [p.alpha.id, p.bravo.id]);
  assert.deepEqual(
    listMessages(p.db, shared).map((m) => [m.role, m.sender, m.content]),
    [
      ['user', 'alpha', 'what is your hostname?'],
      ['assistant', 'bravo', 'my hostname is bravo-box'],
      ['assistant', 'alpha', 'bravo says it is bravo-box.'],
    ],
  );

  // The thread the two share is its own row, and both of them are in it.
  assert.deepEqual(
    listConversations(p.db, p.bravo.id).map((c) => c.participants),
    [['alpha', 'bravo']],
  );
  assert.equal(p.state('alpha'), 'waiting_for_user', 'the reply arrived and alpha answered it');
  assert.equal(p.state('bravo'), 'waiting_for_user');
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

test('messages that land in two threads mid-turn are both answered', async () => {
  let release: () => void = () => {};
  const held = new Promise<void>((done) => {
    release = () => done();
  });
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  let turns = 0;
  const provider: Provider = async () => {
    turns += 1;
    if (turns === 1) await held;
    return { text: `answer ${turns}`, toolCalls: [] };
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
    maxWorkers: 1,
  });
  const bravo = insertAgent(db, 'bravo') as Agent;
  const owner = conversationFor(db, alpha.id);
  const other = conversationWith(db, [alpha.id, bravo.id]);

  appendMessage(db, owner, { role: 'user', content: 'first' });
  runner.start(alpha, owner);
  await tick();
  appendMessage(db, owner, { role: 'user', content: 'second' });
  appendMessage(db, other, { role: 'user', content: 'elsewhere' });
  runner.start(alpha, owner);
  runner.start(alpha, other);
  release();
  await quiet(db);

  assert.equal(turns, 3, 'one turn per message, none repeated for a thread already answered');
  assert.equal(listMessages(db, other).at(-1)?.role, 'assistant', 'the other thread got its answer');
  assert.deepEqual(
    listMessages(db, owner).map((m) => m.content),
    ['first', 'second', 'answer 1', 'answer 2'],
  );
});

test('one message to a group conversation is answered by every agent in it', async () => {
  const p = pair({ alpha: [{ text: 'alpha here' }], bravo: [{ text: 'bravo here' }] });
  const group = conversationWith(p.db, [p.alpha.id, p.bravo.id]);
  appendMessage(p.db, group, { role: 'user', content: 'who is around?' });
  p.runner.start(p.alpha, group);
  p.runner.start(p.bravo, group);
  await quiet(p.db);

  assert.deepEqual(
    listMessages(p.db, group)
      .filter((m) => m.role === 'assistant')
      .map((m) => [m.sender, m.content])
      .sort(),
    [['alpha', 'alpha here'], ['bravo', 'bravo here']],
  );
  // An answer is addressed to nobody, so neither reply set the other one off again.
  assert.equal(p.seen.length, 2, 'one model call each');
  assert.equal(p.state('alpha'), 'waiting_for_user');
  assert.equal(p.state('bravo'), 'waiting_for_user');
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

  const shared = conversationWith(p.db, [p.alpha.id, p.bravo.id]);
  const passed = listMessages(p.db, shared).filter((m) => m.role === 'user');
  // The replies each side gives count too, so the cap lands before that many were even sent.
  assert.ok(passed.length < MAX_AGENT_CHAIN, `only ${passed.length} got through`);
  assert.ok(agentChain(p.db, shared) >= MAX_AGENT_CHAIN, 'the chain stopped at the cap');
  assert.equal(p.state('alpha'), 'waiting_for_user');
  assert.equal(p.state('bravo'), 'waiting_for_user');
  const refusal = listMessages(p.db, shared).find((m) => m.content.includes('back and forth'));
  assert.ok(refusal !== undefined, 'the agent was told why, in a message it can act on');
});

test('a reply in a shared thread counts as a message between agents; in an owner thread it does not', () => {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  const bravo = insertAgent(db, 'bravo') as Agent;
  const shared = conversationWith(db, [alpha.id, bravo.id]);
  const owner = conversationFor(db, alpha.id);
  for (const conversationId of [shared, owner]) {
    appendMessage(db, conversationId, { role: 'user', content: 'go' });
    appendMessage(db, conversationId, { role: 'assistant', content: '', sender: 'alpha', toolCalls: [commandCall] });
    appendMessage(db, conversationId, { role: 'tool', content: 'exit code 0', sender: 'alpha', toolCallId: 'c2' });
    appendMessage(db, conversationId, { role: 'assistant', content: 'done', sender: 'alpha' });
    appendMessage(db, conversationId, { role: 'user', content: 'thanks', sender: 'bravo' });
  }
  assert.equal(agentChain(db, shared), 2, 'the reply and the message, not the tool step');
  assert.equal(agentChain(db, owner), 1, 'a reply to the owner is not between agents');
});

test('a restart hands back an agent whose reply landed before the daemon died', () => {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  const bravo = insertAgent(db, 'bravo') as Agent;

  // What a daemon killed after bravo answered leaves behind: alpha wrote to bravo, ended its
  // turn waiting, and bravo's answer is stored. The wake only ever fires from inside a live
  // turn, so without a repair nothing would ever start alpha again.
  const shared = conversationWith(db, [alpha.id, bravo.id]);
  appendMessage(db, shared, { role: 'user', content: 'hostname?', sender: 'alpha' });
  appendMessage(db, shared, { role: 'assistant', content: 'asked bravo', sender: 'alpha' });
  appendMessage(db, shared, { role: 'assistant', content: 'bravo-box', sender: 'bravo' });
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
  const shared = conversationWith(db, [alpha.id, bravo.id]);
  appendMessage(db, shared, { role: 'user', content: 'hostname?', sender: 'alpha' });
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

test('a turn above the loop cap is refused rather than run', () => {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
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
  runner.start(alpha, conversationFor(db, alpha.id));
  assert.equal(runner.atCapacity('alpha'), undefined, 'an agent already running is not a new loop');
  assert.match(String(runner.atCapacity('bravo')), /at most 1 agent loops can run at once/);
  assert.match(String(runner.atCapacity()), /at most 1 agent loops can run at once/);
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

  // A thread it has never spoken in: nothing but the loaded file can carry the fact into it.
  const shared = conversationWith(db, [alpha.id, bravo.id]);
  appendMessage(db, shared, { role: 'user', content: 'who am I?' });
  await runAgent(deps, alpha, shared);

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

test('each agent in a group thread is compacted on its own view of it', async () => {
  const p = pair({ alpha: [{ text: 'alpha is caught up.' }], bravo: [{ text: 'bravo too.' }] });
  const group = conversationWith(p.db, [p.alpha.id, p.bravo.id]);
  longThread(p.db, group, LONG_TURNS, TURN_CHARS, { label: 'A', sender: 'alpha' });
  longThread(p.db, group, LONG_TURNS, TURN_CHARS, { label: 'B', sender: 'bravo' });

  p.runner.start(p.alpha, group);
  await quiet(p.db);
  p.runner.start(p.bravo, group);
  await quiet(p.db);

  const mine = latestSummary(p.db, group, 'alpha');
  const theirs = latestSummary(p.db, group, 'bravo');
  assert.ok(mine !== undefined && theirs !== undefined, 'one summary each, not one for the thread');
  assert.notEqual(mine.id, theirs.id);

  // What each one was asked to summarise is its own projection. Another agent's tool traffic
  // never reaches a transcript, so it cannot reach a summary of one either.
  assert.equal(p.summarised.length, 2);
  const [forAlpha, forBravo] = p.summarised as [string, string];
  assert.match(forAlpha, /\[you called run_command/, 'alpha summarises its own calls');
  assert.ok(!forAlpha.includes('exit code 0 (B'), 'and never bravo\'s results');
  assert.ok(!forBravo.includes('exit code 0 (A'), 'nor bravo alpha\'s');

  // Each agent is still shown who said what, which is the whole point of the group thread.
  assert.match(forBravo, /alpha said here, to the owner:\n\(A\d/, 'bravo sees alpha by name');
  assert.match(forAlpha, /Message from the owner:\nread the logs/);
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
  assert.equal(delivered?.sender, undefined, 'written as the owner, or nothing would wake on it');
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
