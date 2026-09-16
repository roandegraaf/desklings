import { resolve } from 'node:path';
import assert from 'node:assert/strict';
import test from 'node:test';
import { openDb } from './db.ts';
import {
  AGENT_NAME,
  forgetAgent,
  insertAgent,
  insertWorker,
  listAgents,
  nextDisplay,
  nextWorkerName,
  reconcileDesktops,
} from './agents.ts';
import type { Agent } from '@schermes/shared';
import type { DesktopOps, DesktopOutcome } from './agents.ts';

const MIGRATIONS = resolve(import.meta.dirname, '../migrations');

/** Stands in for the shell boundary: `alive` is the set of displays a probe would answer on. */
function fakeDesktop(alive: Set<number>, broken = new Set<string>()) {
  const calls: { name: string; display: number; outcome: DesktopOutcome }[] = [];
  const ops: DesktopOps = {
    ensure(name, display) {
      if (broken.has(name)) return Promise.reject(new Error(`no display for ${name}`));
      const outcome: DesktopOutcome = alive.has(display) ? 'adopted' : 'started';
      alive.add(display);
      calls.push({ name, display, outcome });
      return Promise.resolve(outcome);
    },
    stop(name) {
      alive.delete(calls.findLast((call) => call.name === name)?.display ?? -1);
      return Promise.resolve();
    },
    rename() {
      return Promise.resolve();
    },
  };
  return { ops, calls };
}

test('agent names that could reach a shell are rejected', () => {
  for (const name of ['alpha', 'a', 'agent-1', '0', 'a'.repeat(31)]) {
    assert.ok(AGENT_NAME.test(name), `${name} should be accepted`);
  }
  for (const name of [
    '',
    '-leading-dash',
    'Alpha',
    'has space',
    'semi;rm -rf /',
    '../escape',
    'back`tick`',
    '$(subshell)',
    'trailing\n',
    'a'.repeat(32),
  ]) {
    assert.ok(!AGENT_NAME.test(name), `${JSON.stringify(name)} should be rejected`);
  }
});

test('displays are allocated from :1 up and reuse a gap left by a removed agent', () => {
  assert.equal(nextDisplay([]), 1);
  assert.equal(nextDisplay([1]), 2);
  assert.equal(nextDisplay([1, 2, 3]), 4);
  assert.equal(nextDisplay([1, 3]), 2);
  assert.equal(nextDisplay([2, 3]), 1);
  assert.throws(() => nextDisplay(Array.from({ length: 999 }, (_, i) => i + 1)));
});

test('each agent gets its own display, and a freed one comes back', () => {
  const db = openDb(':memory:', MIGRATIONS);

  assert.equal(insertAgent(db, 'alpha')?.display, 1);
  assert.equal(insertAgent(db, 'bravo')?.display, 2);
  assert.equal(insertAgent(db, 'charlie')?.display, 3);
  assert.equal(insertAgent(db, 'bravo'), undefined, 'a duplicate name is refused');

  forgetAgent(db, 'bravo');
  assert.equal(insertAgent(db, 'delta')?.display, 2);
  assert.deepEqual(
    listAgents(db).map((agent) => [agent.name, agent.display]),
    [
      ['alpha', 1],
      ['delta', 2],
      ['charlie', 3],
    ],
  );
});

test('a restarted daemon adopts live desktops and respawns dead ones', async () => {
  const db = openDb(':memory:', MIGRATIONS);
  insertAgent(db, 'alpha');
  insertAgent(db, 'bravo');

  const first = fakeDesktop(new Set());
  await reconcileDesktops(db, first.ops);
  assert.deepEqual(
    first.calls.map((call) => call.outcome),
    ['started', 'started'],
  );

  // Same displays still serving: a second daemon must adopt rather than spawn a rival X server.
  const second = fakeDesktop(new Set([1, 2]));
  await reconcileDesktops(db, second.ops);
  assert.deepEqual(
    second.calls.map((call) => call.outcome),
    ['adopted', 'adopted'],
  );

  const third = fakeDesktop(new Set([2]));
  await reconcileDesktops(db, third.ops);
  assert.deepEqual(third.calls, [
    { name: 'alpha', display: 1, outcome: 'started' },
    { name: 'bravo', display: 2, outcome: 'adopted' },
  ]);
});

test('one unreachable desktop does not stop the daemon reconciling the rest', async () => {
  const db = openDb(':memory:', MIGRATIONS);
  insertAgent(db, 'alpha');
  insertAgent(db, 'bravo');

  const { ops, calls } = fakeDesktop(new Set(), new Set(['alpha']));
  await reconcileDesktops(db, ops);
  assert.deepEqual(calls, [{ name: 'bravo', display: 2, outcome: 'started' }]);
});

test('a task worker is never handed to the desktop layer', async () => {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  const worker = insertWorker(db, alpha, nextWorkerName(db, alpha) as string, 1);

  const { ops, calls } = fakeDesktop(new Set());
  await reconcileDesktops(db, ops);

  // It has no Linux user and no display: start-desktop.sh takes three digits at most, so its
  // placeholder number reaching that script would break the boot rather than start anything.
  assert.deepEqual(calls, [{ name: 'alpha', display: 1, outcome: 'started' }]);
  assert.ok(worker.display > 999, 'and its number is outside the range a desktop can use');
  assert.equal(nextWorkerName(db, alpha), 'alpha-w2', 'names count every worker ever born');
});
