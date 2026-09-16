import { createPrivateKey, sign } from 'node:crypto';
import { connect } from 'node:http2';
import { eq } from 'drizzle-orm';
import type { Device } from '@schermes/shared';
import type { Db } from './db.ts';
import { log } from './log.ts';
import { devices } from './schema.ts';
import type { PushConfig } from './settings.ts';

/** APNs refuses a provider token older than an hour; a fresh one is minted before that. */
export const APNS_TOKEN_TTL_MS = 50 * 60 * 1000;
/** What fits on a lock screen. The thread has the rest. */
export const MAX_PUSH_BODY_CHARS = 200;
const REQUEST_TIMEOUT_MS = 10_000;

export type PushNotification = {
  title: string;
  body: string;
  /** Groups the phone's notifications per agent. */
  agent?: string;
  conversationId?: number;
};

export type PushResponse = { status: number; body: string };

/** One request to APNs: the seam a test replaces so no socket is opened. */
export type PushSend = (
  host: string,
  headers: Record<string, string>,
  body: string,
) => Promise<PushResponse>;

export type PushDeps = {
  db: Db;
  config: PushConfig;
  send?: PushSend;
};

const base64url = (data: string | Buffer): string => Buffer.from(data).toString('base64url');

let cached: { token: string; keyId: string; teamId: string; key: string; at: number } | undefined;

/** The ES256 provider token, minted at most once per `APNS_TOKEN_TTL_MS` for the same key. */
export function providerToken(config: PushConfig, now = Date.now()): string {
  if (
    cached !== undefined &&
    cached.keyId === config.keyId &&
    cached.teamId === config.teamId &&
    cached.key === config.key &&
    now - cached.at < APNS_TOKEN_TTL_MS
  ) {
    return cached.token;
  }
  const header = base64url(JSON.stringify({ alg: 'ES256', kid: config.keyId }));
  const claims = base64url(JSON.stringify({ iss: config.teamId, iat: Math.floor(now / 1000) }));
  const signature = sign('sha256', Buffer.from(`${header}.${claims}`), {
    key: createPrivateKey(config.key),
    dsaEncoding: 'ieee-p1363',
  });
  const token = `${header}.${claims}.${base64url(signature)}`;
  cached = { token, keyId: config.keyId, teamId: config.teamId, key: config.key, at: now };
  return token;
}

export function apnsHost(config: PushConfig): string {
  return config.sandbox ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
}

export function listDevices(db: Db): Device[] {
  return db
    .select()
    .from(devices)
    .all()
    .map((row) => ({ token: row.token, platform: row.platform as Device['platform'], createdAt: row.createdAt }));
}

export function upsertDevice(db: Db, token: string, platform: Device['platform']): void {
  db.insert(devices)
    .values({ token, platform, createdAt: Date.now() })
    .onConflictDoUpdate({ target: devices.token, set: { platform } })
    .run();
}

export function deleteDevice(db: Db, token: string): boolean {
  return db.delete(devices).where(eq(devices.token, token)).run().changes > 0;
}

/** One http2 session per batch, closed after; undici's fetch cannot speak HTTP/2 and APNs
 * speaks nothing else. */
function sessionSend(host: string): { send: PushSend; close: () => void } {
  const session = connect(`https://${host}`);
  // An unheard 'error' on the session is thrown, and a push is not worth the daemon: the
  // streams it cancels reject their own requests.
  session.on('error', (error) => log.error('apns connection failed', { error }));
  const send: PushSend = (_host, headers, body) =>
    new Promise((resolve, reject) => {
      const stream = session.request(headers);
      const chunks: Buffer[] = [];
      let status = 0;
      stream.setTimeout(REQUEST_TIMEOUT_MS, () => stream.destroy(new Error('apns request timed out')));
      stream.on('response', (received) => {
        status = Number(received[':status'] ?? 0);
      });
      stream.on('data', (chunk: Buffer) => chunks.push(chunk));
      stream.on('error', reject);
      stream.on('end', () => resolve({ status, body: Buffer.concat(chunks).toString() }));
      stream.end(body);
    });
  return { send, close: () => session.close() };
}

// Not a 400 BadDeviceToken: Apple also answers that for a token pushed to the other gateway,
// which is a sandbox toggle away from working, not a device that is gone.
function unregistered(response: PushResponse): boolean {
  return response.status === 410;
}

/**
 * The notification to every registered device. A token Apple says is gone is dropped; any
 * other failure is a log line, because a push is a nudge and the thread holds the truth.
 */
export async function sendPush(deps: PushDeps, notification: PushNotification): Promise<{ sent: number; error?: string }> {
  const targets = listDevices(deps.db);
  if (targets.length === 0) return { sent: 0 };
  const host = apnsHost(deps.config);
  const payload = JSON.stringify({
    aps: {
      alert: { title: notification.title, body: notification.body.slice(0, MAX_PUSH_BODY_CHARS) },
      sound: 'default',
      'thread-id': notification.agent ?? 'schermes',
    },
    ...(notification.agent === undefined ? {} : { agent: notification.agent }),
    ...(notification.conversationId === undefined ? {} : { conversationId: notification.conversationId }),
  });
  let token: string;
  try {
    token = providerToken(deps.config);
  } catch (caught) {
    log.error('push key could not sign', { error: caught });
    return { sent: 0, error: `the push key could not sign: ${caught instanceof Error ? caught.message : String(caught)}` };
  }
  const session = deps.send === undefined ? sessionSend(host) : undefined;
  const send = deps.send ?? (session as { send: PushSend }).send;
  let sent = 0;
  let error: string | undefined;
  try {
    for (const device of targets) {
      const headers = {
        ':method': 'POST',
        ':path': `/3/device/${device.token}`,
        authorization: `bearer ${token}`,
        'apns-topic': deps.config.bundleId,
        'apns-push-type': 'alert',
        'apns-priority': '10',
        'apns-expiration': '0',
        'content-type': 'application/json',
      };
      try {
        const response = await send(host, headers, payload);
        if (response.status === 200) {
          sent += 1;
        } else if (unregistered(response)) {
          deleteDevice(deps.db, device.token);
          log.info('push device dropped', { platform: device.platform, status: response.status });
        } else {
          error = `apns answered ${response.status}: ${response.body.slice(0, 200)}`;
          log.error('push failed', { platform: device.platform, status: response.status, body: response.body.slice(0, 200) });
        }
      } catch (caught) {
        error = caught instanceof Error ? caught.message : String(caught);
        log.error('push failed', { platform: device.platform, error: caught });
      }
    }
  } finally {
    session?.close();
  }
  return { sent, ...(error === undefined ? {} : { error }) };
}
