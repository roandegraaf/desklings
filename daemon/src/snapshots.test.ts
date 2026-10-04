import assert from 'node:assert/strict';
import { resolve } from 'node:path';
import test from 'node:test';
import type { Agent } from '@schermes/shared';
import { conversationFor } from './conversations.ts';
import { SANDBOX, insertAgent, insertWorker } from './agents.ts';
import { openDb } from './db.ts';
import type { Db } from './db.ts';
import type { Exec, ExecOptions, ExecResult } from './exec.ts';
import {
  KEEP_SNAPSHOTS_COUNT,
  KEEP_SNAPSHOTS_MS,
  SNAPSHOTS,
  diffManifests,
  fileChanges,
  parseSnapshotNames,
  pickSnapshot,
  pruneSnapshots,
  restoreFiles,
  restoredLine,
  snapshotWorkspace,
} from './snapshots.ts';

const MIGRATIONS = resolve(import.meta.dirname, '../migrations');
const NOW = 1_800_000_000_000;

type Call = { user: string; command: string; args: string[]; options: ExecOptions; argv: readonly string[] };
type Reply = Partial<Omit<ExecResult, 'stdout'>> & { stdout?: Buffer | string };
type Handler = (call: Call) => Reply | Promise<Reply>;

function result(reply: Reply): ExecResult {
  const stdout = reply.stdout ?? '';
  return {
    code: reply.code ?? 0,
    stdout: typeof stdout === 'string' ? Buffer.from(stdout) : stdout,
    stderr: reply.stderr ?? '',
    truncated: reply.truncated ?? false,
  };
}

function fakeExec(handler: Handler): { exec: Exec; calls: Call[] } {
  const calls: Call[] = [];
  const exec: Exec = async (file, argv, options = {}) => {
    if (file === 'getent') {
      const user = argv[1] ?? '';
      return result({ stdout: `${user}:x:1001:1001::/home/${user}:/bin/bash\n` });
    }
    assert.equal(file, 'sudo');
    const at = argv.indexOf(SNAPSHOTS);
    assert.ok(at > 0, 'every call runs the snapshot script');
    const call = { user: argv[2] ?? '', command: argv[at + 1] ?? '', args: argv.slice(at + 2), options, argv };
    calls.push(call);
    return result(await handler(call));
  };
  return { exec, calls };
}

function fresh(): { db: Db; alpha: Agent } {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha');
  assert.ok(alpha !== undefined);
  return { db, alpha };
}

function listing(names: readonly string[], size = 10): string {
  let inode = 1;
  return names.flatMap((name) => [`${inode++} ${size} ${name}.list`, `${inode++} ${size} ${name}.tgz`]).join('\n');
}

const names = (count: number, from = 1) => Array.from({ length: count }, (_, i) => `${from + i}-${NOW - (count - i) * 1_000}`);

test('a snapshot runs the script as the agent inside its sandbox, then prunes from its own listing', async () => {
  const { alpha } = fresh();
  const existing = names(KEEP_SNAPSHOTS_COUNT + 2);
  const { exec, calls } = fakeExec((call) => (call.command === 'snapshot' ? { stdout: listing(existing) } : {}));

  await snapshotWorkspace(exec, alpha, 42, NOW);
  const [snapshot, remove, ...more] = calls;
  assert.equal(more.length, 0, 'no separate listing call');
  assert.ok(snapshot !== undefined && remove !== undefined);
  assert.deepEqual(snapshot.argv.slice(0, 6), ['-n', '-u', 'agent-alpha', SANDBOX, 'enter', 'env']);
  assert.ok(snapshot.argv.includes('--chdir=/home/agent-alpha'));
  assert.ok(snapshot.argv.includes('bash') && snapshot.argv.includes('-c'));
  assert.deepEqual(snapshot.args, [`42-${NOW}`]);
  assert.equal(snapshot.options.timeoutMs, 5 * 60 * 1_000);
  assert.equal(snapshot.options.maxBytes, 64 * 1024 * 1024);
  assert.equal(remove.command, 'remove');
  assert.deepEqual(remove.args, existing.slice(0, 2), 'the oldest two go to get back under the count cap');
});

test('a snapshot under the caps removes nothing, and a failed one neither throws nor prunes', async () => {
  const { alpha } = fresh();
  const quiet = fakeExec(() => ({ stdout: listing(names(3)) }));
  await snapshotWorkspace(quiet.exec, alpha, 1, NOW);
  assert.deepEqual(quiet.calls.map((c) => c.command), ['snapshot']);

  const failed = fakeExec(() => ({ code: 1, stderr: 'disk full', stdout: listing(names(KEEP_SNAPSHOTS_COUNT + 5)) }));
  await snapshotWorkspace(failed.exec, alpha, 1, NOW);
  assert.deepEqual(failed.calls.map((c) => c.command), ['snapshot']);

  const thrown = fakeExec(() => {
    throw new Error('spawn failed');
  });
  await snapshotWorkspace(thrown.exec, alpha, 1, NOW);
  assert.equal(thrown.calls.length, 1);

  const noUser: Exec = async () => result({ code: 2 });
  await snapshotWorkspace(noUser, alpha, 1, NOW);
});

test('stop reaches the snapshot command, and a stop during it skips the prune', async () => {
  const { alpha } = fresh();
  const stop = new AbortController();
  const { exec, calls } = fakeExec((call) => {
    assert.equal(call.options.signal, stop.signal, 'the turn\'s signal is handed to the command');
    stop.abort();
    return { stdout: listing(names(KEEP_SNAPSHOTS_COUNT + 5)) };
  });
  await snapshotWorkspace(exec, alpha, 1, NOW, stop.signal);
  assert.deepEqual(calls.map((c) => c.command), ['snapshot']);

  const live = new AbortController();
  const passed = fakeExec((call) => {
    assert.equal(call.options.signal, live.signal);
    return call.command === 'snapshot' ? { stdout: listing(names(KEEP_SNAPSHOTS_COUNT + 1)) } : {};
  });
  await snapshotWorkspace(passed.exec, alpha, 1, NOW, live.signal);
  assert.deepEqual(passed.calls.map((c) => c.command), ['snapshot', 'remove'], 'the remove carries the signal too');
});

test('the hourly prune lists every agent but workers, and one failure does not stop the rest', async () => {
  const { db, alpha } = fresh();
  insertAgent(db, 'bravo');
  insertWorker(db, alpha, 'alpha-w1', conversationFor(db, alpha.id));
  const stale = `1-${NOW - KEEP_SNAPSHOTS_MS - 1}`;
  const { exec, calls } = fakeExec((call) => {
    if (call.command !== 'sizes') return {};
    return call.user === 'agent-alpha' ? { code: 1, stderr: 'boom' } : { stdout: listing([stale, `2-${NOW}`]) };
  });

  await pruneSnapshots(db, exec, NOW);
  assert.deepEqual(
    calls.map((c) => [c.user, c.command, ...c.args]),
    [
      ['agent-alpha', 'sizes'],
      ['agent-bravo', 'sizes'],
      ['agent-bravo', 'remove', stale],
    ],
  );
  assert.equal(calls[0]?.options.signal, undefined);
});

test('file changes diff the first snapshot taken from the given row on, and say when there is none', async () => {
  const { alpha } = fresh();
  const then = ['4 100 a.txt', '4 100 gone'].map((r) => `${r}\0`).join('');
  const now = ['5 100 a.txt', '1 1 new'].map((r) => `${r}\0`).join('');
  const list = [`3-${NOW - 3_000}`, `9-${NOW - 2_000}`, `12-${NOW - 1_000}`].map((n) => `${n}.list`).join('\n');
  const { exec, calls } = fakeExec((call) => (call.command === 'list' ? { stdout: list } : { stdout: `${then}\0${now}` }));

  const found = await fileChanges(exec, alpha, 10, NOW);
  assert.deepEqual(found, {
    name: `9-${NOW - 2_000}`,
    changes: { agent: 'alpha', takenAt: NOW - 2_000, added: ['new'], changed: ['a.txt'], removed: ['gone'] },
  });
  assert.deepEqual(calls.map((c) => [c.command, ...c.args]), [['list'], ['diff', `9-${NOW - 2_000}`]]);

  calls.length = 0;
  assert.equal(await fileChanges(exec, alpha, 14, NOW), undefined, 'every snapshot is from before the row');
  assert.deepEqual(calls.map((c) => c.command), ['list'], 'no diff without a snapshot');
});

test('file changes treat a vanished snapshot as none and a failed or truncated diff as an error', async () => {
  const { alpha } = fresh();
  const list = { stdout: `5-${NOW}.list\n` };
  const diffReply = (reply: Reply) => fakeExec((call) => (call.command === 'list' ? list : reply)).exec;

  assert.equal(await fileChanges(diffReply({ code: 3 }), alpha, 1, NOW), undefined);
  await assert.rejects(fileChanges(diffReply({ code: 1, stderr: 'tar broke' }), alpha, 1, NOW), /reading snapshot 5-\d+ failed: tar broke/);
  await assert.rejects(fileChanges(diffReply({ truncated: true }), alpha, 1, NOW), /reading snapshot/);
  await assert.rejects(fileChanges(fakeExec(() => ({ code: 1, stderr: 'no' })).exec, alpha, 1, NOW), /listing snapshots failed: no/);
  assert.equal(await fileChanges(fakeExec(() => ({ stdout: '' })).exec, alpha, 1, NOW), undefined, 'no snapshot dir yet');
});

test('a restore extracts the snapshot and pipes the paths added since to be removed', async () => {
  const { alpha } = fresh();
  const then = '4 100 a.txt\0';
  const now = ['4 100 a.txt', '1 1 b.txt', '2 2 dir/c d.txt'].map((r) => `${r}\0`).join('');
  const handler = (restoreReply: Reply): Handler => (call) => {
    if (call.command === 'list') return { stdout: `5-${NOW}.list` };
    if (call.command === 'diff') return { stdout: `${then}\0${now}` };
    return restoreReply;
  };
  const ok = fakeExec(handler({}));
  const changes = await restoreFiles(ok.exec, alpha, 1, NOW);
  assert.deepEqual(changes?.added, ['b.txt', 'dir/c d.txt']);
  const restore = ok.calls.at(-1);
  assert.deepEqual([restore?.command, ...(restore?.args ?? [])], ['restore', `5-${NOW}`]);
  assert.equal(restore?.options.input, 'b.txt\0dir/c d.txt\0');

  await assert.rejects(restoreFiles(fakeExec(handler({ code: 1, stderr: 'tar: error' })).exec, alpha, 1, NOW), /restoring alpha's files failed: tar: error/);
  const none = fakeExec(() => ({ stdout: '' }));
  assert.equal(await restoreFiles(none.exec, alpha, 1, NOW), undefined);
  assert.deepEqual(none.calls.map((c) => c.command), ['list'], 'nothing is restored without a snapshot');
});

test('the restored line counts each kind of change in plain words', () => {
  const base = { agent: 'alpha', takenAt: NOW, added: [], changed: [], removed: [] };
  assert.equal(restoredLine(base), "The owner put alpha's files back to how they were at this point in the thread; nothing had changed.");
  assert.equal(
    restoredLine({ ...base, changed: ['a'], removed: ['b', 'c'], added: ['d', 'e', 'f'] }),
    "The owner put alpha's files back to how they were at this point in the thread: 1 changed file put back, 2 deleted files brought back, 3 new files removed.",
  );
  assert.equal(restoredLine({ ...base, added: ['x'] }), "The owner put alpha's files back to how they were at this point in the thread: 1 new file removed.");
});

test('snapshot names parse only well-formed manifests', () => {
  assert.deepEqual(parseSnapshotNames(` 12-1700.list \n12-1700.tgz\nfoo.list\n-1.list\n1-.list\n.new.list\n3-4.list\n`), [
    { name: '12-1700', mark: 12, takenAt: 1700 },
    { name: '3-4', mark: 3, takenAt: 4 },
  ]);
  assert.deepEqual(parseSnapshotNames(''), []);
});

test('the snapshot picked is the earliest from one row before on, within the age limit', () => {
  const snap = (mark: number, takenAt: number) => ({ name: `${mark}-${takenAt}`, mark, takenAt });
  const snapshots = [snap(20, NOW - 10), snap(9, NOW - 30), snap(9, NOW - 40), snap(5, NOW - 50)];
  assert.deepEqual(pickSnapshot(snapshots, 10, NOW), snap(9, NOW - 40), 'mark from-1 counts; the earlier of a tie on mark');
  assert.deepEqual(pickSnapshot(snapshots, 11, NOW), snap(20, NOW - 10));
  assert.equal(pickSnapshot(snapshots, 22, NOW), undefined);
  assert.equal(pickSnapshot([snap(9, NOW - KEEP_SNAPSHOTS_MS - 1)], 1, NOW), undefined, 'too old to trust');
  assert.deepEqual(pickSnapshot([snap(9, NOW - KEEP_SNAPSHOTS_MS)], 1, NOW), snap(9, NOW - KEEP_SNAPSHOTS_MS), 'exactly at the limit is kept');
  assert.equal(pickSnapshot([], 1, NOW), undefined);
});

test('a manifest diff without the separator reads as everything removed, and lists are capped', () => {
  assert.deepEqual(diffManifests('4 100 a\0'), { added: [], changed: [], removed: ['a'] });
  assert.deepEqual(diffManifests(''), { added: [], changed: [], removed: [] });
  assert.deepEqual(diffManifests('4 100 a\0\x004 101 a\0'), { added: [], changed: ['a'], removed: [] }, 'a newer whole second is a change');
  assert.deepEqual(diffManifests('4 100 a\0\x005 100 a\0'), { added: [], changed: ['a'], removed: [] }, 'so is a new size');
  assert.deepEqual(diffManifests('garbage\0\x00 1 x\0'), { added: [], changed: [], removed: [] });
  const many = Array.from({ length: 5_005 }, (_, i) => `1 1 f${String(i).padStart(5, '0')}\0`).join('');
  const { added } = diffManifests(`\0${many}`);
  assert.equal(added.length, 5_000);
  assert.equal(added[0], 'f00000');
  assert.equal(added.at(-1), 'f04999', 'sorted before the cap');
});
