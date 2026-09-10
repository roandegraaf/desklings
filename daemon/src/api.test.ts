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
import { readApiKey } from './settings.ts';

const MIGRATIONS = resolve(import.meta.dirname, '../migrations');
const PASSWORD = 'correct-horse-battery';

function fixture() {
  const db = openDb(':memory:', MIGRATIONS);
  const masterKey = loadMasterKey(join(mkdtempSync(join(tmpdir(), 'schermes-api-')), 'master.key'));
  const spawned: string[] = [];
  const desktop = {
    ensure(name: string) {
      if (name === 'unspawnable') return Promise.reject(new Error('Xvnc did not come up'));
      spawned.push(name);
      return Promise.resolve('started' as const);
    },
  };
  return { db, masterKey, spawned, app: createApp({ db, masterKey, desktop }) };
}

type App = ReturnType<typeof createApp>;

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
  });

  const stored = db.$client.prepare("select value from settings where key = 'provider.apiKey'").get();
  assert.doesNotMatch(JSON.stringify(stored), /shouldnevershowup/);
  assert.equal(readApiKey(db, masterKey), apiKey);
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
});
