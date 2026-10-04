import { createHash, randomBytes } from 'node:crypto';
import {
  closeSync,
  fsyncSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
  unlinkSync,
  writeSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import type { Db } from './db.ts';
import { log } from './log.ts';
import type { Image } from './provider.ts';
import { readImageRetentionDays } from './settings.ts';

/**
 * What `messages.image_ref` holds: the picture's bytes live in a file named by their sha256, or
 * they were pruned and only the media type is left. The legacy `messages.image` column held the
 * base64 inline; a row has at most one of the two set.
 */
export type ImageRef =
  | { mediaType: Image['mediaType']; sha256: string }
  | { mediaType: Image['mediaType']; expired: true };

const SHA256 = /^[0-9a-f]{64}$/;
const DAY_MS = 86_400_000;
const MOVE_BATCH = 50;
const PRUNE_EVERY_MS = 60 * 60 * 1000;

const dirs = new WeakMap<Db, string>();
const epochs = new WeakMap<Db, Map<number, number>>();

/** Beside the database file, so production lands on the data volume the sandbox hides. */
export function imageDir(db: Db): string {
  const known = dirs.get(db);
  if (known !== undefined) return known;
  const dir = db.$client.memory ? mkdtempSync(join(tmpdir(), 'schermes-images-')) : join(dirname(db.$client.name), 'images');
  if (db.$client.memory) process.once('exit', () => rmSync(dir, { recursive: true, force: true }));
  dirs.set(db, dir);
  return dir;
}

function filePath(db: Db, sha256: string): string {
  return join(imageDir(db), sha256.slice(0, 2), sha256);
}

/** Bumped whenever a row's picture expires, which changes what its transcript says. */
export function imageEpoch(db: Db, conversationId: number): number {
  return epochs.get(db)?.get(conversationId) ?? 0;
}

function bumpEpoch(db: Db, conversationId: number): void {
  const map = epochs.get(db) ?? new Map<number, number>();
  epochs.set(db, map);
  map.set(conversationId, (map.get(conversationId) ?? 0) + 1);
}

function expiredRef(mediaType: Image['mediaType']): string {
  return JSON.stringify({ mediaType, expired: true } satisfies ImageRef);
}

/**
 * Writes the bytes once per content and returns the `image_ref` naming them. Synchronous on
 * purpose: the caller inserts the row in the same tick, and the file sweep relies on never
 * running between the two.
 */
export function storeImage(db: Db, image: Image): string {
  if (image.expired === true || image.base64 === '') return expiredRef(image.mediaType);
  const bytes = Buffer.from(image.base64, 'base64');
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  const path = filePath(db, sha256);
  if (!fileExists(path)) {
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    const temp = `${path}.${randomBytes(6).toString('hex')}.tmp`;
    const fd = openSync(temp, 'w', 0o600);
    try {
      writeSync(fd, bytes);
      // A rename that reaches the disk before the data would leave a reference to an empty file.
      fsyncSync(fd);
    } finally {
      closeSync(fd);
    }
    renameSync(temp, path);
  }
  return JSON.stringify({ mediaType: image.mediaType, sha256 } satisfies ImageRef);
}

function fileExists(path: string): boolean {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

function parseJson(raw: string): Record<string, unknown> | undefined {
  try {
    const value: unknown = JSON.parse(raw);
    return typeof value === 'object' && value !== null ? (value as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}

function mediaTypeOf(value: unknown): Image['mediaType'] {
  return value === 'image/jpeg' ? 'image/jpeg' : 'image/png';
}

/**
 * The picture as readers get it. A pruned one, or one whose file is gone, comes back with empty
 * bytes and `expired: true` rather than a throw: the loop reads every row of a thread each round,
 * and one unreadable picture must not cost the agent its turns.
 */
export function resolveImage(db: Db, legacy: string | null, ref: string | null): Image | undefined {
  if (legacy !== null) {
    const parsed = parseJson(legacy);
    if (parsed === undefined) return undefined;
    if (typeof parsed['base64'] !== 'string') return undefined;
    return { mediaType: mediaTypeOf(parsed['mediaType']), base64: parsed['base64'] };
  }
  if (ref === null) return undefined;
  const parsed = parseJson(ref);
  if (parsed === undefined) return undefined;
  const mediaType = mediaTypeOf(parsed['mediaType']);
  const sha256 = parsed['sha256'];
  if (parsed['expired'] !== true && typeof sha256 === 'string' && SHA256.test(sha256)) {
    try {
      return { mediaType, base64: readFileSync(filePath(db, sha256)).toString('base64') };
    } catch {
      // Falls through to expired.
    }
  }
  return { mediaType, base64: '', expired: true };
}

export type MoveResult = { moved: number; last: number; done: boolean };

/**
 * One batch of the move from inline base64 to files, after message id `after`. Each row's file is
 * written before its row is pointed at it, so an interruption leaves either the old base64 or a
 * reference whose file exists. `interrupt` runs between the two, for the resume test.
 */
export function moveImageBatch(
  db: Db,
  after: number,
  limit = MOVE_BATCH,
  interrupt?: (moved: number) => void,
): MoveResult {
  const rows = db.$client
    .prepare('SELECT id, image FROM messages WHERE image IS NOT NULL AND id > ? ORDER BY id LIMIT ?')
    .all(after, limit) as { id: number; image: string }[];
  const update = db.$client.prepare('UPDATE messages SET image_ref = ?, image = NULL WHERE id = ? AND image IS NOT NULL');
  let moved = 0;
  let last = after;
  for (const row of rows) {
    last = row.id;
    const image = resolveImage(db, row.image, null);
    if (image === undefined) continue;
    const ref = storeImage(db, image);
    interrupt?.(moved);
    update.run(ref, row.id);
    moved += 1;
  }
  return { moved, last, done: rows.length < limit };
}

/** Every legacy row, start to end. Restarting from the beginning after a crash is the resume. */
export function moveImagesToFiles(db: Db, interrupt?: (moved: number) => void): number {
  let after = 0;
  let moved = 0;
  for (;;) {
    const batch = moveImageBatch(db, after, MOVE_BATCH, interrupt === undefined ? undefined : (n) => interrupt(moved + n));
    moved += batch.moved;
    after = batch.last;
    if (batch.done) return moved;
  }
}

/** The boot-time move, a batch per event-loop turn so the daemon answers while it runs. A write
 * error (a full disk) stops it; the next boot starts over and skips nothing. */
export function startImageMover(db: Db): void {
  let after = 0;
  let moved = 0;
  const step = () => {
    try {
      const batch = moveImageBatch(db, after);
      moved += batch.moved;
      after = batch.last;
      if (!batch.done) {
        setImmediate(step);
        return;
      }
      if (moved > 0) log.info('images moved out of the database', { moved });
    } catch (error) {
      log.error('moving images out of the database stopped; the next boot resumes it', { moved, after, error });
    }
  };
  setImmediate(step);
}

export type PruneResult = { expired: number; removedFiles: number };

/**
 * Expires agent screenshots older than the window, then deletes every file no row points at:
 * pruned ones, ones whose thread was cleared or rewound, and leftovers of a crash between a
 * file write and its row. The owner's pictures (`role = 'user'`, no sender) are never pruned.
 * Zero days keeps everything, the sweep aside.
 */
export function pruneImages(db: Db, now: number, retentionDays: number): PruneResult {
  let expired = 0;
  if (retentionDays > 0) {
    const due = db.$client
      .prepare(
        `SELECT id, conversation_id AS conversationId,
                COALESCE(json_extract(image_ref, '$.mediaType'), json_extract(image, '$.mediaType')) AS mediaType
           FROM messages
          WHERE (image IS NOT NULL OR (image_ref IS NOT NULL AND json_extract(image_ref, '$.expired') IS NULL))
            AND created_at < ?
            AND NOT (role = 'user' AND sender IS NULL)`,
      )
      .all(now - retentionDays * DAY_MS) as { id: number; conversationId: number; mediaType: unknown }[];
    const expire = db.$client.prepare('UPDATE messages SET image = NULL, image_ref = ? WHERE id = ?');
    db.$client.transaction(() => {
      for (const row of due) expire.run(expiredRef(mediaTypeOf(row.mediaType)), row.id);
    })();
    for (const conversationId of new Set(due.map((row) => row.conversationId))) bumpEpoch(db, conversationId);
    expired = due.length;
  }
  return { expired, removedFiles: sweepImageFiles(db) };
}

/** Synchronous for the same reason as `storeImage`: no row can be written between the live set
 * being read and the unlinks. */
export function sweepImageFiles(db: Db): number {
  const live = new Set(
    (
      db.$client
        .prepare("SELECT DISTINCT json_extract(image_ref, '$.sha256') AS sha FROM messages WHERE image_ref IS NOT NULL")
        .all() as { sha: unknown }[]
    ).flatMap((row) => (typeof row.sha === 'string' ? [row.sha] : [])),
  );
  const root = imageDir(db);
  let removed = 0;
  let shards: string[];
  try {
    shards = readdirSync(root);
  } catch {
    return 0;
  }
  for (const shard of shards) {
    let names: string[];
    try {
      names = readdirSync(join(root, shard));
    } catch {
      continue;
    }
    for (const name of names) {
      if (live.has(name)) continue;
      try {
        unlinkSync(join(root, shard, name));
        removed += 1;
      } catch (error) {
        log.warn('image file not removed', { file: name, error });
      }
    }
  }
  return removed;
}

export function startImagePruner(db: Db): () => void {
  const pass = () => {
    try {
      const result = pruneImages(db, Date.now(), readImageRetentionDays(db));
      if (result.expired > 0 || result.removedFiles > 0) log.info('images pruned', { ...result });
    } catch (error) {
      log.error('image prune failed', { error });
    }
  };
  pass();
  const timer = setInterval(pass, PRUNE_EVERY_MS);
  timer.unref();
  return () => clearInterval(timer);
}
