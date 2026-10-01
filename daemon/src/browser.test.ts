import assert from 'node:assert/strict';
import { test } from 'node:test';
import { BROWSER_HUNG, browse, browserToolDef, debugPort, parseBrowserAction } from './browser.ts';
import type { BrowserTimings, Connect, Session } from './browser.ts';
import type { AgentTarget } from './agents.ts';
import type { Exec, ExecOptions } from './exec.ts';

const TARGET: AgentTarget = { user: 'agent-alpha', home: '/home/agent-alpha', display: 3 };
const LIMIT = 200;

type Sent = { method: string; params: Record<string, unknown> };

/** A page that answers every command from a table and fires load as soon as it is navigated. */
function fakeSession(answers: Record<string, unknown>) {
  const sent: Sent[] = [];
  let closed = false;
  let fireLoad: (() => void) | undefined;
  const listeners = new Map<string, (params: unknown) => void>();
  const session: Session = {
    send(method, params = {}) {
      sent.push({ method, params });
      if (method === 'Page.navigate') fireLoad?.();
      if (method in answers) return Promise.resolve(answers[method]);
      return Promise.resolve({});
    },
    once(event) {
      if (event !== 'Page.loadEventFired') return new Promise((resolve) => listeners.set(event, resolve));
      return new Promise((resolve) => {
        fireLoad = () => resolve({});
      });
    },
    close() {
      closed = true;
    },
  };
  return { session, sent, closed: () => closed, fire: (event: string, params: unknown) => listeners.get(event)?.(params) };
}

function fakeExec() {
  const calls: { file: string; args: readonly string[]; options: ExecOptions }[] = [];
  const exec: Exec = (file, args, options = {}) => {
    calls.push({ file, args, options });
    return Promise.resolve({ code: 0, stdout: Buffer.alloc(0), stderr: '', truncated: false });
  };
  return { exec, calls };
}

const PAGE = { result: { value: { url: 'https://example.com/a', title: 'Example', text: '  Hello\nworld  ' } } };

test('the port is derived from the display the same way /etc/chromium.d/schermes does', () => {
  assert.equal(debugPort(1), 9223);
  assert.equal(debugPort(3), 9225);
});

test('an action is validated before anything reaches the browser', () => {
  for (const body of [{}, { action: 'click' }, { action: 'navigate' }, { action: 'navigate', url: 'ftp://x' }]) {
    assert.ok('error' in parseBrowserAction(body), JSON.stringify(body));
  }
  assert.ok('error' in parseBrowserAction({ action: 'navigate', url: 'file:///etc/passwd' }));
  assert.ok('error' in parseBrowserAction({ action: 'evaluate', expression: ' ' }));
  assert.deepEqual(parseBrowserAction({ action: 'navigate', url: ' https://example.com ' }), {
    action: 'navigate',
    url: 'https://example.com/',
  });
  assert.deepEqual(parseBrowserAction({ action: 'read' }), { action: 'read' });
  assert.deepEqual(parseBrowserAction({ action: 'evaluate', expression: '1+1' }), {
    action: 'evaluate',
    expression: '1+1',
  });
  const def = browserToolDef();
  assert.equal(def.name, 'browser');
  assert.deepEqual((def.parameters['properties'] as Record<string, { enum?: string[] }>)['action']?.enum, [
    'navigate',
    'read',
    'evaluate',
    'dialog',
  ]);
  assert.ok('error' in parseBrowserAction({ action: 'dialog' }));
  assert.deepEqual(parseBrowserAction({ action: 'dialog', accept: false }), { action: 'dialog', accept: false });
});

test('navigate waits for load and returns title, url and the rendered text', async () => {
  const { session, sent, closed } = fakeSession({ 'Runtime.evaluate': PAGE });
  const { exec, calls } = fakeExec();
  const connect: Connect = () => Promise.resolve(session);
  const result = await browse(exec, TARGET, connect, { action: 'navigate', url: 'https://example.com/a' }, LIMIT);
  assert.deepEqual(result, { text: 'Example\nhttps://example.com/a\n\nHello\nworld', url: 'https://example.com/a' });
  assert.deepEqual(
    sent.map((call) => call.method),
    ['Runtime.evaluate', 'Page.enable', 'Page.navigate', 'Runtime.evaluate'],
    'a probe first, then the action',
  );
  assert.equal(sent[2]?.params['url'], 'https://example.com/a');
  assert.equal(calls.length, 0, 'a running browser is not started again');
  assert.ok(closed(), 'the session is closed after the action');
});

test('a navigation the browser refuses is an error the agent can read', async () => {
  const { session } = fakeSession({ 'Page.navigate': { errorText: 'net::ERR_NAME_NOT_RESOLVED' } });
  const result = await browse(
    fakeExec().exec,
    TARGET,
    () => Promise.resolve(session),
    { action: 'navigate', url: 'https://nowhere.invalid/' },
    LIMIT,
  );
  assert.deepEqual(result, { error: 'https://nowhere.invalid/: net::ERR_NAME_NOT_RESOLVED' });
});

test('read clips the text to the observation budget', async () => {
  const long = { result: { value: { url: 'https://example.com/', title: '', text: 'x'.repeat(LIMIT + 50) } } };
  const { session } = fakeSession({ 'Runtime.evaluate': long });
  const result = await browse(fakeExec().exec, TARGET, () => Promise.resolve(session), { action: 'read' }, LIMIT);
  assert.ok('text' in result);
  assert.ok(result.text.startsWith('https://example.com/\n\n'));
  assert.ok(result.text.endsWith('\n[truncated]'));
  assert.equal(result.text.length, 'https://example.com/\n\n'.length + LIMIT + '\n[truncated]'.length);
});

test('evaluate returns the value, or the exception the page threw', async () => {
  const connectWith = (answer: unknown): Connect => () => Promise.resolve(fakeSession({ 'Runtime.evaluate': answer }).session);
  const exec = fakeExec().exec;
  const ask = (answer: unknown) => browse(exec, TARGET, connectWith(answer), { action: 'evaluate', expression: 'x' }, LIMIT);

  assert.deepEqual(await ask({ result: { type: 'string', value: 'plain' } }), { text: 'plain', url: '' });
  assert.deepEqual(await ask({ result: { type: 'object', value: { a: [1, 2] } } }), { text: '{"a":[1,2]}', url: '' });
  assert.deepEqual(await ask({ result: { type: 'undefined' } }), { text: 'undefined', url: '' });
  assert.deepEqual(
    await ask({ result: { type: 'object' }, exceptionDetails: { text: 'Uncaught', exception: { description: 'ReferenceError: x is not defined' } } }),
    { error: 'ReferenceError: x is not defined' },
  );
});

test('a browser that is not running is started as the agent and then reached', async () => {
  const { session } = fakeSession({ 'Runtime.evaluate': PAGE });
  const { exec, calls } = fakeExec();
  let attempts = 0;
  const connect: Connect = (port) => {
    assert.equal(port, debugPort(TARGET.display));
    attempts += 1;
    return Promise.resolve(attempts < 3 ? undefined : session);
  };
  const result = await browse(exec, TARGET, connect, { action: 'read' }, LIMIT);
  assert.ok('text' in result);
  assert.equal(calls.length, 1);
  assert.equal(calls[0]?.file, 'sudo');
  const argv = calls[0]?.args ?? [];
  assert.ok(argv.includes('agent-alpha'));
  assert.ok(argv.includes('DISPLAY=:3'));
  assert.ok(argv.includes('setsid'), 'detached, so the browser outlives the request');
  assert.match(argv.at(-1) ?? '', /chromium --user-data-dir="\$HOME\/\.chromium-profile"/);
});

const QUICK: BrowserTimings = { probeMs: 20, startMs: 100, pollMs: 5 };

/** A page that takes every command and never answers. */
function hungSession() {
  let closed = 0;
  const session: Session = {
    send: () => new Promise(() => undefined),
    once: () => new Promise(() => undefined),
    close() {
      closed += 1;
    },
  };
  return { session, closed: () => closed };
}

const isStop = (args: readonly string[]) => /pkill -KILL/.test(args.at(-1) ?? '');
const isStart = (args: readonly string[]) => /exec chromium/.test(args.at(-1) ?? '');

test('a hung browser is killed and started once, and the action is done again', async () => {
  const hung = hungSession();
  const { session, sent } = fakeSession({ 'Runtime.evaluate': PAGE });
  const { exec, calls } = fakeExec();
  let stopped = false;
  const connect: Connect = () => Promise.resolve(stopped ? session : hung.session);
  const watched: Exec = (file, args, options) => {
    if (isStop(args)) stopped = true;
    return exec(file, args, options);
  };
  const result = await browse(watched, TARGET, connect, { action: 'read' }, LIMIT, QUICK);
  assert.deepEqual(result, { text: 'Example\nhttps://example.com/a\n\nHello\nworld', url: '', restarted: true });
  assert.deepEqual(
    calls.map((call) => (isStop(call.args) ? 'stop' : isStart(call.args) ? 'start' : '?')),
    ['stop', 'start'],
  );
  assert.ok(calls[0]?.args.includes('agent-alpha'), 'killed as the agent, so only its own Chromium');
  assert.equal(hung.closed(), 1, 'the stalled session is let go');
  assert.equal(sent.filter((call) => call.method === 'Runtime.evaluate').length, 2, 'probe, then the read');
});

test('a browser that still hangs after its restart is not restarted again but reported as hung', async () => {
  const { exec, calls } = fakeExec();
  const connect: Connect = () => Promise.resolve(hungSession().session);
  const result = await browse(exec, TARGET, connect, { action: 'navigate', url: 'https://example.com/' }, LIMIT, QUICK);
  assert.ok('error' in result);
  assert.equal(result.hung, true);
  assert.ok(result.error.startsWith(BROWSER_HUNG), result.error);
  assert.equal(calls.filter((call) => isStop(call.args)).length, 1, 'one automatic restart, no more');
});

test('a browser that answers but refuses is not treated as hung', async () => {
  const { session } = fakeSession({ 'Page.navigate': { errorText: 'net::ERR_NAME_NOT_RESOLVED' } });
  const { exec, calls } = fakeExec();
  const result = await browse(exec, TARGET, () => Promise.resolve(session), { action: 'navigate', url: 'https://x.invalid/' }, LIMIT, QUICK);
  assert.ok('error' in result);
  assert.equal(result.hung, undefined);
  assert.equal(calls.length, 0);
});

test('a dialog the page opens is reported, keeps the browser alive, and is answered on the session that saw it', async () => {
  const sent: Sent[] = [];
  const listeners = new Map<string, (params: unknown) => void>();
  let closed = 0;
  const session: Session = {
    send(method, params = {}) {
      sent.push({ method, params });
      if (method === 'Runtime.evaluate' && params['expression'] === 'pay()') {
        listeners.get('Page.javascriptDialogOpening')?.({ type: 'confirm', message: 'Pay 42 euro?' });
        return new Promise(() => undefined);
      }
      return Promise.resolve({ result: { value: 1 } });
    },
    once: (event) => new Promise((resolve) => listeners.set(event, resolve)),
    close() {
      closed += 1;
    },
  };
  const { exec, calls } = fakeExec();
  const connect: Connect = () => Promise.resolve(session);

  const clicked = await browse(exec, TARGET, connect, { action: 'evaluate', expression: 'pay()' }, LIMIT);
  assert.ok('error' in clicked && clicked.hung !== true);
  assert.match(clicked.error, /confirm dialog: "Pay 42 euro\?"/);
  assert.equal(closed, 0, 'the session that saw it stays open');

  const sentBefore = sent.length;
  const read = await browse(exec, TARGET, connect, { action: 'read' }, LIMIT);
  assert.ok('error' in read && /Pay 42 euro/.test(read.error));
  assert.equal(sent.length, sentBefore, 'no probe, so nothing reads it as hung');

  assert.deepEqual(await browse(exec, TARGET, connect, { action: 'dialog', accept: false }, LIMIT), { text: 'Dismissed the dialog.', url: '' });
  assert.deepEqual(sent.at(-1), { method: 'Page.handleJavaScriptDialog', params: { accept: false } });
  assert.equal(closed, 1);
  assert.equal(calls.length, 0, 'never killed or restarted');
  assert.ok('error' in (await browse(exec, TARGET, connect, { action: 'dialog', accept: true }, LIMIT)));

  await browse(exec, TARGET, connect, { action: 'evaluate', expression: 'pay()' }, LIMIT);
  listeners.get('socket closed')?.(undefined);
  await new Promise((done) => setImmediate(done));
  assert.deepEqual(await browse(exec, TARGET, connect, { action: 'read' }, LIMIT), { text: '\n\nThe page has no readable text.', url: '' }, 'a dialog whose browser died is forgotten');
});
