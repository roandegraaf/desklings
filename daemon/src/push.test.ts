import assert from 'node:assert/strict';
import { generateKeyPairSync, verify } from 'node:crypto';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { test } from 'node:test';
import { openDb } from './db.ts';
import { APNS_TOKEN_TTL_MS, listDevices, providerToken, sendPush, upsertDevice } from './push.ts';
import type { PushSend } from './push.ts';
import { pushConfig, readPushSettings, seedPushKey } from './settings.ts';
import { activityAttributes, activityPayload } from './liveactivity.ts';
import type { Agent, LiveActivityState } from '@schermes/shared';

const MIGRATIONS = resolve(import.meta.dirname, '../migrations');
const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const pem = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
const config = { keyId: 'KEY123', teamId: 'TEAM456', bundleId: 'dev.schermes.Schermes', key: pem, sandbox: true };

test('the provider token is ES256 over the key id and team, and is reused until it ages out', () => {
  const token = providerToken(config, 1_000_000);
  const [header, claims, signature] = token.split('.') as [string, string, string];
  assert.deepEqual(JSON.parse(Buffer.from(header, 'base64url').toString()), { alg: 'ES256', kid: 'KEY123' });
  assert.deepEqual(JSON.parse(Buffer.from(claims, 'base64url').toString()), { iss: 'TEAM456', iat: 1000 });
  assert.ok(
    verify('sha256', Buffer.from(`${header}.${claims}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(signature, 'base64url')),
  );
  assert.equal(providerToken(config, 1_000_000 + APNS_TOKEN_TTL_MS - 1), token, 'cached');
  assert.notEqual(providerToken(config, 1_000_000 + APNS_TOKEN_TTL_MS + 1), token, 'minted again');
});

test('a push reaches every device with the apns headers and payload, and a dead token is dropped', async () => {
  const db = openDb(':memory:', MIGRATIONS);
  upsertDevice(db, 'aa'.repeat(32), 'ios');
  upsertDevice(db, 'bb'.repeat(32), 'macos');
  upsertDevice(db, 'aa'.repeat(32), 'ios');
  assert.equal(listDevices(db).length, 2, 'upsert by token');

  const calls: { host: string; headers: Record<string, string>; body: string }[] = [];
  const send: PushSend = (host, headers, body) => {
    calls.push({ host, headers, body });
    return Promise.resolve(
      headers[':path']?.includes('bb') ? { status: 410, body: '{"reason":"Unregistered"}' } : { status: 200, body: '' },
    );
  };
  const result = await sendPush({ db, config, send }, { title: 'Al', body: 'x'.repeat(300), agent: 'alpha', conversationId: 7 });

  assert.deepEqual(result, { sent: 1 });
  assert.equal(calls.length, 2);
  assert.equal(calls[0]?.host, 'api.sandbox.push.apple.com');
  const headers = calls[0]?.headers ?? {};
  assert.equal(headers[':method'], 'POST');
  assert.equal(headers[':path'], `/3/device/${'aa'.repeat(32)}`);
  assert.match(headers['authorization'] ?? '', /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  assert.equal(headers['apns-topic'], 'dev.schermes.Schermes');
  assert.equal(headers['apns-push-type'], 'alert');
  assert.equal(headers['apns-priority'], '10');
  assert.equal(headers['apns-expiration'], '0');
  const payload = JSON.parse(calls[0]?.body ?? '') as { aps: { alert: { title: string; body: string }; 'thread-id': string }; agent: string; conversationId: number };
  assert.equal(payload.aps.alert.title, 'Al');
  assert.equal(payload.aps.alert.body.length, 200, 'clipped for a lock screen');
  assert.equal(payload.aps['thread-id'], 'alpha');
  assert.equal(payload.agent, 'alpha');
  assert.equal(payload.conversationId, 7);
  assert.deepEqual(listDevices(db).map((d) => d.platform), ['ios'], 'the 410 token is gone');

  const failing: PushSend = () => Promise.resolve({ status: 500, body: 'nope' });
  const failed = await sendPush({ db, config, send: failing }, { title: 't', body: 'b' });
  assert.equal(failed.sent, 0);
  assert.match(failed.error ?? '', /500/);
  assert.equal(listDevices(db).length, 1, 'a 500 drops nothing');
});

test('a mounted AuthKey_<KEYID>.p8 is stored at boot with its id read off the name, and an empty mount is nothing', () => {
  const db = openDb(':memory:', MIGRATIONS);
  const masterKey = Buffer.alloc(32, 7);
  const dir = mkdtempSync(join(tmpdir(), 'apns-'));
  const named = join(dir, 'AuthKey_KEY123.p8');
  writeFileSync(named, pem);
  assert.equal(seedPushKey(db, masterKey, named), true);
  assert.deepEqual(readPushSettings(db), { keyId: 'KEY123', teamId: '', bundleId: '', keySet: true, sandbox: false });

  const anonymous = join(dir, 'apns.p8');
  writeFileSync(anonymous, pem);
  assert.throws(() => seedPushKey(db, masterKey, anonymous), /SCHERMES_APNS_KEY_ID/);
  assert.equal(seedPushKey(db, masterKey, anonymous, 'KEY456'), true);
  assert.equal(readPushSettings(db).keyId, 'KEY456');
  assert.equal(pushConfig(db, masterKey), undefined, 'the ids arrive with the first device');

  const empty = join(dir, 'empty.p8');
  writeFileSync(empty, '');
  assert.equal(seedPushKey(db, masterKey, empty), false);
  assert.equal(seedPushKey(db, masterKey, join(dir, 'missing.p8')), false);
  assert.equal(readPushSettings(db).keySet, true, 'a bad mount keeps what is stored');
});

/** Pinned against `LiveActivityTests.swift`, which decodes these very strings: a key the widget
 * does not know is a Live Activity that silently shows nothing. */
const ACTIVITY_STATE_JSON = '{"title":"Ship the site","stepsDone":1,"stepsTotal":3,"needsYou":2,"state":"thinking"}';
const ACTIVITY_ATTRIBUTES_JSON = '{"agent":"alpha","label":"Alpha","look":"cloud:teal"}';

test('a live activity payload carries the content state the widget decodes, and start and end their extras', () => {
  const state = JSON.parse(ACTIVITY_STATE_JSON) as LiveActivityState;
  const attributes = activityAttributes({ name: 'alpha', label: 'Alpha', look: 'cloud:teal' } as Agent);
  assert.equal(JSON.stringify(attributes), ACTIVITY_ATTRIBUTES_JSON);
  assert.equal(JSON.stringify({ title: 'Ship the site', stepsDone: 1, stepsTotal: 3, needsYou: 2, state: 'thinking' } satisfies LiveActivityState), ACTIVITY_STATE_JSON);

  const start = activityPayload({ event: 'start', attributes, state }, 1_700_000_000).aps as Record<string, unknown>;
  assert.equal(JSON.stringify(start['content-state']), ACTIVITY_STATE_JSON);
  assert.deepEqual(start, {
    timestamp: 1_700_000_000,
    event: 'start',
    'content-state': state,
    'attributes-type': 'AgentActivityAttributes',
    attributes,
    'input-push-token': 1,
    alert: { title: 'Alpha', body: 'Ship the site' },
  });
  assert.deepEqual(activityPayload({ event: 'update', state }, 5).aps, { timestamp: 5, event: 'update', 'content-state': state });
  assert.deepEqual(activityPayload({ event: 'end', state, dismissAt: 900 }, 6).aps, {
    timestamp: 6,
    event: 'end',
    'content-state': state,
    'dismissal-date': 900,
  });
  assert.equal(JSON.stringify(activityAttributes({ name: 'beta' } as Agent)), '{"agent":"beta","label":"beta"}');
});
