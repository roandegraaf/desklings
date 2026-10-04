import { randomBytes, scrypt, timingSafeEqual } from 'node:crypto';
import type { ScryptOptions } from 'node:crypto';
import { eq, lte } from 'drizzle-orm';
import { deleteCookie, setCookie } from 'hono/cookie';
import type { Context } from 'hono';
import type { Db } from './db.ts';
import { owner, sessions } from './schema.ts';

// N=16384 keeps scrypt inside Node's default 32 MiB maxmem; anything larger throws.
const SCRYPT = { N: 16384, r: 8, p: 1 } as const;
const KEY_BYTES = 32;
const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const LAST_SEEN_RESOLUTION_MS = 60_000;
const MAX_USER_AGENT_CHARS = 300;

export const SESSION_COOKIE = 'schermes_session';

function derive(password: string, salt: Buffer, options: ScryptOptions): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    scrypt(password, salt, KEY_BYTES, options, (error, key) => (error ? reject(error) : resolve(key)));
  });
}

export async function hashPassword(password: string): Promise<string> {
  const salt = randomBytes(16);
  const hash = await derive(password, salt, SCRYPT);
  return ['scrypt', SCRYPT.N, SCRYPT.r, SCRYPT.p, salt.toString('base64'), hash.toString('base64')].join('$');
}

export async function verifyPassword(password: string, stored: string): Promise<boolean> {
  const parts = stored.split('$');
  if (parts.length !== 6) return false;
  const [tag, n, r, p, salt, hash] = parts;
  if (tag !== 'scrypt' || !n || !r || !p || !salt || !hash) return false;
  const expected = Buffer.from(hash, 'base64');
  if (expected.length !== KEY_BYTES) return false;
  const actual = await derive(password, Buffer.from(salt, 'base64'), { N: Number(n), r: Number(r), p: Number(p) });
  return timingSafeEqual(expected, actual);
}

export function ownerExists(db: Db): boolean {
  return db.select().from(owner).where(eq(owner.id, 1)).get() !== undefined;
}

/** Returns false if the password was already set, so setup cannot double as a reset. */
export async function claimOwner(db: Db, password: string): Promise<boolean> {
  const passwordHash = await hashPassword(password);
  const result = db.insert(owner).values({ id: 1, passwordHash, createdAt: Date.now() }).onConflictDoNothing().run();
  return result.changes > 0;
}

export async function checkPassword(db: Db, password: string): Promise<boolean> {
  const row = db.select().from(owner).where(eq(owner.id, 1)).get();
  return row !== undefined && (await verifyPassword(password, row.passwordHash));
}

export function newSetupToken(): string {
  return randomBytes(24).toString('base64url');
}

export function tokenMatches(given: string, expected: string): boolean {
  const a = Buffer.from(given);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

export function sessionValid(db: Db, id: string): boolean {
  const row = db.select().from(sessions).where(eq(sessions.id, id)).get();
  if (row === undefined) return false;
  const now = Date.now();
  if (row.expiresAt <= now) {
    db.delete(sessions).where(eq(sessions.id, id)).run();
    return false;
  }
  if (row.lastSeenAt === null || now - row.lastSeenAt >= LAST_SEEN_RESOLUTION_MS) {
    db.update(sessions).set({ lastSeenAt: now }).where(eq(sessions.id, id)).run();
  }
  return true;
}

/**
 * TLS terminates in a proxy in front of schermes, so the proxy's `X-Forwarded-Proto` is what
 * says so. It is trusted from anyone: a forged `https` only makes the forger's own cookie
 * Secure, which their plain-HTTP client then drops.
 */
export function cameOverTls(c: Context): boolean {
  const forwarded = c.req.header('x-forwarded-proto')?.split(',')[0]?.trim().toLowerCase();
  return forwarded === 'https' || new URL(c.req.url).protocol === 'https:';
}

export function issueSession(c: Context, db: Db): void {
  const id = randomBytes(32).toString('base64url');
  const now = Date.now();
  const expiresAt = now + SESSION_TTL_MS;
  db.delete(sessions).where(lte(sessions.expiresAt, now)).run();
  db.insert(sessions)
    .values({
      id,
      createdAt: now,
      expiresAt,
      lastSeenAt: now,
      userAgent: c.req.header('user-agent')?.slice(0, MAX_USER_AGENT_CHARS) ?? null,
    })
    .run();
  setCookie(c, SESSION_COOKIE, id, {
    httpOnly: true,
    sameSite: 'Lax',
    path: '/',
    expires: new Date(expiresAt),
    secure: cameOverTls(c),
  });
}

export function dropSession(c: Context, db: Db, id: string | undefined): void {
  if (id !== undefined) db.delete(sessions).where(eq(sessions.id, id)).run();
  deleteCookie(c, SESSION_COOKIE, { path: '/', httpOnly: true, sameSite: 'Lax', secure: cameOverTls(c) });
}

type IncomingEnv = { incoming?: { socket?: { remoteAddress?: string } } } | undefined;

const LOOPBACK = /^(127\.\d+\.\d+\.\d+|::1)$/;

/**
 * The peer address, or the proxy's rightmost `X-Forwarded-For` entry when the peer is loopback.
 * From anywhere else the header is ignored: a remote caller could otherwise name a fresh
 * address per attempt and never back off.
 */
export function clientIp(c: Context): string {
  const peer = (c.env as IncomingEnv)?.incoming?.socket?.remoteAddress?.replace(/^::ffff:/, '');
  if (peer === undefined) return 'unknown';
  if (!LOOPBACK.test(peer)) return peer;
  const forwarded = c.req.header('x-forwarded-for')?.split(',').at(-1)?.trim();
  return forwarded === undefined || forwarded === '' ? peer : forwarded;
}

export type LoginGuardOptions = {
  freeFailures?: number;
  baseMs?: number;
  capMs?: number;
  maxEntries?: number;
  now?: () => number;
};

type Strikes = { failures: number; until: number };

/**
 * Failed password and setup attempts per address, in memory. After `freeFailures` misses each
 * further one locks the address out for `baseMs`, doubling, up to `capMs`; a success clears it.
 * Bounded: past `maxEntries` the least recently failed address is forgotten.
 */
export function createLoginGuard({
  freeFailures = 5,
  baseMs = 1000,
  capMs = 5 * 60_000,
  maxEntries = 10_000,
  now = Date.now,
}: LoginGuardOptions = {}) {
  const strikes = new Map<string, Strikes>();
  return {
    /** Seconds until the address may try again, or 0 when it may now. */
    retryAfter(ip: string): number {
      const entry = strikes.get(ip);
      if (entry === undefined) return 0;
      const wait = entry.until - now();
      return wait > 0 ? Math.ceil(wait / 1000) : 0;
    },
    fail(ip: string): void {
      const failures = (strikes.get(ip)?.failures ?? 0) + 1;
      const over = failures - freeFailures;
      const until = over > 0 ? now() + Math.min(capMs, baseMs * 2 ** (over - 1)) : 0;
      strikes.delete(ip);
      strikes.set(ip, { failures, until });
      if (strikes.size > maxEntries) strikes.delete(strikes.keys().next().value as string);
    },
    succeed(ip: string): void {
      strikes.delete(ip);
    },
    size: () => strikes.size,
  };
}

export type LoginGuard = ReturnType<typeof createLoginGuard>;
