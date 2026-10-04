import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import type { ChildProcess } from 'node:child_process';
import { createServer, connect } from 'node:net';
import { resolve } from 'node:path';
import test from 'node:test';
import type { Agent } from '@schermes/shared';
import { insertAgent } from './agents.ts';
import { appendMessage, conversationFor, latestSummary, listMessages, pageMessages } from './conversations.ts';
import { createControl } from './control.ts';
import { openDb } from './db.ts';
import type { Exec } from './exec.ts';
import { CALL_CUT_OFF, RUN_FAILED, createRunner, runAgent } from './loop.ts';
import type { LoopDeps } from './loop.ts';
import { ProviderError, openAiProvider } from './provider.ts';
import type { Provider } from './provider.ts';

const MIGRATIONS = resolve(import.meta.dirname, '../migrations');
const STUB = resolve(import.meta.dirname, '../../infra/provider-stub.py');
const SCREEN = { width: 1280, height: 800, display: { width: 1280, height: 800 } };
const NONCE = 'stubnonce42';
const noPython = spawnSync('python3', ['--version']).status !== 0;

function freePort(): Promise<number> {
  return new Promise((done, fail) => {
    const server = createServer();
    server.once('error', fail);
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      server.close(() => done(typeof address === 'object' && address !== null ? address.port : 0));
    });
  });
}

function accepting(port: number): Promise<boolean> {
  return new Promise((done) => {
    const socket = connect(port, '127.0.0.1');
    socket.once('connect', () => {
      socket.destroy();
      done(true);
    });
    socket.once('error', () => done(false));
  });
}

/** `infra/provider-stub.py` on a free loopback port, with its environment, until `stop`. */
export async function startStub(
  env: Record<string, string>,
  command = 'true',
): Promise<{ baseUrl: string; stop: () => void }> {
  const port = await freePort();
  const child: ChildProcess = spawn('python3', [STUB, String(port), NONCE, command], {
    env: { ...process.env, ...env },
    stdio: 'ignore',
  });
  const stop = () => {
    child.kill();
  };
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (await accepting(port)) return { baseUrl: `http://127.0.0.1:${port}/v1`, stop };
    await new Promise((done) => setTimeout(done, 25));
  }
  stop();
  throw new Error('the provider stub never started listening');
}

const exec: Exec = (file, args) =>
  Promise.resolve({
    code: 0,
    stdout: Buffer.from(file === 'getent' ? `${String(args[1])}:x:1001:1001::/home/${String(args[1])}:/bin/bash\n` : ''),
    stderr: '',
    truncated: false,
  });

const KEY = 'stub-key-7c1e';

/** One agent with a thread of `turns` finished turns of `chars` each, and a provider on the stub
 * that records every error it passes on. The key is one no error body contains by chance, since
 * `withoutKey` rewrites every occurrence of it. */
function turnOn(baseUrl: string, turns: number, chars: number, model = 'stub') {
  const db = openDb(':memory:', MIGRATIONS);
  const agent = insertAgent(db, 'alpha') as Agent;
  const conversationId = conversationFor(db, agent.id);
  appendMessage(db, conversationId, { role: 'user', content: 'read the logs' });
  for (let turn = 0; turn < turns; turn += 1) {
    const call = { id: `t${turn}`, name: 'run_command', arguments: '{"command":"cat log"}' };
    appendMessage(db, conversationId, {
      role: 'assistant',
      content: `(${turn}) ${'x'.repeat(chars)}`,
      sender: 'alpha',
      toolCalls: [call],
    });
    appendMessage(db, conversationId, { role: 'tool', content: 'exit code 0', sender: 'alpha', toolCallId: call.id });
  }
  appendMessage(db, conversationId, { role: 'user', content: 'and now?' });
  const errors: unknown[] = [];
  const inner = openAiProvider({ baseUrl, model, apiKey: KEY });
  const provider: Provider = (messages, tools, onDelta, signal) =>
    inner(messages, tools, onDelta, signal).catch((error: unknown) => {
      errors.push(error);
      throw error;
    });
  const control = createControl();
  const search = () => undefined;
  const mcp = () => Promise.resolve(undefined);
  const caps = { maxLoops: 4, maxWorkers: 2 };
  const runner = createRunner({ db, exec, screen: SCREEN, provider: () => provider, control, search, mcp, ...caps });
  const deps: LoopDeps = { db, exec, provider, screen: SCREEN, runner, control, search, mcp, maxWorkers: caps.maxWorkers };
  return { db, agent, conversationId, deps, errors, messages: () => listMessages(db, conversationId) };
}

const overflowed = (errors: readonly unknown[]) =>
  errors.filter((error) => error instanceof ProviderError && error.overflow).length;

test('overflow mode: a context-length 400 from the stub leads to compaction and a successful retry', { skip: noPython && 'python3 is not installed' }, async () => {
  const stub = await startStub({ STUB_SCRIPT: 'memory', STUB_MAX_CHARS: '150000' });
  try {
    const t = turnOn(stub.baseUrl, 60, 3_000);
    await runAgent(t.deps, t.agent, t.conversationId);

    assert.equal(overflowed(t.errors), 1, 'the full thread was refused once');
    assert.equal(t.errors.length, 1, 'and nothing else failed, the summariser included');
    const summary = latestSummary(t.db, t.conversationId, 'alpha');
    assert.match(String(summary?.content), new RegExp(`^stub summary ${NONCE}`));
    const reply = String(t.messages().at(-1)?.content);
    assert.match(reply, new RegExp(`nonce=${NONCE}`), 'the retried step was answered');
    assert.match(reply, /valid=yes/, 'with every call answered in the compacted replay');
  } finally {
    stub.stop();
  }
});

test('overflow mode: a turn the stub refuses even after compaction fails as before', { skip: noPython && 'python3 is not installed' }, async () => {
  const stub = await startStub({ STUB_SCRIPT: 'memory', STUB_MAX_CHARS: '1000' });
  try {
    const t = turnOn(stub.baseUrl, 6, 1_000);
    await runAgent(t.deps, t.agent, t.conversationId);

    assert.equal(overflowed(t.errors), 2, 'refused, compacted once, refused again, and not asked a third time');
    assert.match(String(t.messages().at(-1)?.content), new RegExp(`^${RUN_FAILED}: provider returned HTTP 400`));
  } finally {
    stub.stop();
  }
});

test('token-limit mode: a tool call cut off by the stub is never run, and the turn goes on to a valid request', { skip: noPython && 'python3 is not installed' }, async () => {
  const marker = `touch /tmp/${NONCE}-never-ran`;
  const stub = await startStub({ STUB_SCRIPT: 'memory', STUB_FINISH: 'length' }, marker);
  try {
    const t = turnOn(stub.baseUrl, 0, 0);
    const ran: string[] = [];
    const recording: Exec = (file, args, options) => {
      ran.push([file, ...args].join(' '));
      return exec(file, args, options);
    };
    await runAgent({ ...t.deps, exec: recording }, t.agent, t.conversationId);

    assert.deepEqual(t.errors, []);
    assert.ok(!ran.some((argv) => argv.includes(`/tmp/${NONCE}`)), 'the cut-off command never reached a shell');
    const stored = t.messages();
    assert.equal(stored.find((m) => m.toolCalls?.[0]?.id === 'cut-1')?.toolCalls?.[0]?.arguments, '{}');
    assert.equal(stored.find((m) => m.toolCallId === 'cut-1')?.content, CALL_CUT_OFF);
    const reply = String(stored.at(-1)?.content);
    assert.match(reply, new RegExp(`nonce=${NONCE}`), 'the model was asked again and answered');
    assert.match(reply, /calls=run_command results=1/);
    assert.match(reply, /valid=yes/, 'with the cut-off call answered in the replay');
  } finally {
    stub.stop();
  }
});

const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const RUN_TRUE = '{"command": "true", "timeoutMs": 30000}';

/** The stub's last report in the thread, after the turn asked for `true` once and was answered. */
function reportedAfterOneCall(t: ReturnType<typeof turnOn>): string {
  assert.deepEqual(t.errors, []);
  const reply = String(t.messages().at(-1)?.content);
  assert.match(reply, new RegExp(`nonce=${NONCE}`), 'the turn reached the stub\'s report');
  assert.match(reply, /valid=yes/, 'with every call answered in order');
  return reply;
}

const python = { skip: noPython && 'python3 is not installed' };

test('bare-data mode: empty data lines between the events are skipped', python, async () => {
  const stub = await startStub({ STUB_SCRIPT: 'busy', STUB_BARE_DATA: '1' });
  try {
    const t = turnOn(stub.baseUrl, 0, 0);
    await runAgent(t.deps, t.agent, t.conversationId);

    assert.match(reportedAfterOneCall(t), /calls=run_command results=1/);
    assert.deepEqual(t.messages().find((m) => m.toolCalls !== undefined)?.toolCalls, [
      { id: 'cmd-1', name: 'run_command', arguments: RUN_TRUE },
    ]);
  } finally {
    stub.stop();
  }
});

test('no-index mode: two streamed calls without an index stay two calls, each with its own arguments', python, async () => {
  const stub = await startStub({ STUB_SCRIPT: 'busy', STUB_NO_INDEX: '1' });
  try {
    const t = turnOn(stub.baseUrl, 0, 0);
    await runAgent(t.deps, t.agent, t.conversationId);

    assert.match(reportedAfterOneCall(t), /calls=run_command,run_command results=2/);
    assert.deepEqual(t.messages().find((m) => m.toolCalls !== undefined)?.toolCalls, [
      { id: 'cmd-1', name: 'run_command', arguments: RUN_TRUE },
      { id: 'cmd-1-twin', name: 'run_command', arguments: RUN_TRUE },
    ]);
  } finally {
    stub.stop();
  }
});

test('deepseek mode: reasoning_content goes back on every earlier reply, the last turn\'s answer included', python, async () => {
  const stub = await startStub({ STUB_SCRIPT: 'busy', STUB_DEEPSEEK: '1' });
  try {
    const t = turnOn(stub.baseUrl, 0, 0);
    await runAgent(t.deps, t.agent, t.conversationId);
    reportedAfterOneCall(t);
    const answer = t.messages().at(-1);
    assert.equal(answer?.echo?.reasoningContent, 'stub reasoning for alpha, step 2', 'stored with the reply');

    appendMessage(t.db, t.conversationId, { role: 'user', content: 'one more thing' });
    await runAgent(t.deps, t.agent, t.conversationId);

    assert.deepEqual(t.errors, [], 'the second turn replayed the first turn\'s reasoning, or DeepSeek refuses it');
    assert.match(String(t.messages().at(-1)?.content), new RegExp(`nonce=${NONCE}`));
    assert.notEqual(t.messages().at(-1)?.id, answer?.id);
  } finally {
    stub.stop();
  }
});

test('gemini signature mode: the thought signature on a call goes back on the replayed call', python, async () => {
  const stub = await startStub({ STUB_SCRIPT: 'busy', STUB_SIGNATURES: 'gemini' });
  try {
    const t = turnOn(stub.baseUrl, 0, 0);
    await runAgent(t.deps, t.agent, t.conversationId);

    reportedAfterOneCall(t);
    const asked = t.messages().find((m) => m.toolCalls !== undefined);
    assert.deepEqual(asked?.echo?.callExtras, { 'cmd-1': { google: { thought_signature: 'c2ln-alpha-1' } } });
    assert.deepEqual(asked?.toolCalls, [{ id: 'cmd-1', name: 'run_command', arguments: RUN_TRUE }], 'and never shown to clients as part of the call');
    const served = pageMessages(t.db, t.conversationId, { limit: 50 });
    assert.ok(served.every((m) => !('echo' in m)), 'nor at all: the page clients read leaves the column out');
  } finally {
    stub.stop();
  }
});

test('openrouter signature mode: reasoning_details streamed in fragments go back whole and unchanged', python, async () => {
  const stub = await startStub({ STUB_SCRIPT: 'busy', STUB_SIGNATURES: 'openrouter' });
  try {
    const t = turnOn(stub.baseUrl, 0, 0);
    await runAgent(t.deps, t.agent, t.conversationId);

    reportedAfterOneCall(t);
    const details = t.messages().find((m) => m.toolCalls !== undefined)?.echo?.reasoningDetails;
    assert.equal((details?.[0] as { text?: string } | undefined)?.text, 'stub thinks about step 1');
    assert.equal(details?.length, 2);
  } finally {
    stub.stop();
  }
});

test('alternating-roles mode: consecutive user messages, a screenshot among them, reach a strict template as one', python, async () => {
  const stub = await startStub({ STUB_SCRIPT: 'busy', STUB_ALTERNATE: '1' });
  try {
    const t = turnOn(stub.baseUrl, 0, 0);
    const shot = { id: 'shot-0', name: 'computer', arguments: '{"action":"screenshot"}' };
    appendMessage(t.db, t.conversationId, { role: 'assistant', content: '', sender: 'alpha', toolCalls: [shot] });
    appendMessage(t.db, t.conversationId, {
      role: 'tool',
      content: 'screenshot taken',
      sender: 'alpha',
      toolCallId: shot.id,
      image: { mediaType: 'image/png', base64: PNG },
    });
    appendMessage(t.db, t.conversationId, { role: 'user', content: 'what do you see?' });
    await runAgent(t.deps, t.agent, t.conversationId);

    const reply = reportedAfterOneCall(t);
    assert.match(reply, /heard=the_owner /, 'every merged message still names its writer');
    assert.match(reply, /images=1 png=yes/, 'and the screenshot survives the merge');
    assert.match(reply, /calls=computer,run_command results=2/, 'tool results are never merged');
  } finally {
    stub.stop();
  }
});

test('strict-schema mode: a Gemini model gets tool parameters its endpoint accepts, and any other model does not', python, async () => {
  const stub = await startStub({ STUB_SCRIPT: 'busy', STUB_STRICT_SCHEMA: '1' });
  try {
    const gemini = turnOn(stub.baseUrl, 0, 0, 'gemini-stub');
    await runAgent(gemini.deps, gemini.agent, gemini.conversationId);
    assert.match(reportedAfterOneCall(gemini), /calls=run_command results=1/);

    const other = turnOn(stub.baseUrl, 0, 0);
    await runAgent(other.deps, other.agent, other.conversationId);
    assert.match(String(other.errors[0]), /HTTP 400.*Invalid JSON payload/, 'unsanitised, the same tools are refused');
  } finally {
    stub.stop();
  }
});
