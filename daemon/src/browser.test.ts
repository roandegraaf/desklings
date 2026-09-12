import assert from 'node:assert/strict';
import { test } from 'node:test';
import { browse, browserToolDef, debugPort, parseBrowserAction } from './browser.ts';
import type { Connect, Session } from './browser.ts';
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
  const session: Session = {
    send(method, params = {}) {
      sent.push({ method, params });
      if (method === 'Page.navigate') fireLoad?.();
      if (method in answers) return Promise.resolve(answers[method]);
      return Promise.resolve({});
    },
    once(event) {
      assert.equal(event, 'Page.loadEventFired');
      return new Promise((resolve) => {
        fireLoad = () => resolve({});
      });
    },
    close() {
      closed = true;
    },
  };
  return { session, sent, closed: () => closed };
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
  ]);
});

test('navigate waits for load and returns title, url and the rendered text', async () => {
  const { session, sent, closed } = fakeSession({ 'Runtime.evaluate': PAGE });
  const { exec, calls } = fakeExec();
  const connect: Connect = () => Promise.resolve(session);
  const result = await browse(exec, TARGET, connect, { action: 'navigate', url: 'https://example.com/a' }, LIMIT);
  assert.deepEqual(result, { text: 'Example\nhttps://example.com/a\n\nHello\nworld', url: 'https://example.com/a' });
  assert.deepEqual(
    sent.map((call) => call.method),
    ['Page.enable', 'Page.navigate', 'Runtime.evaluate'],
  );
  assert.equal(sent[1]?.params['url'], 'https://example.com/a');
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
