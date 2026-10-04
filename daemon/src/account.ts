import { createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { and, count, desc, eq, isNull, lt, lte, ne, or } from 'drizzle-orm';
import type { AuditAction, AuditEvent, SessionEntry, TotpSetup, TotpStatus } from '@schermes/shared';
import type { Db } from './db.ts';
import { hashPassword } from './auth.ts';
import { auditEvents, owner, recoveryCodes, sessions } from './schema.ts';
import { decrypt, encrypt } from './secrets.ts';

export const TOTP_STEP_MS = 30_000;
export const TOTP_DIGITS = 6;
const TOTP_SECRET_BYTES = 20;
const TOTP_ISSUER = 'schermes';
export const RECOVERY_CODE_COUNT = 10;
const RECOVERY_CODE_BYTES = 10;
const HANDLE_CHARS = 16;

export const AUDIT_KEEP_ROWS = 10_000;
export const AUDIT_KEEP_MS = 90 * 24 * 60 * 60 * 1000;
export const AUDIT_PAGE_MAX = 200;
const MAX_USER_AGENT_CHARS = 300;

const BASE32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

export function base32Encode(bytes: Buffer): string {
  let bits = 0;
  let value = 0;
  let out = '';
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += BASE32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += BASE32[(value << (5 - bits)) & 31];
  return out;
}

export function base32Decode(text: string): Buffer {
  let bits = 0;
  let value = 0;
  const out: number[] = [];
  for (const char of text.toUpperCase().replace(/[\s=-]/g, '')) {
    const index = BASE32.indexOf(char);
    if (index === -1) throw new Error(`not base32: ${char}`);
    value = (value << 5) | index;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 255);
      bits -= 8;
    }
  }
  return Buffer.from(out);
}

/** RFC 4226 HOTP with HMAC-SHA-1, which is what RFC 6238 and every authenticator default to. */
export function hotp(secret: Buffer, counter: number, digits = TOTP_DIGITS): string {
  const message = Buffer.alloc(8);
  message.writeBigUInt64BE(BigInt(counter));
  const mac = createHmac('sha1', secret).update(message).digest();
  const offset = (mac[mac.length - 1] as number) & 0x0f;
  const binary = mac.readUInt32BE(offset) & 0x7fffffff;
  return String(binary % 10 ** digits).padStart(digits, '0');
}

export function totpStep(now: number): number {
  return Math.floor(now / TOTP_STEP_MS);
}

/** The step in now ±1 that `code` is for, so a phone clock 30 s off still works. */
export function matchingStep(secret: Buffer, code: string, now: number): number | undefined {
  const given = Buffer.from(code.replace(/\s/g, ''));
  if (given.length !== TOTP_DIGITS) return undefined;
  const current = totpStep(now);
  let found: number | undefined;
  for (const step of [current - 1, current, current + 1]) {
    if (timingSafeEqual(given, Buffer.from(hotp(secret, step)))) found ??= step;
  }
  return found;
}

export function otpauthUri(secret: string): string {
  const label = encodeURIComponent(`${TOTP_ISSUER}:owner`);
  return `otpauth://totp/${label}?secret=${secret}&issuer=${TOTP_ISSUER}&algorithm=SHA1&digits=${TOTP_DIGITS}&period=${TOTP_STEP_MS / 1000}`;
}

function ownerRow(db: Db) {
  return db.select().from(owner).where(eq(owner.id, 1)).get();
}

export function totpEnabled(db: Db): boolean {
  return ownerRow(db)?.totpSecret != null;
}

export function totpStatus(db: Db): TotpStatus {
  const row = ownerRow(db);
  return {
    enabled: row?.totpSecret != null,
    pending: row?.totpPending != null,
    recoveryCodesLeft: db.select({ n: count() }).from(recoveryCodes).get()?.n ?? 0,
  };
}

/** A fresh secret, held pending until a code from it is confirmed. A second call replaces it. */
export function beginTotp(db: Db, masterKey: Buffer): TotpSetup {
  const secret = base32Encode(randomBytes(TOTP_SECRET_BYTES));
  db.update(owner).set({ totpPending: encrypt(masterKey, secret) }).where(eq(owner.id, 1)).run();
  return { secret, uri: otpauthUri(secret) };
}

/** Atomic, so two requests carrying the same code cannot both get in. */
function spendStep(db: Db, step: number): boolean {
  return (
    db
      .update(owner)
      .set({ totpLastStep: step })
      .where(and(eq(owner.id, 1), or(isNull(owner.totpLastStep), lt(owner.totpLastStep, step))))
      .run().changes > 0
  );
}

function acceptCode(db: Db, masterKey: Buffer, sealed: string, code: string, now: number): boolean {
  const step = matchingStep(base32Decode(decrypt(masterKey, sealed)), code, now);
  return step !== undefined && spendStep(db, step);
}

/** Turns the pending secret on, and returns the recovery codes that replace any earlier ones. */
export function confirmTotp(db: Db, masterKey: Buffer, code: string, now: number): string[] | undefined {
  const pending = ownerRow(db)?.totpPending;
  if (pending == null || !acceptCode(db, masterKey, pending, code, now)) return undefined;
  db.update(owner).set({ totpSecret: pending, totpPending: null }).where(eq(owner.id, 1)).run();
  return replaceRecoveryCodes(db, now);
}

export function disableTotp(db: Db): void {
  db.update(owner).set({ totpSecret: null, totpPending: null, totpLastStep: null }).where(eq(owner.id, 1)).run();
  db.delete(recoveryCodes).run();
}

export type SecondFactor = { totp?: string | undefined; recoveryCode?: string | undefined };

/** Which factor got the owner in, spending it, or undefined when neither did. */
export function checkSecondFactor(
  db: Db,
  masterKey: Buffer,
  { totp, recoveryCode }: SecondFactor,
  now: number,
): 'totp' | 'recovery' | undefined {
  const secret = ownerRow(db)?.totpSecret;
  if (secret == null) return undefined;
  if (totp !== undefined && totp !== '' && acceptCode(db, masterKey, secret, totp, now)) return 'totp';
  if (recoveryCode !== undefined && recoveryCode !== '' && spendRecoveryCode(db, recoveryCode)) return 'recovery';
  return undefined;
}

function normaliseRecoveryCode(code: string): string {
  return code.toLowerCase().replace(/[\s-]/g, '');
}

function hashRecoveryCode(code: string): string {
  return createHash('sha256').update(normaliseRecoveryCode(code)).digest('hex');
}

function replaceRecoveryCodes(db: Db, now: number): string[] {
  const codes = Array.from({ length: RECOVERY_CODE_COUNT }, () =>
    (base32Encode(randomBytes(RECOVERY_CODE_BYTES)).toLowerCase().match(/.{4}/g) ?? []).join('-'),
  );
  db.transaction((tx) => {
    tx.delete(recoveryCodes).run();
    tx.insert(recoveryCodes)
      .values(codes.map((code) => ({ hash: hashRecoveryCode(code), createdAt: now })))
      .run();
  });
  return codes;
}

function spendRecoveryCode(db: Db, code: string): boolean {
  return db.delete(recoveryCodes).where(eq(recoveryCodes.hash, hashRecoveryCode(code))).run().changes > 0;
}

/** A prefix of the id's hash: enough to name a session, useless as a cookie. */
export function sessionHandle(id: string): string {
  return createHash('sha256').update(id).digest('base64url').slice(0, HANDLE_CHARS);
}

export function listSessions(db: Db, currentId: string | undefined, now: number): SessionEntry[] {
  return db
    .select()
    .from(sessions)
    .all()
    .filter((row) => row.expiresAt > now)
    .map((row) => ({
      handle: sessionHandle(row.id),
      createdAt: row.createdAt,
      lastSeenAt: row.lastSeenAt,
      userAgent: row.userAgent,
      current: row.id === currentId,
    }))
    .sort((a, b) => (b.lastSeenAt ?? b.createdAt) - (a.lastSeenAt ?? a.createdAt));
}

export function sessionByHandle(db: Db, handle: string): string | undefined {
  return db
    .select({ id: sessions.id })
    .from(sessions)
    .all()
    .find((row) => sessionHandle(row.id) === handle)?.id;
}

export function revokeSession(db: Db, id: string): void {
  db.delete(sessions).where(eq(sessions.id, id)).run();
}

/** Sets the new hash and signs out every session but `keepId`, returning how many went. */
export async function changePassword(db: Db, next: string, keepId: string): Promise<number> {
  const passwordHash = await hashPassword(next);
  return db.transaction((tx) => {
    tx.update(owner).set({ passwordHash }).where(eq(owner.id, 1)).run();
    return tx.delete(sessions).where(ne(sessions.id, keepId)).run().changes;
  });
}

export type AuditOrigin = { ip: string; userAgent: string | undefined };

/** Bounded on every write: past AUDIT_KEEP_ROWS rows or AUDIT_KEEP_MS old, the oldest go. */
export function recordAudit(
  db: Db,
  origin: AuditOrigin,
  action: AuditAction,
  detail: Record<string, unknown> | undefined,
  now: number,
): void {
  const { id } = db
    .insert(auditEvents)
    .values({
      at: now,
      action,
      ip: origin.ip,
      userAgent: origin.userAgent?.slice(0, MAX_USER_AGENT_CHARS) ?? null,
      detail: detail === undefined ? null : JSON.stringify(detail),
    })
    .returning({ id: auditEvents.id })
    .get();
  db.delete(auditEvents)
    .where(or(lte(auditEvents.id, id - AUDIT_KEEP_ROWS), lt(auditEvents.at, now - AUDIT_KEEP_MS)))
    .run();
}

/** Newest first; `before` is the id of the oldest row the reader already has. */
export function listAudit(db: Db, before: number | undefined, limit: number): AuditEvent[] {
  return db
    .select()
    .from(auditEvents)
    .where(before === undefined ? undefined : lt(auditEvents.id, before))
    .orderBy(desc(auditEvents.id))
    .limit(limit)
    .all()
    .map((row) => ({
      id: row.id,
      at: row.at,
      action: row.action as AuditAction,
      ip: row.ip,
      userAgent: row.userAgent,
      detail: row.detail === null ? null : (JSON.parse(row.detail) as Record<string, unknown>),
    }));
}
