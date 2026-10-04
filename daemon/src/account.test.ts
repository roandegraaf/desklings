import { resolve, join } from 'node:path';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import assert from 'node:assert/strict';
import test from 'node:test';
import type { AuditEvent, SessionEntry, TotpSetup, TotpStatus } from '@schermes/shared';
import { createApp } from './app.ts';
import type { AppDeps } from './app.ts';
import { openDb } from './db.ts';
import { SESSION_COOKIE, createLoginGuard } from './auth.ts';
import { decrypt, loadMasterKey } from './secrets.ts';
import type { Exec } from './exec.ts';
import {
  AUDIT_KEEP_MS,
  AUDIT_KEEP_ROWS,
  RECOVERY_CODE_COUNT,
  TOTP_STEP_MS,
  base32Decode,
  base32Encode,
  hotp,
  matchingStep,
  recordAudit,
  totpStep,
} from './account.ts';
import { auditEvents, owner, recoveryCodes, sessions } from './schema.ts';

const MIGRATIONS = resolve(import.meta.dirname, '../migrations');
const PASSWORD = 'correct-horse-battery';
const SETUP_TOKEN = 'a-fixed-setup-token';
const START = 1_790_000_000_000;

function fixture(deps: Partial<Pick<AppDeps, 'loginGuard'>> = {}) {
  const db = openDb(':memory:', MIGRATIONS);
  const masterKey = loadMasterKey(join(mkdtempSync(join(tmpdir(), 'schermes-account-')), 'master.key'));
  const desktop = {
    ensure: () => Promise.resolve('started' as const),
    stop: () => Promise.resolve(),
    stopDisplay: () => Promise.resolve(),
    remove: () => Promise.resolve(),
    rename: () => Promise.resolve(),
  };
  const exec: Exec = () => Promise.resolve({ code: 0, stdout: Buffer.from(''), stderr: '', truncated: false });
  const clock = { now: START };
  const { app } = createApp({ db, masterKey, desktop, exec, setupToken: SETUP_TOKEN, now: () => clock.now, ...deps });
  return { app, db, masterKey, clock };
}

type App = ReturnType<typeof fixture>['app'];

function send(app: App, method: string, path: string, body?: unknown, cookie?: string, headers: Record<string, string> = {}) {
  return app.request(path, {
    method,
    ...(body === undefined || method === 'GET' ? {} : { body: JSON.stringify(body) }),
    headers: { 'content-type': 'application/json', ...(cookie ? { cookie } : {}), ...headers },
  });
}

function cookieOf(res: Response): string {
  const header = res.headers.get('set-cookie');
  assert.ok(header, 'expected a session cookie');
  return header.split(';')[0] as string;
}

async function setUp(app: App): Promise<string> {
  const res = await send(app, 'POST', '/api/auth/setup', { password: PASSWORD, setupToken: SETUP_TOKEN });
  assert.equal(res.status, 201);
  return cookieOf(res);
}

async function login(app: App, body: Record<string, unknown>, userAgent = 'test-client'): Promise<Response> {
  return send(app, 'POST', '/api/auth/login', body, undefined, { 'user-agent': userAgent });
}

async function auditActions(app: App, cookie: string): Promise<string[]> {
  const res = await send(app, 'GET', '/api/audit?limit=200', undefined, cookie);
  assert.equal(res.status, 200);
  return ((await res.json()) as AuditEvent[]).map((event) => event.action);
}

/** Enrols TOTP at the fixture clock and returns the secret plus the recovery codes. */
async function enrol(app: App, cookie: string, clock: { now: number }) {
  const setup = (await (await send(app, 'POST', '/api/auth/totp/setup', { password: PASSWORD }, cookie)).json()) as TotpSetup;
  const secret = base32Decode(setup.secret);
  const confirmed = await send(app, 'POST', '/api/auth/totp/confirm', { code: hotp(secret, totpStep(clock.now)) }, cookie);
  assert.equal(confirmed.status, 200);
  const { recoveryCodes: codes } = (await confirmed.json()) as { recoveryCodes: string[] };
  return { secret, codes };
}

test('TOTP matches the RFC 6238 SHA-1 test vectors', () => {
  const seed = Buffer.from('12345678901234567890');
  const vectors: [number, string][] = [
    [59, '94287082'],
    [1111111109, '07081804'],
    [1111111111, '14050471'],
    [1234567890, '89005924'],
    [2000000000, '69279037'],
    [20000000000, '65353130'],
  ];
  for (const [seconds, expected] of vectors) {
    assert.equal(hotp(seed, totpStep(seconds * 1000), 8), expected, `T=${seconds}`);
    assert.equal(hotp(seed, totpStep(seconds * 1000)), expected.slice(2), `T=${seconds}, six digits`);
  }
});

test('base32 follows RFC 4648 and round-trips', () => {
  assert.equal(base32Encode(Buffer.from('foobar')), 'MZXW6YTBOI');
  assert.equal(base32Encode(Buffer.from('f')), 'MY');
  assert.equal(base32Decode('mzxw 6ytb-oi======').toString(), 'foobar');
  assert.throws(() => base32Decode('MZ1'));
});

test('a code is accepted one step either side of now and no further', () => {
  const secret = Buffer.from('12345678901234567890');
  const now = 1_111_111_111_000;
  const step = totpStep(now);
  for (const offset of [-1, 0, 1]) assert.equal(matchingStep(secret, hotp(secret, step + offset), now), step + offset);
  for (const offset of [-2, 2]) assert.equal(matchingStep(secret, hotp(secret, step + offset), now), undefined);
  assert.equal(matchingStep(secret, '12345', now), undefined);
});

test('the account routes are behind the session guard', async () => {
  const { app } = fixture();
  await setUp(app);
  for (const [method, path] of [
    ['POST', '/api/auth/password'],
    ['GET', '/api/auth/sessions'],
    ['DELETE', '/api/auth/sessions/abc'],
    ['GET', '/api/auth/totp'],
    ['POST', '/api/auth/totp/setup'],
    ['POST', '/api/auth/totp/confirm'],
    ['DELETE', '/api/auth/totp'],
    ['GET', '/api/audit'],
  ] as const) {
    assert.equal((await send(app, method, path, {})).status, 401, `${method} ${path}`);
  }
});

test('changing the password checks the current one, signs out every other session and keeps the caller', async () => {
  const loginGuard = createLoginGuard({ freeFailures: 2, baseMs: 60_000 });
  const { app, db } = fixture({ loginGuard });
  const mine = await setUp(app);
  const other = cookieOf(await login(app, { password: PASSWORD }));

  assert.equal((await send(app, 'POST', '/api/auth/password', { current: 'wrong-pass', next: 'a-new-password' }, mine)).status, 403);
  assert.equal((await send(app, 'POST', '/api/auth/password', { current: PASSWORD, next: 'short' }, mine)).status, 400);
  assert.equal((await login(app, { password: PASSWORD })).status, 200, 'nothing changed yet');

  const changed = await send(app, 'POST', '/api/auth/password', { current: PASSWORD, next: 'a-new-password' }, mine);
  assert.equal(changed.status, 200);
  assert.equal(((await changed.json()) as { signedOut: number }).signedOut, 2);
  assert.equal((await send(app, 'GET', '/api/settings', undefined, mine)).status, 200, 'the caller stays signed in');
  assert.equal((await send(app, 'GET', '/api/settings', undefined, other)).status, 401, 'every other session is gone');
  assert.equal(db.select().from(sessions).all().length, 1);
  assert.equal((await login(app, { password: PASSWORD })).status, 401);
  assert.equal((await login(app, { password: 'a-new-password' })).status, 200);

  const actions = await auditActions(app, mine);
  assert.ok(actions.includes('password_change_failed'));
  assert.ok(actions.includes('password_changed'));
});

test('a stolen cookie cannot guess the password through the password change', async () => {
  const loginGuard = createLoginGuard({ freeFailures: 2, baseMs: 60_000 });
  const { app } = fixture({ loginGuard });
  const cookie = await setUp(app);
  for (let i = 0; i < 3; i += 1) {
    await send(app, 'POST', '/api/auth/password', { current: `guess-${i}`, next: 'a-new-password' }, cookie);
  }
  const refused = await send(app, 'POST', '/api/auth/password', { current: PASSWORD, next: 'a-new-password' }, cookie);
  assert.equal(refused.status, 429);
  assert.ok(refused.headers.get('retry-after'));
});

test('the session list names each session by a handle, never its id, and marks the caller', async () => {
  const { app, db } = fixture();
  const mine = await setUp(app);
  await login(app, { password: PASSWORD }, 'Schermes/2.0 iPhone');
  db.insert(sessions).values({ id: 'expired-session', createdAt: 1, expiresAt: 2 }).run();

  const res = await send(app, 'GET', '/api/auth/sessions', undefined, mine);
  const text = await res.text();
  for (const row of db.select().from(sessions).all()) assert.ok(!text.includes(row.id), 'a raw session id was returned');
  const list = JSON.parse(text) as SessionEntry[];
  assert.equal(list.length, 2, 'the expired row is not listed');
  assert.equal(list.filter((entry) => entry.current).length, 1);
  assert.ok(list.some((entry) => entry.userAgent === 'Schermes/2.0 iPhone' && !entry.current));
  for (const entry of list) assert.match(entry.handle, /^[A-Za-z0-9_-]{16}$/);
});

test('revoking a session signs it out, and revoking your own works like logout', async () => {
  const { app } = fixture();
  const mine = await setUp(app);
  const other = cookieOf(await login(app, { password: PASSWORD }, 'the-other-one'));
  const list = (await (await send(app, 'GET', '/api/auth/sessions', undefined, mine)).json()) as SessionEntry[];
  const theirs = list.find((entry) => !entry.current)?.handle ?? '';
  const own = list.find((entry) => entry.current)?.handle ?? '';

  assert.equal((await send(app, 'DELETE', '/api/auth/sessions/not-a-handle', undefined, mine)).status, 404);
  assert.equal((await send(app, 'DELETE', `/api/auth/sessions/${theirs}`, undefined, mine)).status, 200);
  assert.equal((await send(app, 'GET', '/api/settings', undefined, other)).status, 401);
  assert.equal((await send(app, 'GET', '/api/settings', undefined, mine)).status, 200);

  const out = await send(app, 'DELETE', `/api/auth/sessions/${own}`, undefined, mine);
  assert.equal(out.status, 200);
  assert.match(out.headers.get('set-cookie') ?? '', new RegExp(`^${SESSION_COOKIE}=;.*Max-Age=0`));
  assert.equal((await send(app, 'GET', '/api/settings', undefined, mine)).status, 401);
});

test('TOTP enrolment needs the password, keeps the secret encrypted, and hands out hashed recovery codes once', async () => {
  const { app, db, masterKey, clock } = fixture();
  const cookie = await setUp(app);

  assert.equal((await send(app, 'POST', '/api/auth/totp/setup', { password: 'not-it' }, cookie)).status, 403);
  assert.equal((await send(app, 'POST', '/api/auth/totp/confirm', { code: '123456' }, cookie)).status, 409, 'nothing pending');

  const setupRes = await send(app, 'POST', '/api/auth/totp/setup', { password: PASSWORD }, cookie);
  assert.equal(setupRes.status, 200);
  const setup = (await setupRes.json()) as TotpSetup;
  assert.match(setup.secret, /^[A-Z2-7]{32}$/);
  assert.equal(
    setup.uri,
    `otpauth://totp/schermes%3Aowner?secret=${setup.secret}&issuer=schermes&algorithm=SHA1&digits=6&period=30`,
  );
  const stored = db.select().from(owner).get();
  assert.ok(stored?.totpPending && !stored.totpPending.includes(setup.secret));
  assert.equal(decrypt(masterKey, stored.totpPending), setup.secret);
  assert.equal(stored.totpSecret, null, 'not on until confirmed');
  assert.equal((await login(app, { password: PASSWORD })).status, 200, 'a pending enrolment does not gate login');

  const secret = base32Decode(setup.secret);
  const wrong = hotp(secret, totpStep(clock.now) + 5);
  assert.equal((await send(app, 'POST', '/api/auth/totp/confirm', { code: wrong }, cookie)).status, 400);
  const confirmed = await send(app, 'POST', '/api/auth/totp/confirm', { code: hotp(secret, totpStep(clock.now)) }, cookie);
  assert.equal(confirmed.status, 200);
  const { recoveryCodes: codes } = (await confirmed.json()) as { recoveryCodes: string[] };
  assert.equal(codes.length, RECOVERY_CODE_COUNT);
  assert.equal(new Set(codes).size, RECOVERY_CODE_COUNT);
  for (const code of codes) assert.match(code, /^[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}$/);
  const hashes = db.select().from(recoveryCodes).all().map((row) => row.hash);
  assert.equal(hashes.length, RECOVERY_CODE_COUNT);
  for (const code of codes) assert.ok(!hashes.some((hash) => hash.includes(code.replace(/-/g, ''))));

  assert.deepEqual((await (await send(app, 'GET', '/api/auth/totp', undefined, cookie)).json()) as TotpStatus, {
    enabled: true,
    pending: false,
    recoveryCodesLeft: RECOVERY_CODE_COUNT,
  });
  assert.equal((await send(app, 'POST', '/api/auth/totp/setup', { password: PASSWORD }, cookie)).status, 409);
  assert.ok((await auditActions(app, cookie)).includes('totp_enabled'));
});

test('with TOTP on, the password alone is a 401 asking for the code, with no session', async () => {
  const { app, db, clock } = fixture();
  const cookie = await setUp(app);
  const { secret } = await enrol(app, cookie, clock);
  const before = db.select().from(sessions).all().length;

  const half = await login(app, { password: PASSWORD });
  assert.equal(half.status, 401);
  assert.equal(((await half.json()) as { totpRequired?: boolean }).totpRequired, true);
  assert.equal(half.headers.get('set-cookie'), null);
  assert.equal(db.select().from(sessions).all().length, before);

  const wrongPassword = await login(app, { password: 'not-it', totp: hotp(secret, totpStep(clock.now) + 1) });
  assert.equal(wrongPassword.status, 401);
  assert.equal(((await wrongPassword.json()) as { totpRequired?: boolean }).totpRequired, undefined, 'says nothing about TOTP');

  clock.now += TOTP_STEP_MS;
  const full = await login(app, { password: PASSWORD, totp: hotp(secret, totpStep(clock.now)) });
  assert.equal(full.status, 200);
  cookieOf(full);
});

test('a TOTP step is accepted once: the confirm code and a used login code are both refused again', async () => {
  const { app, clock } = fixture();
  const cookie = await setUp(app);
  const { secret } = await enrol(app, cookie, clock);
  const confirmCode = hotp(secret, totpStep(clock.now));
  assert.equal((await login(app, { password: PASSWORD, totp: confirmCode })).status, 401, 'the confirm code replayed');

  const next = hotp(secret, totpStep(clock.now) + 1);
  assert.equal((await login(app, { password: PASSWORD, totp: next })).status, 200, 'the next step, within the window');
  assert.equal((await login(app, { password: PASSWORD, totp: next })).status, 401, 'the same step again');
  clock.now += 2 * TOTP_STEP_MS;
  assert.equal((await login(app, { password: PASSWORD, totp: hotp(secret, totpStep(clock.now)) })).status, 200);
});

test('a recovery code logs in once and is spent', async () => {
  const { app, clock } = fixture();
  const cookie = await setUp(app);
  const { codes } = await enrol(app, cookie, clock);
  const code = codes[3] as string;

  const used = await login(app, { password: PASSWORD, recoveryCode: ` ${code.toUpperCase().replace(/-/g, ' ')} ` });
  assert.equal(used.status, 200, 'case, dashes and spaces do not matter');
  assert.equal((await login(app, { password: PASSWORD, recoveryCode: code })).status, 401, 'spent');
  const status = (await (await send(app, 'GET', '/api/auth/totp', undefined, cookie)).json()) as TotpStatus;
  assert.equal(status.recoveryCodesLeft, RECOVERY_CODE_COUNT - 1);

  const res = await send(app, 'GET', '/api/audit?limit=200', undefined, cookie);
  const events = (await res.json()) as AuditEvent[];
  const spent = events.find((event) => event.action === 'recovery_code_used');
  assert.deepEqual(spent?.detail, { left: RECOVERY_CODE_COUNT - 1 });
  assert.ok(!JSON.stringify(events).includes(code));
  assert.ok(events.some((event) => event.action === 'login' && event.detail?.['method'] === 'recovery'));
});

test('wrong TOTP codes and wrong recovery codes both count toward the backoff', async () => {
  const loginGuard = createLoginGuard({ freeFailures: 2, baseMs: 60_000 });
  const { app, clock } = fixture({ loginGuard });
  const cookie = await setUp(app);
  const { secret } = await enrol(app, cookie, clock);
  await login(app, { password: PASSWORD, totp: '000000' });
  await login(app, { password: PASSWORD, recoveryCode: 'aaaa-bbbb-cccc-dddd' });
  await login(app, { password: PASSWORD, totp: '111111' });
  const refused = await login(app, { password: PASSWORD, totp: hotp(secret, totpStep(clock.now) + 1) });
  assert.equal(refused.status, 429);
});

test('turning TOTP off takes the password plus a code or a recovery code', async () => {
  const { app, db, clock } = fixture();
  const cookie = await setUp(app);
  const { secret, codes } = await enrol(app, cookie, clock);
  const next = hotp(secret, totpStep(clock.now) + 1);

  assert.equal((await send(app, 'DELETE', '/api/auth/totp', { password: PASSWORD }, cookie)).status, 403, 'no code');
  assert.equal((await send(app, 'DELETE', '/api/auth/totp', { password: 'not-it', code: next }, cookie)).status, 403);
  assert.equal(db.select().from(owner).get()?.totpSecret !== null, true, 'still on');

  assert.equal((await send(app, 'DELETE', '/api/auth/totp', { password: PASSWORD, recoveryCode: codes[0] }, cookie)).status, 200);
  assert.deepEqual((await (await send(app, 'GET', '/api/auth/totp', undefined, cookie)).json()) as TotpStatus, {
    enabled: false,
    pending: false,
    recoveryCodesLeft: 0,
  });
  assert.equal((await login(app, { password: PASSWORD })).status, 200);
  assert.equal((await send(app, 'DELETE', '/api/auth/totp', { password: PASSWORD, code: next }, cookie)).status, 409);
  assert.ok((await auditActions(app, cookie)).includes('totp_disabled'));
});

test('the audit log records auth events and owner writes, newest first, paged, with names and never values', async () => {
  const { app, clock } = fixture();
  const cookie = await setUp(app);
  clock.now += 1000;
  await login(app, { password: 'not-it' });
  await login(app, { password: PASSWORD });
  const apiKey = 'sk-live-must-not-be-logged';
  assert.equal(
    (await send(app, 'PUT', '/api/settings', { baseUrl: 'http://127.0.0.1:9/v1', apiKey }, cookie)).status,
    200,
  );
  assert.equal((await send(app, 'PUT', '/api/settings', { baseUrl: 'not a url' }, cookie)).status, 400);
  const provider = await send(app, 'POST', '/api/providers', { name: 'p', baseUrl: 'http://127.0.0.1:9/v1', apiKey }, cookie);
  assert.equal(provider.status, 201);
  const providerId = ((await provider.json()) as { id: number }).id;
  assert.equal((await send(app, 'POST', '/api/models', { name: 'm', model: 'x', providerId }, cookie)).status, 201);
  await send(app, 'GET', '/api/settings', undefined, cookie);
  await send(app, 'POST', '/api/auth/logout', {}, cookie);

  const reader = cookieOf(await login(app, { password: PASSWORD }));
  const page = (await (await send(app, 'GET', '/api/audit?limit=200', undefined, reader)).json()) as AuditEvent[];
  assert.deepEqual(
    page.map((event) => event.action),
    ['login', 'logout', 'model_changed', 'provider_changed', 'settings_changed', 'login', 'login_failed', 'setup'],
    'the failed write and the reads are not recorded',
  );
  assert.ok(!JSON.stringify(page).includes(apiKey), 'a value reached the audit log');
  const settings = page.find((event) => event.action === 'settings_changed');
  assert.deepEqual(settings?.detail, { method: 'PUT', path: '/api/settings', fields: ['baseUrl', 'apiKey'] });
  assert.deepEqual(page.find((event) => event.action === 'login_failed')?.detail, { reason: 'password' });
  assert.equal(page.at(-1)?.at, START);
  assert.equal(page[0]?.userAgent, 'test-client');

  const first = (await (await send(app, 'GET', '/api/audit?limit=3', undefined, reader)).json()) as AuditEvent[];
  assert.deepEqual(first.map((event) => event.id), page.slice(0, 3).map((event) => event.id));
  const second = (await (await send(app, 'GET', `/api/audit?limit=3&before=${first.at(-1)?.id}`, undefined, reader)).json()) as AuditEvent[];
  assert.deepEqual(second.map((event) => event.id), page.slice(3, 6).map((event) => event.id));
  for (const query of ['limit=0', `limit=${AUDIT_KEEP_ROWS}`, 'before=abc', 'before=-1']) {
    assert.equal((await send(app, 'GET', `/api/audit?${query}`, undefined, reader)).status, 400, query);
  }
});

test('the audit log is bounded by row count and by age', () => {
  const { db } = fixture();
  const origin = { ip: '203.0.113.7', userAgent: undefined };
  const count = () => db.select().from(auditEvents).all().length;
  for (let i = 0; i < AUDIT_KEEP_ROWS + 25; i += 1) recordAudit(db, origin, 'login', undefined, START);
  assert.equal(count(), AUDIT_KEEP_ROWS);
  recordAudit(db, origin, 'logout', undefined, START + AUDIT_KEEP_MS + 1);
  assert.equal(count(), 1, 'everything past the age bound went');
});
