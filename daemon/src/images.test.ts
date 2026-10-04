import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { appendMessage, conversationFor, listMessages, listMessagesWithoutImages } from './conversations.ts';
import { insertAgent } from './agents.ts';
import { openDb } from './db.ts';
import type { Db } from './db.ts';
import { imageDir, moveImageBatch, moveImagesToFiles, pruneImages, resolveImage, sweepImageFiles } from './images.ts';
import { transcript } from './loop.ts';
import { openAiProvider } from './provider.ts';
import type { Image } from './provider.ts';

const MIGRATIONS = resolve(import.meta.dirname, '../migrations');
const DAY = 86_400_000;

function png(tag: string): Image {
  return { mediaType: 'image/png', base64: Buffer.from(`\x89PNG fake ${tag}`, 'binary').toString('base64') };
}

function fresh(): { db: Db; thread: number } {
  const dir = mkdtempSync(join(tmpdir(), 'schermes-images-test-'));
  const db = openDb(join(dir, 'schermes.db'), MIGRATIONS);
  const agent = insertAgent(db, 'alpha')!;
  return { db, thread: conversationFor(db, agent.id) };
}

type Row = { id: number; role: string; sender: string | null; image: string | null; imageRef: string | null; createdAt: number };

function rows(db: Db): Row[] {
  return db.$client
    .prepare('SELECT id, role, sender, image, image_ref AS imageRef, created_at AS createdAt FROM messages ORDER BY id')
    .all() as Row[];
}

function files(db: Db): string[] {
  const root = imageDir(db);
  if (!existsSync(root)) return [];
  return readdirSync(root).flatMap((shard) => readdirSync(join(root, shard))).sort();
}

function shoot(db: Db, thread: number, image: Image, id: string) {
  appendMessage(db, thread, { role: 'assistant', content: '', sender: 'alpha', toolCalls: [{ id, name: 'computer', arguments: '{"action":"screenshot"}' }] });
  return appendMessage(db, thread, { role: 'tool', content: 'Screenshot taken.', sender: 'alpha', toolCallId: id, image });
}

function age(db: Db, id: number, days: number) {
  db.$client.prepare('UPDATE messages SET created_at = ? WHERE id = ?').run(Date.now() - days * DAY, id);
}

test('a new picture is written once to a content-addressed file beside the database, and read back from it', () => {
  const { db, thread } = fresh();
  const first = png('one');
  const message = shoot(db, thread, first, 'c1');
  shoot(db, thread, first, 'c2');
  appendMessage(db, thread, { role: 'user', content: 'mine', image: png('two') });

  assert.equal(imageDir(db), join(resolve(db.$client.name, '..'), 'images'));
  const stored = rows(db).filter((row) => row.imageRef !== null);
  assert.equal(stored.length, 3);
  assert.ok(stored.every((row) => row.image === null), 'nothing inline any more');
  const ref = JSON.parse(stored[0]!.imageRef!) as { mediaType: string; sha256: string };
  assert.equal(ref.mediaType, 'image/png');
  assert.match(ref.sha256, /^[0-9a-f]{64}$/);
  assert.equal(files(db).length, 2, 'the same screenshot twice is one file');
  assert.ok(!files(db).some((name) => name.endsWith('.tmp')));
  const path = join(imageDir(db), ref.sha256.slice(0, 2), ref.sha256);
  assert.deepEqual(readFileSync(path), Buffer.from(first.base64, 'base64'));

  assert.deepEqual(message.image, first, 'the writer gets the picture back');
  assert.deepEqual(listMessages(db, thread).find((m) => m.id === message.id)?.image, first);
});

test('the move out of the database resumes after an interruption between a file and its row', () => {
  const { db, thread } = fresh();
  const insert = db.$client.prepare(
    "INSERT INTO messages (conversation_id, role, content, sender, tool_call_id, image, created_at) VALUES (?, 'tool', 'shot', 'alpha', ?, ?, 1)",
  );
  const originals: Image[] = [];
  for (let n = 0; n < 60; n += 1) {
    const image = n % 10 === 9 ? originals[0]! : png(`legacy ${n}`);
    originals.push(image);
    insert.run(thread, `c${n}`, JSON.stringify(image));
  }
  insert.run(thread, 'broken', '{"mediaType":"image/png"}');

  assert.throws(
    () =>
      moveImagesToFiles(db, (moved) => {
        if (moved === 53) throw new Error('crash');
      }),
    /crash/,
  );
  const half = rows(db);
  assert.equal(half.filter((row) => row.imageRef !== null).length, 53, 'past a batch boundary');
  assert.ok(half.every((row) => row.image === null || row.imageRef === null), 'never both');
  for (const row of half.filter((r) => r.imageRef !== null)) {
    const sha = (JSON.parse(row.imageRef!) as { sha256: string }).sha256;
    assert.ok(existsSync(join(imageDir(db), sha.slice(0, 2), sha)), 'no reference without its file');
  }
  const interrupted = half[53]!;
  assert.notEqual(interrupted.image, null, 'the row being moved still has its base64');
  const sha = createHash('sha256').update(Buffer.from(originals[53]!.base64, 'base64')).digest('hex');
  assert.ok(existsSync(join(imageDir(db), sha.slice(0, 2), sha)), 'its file was written');

  assert.equal(moveImagesToFiles(db), 60 - 53, 'run again, it finishes');
  const done = rows(db);
  assert.equal(done.filter((row) => row.image !== null).length, 1, 'only the malformed legacy row stays');
  assert.deepEqual(
    listMessages(db, thread).slice(0, 60).map((m) => m.image),
    originals,
    'every picture reads back exactly',
  );
  assert.equal(moveImagesToFiles(db), 0, 'and a third run has nothing to do');
  assert.equal(files(db).length, 54, 'duplicates share a file');
  assert.equal(sweepImageFiles(db), 0, 'every file is referenced');

  assert.deepEqual(moveImageBatch(db, 0, 10), { moved: 0, last: 61, done: true });
});

test('retention expires old agent screenshots, keeps the owner pictures, and frees only unreferenced files', () => {
  const { db, thread } = fresh();
  const shared = png('shared');
  const oldShot = shoot(db, thread, png('old'), 'c1');
  const oldShared = shoot(db, thread, shared, 'c2');
  const newShot = shoot(db, thread, png('new'), 'c3');
  const owner = appendMessage(db, thread, { role: 'user', content: 'from me', image: shared });
  const ownerOld = appendMessage(db, thread, { role: 'user', content: 'old, from me', image: png('owner old') });
  db.$client
    .prepare("INSERT INTO messages (conversation_id, role, content, sender, tool_call_id, image, created_at) VALUES (?, 'tool', 'shot', 'alpha', 'c4', ?, 1)")
    .run(thread, JSON.stringify(png('legacy')));
  for (const message of [oldShot, oldShared, owner, ownerOld]) age(db, message.id, 31);
  age(db, newShot.id, 29);
  writeFileSync(join(mkdirAndReturn(join(imageDir(db), 'ff')), 'f'.repeat(64)), 'orphan');

  assert.deepEqual(pruneImages(db, Date.now(), 0), { expired: 0, removedFiles: 1 }, 'zero days keeps every picture; the orphan goes');
  assert.equal(files(db).length, 4);

  const result = pruneImages(db, Date.now(), 30);
  assert.equal(result.expired, 3, 'the two old screenshots and the legacy one');
  assert.equal(result.removedFiles, 1, 'the shared file stays: the owner still points at it');

  const byId = new Map(listMessages(db, thread).map((m) => [m.id, m.image]));
  assert.deepEqual(byId.get(oldShot.id), { mediaType: 'image/png', base64: '', expired: true });
  assert.deepEqual(byId.get(oldShared.id), { mediaType: 'image/png', base64: '', expired: true });
  assert.deepEqual(byId.get(newShot.id), png('new'));
  assert.deepEqual(byId.get(owner.id), shared);
  assert.deepEqual(byId.get(ownerOld.id), png('owner old'), "the owner's pictures are never pruned");
  const legacy = rows(db).at(-1)!;
  assert.equal(legacy.image, null);
  assert.deepEqual(JSON.parse(legacy.imageRef!), { mediaType: 'image/png', expired: true });
  assert.deepEqual(pruneImages(db, Date.now(), 30), { expired: 0, removedFiles: 0 }, 'idempotent');

  db.$client.prepare('DELETE FROM messages WHERE id = ?').run(owner.id);
  assert.equal(pruneImages(db, Date.now(), 30).removedFiles, 1, 'once the last row goes, so does the file');
});

function mkdirAndReturn(dir: string): string {
  mkdirSync(dir, { recursive: true });
  return dir;
}

test('a picture whose file is missing or unreadable reads as expired rather than throwing', () => {
  const { db } = fresh();
  assert.deepEqual(resolveImage(db, null, JSON.stringify({ mediaType: 'image/jpeg', sha256: 'a'.repeat(64) })), {
    mediaType: 'image/jpeg',
    base64: '',
    expired: true,
  });
  assert.deepEqual(resolveImage(db, null, JSON.stringify({ mediaType: 'image/png', sha256: '../../etc/passwd' })), {
    mediaType: 'image/png',
    base64: '',
    expired: true,
  });
  assert.equal(resolveImage(db, null, 'not json'), undefined);
  assert.equal(resolveImage(db, null, null), undefined);
});

test('an expired screenshot reaches the model as a line of text, never as an image_url, and frees its slot', async () => {
  const { db, thread } = fresh();
  appendMessage(db, thread, { role: 'user', content: 'watch' });
  const shots = [0, 1, 2, 3].map((n) => shoot(db, thread, png(`s${n}`), `s${n}`));
  age(db, shots[3]!.id, 31);
  pruneImages(db, Date.now(), 30);

  const projected = transcript('alpha', 'system', listMessages(db, thread));
  const carried = projected.filter((m) => m.role === 'user' && m.image !== undefined);
  assert.deepEqual(
    carried.map((m) => /tool call (s\d)/.exec(m.text)?.[1]),
    ['s0', 's1', 's2'],
    'the dead one does not take one of the three places',
  );
  assert.ok(projected.some((m) => m.role === 'user' && m.text.includes('tool call s3 has expired')));

  const lean = transcript('alpha', 'system', listMessagesWithoutImages(db, thread));
  assert.deepEqual(
    lean.map((m) => m.text),
    projected.map((m) => m.text),
    'the agent list measures the same text the model is sent',
  );

  const sent: string[] = [];
  const original = globalThis.fetch;
  globalThis.fetch = (_url, init) => {
    sent.push(String(init?.body));
    return Promise.resolve(new Response(JSON.stringify({ choices: [{ message: { content: 'ok' } }] }), { status: 200 }));
  };
  try {
    await openAiProvider({ baseUrl: 'http://stub/v1', model: 'm', apiKey: 'k' })(
      [...projected, { role: 'user', text: 'forced', image: { mediaType: 'image/png', base64: '', expired: true } }],
      [],
    );
  } finally {
    globalThis.fetch = original;
  }
  assert.equal(sent.length, 1);
  assert.equal((sent[0]!.match(/"type":"image_url"/g) ?? []).length, 3);
  assert.doesNotMatch(sent[0]!, /base64,"/, 'no empty data: url');
});
