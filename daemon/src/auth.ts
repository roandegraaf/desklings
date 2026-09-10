import { randomBytes, scryptSync, timingSafeEqual } from 'node:crypto';
import { eq } from 'drizzle-orm';
import { setCookie } from 'hono/cookie';
import type { Context } from 'hono';
import type { Db } from './db.ts';
import { owner, sessions } from './schema.ts';

// N=16384 keeps scrypt inside Node's default 32 MiB maxmem; anything larger throws.
const SCRYPT = { N: 16384, r: 8, p: 1 } as const;
const KEY_BYTES = 32;
const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;

export const SESSION_COOKIE = 'schermes_session';

export function hashPassword(password: string): string {
  const salt = randomBytes(16);
  const hash = scryptSync(password, salt, KEY_BYTES, SCRYPT);
  return ['scrypt', SCRYPT.N, SCRYPT.r, SCRYPT.p, salt.toString('base64'), hash.toString('base64')].join('$');
}

export function verifyPassword(password: string, stored: string): boolean {
  const parts = stored.split('$');
  if (parts.length !== 6) return false;
  const [tag, n, r, p, salt, hash] = parts;
  if (tag !== 'scrypt' || !n || !r || !p || !salt || !hash) return false;
  const expected = Buffer.from(hash, 'base64');
  if (expected.length !== KEY_BYTES) return false;
  const actual = scryptSync(password, Buffer.from(salt, 'base64'), KEY_BYTES, {
    N: Number(n),
    r: Number(r),
    p: Number(p),
  });
  return timingSafeEqual(expected, actual);
}

export function ownerExists(db: Db): boolean {
  return db.select().from(owner).where(eq(owner.id, 1)).get() !== undefined;
}

/** Returns false if the password was already set, so setup cannot double as a reset. */
export function claimOwner(db: Db, password: string): boolean {
  const result = db
    .insert(owner)
    .values({ id: 1, passwordHash: hashPassword(password), createdAt: Date.now() })
    .onConflictDoNothing()
    .run();
  return result.changes > 0;
}

export function checkPassword(db: Db, password: string): boolean {
  const row = db.select().from(owner).where(eq(owner.id, 1)).get();
  return row !== undefined && verifyPassword(password, row.passwordHash);
}

export function sessionValid(db: Db, id: string): boolean {
  const row = db.select().from(sessions).where(eq(sessions.id, id)).get();
  if (row === undefined) return false;
  if (row.expiresAt <= Date.now()) {
    db.delete(sessions).where(eq(sessions.id, id)).run();
    return false;
  }
  return true;
}

export function issueSession(c: Context, db: Db): void {
  const id = randomBytes(32).toString('base64url');
  const now = Date.now();
  const expiresAt = now + SESSION_TTL_MS;
  db.insert(sessions).values({ id, createdAt: now, expiresAt }).run();
  setCookie(c, SESSION_COOKIE, id, {
    httpOnly: true,
    sameSite: 'Lax',
    path: '/',
    expires: new Date(expiresAt),
    // Deliberately not `secure`: schermes speaks plain HTTP and TLS terminates in a proxy
    // in front of it. A Secure cookie would be dropped and login would silently fail.
  });
}

export function dropSession(db: Db, id: string): void {
  db.delete(sessions).where(eq(sessions.id, id)).run();
}
