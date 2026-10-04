import assert from 'node:assert/strict';
import { resolve } from 'node:path';
import test from 'node:test';
import { eq } from 'drizzle-orm';
import type { Agent, Goal } from '@schermes/shared';
import { MAX_DISPLAY, findAgent, insertAgent, insertWorker } from './agents.ts';
import { conversationFor } from './conversations.ts';
import { openDb } from './db.ts';
import { agents } from './schema.ts';
import { liveWorkers, parseSpawnWorker, spawnWorkerToolDef, workerDir, workerPrompt } from './workers.ts';

const MIGRATIONS = resolve(import.meta.dirname, '../migrations');

test('a worker directory comes from its name, under the parent workspace', () => {
  assert.equal(workerDir('/home/agent-alpha', 'alpha-w3'), '/home/agent-alpha/workspace/workers/alpha-w3');
});

test('a spawn brief is a non-empty string of at most 4096 characters, kept as written', () => {
  const refuse = (body: Record<string, unknown>): string => {
    const parsed = parseSpawnWorker(body);
    assert.ok('error' in parsed, `expected ${JSON.stringify(body)} to be refused`);
    return parsed.error;
  };
  assert.match(refuse({}), /non-empty string/);
  assert.match(refuse({ brief: 42 }), /non-empty string/);
  assert.match(refuse({ brief: ' \n\t' }), /non-empty string/);
  assert.match(refuse({ brief: 'x'.repeat(4_097) }), /at most 4096/);
  assert.deepEqual(parseSpawnWorker({ brief: 'x'.repeat(4_096) }), { brief: 'x'.repeat(4_096) });
  assert.deepEqual(parseSpawnWorker({ brief: '  Count the files.\n' }), { brief: '  Count the files.\n' });
});

test('the spawn tool definition carries the same limit the parser enforces', () => {
  const def = spawnWorkerToolDef();
  assert.equal(def.name, 'spawn_task_worker');
  const props = def.parameters['properties'] as Record<string, Record<string, unknown>>;
  assert.equal(props['brief']?.['maxLength'], 4_096);
  assert.deepEqual(def.parameters['required'], ['brief']);
  assert.equal(def.parameters['additionalProperties'], false);
});

test('live workers are the unfinished ones, and permanent agents never count', () => {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  insertAgent(db, 'beta');
  const conversation = conversationFor(db, alpha.id);
  const states = ['idle', 'thinking', 'completed', 'failed', 'waiting_for_user'] as const;
  states.forEach((state, i) => {
    const worker = insertWorker(db, alpha, `alpha-w${i + 1}`, conversation);
    db.update(agents).set({ state }).where(eq(agents.id, worker.id)).run();
  });

  assert.deepEqual(
    liveWorkers(db).map((worker) => worker.name).sort(),
    ['alpha-w1', 'alpha-w2', 'alpha-w5'],
  );
  assert.ok(liveWorkers(db).every((worker) => worker.parentId === alpha.id));
});

test('a worker prompt says whether it has a screen, and carries its goal when it is a helper', () => {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  const conversation = conversationFor(db, alpha.id);
  const blind = insertWorker(db, alpha, 'alpha-w1', conversation);
  const seeing = insertWorker(db, alpha, 'alpha-w2', conversation, 12);
  assert.ok(blind.display > MAX_DISPLAY);

  const blindPrompt = workerPrompt(blind, 'alpha');
  assert.match(blindPrompt, /^You are alpha-w1, a task worker on this machine\./);
  assert.match(blindPrompt, /alpha spawned you to do one job/);
  assert.match(blindPrompt, /You have no desktop\./);
  assert.doesNotMatch(blindPrompt, /computer tool/);
  assert.doesNotMatch(blindPrompt, /helper on this goal/);

  const seeingPrompt = workerPrompt(findAgent(db, seeing.name) as Agent, 'alpha');
  assert.match(seeingPrompt, /display :12/);
  assert.doesNotMatch(seeingPrompt, /no desktop/);

  const goal: Goal = {
    id: 4,
    title: 'Launch',
    lead: 'alpha',
    state: 'open',
    steps: [{ text: 'Test the build', owner: 'alpha-w2', state: 'doing' }],
    results: [],
    nextFromYou: [],
    helpers: [],
    createdAt: 1,
    updatedAt: 1,
  };
  const helperPrompt = workerPrompt(seeing, 'alpha', goal);
  assert.ok(helperPrompt.startsWith(seeingPrompt), 'the goal comes after the usual prompt');
  assert.match(helperPrompt, /You are a helper on this goal:\nGoal 4: Launch \(open\), led by alpha\./);
  assert.match(helperPrompt, /- \[doing\] Test the build \(alpha-w2\)/);
});
