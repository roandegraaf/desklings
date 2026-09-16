import { resolve } from 'node:path';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import assert from 'node:assert/strict';
import test from 'node:test';
import { createApp } from './app.ts';
import { openDb } from './db.ts';
import { hashPassword, verifyPassword } from './auth.ts';
import { loadMasterKey } from './secrets.ts';
import { mcpServers, readApiKey, searchConfig } from './settings.ts';
import { MAX_MCP_SERVERS } from './mcp.ts';
import type { Exec } from './exec.ts';
import type { ChatReply, Provider } from './provider.ts';
import { STOPPED } from './loop.ts';
import { KICKOFF, MAX_PROFILE_CHARS } from './interview.ts';
import { eq } from 'drizzle-orm';
import { settings as settingsTable } from './schema.ts';
import { generateKeyPairSync } from 'node:crypto';
import { HOME_READ_MEMORY, HOME_WRITE_MEMORY } from './home.ts';
import { findAgent, findAgentById, insertWorker } from './agents.ts';
import {
  appendMessage,
  appendSummary,
  conversationFor,
  conversationWith,
  findConversation,
  latestSummary,
  listEvents,
  listMessages,
  participantAgents,
} from './conversations.ts';
import { describeApproval, insertApproval, listApprovals } from './approvals.ts';
import { listSchedules } from './schedules.ts';
import type { Agent, Approval } from '@schermes/shared';

const MIGRATIONS = resolve(import.meta.dirname, '../migrations');
const PASSWORD = 'correct-horse-battery';
/** An agent created with a profile is not interviewed, so a test's scripted replies are its. */
const PROFILED = 'A test agent.';

function fixture(caps: { maxLoops?: number } = {}) {
  const db = openDb(':memory:', MIGRATIONS);
  const masterKey = loadMasterKey(join(mkdtempSync(join(tmpdir(), 'schermes-api-')), 'master.key'));
  const spawned: string[] = [];
  const stopped: string[] = [];
  const desktop = {
    ensure(name: string) {
      if (name === 'unspawnable') return Promise.reject(new Error('Xvnc did not come up'));
      spawned.push(name);
      return Promise.resolve('started' as const);
    },
    stop(name: string) {
      stopped.push(name);
      return Promise.resolve();
    },
  };

  const ran: string[][] = [];
  const exec: Exec = (file, args) => {
    ran.push([file, ...args]);
    const user = String(args[1]);
    const stdout =
      file === 'getent'
        ? Buffer.from(`${user}:x:1001:1001::/home/${user}:/bin/bash\n`)
        : Buffer.from('tool output');
    return Promise.resolve({ code: 0, stdout, stderr: '', truncated: false });
  };

  const replies: Partial<ChatReply>[] = [];
  let held: Promise<void> | undefined;
  const makeProvider = (): Provider => async (_messages, _tools, _onDelta, signal) => {
    // A held turn honours a stop the way the real provider does: the call ends, not the hold.
    if (held !== undefined) {
      if (signal?.aborted) throw signal.reason;
      await Promise.race([
        held,
        new Promise((_, reject) => signal?.addEventListener('abort', () => reject(signal.reason), { once: true })),
      ]);
    }
    const reply = replies.shift();
    if (reply === undefined) throw new Error('the script ran out of replies');
    return { text: reply.text ?? '', toolCalls: reply.toolCalls ?? [] };
  };

  return {
    db,
    masterKey,
    spawned,
    stopped,
    ran,
    replies,
    app: createApp({ db, masterKey, desktop, exec, makeProvider, ...caps }).app,
    /** Parks every turn started from now on, so a test can hold a loop open on purpose. */
    hold() {
      let release = () => {};
      held = new Promise<void>((done) => {
        release = () => {
          held = undefined;
          done();
        };
      });
      return release;
    },
    // The turn outlives the request that started it, so tests wait for the state it lands in.
    async settled(name: string) {
      for (let attempt = 0; attempt < 200; attempt += 1) {
        // Sleeping first also lets the drain that frees the agent run, so a test can send a
        // second message straight after without racing the one that just finished.
        await new Promise((done) => setTimeout(done, 5));
        const state = findAgent(db, name)?.state;
        if (state === 'waiting_for_user' || state === 'waiting_for_agent' || state === 'failed') {
          return state;
        }
      }
      throw new Error(`agent ${name} never settled`);
    },
  };
}

type App = ReturnType<typeof createApp>['app'];

function post(app: App, path: string, body: unknown, cookie?: string) {
  return app.request(path, {
    method: 'POST',
    body: JSON.stringify(body),
    headers: { 'content-type': 'application/json', ...(cookie ? { cookie } : {}) },
  });
}

async function json(res: Response): Promise<Record<string, unknown>> {
  return (await res.json()) as Record<string, unknown>;
}

function sessionCookie(res: Response): string {
  const header = res.headers.get('set-cookie');
  assert.ok(header, 'expected a session cookie');
  return header.split(';')[0] as string;
}

test('health is public and reports that setup is required until an owner exists', async () => {
  const { app } = fixture();
  assert.deepEqual(await json(await app.request('/api/health')), {
    status: 'ok',
    setupRequired: true,
  });
  await post(app, '/api/auth/setup', { password: PASSWORD });
  assert.equal((await json(await app.request('/api/health')))['setupRequired'], false);
});

test('every non-public route is denied without a session', async () => {
  const { app } = fixture();
  await post(app, '/api/auth/setup', { password: PASSWORD });
  for (const path of ['/api/settings', '/api/auth/logout', '/api/unknown']) {
    assert.equal((await app.request(path)).status, 401, `${path} should require a session`);
  }
});

test('setup refuses to run twice, so it cannot be used as a password reset', async () => {
  const { app } = fixture();
  assert.equal((await post(app, '/api/auth/setup', { password: PASSWORD })).status, 201);
  const second = await post(app, '/api/auth/setup', { password: 'attacker-chosen-pw' });
  assert.equal(second.status, 409);
  assert.equal((await post(app, '/api/auth/login', { password: 'attacker-chosen-pw' })).status, 401);
  assert.equal((await post(app, '/api/auth/login', { password: PASSWORD })).status, 200);
});

test('setup rejects a short password', async () => {
  const { app } = fixture();
  assert.equal((await post(app, '/api/auth/setup', { password: 'short' })).status, 400);
  assert.equal((await json(await app.request('/api/health')))['setupRequired'], true);
});

test('logging out invalidates the session it was issued with', async () => {
  const { app } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));
  assert.equal((await app.request('/api/settings', { headers: { cookie } })).status, 200);
  await post(app, '/api/auth/logout', {}, cookie);
  assert.equal((await app.request('/api/settings', { headers: { cookie } })).status, 401);
});

test('settings round-trip and the api key is stored encrypted, never returned', async () => {
  const { app, db, masterKey } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));
  const apiKey = 'sk-live-shouldnevershowup';

  const written = await app.request('/api/settings', {
    method: 'PUT',
    body: JSON.stringify({ baseUrl: 'https://api.example.com/v1', model: 'gpt-4o-mini', apiKey }),
    headers: { 'content-type': 'application/json', cookie },
  });
  assert.equal(written.status, 200);

  const read = await app.request('/api/settings', { headers: { cookie } });
  const body = await read.text();
  assert.doesNotMatch(body, /shouldnevershowup/);
  assert.deepEqual(JSON.parse(body), {
    baseUrl: 'https://api.example.com/v1',
    model: 'gpt-4o-mini',
    apiKeySet: true,
    extraBody: '',
    searchUrl: '',
    searchKeySet: false,
    push: { keyId: '', teamId: '', bundleId: '', keySet: false, sandbox: false },
  });

  const stored = db.$client.prepare("select value from settings where key = 'provider.apiKey'").get();
  assert.doesNotMatch(JSON.stringify(stored), /shouldnevershowup/);
  assert.equal(readApiKey(db, masterKey), apiKey);
});

test('the search key is stored encrypted and never returned, and an empty url means the default', async () => {
  const { app, db, masterKey } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));
  const searchKey = 'brave-shouldnevershowup';

  const written = await app.request('/api/settings', {
    method: 'PUT',
    body: JSON.stringify({ searchKey }),
    headers: { 'content-type': 'application/json', cookie },
  });
  assert.equal(written.status, 200);
  assert.doesNotMatch(await written.text(), /shouldnevershowup/);

  const read = await app.request('/api/settings', { headers: { cookie } });
  const body = JSON.parse(await read.text()) as Record<string, unknown>;
  assert.equal(body['searchKeySet'], true);
  assert.equal(body['searchUrl'], '');

  const stored = db.$client.prepare("select value from settings where key = 'web.searchKey'").get();
  assert.doesNotMatch(JSON.stringify(stored), /shouldnevershowup/);
  const config = searchConfig(db, masterKey);
  assert.equal(config?.apiKey, searchKey);
  assert.match(config?.url ?? '', /^https:\/\/api\.search\.brave\.com\//);
});

test('settings rejects a search url that is not http(s)', async () => {
  const { app } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));
  const res = await app.request('/api/settings', {
    method: 'PUT',
    body: JSON.stringify({ searchUrl: 'file:///etc/passwd' }),
    headers: { 'content-type': 'application/json', cookie },
  });
  assert.equal(res.status, 400);
});

test('settings rejects a base url that is not http(s)', async () => {
  const { app } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));
  const res = await app.request('/api/settings', {
    method: 'PUT',
    body: JSON.stringify({ baseUrl: 'file:///etc/passwd' }),
    headers: { 'content-type': 'application/json', cookie },
  });
  assert.equal(res.status, 400);
});

test('a password verifies only against its own hash', () => {
  const stored = hashPassword(PASSWORD);
  assert.notEqual(stored, hashPassword(PASSWORD));
  assert.ok(verifyPassword(PASSWORD, stored));
  assert.ok(!verifyPassword('wrong', stored));
  assert.ok(!verifyPassword(PASSWORD, 'garbage'));
  assert.ok(!verifyPassword(PASSWORD, `${stored}$extra`));
});

test('creating an agent allocates a display and gives it a desktop', async () => {
  const { app, spawned } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));

  const created = await post(app, '/api/agents', { name: 'alpha' }, cookie);
  assert.equal(created.status, 201);
  const alpha = await json(created);
  assert.equal(alpha['name'], 'alpha');
  assert.equal(alpha['display'], 1);
  assert.deepEqual(spawned, ['alpha']);

  assert.equal((await post(app, '/api/agents', { name: 'bravo' }, cookie)).status, 201);
  const listed = (await (await app.request('/api/agents', { headers: { cookie } })).json()) as {
    name: string;
    display: number;
  }[];
  assert.deepEqual(listed.map((agent) => [agent.name, agent.display]), [
    ['alpha', 1],
    ['bravo', 2],
  ]);

  const fetched = await app.request('/api/agents/alpha', { headers: { cookie } });
  assert.deepEqual(await json(fetched), alpha);
  assert.equal((await app.request('/api/agents/nobody', { headers: { cookie } })).status, 404);
});

test('agent creation refuses a name that could reach a shell, and a duplicate', async () => {
  const { app, spawned } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));

  for (const name of ['Alpha', 'has space', 'rm -rf /', '../escape', '$(id)', '']) {
    const res = await post(app, '/api/agents', { name }, cookie);
    assert.equal(res.status, 400, `${JSON.stringify(name)} should be rejected`);
  }
  assert.deepEqual(spawned, [], 'no name reached the desktop layer');

  assert.equal((await post(app, '/api/agents', { name: 'alpha' }, cookie)).status, 201);
  assert.equal((await post(app, '/api/agents', { name: 'alpha' }, cookie)).status, 409);
});

test('an agent carries the free-text name the owner gave it, and can be renamed', async () => {
  const { app, spawned } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));

  const created = await post(app, '/api/agents', { name: 'alpha', label: 'Bob the Builder' }, cookie);
  assert.equal(created.status, 201);
  const alpha = await json(created);
  assert.equal(alpha['label'], 'Bob the Builder');
  assert.equal(alpha['name'], 'alpha', 'the label does not become the identity');
  assert.deepEqual(spawned, ['alpha'], 'the desktop layer is handed the name, never the label');

  assert.equal((await json(await app.request('/api/agents/alpha', { headers: { cookie } })))['label'], 'Bob the Builder');

  const renamed = await patch(app, '/api/agents/alpha', { label: '  Bob 2.0 🛠  ' }, cookie);
  assert.equal(renamed.status, 200);
  const after = await json(renamed);
  assert.equal(after['label'], 'Bob 2.0 🛠', 'trimmed, and the emoji survives');
  assert.equal(after['name'], 'alpha');

  for (const label of ['', '   ', 'two\nlines', 'a'.repeat(65)]) {
    const res = await patch(app, '/api/agents/alpha', { label }, cookie);
    assert.equal(res.status, 400, `${JSON.stringify(label)} should be rejected`);
  }
  assert.equal((await post(app, '/api/agents', { name: 'bravo', label: '' }, cookie)).status, 400);
  assert.equal((await patch(app, '/api/agents/nobody', { label: 'Ghost' }, cookie)).status, 404);

  // An agent created without one has no label at all, so a reader falls back to the name.
  const plain = await json(await post(app, '/api/agents', { name: 'charlie' }, cookie));
  assert.ok(!('label' in plain), 'no label rather than an empty one');
});

test('an agent whose desktop will not start is not left half-created', async () => {
  const { app } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));

  assert.equal((await post(app, '/api/agents', { name: 'unspawnable' }, cookie)).status, 500);
  assert.deepEqual(await json(await app.request('/api/agents', { headers: { cookie } })), []);

  // The freed display goes to the next agent instead of being stranded.
  const next = await post(app, '/api/agents', { name: 'alpha' }, cookie);
  assert.equal((await json(next))['display'], 1);
});

test('the agent routes are behind the session guard', async () => {
  const { app } = fixture();
  await post(app, '/api/auth/setup', { password: PASSWORD });
  assert.equal((await app.request('/api/agents')).status, 401);
  assert.equal((await post(app, '/api/agents', { name: 'alpha' })).status, 401);
  assert.equal((await post(app, '/api/agents/alpha/computer', { action: 'screenshot' })).status, 401);
  assert.equal((await post(app, '/api/agents/alpha/command', { command: 'id' })).status, 401);
  assert.equal((await post(app, '/api/agents/alpha/control', {})).status, 401);
  assert.equal((await app.request('/api/agents/alpha/control')).status, 401);
});

test('taking control stands every other input down until it is returned', async () => {
  const { app, db, ran } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));
  await post(app, '/api/agents', { name: 'alpha' }, cookie);

  const idle = await app.request('/api/agents/alpha/control', { headers: { cookie } });
  assert.deepEqual(await json(idle), { held: false });

  assert.deepEqual(await json(await post(app, '/api/agents/alpha/control', {}, cookie)), {
    held: true,
  });

  const refused = await post(app, '/api/agents/alpha/computer', { action: 'screenshot' }, cookie);
  assert.equal(refused.status, 409);
  assert.match(String((await json(refused))['error']), /taken control of this desktop/);
  assert.deepEqual(ran, [], 'the refusal came before anything reached a shell');

  // run_command is not input to the display, so a human at the screen does not stop the work.
  assert.equal(
    (await post(app, '/api/agents/alpha/command', { command: 'id' }, cookie)).status,
    200,
  );

  const alpha = findAgent(db, 'alpha') as Agent;
  const held = () => listEvents(db, alpha.id).filter((e) => e.type === 'control');
  assert.deepEqual(held().map((e) => e.data['held']), [true], 'the takeover is in the history');

  const returned = await app.request('/api/agents/alpha/control', {
    method: 'DELETE',
    headers: { cookie },
  });
  assert.deepEqual(await json(returned), { held: false });
  assert.deepEqual(held().map((e) => e.data['held']), [true, false]);
  assert.equal(
    (await post(app, '/api/agents/alpha/computer', { action: 'screenshot' }, cookie)).status,
    200,
  );
});

test('there is no control to take of an agent that has no desktop', async () => {
  const { app } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));
  for (const method of ['GET', 'POST', 'DELETE']) {
    const res = await app.request('/api/agents/nobody/control', { method, headers: { cookie } });
    assert.equal(res.status, 404, `${method} on an unknown agent`);
  }
});

test('the tool routes run as the agent, 404 an unknown one and 400 a malformed request', async () => {
  const { app, ran } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));
  await post(app, '/api/agents', { name: 'alpha' }, cookie);

  const shot = await post(app, '/api/agents/alpha/computer', { action: 'screenshot' }, cookie);
  assert.equal(shot.status, 200);
  assert.deepEqual(await json(shot), {
    action: 'screenshot',
    image: { mediaType: 'image/png', base64: Buffer.from('tool output').toString('base64') },
  });

  const command = await post(app, '/api/agents/alpha/command', { command: 'id' }, cookie);
  assert.equal(command.status, 200);
  assert.deepEqual(await json(command), {
    exitCode: 0,
    stdout: 'tool output',
    stderr: '',
    timedOut: false,
    background: false,
  });

  const sudoed = ran.filter(([file]) => file === 'sudo');
  assert.equal(sudoed.length, 2);
  for (const argv of sudoed) {
    assert.deepEqual(argv.slice(0, 4), ['sudo', '-n', '-u', 'agent-alpha']);
    assert.ok(argv.includes('DISPLAY=:1'), 'the agent display is passed through');
  }

  for (const path of ['/api/agents/nobody/computer', '/api/agents/nobody/command']) {
    assert.equal((await post(app, path, { action: 'screenshot', command: 'id' }, cookie)).status, 404);
  }

  assert.equal(
    (await post(app, '/api/agents/alpha/computer', { action: 'explode' }, cookie)).status,
    400,
  );
  assert.equal(
    (await post(app, '/api/agents/alpha/computer', { action: 'move', x: 99999, y: 0 }, cookie)).status,
    400,
  );
  assert.equal((await post(app, '/api/agents/alpha/command', { command: '' }, cookie)).status, 400);
});

test('an unknown agent is refused before the daemon shells out at all', async () => {
  const { app, ran } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));
  await post(app, '/api/agents/nobody/command', { command: 'id' }, cookie);
  assert.deepEqual(ran, []);
});

async function configured(
  caps: { maxLoops?: number } = {},
): Promise<{ f: ReturnType<typeof fixture>; cookie: string }> {
  const f = fixture(caps);
  const cookie = sessionCookie(await post(f.app, '/api/auth/setup', { password: PASSWORD }));
  await f.app.request('/api/settings', {
    method: 'PUT',
    body: JSON.stringify({ baseUrl: 'https://api.example.com/v1', model: 'm', apiKey: 'sk-x' }),
    headers: { 'content-type': 'application/json', cookie },
  });
  await post(f.app, '/api/agents', { name: 'alpha', profile: PROFILED }, cookie);
  return { f, cookie };
}

async function getJson(app: App, path: string, cookie: string): Promise<unknown> {
  const res = await app.request(path, { headers: { cookie } });
  assert.equal(res.status, 200, `GET ${path}`);
  return res.json();
}

test('a new agent opens its thread by interviewing the owner, unless it was born with a profile', async () => {
  const { f, cookie } = await configured();
  f.replies.push({
    text: 'Hello.',
    toolCalls: [{ id: 'q1', name: 'ask_owner', arguments: JSON.stringify({ questions: [{ question: 'What am I for?' }] }) }],
  });

  const created = await json(await post(f.app, '/api/agents', { name: 'bravo' }, cookie));
  assert.equal(created['profile'], undefined);
  assert.equal(await f.settled('bravo'), 'waiting_for_user');
  const messages = (await getJson(f.app, '/api/agents/bravo/messages', cookie)) as { role: string; content: string }[];
  assert.equal(messages[0]?.content, KICKOFF);
  assert.deepEqual(messages.map((m) => m.role), ['user', 'assistant', 'tool']);
  assert.match(String(messages[2]?.content), /Asked the owner 1 question/);

  // alpha was created with a profile, so nobody asked it anything.
  assert.deepEqual(await getJson(f.app, '/api/agents/alpha/messages', cookie), []);
  assert.equal(((await getJson(f.app, '/api/agents/alpha', cookie)) as Agent).profile, PROFILED);

  const patch = (body: unknown) =>
    f.app.request('/api/agents/bravo', {
      method: 'PATCH',
      body: JSON.stringify(body),
      headers: { 'content-type': 'application/json', cookie },
    });
  assert.equal((await json(await patch({ profile: ' # Bravo\nDoes things. ' })))['profile'], '# Bravo\nDoes things.');
  assert.equal((await patch({ profile: 'x'.repeat(MAX_PROFILE_CHARS + 1) })).status, 400);
  assert.equal((await json(await patch({ profile: '' })))['profile'], undefined, 'blank clears it');
});

test('posting a message runs a turn whose transcript and events read back', async () => {
  const { f, cookie } = await configured();
  f.replies.push(
    { toolCalls: [{ id: 'c1', name: 'run_command', arguments: '{"command":"id"}' }] },
    { text: 'you are agent-alpha' },
  );

  const accepted = await post(f.app, '/api/agents/alpha/messages', { text: 'who am i?' }, cookie);
  assert.equal(accepted.status, 202);
  assert.equal(await f.settled('alpha'), 'waiting_for_user');

  const messages = (await (
    await f.app.request('/api/agents/alpha/messages', { headers: { cookie } })
  ).json()) as { role: string; content: string }[];
  assert.deepEqual(messages.map((m) => m.role), ['user', 'assistant', 'tool', 'assistant']);
  assert.equal(messages.at(-1)?.content, 'you are agent-alpha');

  const events = (await (
    await f.app.request('/api/agents/alpha/events', { headers: { cookie } })
  ).json()) as { type: string; data: Record<string, unknown> }[];
  assert.ok(events.some((e) => e.type === 'tool_call' && e.data['command'] === 'id'));
  assert.ok(events.some((e) => e.type === 'state' && e.data['to'] === 'waiting_for_user'));

  // The provider key is a secret; neither view of a turn may echo it.
  const dumped = JSON.stringify({ messages, events });
  assert.doesNotMatch(dumped, /sk-x/);
});

test('the conversation routes 404 an unknown agent and refuse an empty message', async () => {
  const { f, cookie } = await configured();
  for (const path of ['/api/agents/nobody/messages', '/api/agents/nobody/events']) {
    assert.equal((await f.app.request(path, { headers: { cookie } })).status, 404);
  }
  assert.equal((await post(f.app, '/api/agents/nobody/messages', { text: 'hi' }, cookie)).status, 404);
  assert.equal((await post(f.app, '/api/agents/alpha/messages', { text: '  ' }, cookie)).status, 400);
  assert.equal((await post(f.app, '/api/agents/alpha/messages', { text: 'hi' })).status, 401);
});

test('a message is refused until the provider is configured', async () => {
  const f = fixture();
  const cookie = sessionCookie(await post(f.app, '/api/auth/setup', { password: PASSWORD }));
  await post(f.app, '/api/agents', { name: 'alpha', profile: PROFILED }, cookie);

  const res = await post(f.app, '/api/agents/alpha/messages', { text: 'hi' }, cookie);
  assert.equal(res.status, 400);
  assert.match(String((await json(res))['error']), /provider base url/);
});

test('a failed turn leaves the agent able to take another message', async () => {
  const { f, cookie } = await configured();
  assert.equal((await post(f.app, '/api/agents/alpha/messages', { text: 'hi' }, cookie)).status, 202);
  assert.equal(await f.settled('alpha'), 'failed');

  f.replies.push({ text: 'second time lucky' });
  assert.equal((await post(f.app, '/api/agents/alpha/messages', { text: 'again' }, cookie)).status, 202);
  assert.equal(await f.settled('alpha'), 'waiting_for_user');
});

test('an agent lists the conversations it is in, starting with its own thread', async () => {
  const { f, cookie } = await configured();
  await post(f.app, '/api/agents', { name: 'bravo', profile: PROFILED }, cookie);
  f.replies.push({ text: 'hello' });
  await post(f.app, '/api/agents/alpha/messages', { text: 'hi' }, cookie);
  await f.settled('alpha');

  const created = await post(f.app, '/api/conversations', { participants: ['alpha', 'bravo'] }, cookie);
  assert.equal(created.status, 201);
  const group = await json(created);
  assert.deepEqual(group['participants'], ['alpha', 'bravo']);

  const listed = (await getJson(f.app, '/api/agents/alpha/conversations', cookie)) as {
    participants: string[];
  }[];
  assert.deepEqual(listed.map((c) => c.participants), [['alpha'], ['alpha', 'bravo']]);

  // Asking for the same set again is the same thread, not a second one.
  const again = await post(f.app, '/api/conversations', { participants: ['bravo', 'alpha'] }, cookie);
  assert.equal((await json(again))['id'], group['id']);
});

test('a thread reads back a page at a time and can be walked backwards', async () => {
  const { f, cookie } = await configured();
  const agent = findAgent(f.db, 'alpha');
  assert.ok(agent !== undefined);
  const thread = conversationFor(f.db, agent.id);
  for (let n = 1; n <= 12; n += 1) {
    appendMessage(f.db, thread, { role: 'user', content: `m${n}` });
  }

  type Page = { id: number; content: string }[];
  const page = async (query: string) =>
    (await getJson(f.app, `/api/agents/alpha/messages${query}`, cookie)) as Page;
  const said = (rows: Page) => rows.map((row) => row.content);
  const oldestOf = (rows: Page) => {
    const first = rows[0];
    assert.ok(first !== undefined);
    return first.id;
  };

  // No cursor is the newest page, because that is what a chat view opens on.
  const newest = await page('?limit=5');
  assert.deepEqual(said(newest), ['m8', 'm9', 'm10', 'm11', 'm12']);

  const older = await page(`?limit=5&before=${String(oldestOf(newest))}`);
  assert.deepEqual(said(older), ['m3', 'm4', 'm5', 'm6', 'm7']);

  // A page shorter than the limit is the start of the thread, which is the only end marker a
  // reader needs: nothing has to count the rest.
  const start = await page(`?limit=5&before=${String(oldestOf(older))}`);
  assert.deepEqual(said(start), ['m1', 'm2']);

  assert.deepEqual(said(await page('')), said(await page('?limit=12')));
  const viaThread = (await getJson(
    f.app,
    `/api/conversations/${String(thread)}/messages?limit=2`,
    cookie,
  )) as Page;
  assert.deepEqual(said(viaThread), ['m11', 'm12']);

  for (const query of [
    'limit=0',
    'limit=201',
    'limit=abc',
    'limit=1.5',
    'before=0',
    'before=x',
    'after=0',
    'after=x',
    'before=4&after=4',
  ]) {
    const res = await f.app.request(`/api/agents/alpha/messages?${query}`, { headers: { cookie } });
    assert.equal(res.status, 400, `?${query} should be refused`);
  }
});

test('a reader watching a thread asks for what came after the last row it has', async () => {
  const { f, cookie } = await configured();
  const agent = findAgent(f.db, 'alpha');
  assert.ok(agent !== undefined);
  const thread = conversationFor(f.db, agent.id);
  const ids = [];
  for (let n = 1; n <= 12; n += 1) {
    ids.push(appendMessage(f.db, thread, { role: 'user', content: `m${n}` }).id);
  }

  type Page = { id: number; content: string }[];
  const page = async (query: string) =>
    (await getJson(f.app, `/api/agents/alpha/messages${query}`, cookie)) as Page;

  // Ascending from the mark, not the newest rows above it: a poll that missed a burst longer
  // than its limit must resume where it stopped rather than skip the middle of the thread.
  const caught = await page(`?after=${String(ids[1] ?? 0)}&limit=3`);
  assert.deepEqual(caught.map((row) => row.content), ['m3', 'm4', 'm5']);

  // The reason polling is affordable: nothing new is an empty array, not a page of screenshots.
  assert.deepEqual(await page(`?after=${String(ids.at(-1) ?? 0)}`), []);
});

test('a preview can ask for the newest row without its screenshot bytes', async () => {
  const { f, cookie } = await configured();
  const agent = findAgent(f.db, 'alpha');
  assert.ok(agent !== undefined);
  const thread = conversationFor(f.db, agent.id);
  const image = { mediaType: 'image/png' as const, base64: 'iVBORw0KGgo=' };
  appendMessage(f.db, thread, { role: 'tool', content: 'screenshot', sender: 'alpha', toolCallId: 'c1', image });

  type Page = { image?: { mediaType: string; base64: string } }[];
  const full = (await getJson(f.app, '/api/agents/alpha/messages?limit=1', cookie)) as Page;
  assert.deepEqual(full[0]?.image, image);
  for (const path of ['/api/agents/alpha/messages', `/api/conversations/${String(thread)}/messages`]) {
    const bare = (await getJson(f.app, `${path}?limit=1&images=0`, cookie)) as Page;
    assert.deepEqual(bare[0]?.image, { mediaType: 'image/png', base64: '' });
  }
});

test('a page boundary can land inside a turn, and the reader gets the half it asked for', async () => {
  const { f, cookie } = await configured();
  const agent = findAgent(f.db, 'alpha');
  assert.ok(agent !== undefined);
  const thread = conversationFor(f.db, agent.id);
  const call = { id: 'c1', name: 'computer', arguments: '{"action":"screenshot"}' };
  appendMessage(f.db, thread, { role: 'user', content: 'look' });
  appendMessage(f.db, thread, { role: 'assistant', content: '', sender: 'alpha', toolCalls: [call] });
  appendMessage(f.db, thread, { role: 'tool', content: 'done', sender: 'alpha', toolCallId: 'c1' });

  // A page is a window on the rows, not on the turns: asking for one message lands between an
  // assistant message and the tool result answering it. Nothing here is a model request, so the
  // orphan is a rendering problem rather than the shape a strict endpoint rejects — a reader
  // that wants the rest asks for the page before it.
  const orphan = (await getJson(f.app, '/api/agents/alpha/messages?limit=1', cookie)) as {
    role: string;
    toolCallId?: string;
  }[];
  assert.deepEqual(orphan.map((m) => m.role), ['tool']);
  assert.equal(orphan[0]?.toolCallId, 'c1');

  const both = (await getJson(f.app, '/api/agents/alpha/messages?limit=2', cookie)) as {
    role: string;
  }[];
  assert.deepEqual(both.map((m) => m.role), ['assistant', 'tool']);
});

test('the conversation routes refuse an unknown agent and an unknown thread', async () => {
  const { f, cookie } = await configured();
  assert.equal((await f.app.request('/api/agents/nobody/conversations', { headers: { cookie } })).status, 404);

  for (const participants of [['alpha', 'nobody'], [], ['x y'], 'alpha']) {
    const res = await post(f.app, '/api/conversations', { participants }, cookie);
    assert.equal(res.status, 400, `${JSON.stringify(participants)} should be rejected`);
  }

  assert.equal((await f.app.request('/api/conversations/999/messages', { headers: { cookie } })).status, 404);
  assert.equal((await post(f.app, '/api/conversations/999/messages', { text: 'hi' }, cookie)).status, 404);
  assert.equal((await f.app.request('/api/agents/alpha/conversations')).status, 401);
  assert.equal((await post(f.app, '/api/conversations', { participants: ['alpha'] })).status, 401);
});

test('a group conversation gets a reply from every agent in it, each naming itself', async () => {
  const { f, cookie } = await configured();
  await post(f.app, '/api/agents', { name: 'bravo', profile: PROFILED }, cookie);
  const group = await json(await post(f.app, '/api/conversations', { participants: ['alpha', 'bravo'] }, cookie));

  f.replies.push({ text: 'alpha is here' }, { text: 'bravo is here' });
  const posted = await post(f.app, `/api/conversations/${String(group['id'])}/messages`, { text: 'who is around?' }, cookie);
  assert.equal(posted.status, 202);
  await f.settled('alpha');
  await f.settled('bravo');

  const messages = (await getJson(f.app, `/api/conversations/${String(group['id'])}/messages`, cookie)) as {
    role: string;
    sender?: string;
    content: string;
  }[];
  assert.equal(messages[0]?.sender, undefined, 'the owner has no sender');
  assert.deepEqual(
    messages.filter((m) => m.role === 'assistant').map((m) => m.sender).sort(),
    ['alpha', 'bravo'],
  );
});

test('a thread rewinds to an earlier point, and a retry asks the kept message again', async () => {
  const { f, cookie } = await configured();
  const agent = findAgent(f.db, 'alpha');
  assert.ok(agent !== undefined);
  const thread = conversationFor(f.db, agent.id);
  const first = appendMessage(f.db, thread, { role: 'user', content: 'first' });
  appendMessage(f.db, thread, {
    role: 'assistant',
    content: '',
    sender: 'alpha',
    toolCalls: [{ id: 'c1', name: 'run_command', arguments: '{}' }],
  });
  const mid = appendMessage(f.db, thread, { role: 'user', content: 'mid' });
  appendMessage(f.db, thread, { role: 'tool', content: 'ok', sender: 'alpha', toolCallId: 'c1' });
  const done = appendMessage(f.db, thread, { role: 'assistant', content: 'done', sender: 'alpha' });
  appendSummary(f.db, { conversationId: thread, sender: 'alpha', content: 's', fromMessageId: first.id, throughMessageId: done.id });

  assert.equal((await post(f.app, '/api/agents/alpha/rewind', { from: mid.id }, cookie)).status, 200);
  assert.deepEqual(
    listMessages(f.db, thread).map((m) => m.role),
    ['user', 'assistant', 'tool'],
    'the answer to a call from before the cut stays',
  );
  assert.equal(latestSummary(f.db, thread, 'alpha'), undefined);

  f.replies.push({ text: 'again' });
  assert.equal((await post(f.app, '/api/agents/alpha/rewind', { from: first.id + 1, retry: true }, cookie)).status, 200);
  await f.settled('alpha');
  const after = listMessages(f.db, thread);
  assert.deepEqual(after.map((m) => m.content), ['first', 'again']);

  const last = after.at(-1);
  assert.ok(last !== undefined);
  assert.equal((await post(f.app, '/api/agents/alpha/rewind', { from: last.id + 1, retry: true }, cookie)).status, 400);

  const release = f.hold();
  f.replies.push({ text: 'late' });
  await post(f.app, '/api/agents/alpha/messages', { text: 'busy?' }, cookie);
  assert.equal((await post(f.app, '/api/agents/alpha/rewind', { from: first.id }, cookie)).status, 409);
  release();
  await f.settled('alpha');
});

test('the owner compacts a thread on demand, everything since the last summary and never mid-turn', async () => {
  const { f, cookie } = await configured();
  const agent = findAgent(f.db, 'alpha');
  assert.ok(agent !== undefined);
  const thread = conversationFor(f.db, agent.id);
  appendMessage(f.db, thread, { role: 'user', content: 'first' });
  appendMessage(f.db, thread, {
    role: 'assistant',
    content: '',
    sender: 'alpha',
    toolCalls: [{ id: 'c1', name: 'run_command', arguments: '{}' }],
  });
  appendMessage(f.db, thread, { role: 'tool', content: 'ok', sender: 'alpha', toolCallId: 'c1' });
  const done = appendMessage(f.db, thread, { role: 'assistant', content: 'done', sender: 'alpha' });

  f.replies.push({ text: 'You were asked for first and did it.' });
  const res = await post(f.app, '/api/agents/alpha/compact', {}, cookie);
  assert.equal(res.status, 200);
  assert.deepEqual(await json(res), { compacted: { alpha: 4 } });
  const summary = latestSummary(f.db, thread, 'alpha');
  assert.equal(summary?.content, 'You were asked for first and did it.');
  assert.equal(summary?.throughMessageId, done.id, 'nothing is kept verbatim');
  assert.equal(listMessages(f.db, thread).length, 4, 'and nothing is deleted');

  // Nothing new since: no summary is asked for, and the script that has no reply left proves it.
  const again = await post(f.app, '/api/agents/alpha/compact', {}, cookie);
  assert.deepEqual(await json(again), { compacted: { alpha: 0 } });

  const release = f.hold();
  f.replies.push({ text: 'late' });
  await post(f.app, '/api/agents/alpha/messages', { text: 'busy?' }, cookie);
  assert.equal((await post(f.app, '/api/agents/alpha/compact', {}, cookie)).status, 409);
  release();
  await f.settled('alpha');

  assert.equal((await post(f.app, '/api/agents/nobody/compact', {}, cookie)).status, 404);
  assert.equal((await post(f.app, '/api/conversations/999/compact', {}, cookie)).status, 404);
});

test('compaction is refused until the provider is configured', async () => {
  const f = fixture();
  const cookie = sessionCookie(await post(f.app, '/api/auth/setup', { password: PASSWORD }));
  await post(f.app, '/api/agents', { name: 'alpha', profile: PROFILED }, cookie);
  const res = await post(f.app, '/api/agents/alpha/compact', {}, cookie);
  assert.equal(res.status, 400);
});

test('two messages in a row are both accepted and both answered', async () => {
  const { f, cookie } = await configured();
  f.replies.push({ text: 'one' }, { text: 'two' });

  const first = await post(f.app, '/api/agents/alpha/messages', { text: 'first' }, cookie);
  const second = await post(f.app, '/api/agents/alpha/messages', { text: 'second' }, cookie);
  assert.equal(first.status, 202);
  // No 409 whether or not the first turn is still running; loop.test.ts holds a turn open to
  // prove the mid-turn case, which nothing here can time reliably.
  assert.equal(second.status, 202, 'the row is the queue, so nothing has to retry');
  await f.settled('alpha');

  for (let attempt = 0; attempt < 200 && f.replies.length > 0; attempt += 1) {
    await new Promise((done) => setTimeout(done, 5));
  }
  const messages = (await getJson(f.app, '/api/agents/alpha/messages', cookie)) as {
    content: string;
  }[];
  assert.deepEqual(messages.map((m) => m.content).sort(), ['first', 'one', 'second', 'two']);
  assert.equal(await f.settled('alpha'), 'waiting_for_user');
});

test('a conversation id that is not a number is a 404, never a query', async () => {
  const { f, cookie } = await configured();
  for (const id of ['abc', 'NaN', '1e999', '../1']) {
    const res = await f.app.request(`/api/conversations/${id}/messages`, { headers: { cookie } });
    assert.equal(res.status, 404, `${id} should not reach the database`);
  }
});

test('a message above the loop cap is refused with an error that names the cap', async () => {
  const { f, cookie } = await configured({ maxLoops: 1 });
  await post(f.app, '/api/agents', { name: 'bravo', profile: PROFILED }, cookie);
  const release = f.hold();

  const first = await post(f.app, '/api/agents/alpha/messages', { text: 'take your time' }, cookie);
  assert.equal(first.status, 202, "alpha's turn holds the only loop this daemon allows");

  const refused = await post(f.app, '/api/agents/bravo/messages', { text: 'and me?' }, cookie);
  assert.equal(refused.status, 429);
  assert.match(String((await json(refused))['error']), /at most 1 agent loops can run at once/);

  // Refused before it was stored: the owner was told, so nothing is left waiting for a turn.
  const stored = (await getJson(f.app, '/api/agents/bravo/messages', cookie)) as unknown[];
  assert.deepEqual(stored, []);

  f.replies.push({ text: 'done' });
  release();
  assert.equal(await f.settled('alpha'), 'waiting_for_user');

  f.replies.push({ text: 'here' });
  const taken = await post(f.app, '/api/agents/bravo/messages', { text: 'now?' }, cookie);
  assert.equal(taken.status, 202, 'and taken once the loop is free again');
  assert.equal(await f.settled('bravo'), 'waiting_for_user');
});

function patch(app: App, path: string, body: unknown, cookie: string) {
  return app.request(path, {
    method: 'PATCH',
    body: JSON.stringify(body),
    headers: { 'content-type': 'application/json', cookie },
  });
}

test('the owner can list, create, pause and cancel an agent\'s schedules', async () => {
  const { app } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));
  await post(app, '/api/agents', { name: 'alpha' }, cookie);

  assert.deepEqual(await json(await app.request('/api/agents/alpha/schedules', { headers: { cookie } })), []);

  const created = await post(
    app,
    '/api/agents/alpha/schedules',
    { cron: '0 7 * * *', prompt: 'check the overnight logs' },
    cookie,
  );
  assert.equal(created.status, 201);
  const job = await json(created);
  assert.equal(job['agent'], 'alpha');
  assert.equal(job['paused'], false);
  assert.ok(Number(job['nextRunAt']) > Date.now());

  const paused = await patch(app, `/api/agents/alpha/schedules/${String(job['id'])}`, { paused: true }, cookie);
  assert.equal(paused.status, 200);
  assert.equal((await json(paused))['paused'], true);

  const listed = (await (
    await app.request('/api/agents/alpha/schedules', { headers: { cookie } })
  ).json()) as { id: number; paused: boolean }[];
  assert.deepEqual(listed.map((row) => [row.id, row.paused]), [[job['id'], true]]);

  const gone = await app.request(`/api/agents/alpha/schedules/${String(job['id'])}`, {
    method: 'DELETE',
    headers: { cookie },
  });
  assert.equal(gone.status, 200);
  assert.deepEqual(await json(await app.request('/api/agents/alpha/schedules', { headers: { cookie } })), []);
});

test('the schedule routes refuse a bad body, an unknown agent and another agent\'s id', async () => {
  const { app } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));
  await post(app, '/api/agents', { name: 'alpha' }, cookie);
  await post(app, '/api/agents', { name: 'bravo' }, cookie);

  const mine = await json(
    await post(app, '/api/agents/alpha/schedules', { cron: '0 7 * * *', prompt: 'mine' }, cookie),
  );
  const id = String(mine['id']);

  // The tool's parse is the route's parse, so prose is refused on both.
  const prose = await post(
    app,
    '/api/agents/alpha/schedules',
    { cron: 'every morning at seven', prompt: 'mine' },
    cookie,
  );
  assert.equal(prose.status, 400);
  assert.equal((await post(app, '/api/agents/alpha/schedules', { cron: '0 7 * * *' }, cookie)).status, 400);
  assert.equal((await post(app, '/api/agents/nobody/schedules', { cron: '0 7 * * *', prompt: 'x' }, cookie)).status, 404);
  assert.equal((await app.request('/api/agents/nobody/schedules', { headers: { cookie } })).status, 404);

  assert.equal((await patch(app, `/api/agents/alpha/schedules/${id}`, { paused: 'yes' }, cookie)).status, 400);
  assert.equal((await patch(app, `/api/agents/bravo/schedules/${id}`, { paused: true }, cookie)).status, 404);
  assert.equal(
    (await app.request(`/api/agents/bravo/schedules/${id}`, { method: 'DELETE', headers: { cookie } })).status,
    404,
    'an id is only ever looked up inside the agent the path named',
  );
  assert.equal((await patch(app, '/api/agents/alpha/schedules/nonsense', { paused: true }, cookie)).status, 404);

  // And the whole set is behind the session guard like every other agent route.
  assert.equal((await app.request('/api/agents/alpha/schedules')).status, 401);
  assert.equal((await post(app, '/api/agents/alpha/schedules', { cron: '0 7 * * *', prompt: 'x' })).status, 401);
});

test('MCP servers are stored encrypted and come back without their secrets', async () => {
  const { app, db, masterKey } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));

  const written = await app.request('/api/mcp/servers', {
    method: 'PUT',
    body: JSON.stringify({
      servers: [
        { name: 'files', command: 'npx', args: ['-y', 'pkg'], env: { TOKEN: 'shouldnevershowup' } },
        { name: 'docs', url: 'https://example.com/mcp', headers: { authorization: 'Bearer nope' } },
      ],
    }),
    headers: { 'content-type': 'application/json', cookie },
  });
  assert.equal(written.status, 200);
  assert.doesNotMatch(await written.text(), /shouldnevershowup/);

  const read = await app.request('/api/mcp/servers', { headers: { cookie } });
  assert.deepEqual(await read.json(), [
    { name: 'files', transport: 'stdio', command: 'npx', args: ['-y', 'pkg'], secretKeys: ['TOKEN'] },
    { name: 'docs', transport: 'http', url: 'https://example.com/mcp', secretKeys: ['authorization'] },
  ]);

  const stored = db.$client.prepare("select value from settings where key = 'mcp.servers'").get();
  assert.doesNotMatch(JSON.stringify(stored), /shouldnevershowup/);
  assert.equal(mcpServers(db, masterKey).length, 2, 'and the daemon can still read them back');
});

test('a server list the daemon could not run is a 400 that changes nothing', async () => {
  const { app, db, masterKey } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));

  const res = await app.request('/api/mcp/servers', {
    method: 'PUT',
    body: JSON.stringify({ servers: [{ name: 'Files', command: 'npx' }] }),
    headers: { 'content-type': 'application/json', cookie },
  });
  assert.equal(res.status, 400);
  assert.deepEqual(mcpServers(db, masterKey), []);
});

function put(app: App, path: string, body: unknown, cookie?: string) {
  return app.request(path, {
    method: 'PUT',
    body: JSON.stringify(body),
    headers: { 'content-type': 'application/json', ...(cookie ? { cookie } : {}) },
  });
}

test('one server is added, changed and removed without retyping the list or its secrets', async () => {
  const { app, db, masterKey } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));

  // Appended onto an empty list, and the name in the path wins over the one in the body.
  const added = await put(
    app,
    '/api/mcp/servers/files',
    { name: 'other', command: 'npx', args: ['-y', 'pkg'], env: { TOKEN: 'shouldnevershowup', GONE: 'x' } },
    cookie,
  );
  assert.equal(added.status, 200);
  assert.doesNotMatch(await added.text(), /shouldnevershowup/);
  assert.deepEqual(mcpServers(db, masterKey), [
    { name: 'files', command: 'npx', args: ['-y', 'pkg'], env: { TOKEN: 'shouldnevershowup', GONE: 'x' } },
  ]);

  // A second one appends rather than replacing the first.
  const other = { url: 'https://example.com/mcp', headers: { authorization: 'Bearer nope' } };
  assert.equal((await put(app, '/api/mcp/servers/docs', other, cookie)).status, 200);

  // Changing it: a blank value keeps the stored secret, a key the body leaves out goes with it.
  const changed = await put(app, '/api/mcp/servers/files', { command: 'uvx', args: ['pkg'], env: { TOKEN: '' } }, cookie);
  assert.equal(changed.status, 200);
  assert.deepEqual(await changed.json(), [
    { name: 'files', transport: 'stdio', command: 'uvx', args: ['pkg'], secretKeys: ['TOKEN'] },
    { name: 'docs', transport: 'http', url: 'https://example.com/mcp', secretKeys: ['authorization'] },
  ]);
  assert.deepEqual(
    mcpServers(db, masterKey),
    [
      { name: 'files', command: 'uvx', args: ['pkg'], env: { TOKEN: 'shouldnevershowup' } },
      { name: 'docs', url: 'https://example.com/mcp', headers: { authorization: 'Bearer nope' } },
    ],
    'the secret the owner never saw survived the edit, and the one left out did not',
  );

  // And the same merge on the headers half: the bearer token survives a change of endpoint.
  const moved = await put(app, '/api/mcp/servers/docs', { url: 'https://example.com/mcp/v2', headers: { authorization: '' } }, cookie);
  assert.equal(moved.status, 200);
  assert.deepEqual(mcpServers(db, masterKey)[1], {
    name: 'docs',
    url: 'https://example.com/mcp/v2',
    headers: { authorization: 'Bearer nope' },
  });

  const gone = await app.request('/api/mcp/servers/docs', { method: 'DELETE', headers: { cookie } });
  assert.equal(gone.status, 200);
  assert.deepEqual(
    mcpServers(db, masterKey).map((s) => s.name),
    ['files'],
  );
  assert.equal(
    (await app.request('/api/mcp/servers/docs', { method: 'DELETE', headers: { cookie } })).status,
    404,
  );
});

test('a per-server write the daemon could not run is a 400 that changes nothing', async () => {
  const { app, db, masterKey } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));
  assert.equal((await put(app, '/api/mcp/servers/files', { command: 'npx', env: { TOKEN: 'keep-me' } }, cookie)).status, 200);

  // Neither a command nor a url, so there is nothing to start.
  assert.equal((await put(app, '/api/mcp/servers/files', { args: ['x'] }, cookie)).status, 400);
  // A name the `mcp__<server>__<tool>` namespace cannot carry.
  assert.equal((await put(app, '/api/mcp/servers/Files', { command: 'npx' }, cookie)).status, 400);
  assert.deepEqual(mcpServers(db, masterKey), [{ name: 'files', command: 'npx', args: [], env: { TOKEN: 'keep-me' } }]);

  // The whole list goes through the parse, so an append is held to the same cap as a replace.
  for (let n = 2; n <= MAX_MCP_SERVERS; n += 1) {
    assert.equal((await put(app, `/api/mcp/servers/s${n}`, { command: 'npx' }, cookie)).status, 200);
  }
  assert.equal((await put(app, '/api/mcp/servers/spare', { command: 'npx' }, cookie)).status, 400);

  // And both paths are behind the session guard like every other route.
  assert.equal((await put(app, '/api/mcp/servers/files', { command: 'npx' })).status, 401);
  assert.equal((await app.request('/api/mcp/servers/files', { method: 'DELETE' })).status, 401);
});

test('testing a server that cannot be reached is an answer, not a failed request', async () => {
  const { app } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));
  await post(app, '/api/agents', { name: 'alpha' }, cookie);
  // Port 1 refuses at once, so this exercises the route without a spawn or a timeout.
  await app.request('/api/mcp/servers', {
    method: 'PUT',
    body: JSON.stringify({ servers: [{ name: 'docs', url: 'http://127.0.0.1:1/mcp' }] }),
    headers: { 'content-type': 'application/json', cookie },
  });

  const res = await post(app, '/api/agents/alpha/mcp/docs/test', {}, cookie);
  assert.equal(res.status, 200);
  const body = await json(res);
  assert.equal(body['ok'], false);
  assert.deepEqual(body['tools'], []);
  assert.ok(typeof body['error'] === 'string' && body['error'] !== '');

  assert.equal((await post(app, '/api/agents/alpha/mcp/nope/test', {}, cookie)).status, 404);
  assert.equal((await post(app, '/api/agents/nobody/mcp/docs/test', {}, cookie)).status, 404);
});

test('deleting an agent takes its workers, threads, routines and history with it', async () => {
  const { app, db, stopped } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));
  await post(app, '/api/agents', { name: 'alpha' }, cookie);
  await post(app, '/api/agents', { name: 'bravo' }, cookie);

  const alpha = findAgent(db, 'alpha') as Agent;
  const bravo = findAgent(db, 'bravo') as Agent;
  const own = conversationFor(db, alpha.id);
  appendMessage(db, own, { role: 'user', content: 'hello' });
  const shared = conversationWith(db, [alpha.id, bravo.id]);
  appendMessage(db, shared, { role: 'user', content: 'both of you', sender: 'alpha' });
  appendMessage(db, shared, { role: 'user', content: 'heard', sender: 'bravo' });
  const worker = insertWorker(db, alpha, 'alpha-w1', own);
  await post(app, `/api/agents/alpha/schedules`, { cron: '0 9 * * *', prompt: 'morning' }, cookie);

  const gone = await app.request('/api/agents/alpha', { method: 'DELETE', headers: { cookie } });
  assert.equal(gone.status, 200);
  assert.deepEqual(stopped, ['alpha'], 'the desktop is stopped before the row goes');

  assert.equal(findAgent(db, 'alpha'), undefined);
  assert.equal(findAgent(db, 'alpha-w1'), undefined, 'its workers go with it');
  assert.equal(findAgentById(db, worker.id), undefined);
  assert.deepEqual(listMessages(db, own), [], 'the thread it was alone in is gone');
  assert.equal(findConversation(db, own), undefined);

  // The thread it shared outlives it, minus what it wrote and its seat in it.
  assert.deepEqual(listMessages(db, shared).map((row) => row.sender), ['bravo']);
  assert.deepEqual(
    participantAgents(db, shared).map((agent) => agent.name),
    ['bravo'],
  );
  assert.deepEqual(listSchedules(db, bravo), []);
  assert.equal(findAgent(db, 'bravo')?.name, 'bravo', 'nobody else is touched');

  // Its display number goes back in the pool, which is the whole reason the desktop is stopped.
  const reused = await json(await post(app, '/api/agents', { name: 'charlie' }, cookie));
  assert.equal(reused['display'], 1);
  assert.equal(
    (await app.request('/api/agents/nobody', { method: 'DELETE', headers: { cookie } })).status,
    404,
  );
});

test('an agent in the middle of a turn is not deleted out from under its own loop', async () => {
  const { f, cookie } = await configured();
  const release = f.hold();
  assert.equal((await post(f.app, '/api/agents/alpha/messages', { text: 'go' }, cookie)).status, 202);

  const refused = await f.app.request('/api/agents/alpha', { method: 'DELETE', headers: { cookie } });
  assert.equal(refused.status, 409);
  assert.match(String((await json(refused))['error']), /middle of a turn/);

  // Its thread is refused for the same reason: clearing it mid-turn is the same rows.
  const thread = conversationFor(f.db, findAgent(f.db, 'alpha')?.id as number);
  const alsoRefused = await f.app.request(`/api/conversations/${thread}`, {
    method: 'DELETE',
    headers: { cookie },
  });
  assert.equal(alsoRefused.status, 409);

  f.replies.push({ text: 'done' });
  release();
  await f.settled('alpha');
  assert.ok(findAgent(f.db, 'alpha'), 'and it is still there');
  assert.equal(
    (await f.app.request('/api/agents/alpha', { method: 'DELETE', headers: { cookie } })).status,
    200,
  );
});

test('deleting a thread clears it and leaves the agents in it alone', async () => {
  const { app, db } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));
  await post(app, '/api/agents', { name: 'alpha' }, cookie);
  await post(app, '/api/agents', { name: 'bravo' }, cookie);
  const shared = conversationWith(
    db,
    [findAgent(db, 'alpha') as Agent, findAgent(db, 'bravo') as Agent].map((agent) => agent.id),
  );
  appendMessage(db, shared, { role: 'user', content: 'a word' });

  const gone = await app.request(`/api/conversations/${shared}`, {
    method: 'DELETE',
    headers: { cookie },
  });
  assert.equal(gone.status, 200);
  assert.equal(findConversation(db, shared), undefined);
  assert.equal(findAgent(db, 'alpha')?.name, 'alpha');
  assert.equal(findAgent(db, 'bravo')?.name, 'bravo');
  assert.equal(
    (await app.request('/api/conversations/9999', { method: 'DELETE', headers: { cookie } })).status,
    404,
  );
});

test('an agent asks the owner before anything is deleted, and is told either way', async () => {
  const { app, db } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));
  await post(app, '/api/agents', { name: 'alpha' }, cookie);
  await post(app, '/api/agents', { name: 'bravo' }, cookie);
  const alpha = findAgent(db, 'alpha') as Agent;
  const thread = conversationFor(db, alpha.id);

  const asked = insertApproval(db, alpha, thread, {
    kind: 'agent',
    target: 'bravo',
    reason: 'bravo finished its job',
  });
  const listed = (await (
    await app.request('/api/approvals', { headers: { cookie } })
  ).json()) as Approval[];
  assert.deepEqual(listed.map((row) => [row.agent, row.kind, row.target]), [
    ['alpha', 'agent', 'bravo'],
  ]);
  assert.ok(findAgent(db, 'bravo'), 'the request alone deletes nothing');

  // No: the request is gone, bravo is not, and alpha is told.
  assert.equal((await post(app, `/api/approvals/${asked.id}`, { approve: false }, cookie)).status, 200);
  assert.deepEqual(listApprovals(db), []);
  assert.ok(findAgent(db, 'bravo'));
  assert.match(String(listMessages(db, thread).at(-1)?.content), /said no/);

  // Yes: it happens, and alpha is told that too.
  const again = insertApproval(db, alpha, thread, {
    kind: 'agent',
    target: 'bravo',
    reason: 'still finished',
  });
  assert.equal((await post(app, `/api/approvals/${again.id}`, { approve: true }, cookie)).status, 200);
  assert.equal(findAgent(db, 'bravo'), undefined);
  assert.match(String(listMessages(db, thread).at(-1)?.content), /approved/);

  assert.equal((await post(app, '/api/approvals/404', { approve: true }, cookie)).status, 404);
  assert.equal((await post(app, `/api/approvals/${again.id}`, { approve: true }, cookie)).status, 404);
});

test('an agent can ask to be deleted itself, and the request goes with it', async () => {
  const { app, db } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));
  await post(app, '/api/agents', { name: 'alpha' }, cookie);
  const alpha = findAgent(db, 'alpha') as Agent;
  const asked = insertApproval(db, alpha, conversationFor(db, alpha.id), {
    kind: 'agent',
    target: 'alpha',
    reason: 'my work here is done',
  });
  assert.equal(describeApproval(asked), 'delete itself (alpha)');

  assert.equal((await post(app, `/api/approvals/${asked.id}`, { approve: true }, cookie)).status, 200);
  assert.equal(findAgent(db, 'alpha'), undefined);
  assert.deepEqual(listApprovals(db), [], 'nothing points at an agent that is gone');
});

test('the owner can stop a turn, and the agent takes the next message afterwards', async () => {
  const { f, cookie } = await configured();
  const release = f.hold();
  assert.equal((await post(f.app, '/api/agents/alpha/messages', { text: 'go' }, cookie)).status, 202);
  await new Promise((done) => setTimeout(done, 10));

  const stopped = await post(f.app, '/api/agents/alpha/stop', {}, cookie);
  assert.equal(stopped.status, 200);
  assert.deepEqual(await json(stopped), { stopped: true });
  assert.equal(await f.settled('alpha'), 'waiting_for_user');

  const thread = (await getJson(f.app, '/api/agents/alpha/messages', cookie)) as Record<string, unknown>[];
  assert.equal(thread.at(-1)?.['content'], STOPPED, 'the stop is written into the thread');
  const events = (await getJson(f.app, '/api/agents/alpha/events', cookie)) as Record<string, unknown>[];
  assert.ok(events.some((event) => event['type'] === 'stop'));
  const turn = events.find((event) => event['type'] === 'turn')?.['data'] as Record<string, unknown>;
  assert.deepEqual(turn, { steps: 0 }, 'the turn cost nothing: the model never answered');

  // Nothing is running now, so a second stop is an honest no.
  assert.deepEqual(await json(await post(f.app, '/api/agents/alpha/stop', {}, cookie)), { stopped: false });
  assert.equal((await post(f.app, '/api/agents/nobody/stop', {}, cookie)).status, 404);

  release();
  f.replies.push({ text: 'done' });
  assert.equal((await post(f.app, '/api/agents/alpha/messages', { text: 'again' }, cookie)).status, 202);
  assert.equal(await f.settled('alpha'), 'waiting_for_user');
});

test('the event log can be asked for its tail', async () => {
  const { f, cookie } = await configured();
  f.replies.push({ text: 'done' });
  await post(f.app, '/api/agents/alpha/messages', { text: 'go' }, cookie);
  await f.settled('alpha');

  const whole = (await getJson(f.app, '/api/agents/alpha/events', cookie)) as { id: number }[];
  assert.ok(whole.length >= 3);
  const tail = (await getJson(f.app, '/api/agents/alpha/events?limit=2', cookie)) as { id: number }[];
  assert.deepEqual(tail.map((e) => e.id), whole.slice(-2).map((e) => e.id), 'the newest two, oldest first');
  for (const bad of ['0', '-1', 'x', '1001']) {
    assert.equal((await f.app.request(`/api/agents/alpha/events?limit=${bad}`, { headers: { cookie } })).status, 400);
  }
});

test('an agent carries the look a client gave it, so every device draws the same avatar', async () => {
  const { app } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));
  const created = await json(await post(app, '/api/agents', { name: 'alpha', label: 'Al', look: 'blob:red' }, cookie));
  assert.equal(created['look'], 'blob:red');

  const relooked = await json(await patch(app, '/api/agents/alpha', { look: 'star:blue' }, cookie));
  assert.equal(relooked['look'], 'star:blue');
  assert.equal(relooked['label'], 'Al', 'a look alone leaves the label as it was');
  const fetched = await json(await app.request('/api/agents/alpha', { headers: { cookie } }));
  assert.equal(fetched['look'], 'star:blue');
  assert.equal(fetched['label'], 'Al');

  assert.equal((await patch(app, '/api/agents/alpha', {}, cookie)).status, 400, 'nothing to change');
  assert.equal((await patch(app, '/api/agents/alpha', { look: 'two\nlines' }, cookie)).status, 400);
  const plain = await json(await post(app, '/api/agents', { name: 'bravo' }, cookie));
  assert.ok(!('look' in plain), 'no look rather than an empty one');
});

test('a file the owner hands an agent is written into its home as the agent', async () => {
  const { f, cookie } = await configured();
  const res = await post(f.app, '/api/agents/alpha/uploads', { name: 'notes (1).txt', base64: btoa('hi') }, cookie);
  assert.equal(res.status, 201);
  assert.deepEqual(await json(res), { path: '/home/agent-alpha/uploads/notes (1).txt', bytes: 2 });
  const upload = f.ran.find((argv) => argv.includes('schermes-upload'));
  assert.ok(upload, 'written through the agent');
  assert.equal(upload[0], 'sudo');
  assert.equal(upload[3], 'agent-alpha');
  assert.equal(upload.at(-1), 'notes (1).txt', 'the name is an operand, never a word in the script');

  for (const name of ['../etc/passwd', 'a/b', '.hidden', '', 'x'.repeat(129)]) {
    const refused = await post(f.app, '/api/agents/alpha/uploads', { name, base64: btoa('hi') }, cookie);
    assert.equal(refused.status, 400, `${JSON.stringify(name)} should be refused`);
  }
  assert.equal((await post(f.app, '/api/agents/alpha/uploads', { name: 'a.txt', base64: '%%' }, cookie)).status, 400);
  assert.equal((await post(f.app, '/api/agents/nobody/uploads', { name: 'a.txt', base64: '' }, cookie)).status, 404);
});

test('the owner reads an agent\'s memory files and may rewrite the lasting one', async () => {
  const { f, cookie } = await configured();
  // The fake exec answers every sudo with the same bytes, which land in the first file.
  assert.deepEqual(await getJson(f.app, '/api/agents/alpha/memory', cookie), { lasting: 'tool output', today: '' });
  assert.ok(f.ran.some((argv) => argv.includes(HOME_READ_MEMORY)));

  const written = await f.app.request('/api/agents/alpha/memory', {
    method: 'PUT',
    body: JSON.stringify({ lasting: '- likes tea\n' }),
    headers: { 'content-type': 'application/json', cookie },
  });
  assert.equal(written.status, 200);
  const write = f.ran.find((argv) => argv.includes(HOME_WRITE_MEMORY));
  assert.ok(write, 'written through the agent');
  assert.equal(write[3], 'agent-alpha');

  const bad = await f.app.request('/api/agents/alpha/memory', {
    method: 'PUT',
    body: JSON.stringify({ lasting: 7 }),
    headers: { 'content-type': 'application/json', cookie },
  });
  assert.equal(bad.status, 400);
  assert.equal((await f.app.request('/api/agents/nobody/memory', { headers: { cookie } })).status, 404);
});

test('the provider settings can be tested with one model call', async () => {
  const { app, replies } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));
  assert.equal((await post(app, '/api/settings/test', {}, cookie)).status, 400, 'nothing stored yet');

  await app.request('/api/settings', {
    method: 'PUT',
    body: JSON.stringify({ baseUrl: 'https://api.example.com/v1', model: 'm', apiKey: 'sk-x' }),
    headers: { 'content-type': 'application/json', cookie },
  });
  replies.push({ text: 'ok\nand more' });
  assert.deepEqual(await json(await post(app, '/api/settings/test', {}, cookie)), { ok: true, reply: 'ok' });

  // The script is empty now, so the next call throws: an unreachable endpoint is an answer.
  const failed = await json(await post(app, '/api/settings/test', {}, cookie));
  assert.equal(failed['ok'], false);
  assert.match(String(failed['error']), /ran out of replies/);
});

test('a search reads across every thread and clips what it finds', async () => {
  const { f, cookie } = await configured();
  await post(f.app, '/api/agents', { name: 'bravo', profile: PROFILED }, cookie);
  f.replies.push({ text: 'The invoice total is 42 euros.' });
  await post(f.app, '/api/agents/alpha/messages', { text: 'what was the invoice total?' }, cookie);
  await f.settled('alpha');
  f.replies.push({ text: 'x'.repeat(300) + ' needle ' + 'y'.repeat(300) });
  await post(f.app, '/api/agents/bravo/messages', { text: 'go' }, cookie);
  await f.settled('bravo');

  const hits = (await getJson(f.app, '/api/search?q=INVOICE', cookie)) as Record<string, unknown>[];
  assert.equal(hits.length, 2, 'the question and the answer, case-insensitively');
  assert.deepEqual(hits[0]?.['participants'], ['alpha']);
  assert.equal((hits[0]?.['message'] as Record<string, unknown>)['content'], 'The invoice total is 42 euros.');
  assert.ok(!('image' in (hits[0]?.['message'] as object)));

  const clipped = (await getJson(f.app, '/api/search?q=needle', cookie)) as Record<string, unknown>[];
  const text = String((clipped[0]?.['message'] as Record<string, unknown>)['content']);
  assert.ok(text.length < 300 && text.includes('needle') && text.startsWith('…') && text.endsWith('…'));

  assert.equal((await getJson(f.app, '/api/search?q=%25', cookie) as unknown[]).length, 0, 'a wildcard is a character');
  assert.equal((await f.app.request('/api/search?q=', { headers: { cookie } })).status, 400);
  assert.equal((await f.app.request('/api/search', {})).status, 401);
});


const P8 = generateKeyPairSync('ec', { namedCurve: 'prime256v1' }).privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();

test('the push settings round-trip with the key stored encrypted, and devices register by token', async () => {
  const { app, db } = fixture();
  const cookie = sessionCookie(await post(app, '/api/auth/setup', { password: PASSWORD }));
  const put = (body: unknown) =>
    app.request('/api/settings', { method: 'PUT', body: JSON.stringify(body), headers: { 'content-type': 'application/json', cookie } });

  assert.equal((await put({ pushKey: 'not a key' })).status, 400);
  assert.equal((await put({ pushSandbox: 'yes' })).status, 400);
  const saved = await put({ pushKeyId: ' K1 ', pushTeamId: 'T1', pushBundleId: 'dev.schermes.Schermes', pushKey: P8, pushSandbox: true });
  assert.equal(saved.status, 200);
  assert.deepEqual((await json(saved))['push'], { keyId: 'K1', teamId: 'T1', bundleId: 'dev.schermes.Schermes', keySet: true, sandbox: true });
  const row = db.select().from(settingsTable).where(eq(settingsTable.key, 'push.key')).get();
  assert.ok(row?.encrypted && !row.value.includes('PRIVATE KEY'));
  assert.equal(((await json(await put({ pushKey: '' })))['push'] as Record<string, unknown>)['keySet'], false, 'empty clears it');

  assert.equal((await post(app, '/api/devices', { token: 'zz', platform: 'ios' }, cookie)).status, 400);
  assert.equal((await post(app, '/api/devices', { token: 'ab'.repeat(32), platform: 'watch' }, cookie)).status, 400);
  assert.equal((await post(app, '/api/devices', { token: 'AB'.repeat(32), platform: 'ios' }, cookie)).status, 201);
  assert.equal((await post(app, '/api/devices', { token: 'ab'.repeat(32), platform: 'macos' }, cookie)).status, 201);
  const listed = (await getJson(app, '/api/devices', cookie)) as Record<string, unknown>[];
  assert.equal(listed.length, 1, 'one row per token, case folded');
  assert.equal(listed[0]?.['platform'], 'macos');
  assert.equal((await app.request('/api/devices/nobody', { method: 'DELETE', headers: { cookie } })).status, 404);
  assert.equal((await app.request(`/api/devices/${'ab'.repeat(32)}`, { method: 'DELETE', headers: { cookie } })).status, 200);
  assert.deepEqual(await getJson(app, '/api/devices', cookie), []);
  assert.equal((await app.request('/api/devices')).status, 401);

  // The test push wants the whole configuration and somebody to send to.
  assert.equal((await post(app, '/api/settings/push/test', {}, cookie)).status, 400);
  await put({ pushKey: P8 });
  assert.equal((await post(app, '/api/settings/push/test', {}, cookie)).status, 400, 'no device');
});

test('a picture the owner sends is stored, read back, and reaches the model with its media type', async () => {
  const { f, cookie } = await configured();
  f.replies.push({ text: 'a lovely cat' });
  const png = Buffer.from('\x89PNG fake', 'binary').toString('base64');
  assert.equal((await post(f.app, '/api/agents/alpha/messages', { image: { mediaType: 'image/gif', base64: png } }, cookie)).status, 400);
  assert.equal((await post(f.app, '/api/agents/alpha/messages', { image: { mediaType: 'image/jpeg', base64: '%%' } }, cookie)).status, 400);
  assert.equal((await post(f.app, '/api/agents/alpha/messages', {}, cookie)).status, 400, 'nothing at all');

  const posted = await post(f.app, '/api/agents/alpha/messages', { text: '', image: { mediaType: 'image/jpeg', base64: png } }, cookie);
  assert.equal(posted.status, 202);
  assert.equal(await f.settled('alpha'), 'waiting_for_user');
  const thread = (await getJson(f.app, '/api/agents/alpha/messages', cookie)) as Record<string, unknown>[];
  assert.equal(thread[0]?.['content'], '');
  assert.deepEqual(thread[0]?.['image'], { mediaType: 'image/jpeg', base64: png });
});

test('the owner fetches a file an agent mentions, only from inside its home', async () => {
  const { f, cookie } = await configured();
  const at = (path: string) => `/api/agents/alpha/files?path=${encodeURIComponent(path)}`;

  const file = (await getJson(f.app, at('~/workspace/furby list.xlsx'), cookie)) as Record<string, unknown>;
  assert.equal(file['name'], 'furby list.xlsx');
  const read = f.ran.find((argv) => argv.includes('schermes-read-file'));
  assert.ok(read, 'read through the agent');
  assert.equal(read[3], 'agent-alpha');
  assert.equal(read.at(-2), '/home/agent-alpha/workspace/furby list.xlsx', 'the path is an operand');

  assert.equal((await f.app.request(at('/home/agent-alpha/a/../notes.txt'), { headers: { cookie } })).status, 200);
  for (const path of ['~/../agent-bravo/secret', '/etc/passwd', 'workspace/x', '', '/home/agent-alpha']) {
    const refused = await f.app.request(at(path), { headers: { cookie } });
    assert.equal(refused.status, 400, `${JSON.stringify(path)} should be refused`);
  }
  assert.equal((await f.app.request('/api/agents/nobody/files?path=~/a', { headers: { cookie } })).status, 404);

  const alpha = findAgent(f.db, 'alpha')!;
  insertWorker(f.db, alpha, 'alpha-job', conversationFor(f.db, alpha.id));
  assert.equal((await f.app.request('/api/agents/alpha-job/files?path=~/out.csv', { headers: { cookie } })).status, 200);
  assert.equal(f.ran.at(-1)?.at(-2), '/home/agent-alpha/out.csv', "a worker's files are in its parent's home");
});
