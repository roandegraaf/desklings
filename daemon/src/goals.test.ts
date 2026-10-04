import assert from 'node:assert/strict';
import { resolve } from 'node:path';
import test from 'node:test';
import type { Agent, Goal } from '@schermes/shared';
import { findAgent, insertAgent, insertWorker } from './agents.ts';
import type { DesktopOps } from './agents.ts';
import { conversationFor } from './conversations.ts';
import { openDb } from './db.ts';
import type { Db } from './db.ts';
import {
  ADD_HELPER,
  MAX_BRIEF_CHARS,
  MAX_HELPERS,
  UPDATE_GOAL,
  addHelperRow,
  addHelperToolDef,
  applyGoalUpdate,
  deleteGoal,
  describeGoal,
  findGoal,
  finishGoal,
  goalNeeds,
  goalPrompt,
  helperCount,
  helperGoal,
  isHelper,
  keepHelper,
  leadGoal,
  listGoals,
  nextHelperName,
  parseAddHelper,
  parseGoalUpdate,
  updateGoalToolDef,
} from './goals.ts';
import type { HelperOps } from './goals.ts';
import type { Runner } from './loop.ts';

const MIGRATIONS = resolve(import.meta.dirname, '../migrations');

function fresh(): { db: Db; lead: Agent } {
  const db = openDb(':memory:', MIGRATIONS);
  const lead = insertAgent(db, 'alpha') as Agent;
  return { db, lead };
}

function errorOf(value: object): string {
  assert.ok('error' in value, `expected an error, got ${JSON.stringify(value)}`);
  return String(value.error);
}

function goalOf(value: Goal | { error: string }): Goal {
  assert.ok(!('error' in value), `expected a goal, got ${JSON.stringify(value)}`);
  return value;
}

type Calls = { removed: string[]; stoppedDisplays: Array<[string, number]> };

function ops(db: Db, running: readonly string[] = [], failRemove = false): { ops: HelperOps; calls: Calls } {
  const calls: Calls = { removed: [], stoppedDisplays: [] };
  const desktop: DesktopOps = {
    ensure: async () => 'started',
    stopDisplay: async (name, display) => {
      calls.stoppedDisplays.push([name, display]);
    },
    stop: async () => {},
    remove: async (name) => {
      calls.removed.push(name);
      if (failRemove) throw new Error('userdel refused');
    },
    rename: async () => {},
  };
  const runner: Runner = {
    start: () => {},
    atCapacity: () => undefined,
    running: (name) => running.includes(name),
    stop: () => false,
  };
  return { ops: { db, desktop, runner }, calls };
}

test('a goal update needs a title or an id, and every field is bounded', () => {
  assert.match(errorOf(parseGoalUpdate({})), /needs a title/);
  assert.match(errorOf(parseGoalUpdate({ goal: 1.5 })), /goal id/);
  assert.match(errorOf(parseGoalUpdate({ goal: '1' })), /goal id/);
  assert.match(errorOf(parseGoalUpdate({ title: '   ' })), /title must be/);
  assert.match(errorOf(parseGoalUpdate({ title: 'x'.repeat(121) })), /1 to 120/);
  assert.match(errorOf(parseGoalUpdate({ title: 'T', steps: 'plan' })), /steps must be a list/);
  assert.match(errorOf(parseGoalUpdate({ title: 'T', steps: Array(31).fill({ text: 'x' }) })), /at most 30/);
  assert.match(errorOf(parseGoalUpdate({ title: 'T', steps: [null] })), /each step needs a text/);
  assert.match(errorOf(parseGoalUpdate({ title: 'T', steps: [{ text: 'x', state: 'maybe' }] })), /todo, doing, done, blocked/);
  assert.match(errorOf(parseGoalUpdate({ title: 'T', steps: [{ text: 'x', owner: 7 }] })), /owner is an agent's name/);
  assert.match(errorOf(parseGoalUpdate({ title: 'T', addResults: Array(51).fill('r') })), /addResults must be a list of at most 50/);
  assert.match(errorOf(parseGoalUpdate({ title: 'T', addResults: ['x'.repeat(1_001)] })), /1 to 1000/);
  assert.match(errorOf(parseGoalUpdate({ title: 'T', nextFromYou: Array(11).fill('n') })), /nextFromYou must be a list of at most 10/);
  assert.match(errorOf(parseGoalUpdate({ title: 'T', nextFromYou: [''] })), /each of nextFromYou/);
});

test('a parsed goal update trims to one line, defaults step state, and only finishes on true', () => {
  assert.deepEqual(
    parseGoalUpdate({
      title: '  Plan\n the   trip ',
      steps: [{ text: ' Book\tflights ' }, { text: 'Hotel', state: 'doing', owner: 'alpha-g1-1' }],
      addResults: [' Found  three '],
      nextFromYou: [],
      finish: 'yes',
    }),
    {
      finish: false,
      title: 'Plan the trip',
      steps: [
        { text: 'Book flights', state: 'todo' },
        { text: 'Hotel', state: 'doing', owner: 'alpha-g1-1' },
      ],
      addResults: ['Found three'],
      nextFromYou: [],
    },
  );
  assert.deepEqual(parseGoalUpdate({ goal: 3, finish: true }), { goal: 3, finish: true });
});

test('applying an update creates, appends results, replaces next steps, and refuses strangers', () => {
  const { db, lead } = fresh();
  const created = goalOf(applyGoalUpdate(db, lead, { title: 'Move house', steps: [{ text: 'Pack', state: 'todo' }], finish: false }, 1_000));
  assert.equal(created.lead, 'alpha');
  assert.equal(created.state, 'open');
  assert.deepEqual(created.steps, [{ text: 'Pack', state: 'todo', owner: 'alpha' }]);
  assert.equal(created.createdAt, 1_000);

  goalOf(applyGoalUpdate(db, lead, { goal: created.id, addResults: ['Van booked'], finish: false }, 2_000));
  const later = goalOf(
    applyGoalUpdate(db, lead, { goal: created.id, addResults: ['Boxes bought'], nextFromYou: ['Sign the lease'], finish: false }, 3_000),
  );
  assert.deepEqual(later.results, ['Van booked', 'Boxes bought']);
  assert.deepEqual(later.nextFromYou, ['Sign the lease']);
  assert.deepEqual(later.steps, [{ text: 'Pack', state: 'todo', owner: 'alpha' }], 'steps untouched when not passed');
  assert.equal(later.updatedAt, 3_000);

  assert.match(
    errorOf(applyGoalUpdate(db, lead, { goal: created.id, steps: [{ text: 'Drive', owner: 'beta', state: 'todo' }], finish: false })),
    /beta is neither you nor a helper/,
  );
  assert.match(
    errorOf(applyGoalUpdate(db, lead, { goal: created.id, addResults: Array(49).fill('more'), finish: false })),
    /at most 50 results/,
  );

  const helper = insertAgent(db, 'alpha-g1-1') as Agent;
  addHelperRow(db, created.id, helper, 'agent', 'packing help');
  const assigned = goalOf(
    applyGoalUpdate(db, lead, { goal: created.id, steps: [{ text: 'Drive', owner: 'alpha-g1-1', state: 'doing' }], finish: false }),
  );
  assert.deepEqual(assigned.steps, [{ text: 'Drive', owner: 'alpha-g1-1', state: 'doing' }]);
});

test('only the lead of an open goal may change it, and a lead has at most ten open goals', () => {
  const { db, lead } = fresh();
  const beta = insertAgent(db, 'beta') as Agent;
  const goal = goalOf(applyGoalUpdate(db, lead, { title: 'Mine', finish: false }));

  assert.match(errorOf(leadGoal(db, beta, goal.id)), /you lead no goal/);
  assert.match(errorOf(leadGoal(db, lead, 999)), /you lead no goal 999/);
  assert.equal((leadGoal(db, lead, goal.id) as { id: number }).id, goal.id);
  assert.match(errorOf(applyGoalUpdate(db, beta, { goal: goal.id, title: 'Theirs', finish: false })), /you lead no goal/);

  for (let i = 1; i < 10; i++) goalOf(applyGoalUpdate(db, lead, { title: `Goal ${i}`, finish: false }));
  assert.match(errorOf(applyGoalUpdate(db, lead, { title: 'Eleventh', finish: false })), /already lead 10 open goals/);
  goalOf(applyGoalUpdate(db, beta, { title: 'Beta has room', finish: false }));
});

test('helper names count up per goal and never repeat, even after a helper goes', async () => {
  const { db, lead } = fresh();
  const goal = goalOf(applyGoalUpdate(db, lead, { title: 'Launch', finish: false }));
  const row = () => leadGoal(db, lead, goal.id) as Parameters<typeof nextHelperName>[2];

  const first = nextHelperName(db, lead, row());
  assert.equal(first, `alpha-g${goal.id}-1`);
  const helper = insertAgent(db, first) as Agent;
  addHelperRow(db, goal.id, helper, 'agent', 'copy');
  assert.equal(helperCount(db, goal.id), 1);

  const { ops: helperOps } = ops(db);
  await deleteGoal(helperOps, goal.id);
  const again = goalOf(applyGoalUpdate(db, lead, { title: 'Launch again', finish: false }));
  assert.notEqual(again.id, goal.id);
  assert.equal(nextHelperName(db, lead, leadGoal(db, lead, again.id) as Parameters<typeof nextHelperName>[2]), `alpha-g${again.id}-1`);
  assert.equal(nextHelperName(db, lead, leadGoal(db, lead, again.id) as Parameters<typeof nextHelperName>[2]), `alpha-g${again.id}-2`);
});

test('a helper knows its open goal until the owner keeps it, and loses it when the goal is done', async () => {
  const { db, lead } = fresh();
  const goal = goalOf(applyGoalUpdate(db, lead, { title: 'Research', finish: false }));
  const helper = insertAgent(db, 'alpha-g1-1') as Agent;
  addHelperRow(db, goal.id, helper, 'agent', 'reads papers');

  assert.equal(isHelper(db, helper), true);
  assert.equal(isHelper(db, lead), false);
  assert.equal(helperGoal(db, helper)?.id, goal.id);
  assert.equal(helperGoal(db, lead), undefined);

  const kept = keepHelper(db, goal.id, 'alpha-g1-1', 5_000);
  assert.ok(!('error' in kept));
  assert.equal(kept.helpers[0]?.keptAt, 5_000);
  assert.equal(isHelper(db, helper), false, 'a kept helper is its own agent');
  const keptAgain = keepHelper(db, goal.id, 'alpha-g1-1', 9_000);
  assert.ok(!('error' in keptAgain));
  assert.equal(keptAgain.helpers[0]?.keptAt, 5_000, 'keeping twice keeps the first time');

  const { ops: helperOps, calls } = ops(db);
  goalOf(await finishGoal(helperOps, goal.id, 6_000));
  assert.deepEqual(calls.removed, [], 'a kept helper survives the finish');
  assert.ok(findAgent(db, 'alpha-g1-1'));
  assert.equal(helperGoal(db, helper), undefined, 'a done goal is nobody\'s to help on');
});

test('only a temporary agent can be kept', () => {
  const { db, lead } = fresh();
  const goal = goalOf(applyGoalUpdate(db, lead, { title: 'Scrape', finish: false }));
  const worker = insertWorker(db, lead, 'alpha-g1-1', conversationFor(db, lead.id), 7);
  addHelperRow(db, goal.id, worker, 'worker', 'scrapes');

  const refused = keepHelper(db, goal.id, 'alpha-g1-1');
  assert.ok('error' in refused);
  assert.equal(refused.status, 400);
  assert.match(refused.error, /runs as alpha/);

  const missing = keepHelper(db, goal.id, 'nobody');
  assert.ok('error' in missing);
  assert.equal(missing.status, 404);
  const noGoal = keepHelper(db, 999, 'alpha-g1-1');
  assert.ok('error' in noGoal);
  assert.equal(noGoal.status, 404);
});

test('finishing removes temporary agents, frees worker screens, and waits for busy helpers', async () => {
  const { db, lead } = fresh();
  const goal = goalOf(applyGoalUpdate(db, lead, { title: 'Ship', finish: false }));
  const temp = insertAgent(db, 'alpha-g1-1') as Agent;
  addHelperRow(db, goal.id, temp, 'agent', 'writes copy');
  const worker = insertWorker(db, lead, 'alpha-g1-2', conversationFor(db, lead.id), 7);
  addHelperRow(db, goal.id, worker, 'worker', 'tests the build');

  const busy = await finishGoal(ops(db, ['alpha-g1-1']).ops, goal.id);
  assert.ok('error' in busy);
  assert.equal(busy.status, 409);
  assert.match(busy.error, /alpha-g1-1 is still working/);
  assert.equal(findGoal(db, goal.id)?.state, 'open');

  const { ops: helperOps, calls } = ops(db);
  const done = goalOf(await finishGoal(helperOps, goal.id, 7_000));
  assert.equal(done.state, 'done');
  assert.equal(done.doneAt, 7_000);
  assert.deepEqual(calls.removed, ['alpha-g1-1']);
  assert.deepEqual(calls.stoppedDisplays, [['alpha', 7]]);
  assert.equal(findAgent(db, 'alpha-g1-1'), undefined, 'the temporary agent is gone');
  const finishedWorker = findAgent(db, 'alpha-g1-2');
  assert.ok(finishedWorker, 'the worker stays behind as an ordinary finished worker');
  assert.notEqual(finishedWorker.display, 7, 'and gives its screen back');
  assert.equal(isHelper(db, finishedWorker), false);

  const twice = await finishGoal(helperOps, goal.id);
  assert.ok('error' in twice);
  assert.equal(twice.status, 409);
  const none = await finishGoal(helperOps, 999);
  assert.ok('error' in none);
  assert.equal(none.status, 404);
});

test('a temporary agent whose user will not go is still removed from the goal', async () => {
  const { db, lead } = fresh();
  const goal = goalOf(applyGoalUpdate(db, lead, { title: 'Ship', finish: false }));
  addHelperRow(db, goal.id, insertAgent(db, 'alpha-g1-1') as Agent, 'agent', 'copy');

  const { ops: helperOps, calls } = ops(db, [], true);
  const result = await deleteGoal(helperOps, goal.id);
  assert.deepEqual(result, { ok: true });
  assert.deepEqual(calls.removed, ['alpha-g1-1']);
  assert.equal(findAgent(db, 'alpha-g1-1'), undefined);
  assert.equal(findGoal(db, goal.id), undefined);
  assert.equal(helperCount(db, goal.id), 0);

  const again = await deleteGoal(helperOps, goal.id);
  assert.ok('error' in again);
  assert.equal(again.status, 404);
});

test('deleting a goal keeps the helpers the owner kept and refuses while one is busy', async () => {
  const { db, lead } = fresh();
  const goal = goalOf(applyGoalUpdate(db, lead, { title: 'Ship', finish: false }));
  addHelperRow(db, goal.id, insertAgent(db, 'alpha-g1-1') as Agent, 'agent', 'kept one');
  addHelperRow(db, goal.id, insertAgent(db, 'alpha-g1-2') as Agent, 'agent', 'temporary one');
  keepHelper(db, goal.id, 'alpha-g1-1');

  const busy = await deleteGoal(ops(db, ['alpha-g1-2']).ops, goal.id);
  assert.ok('error' in busy);
  assert.equal(busy.status, 409);

  const keptBusy = await deleteGoal(ops(db, ['alpha-g1-1']).ops, goal.id);
  assert.deepEqual(keptBusy, { ok: true }, 'a kept helper being busy does not block it');
  assert.ok(findAgent(db, 'alpha-g1-1'));
  assert.equal(findAgent(db, 'alpha-g1-2'), undefined);
  assert.deepEqual(listGoals(db), []);
});

test('the goal prompt tells a lead its goals, a helper its lead, and others how to start one', () => {
  const { db, lead } = fresh();
  assert.match(goalPrompt(db, lead), /^You lead no goals\. .*update_goal.*add_helper/s);

  const goal = goalOf(
    applyGoalUpdate(db, lead, {
      title: 'Trip',
      steps: [{ text: 'Flights', state: 'done' }],
      addResults: ['KL 1234'],
      nextFromYou: ['Pick a date'],
      finish: false,
    }),
  );
  const helper = insertAgent(db, 'alpha-g1-1') as Agent;
  addHelperRow(db, goal.id, helper, 'agent', 'hotels');

  const leading = goalPrompt(db, lead);
  assert.match(leading, /^Your goals:/);
  assert.match(leading, new RegExp(`Goal ${goal.id}: Trip \\(open\\), led by alpha\\.`));
  assert.match(leading, /- \[done\] Flights \(alpha\)/);
  assert.match(leading, /Helper alpha-g1-1, temporary agent: hotels/);
  assert.match(leading, /Results:\n- KL 1234/);
  assert.match(leading, /Next from the owner:\n- Pick a date/);
  assert.match(leading, /You lead it/);
  assert.match(leading, /call update_goal first/);

  const helping = goalPrompt(db, helper);
  assert.match(helping, /You are a helper on it\. Report to alpha/);
  assert.doesNotMatch(helping, /call update_goal first/, 'a helper starts no goals of its own');
});

test('describeGoal says when there is no plan and when a helper was kept', () => {
  const { db, lead } = fresh();
  const goal = goalOf(applyGoalUpdate(db, lead, { title: 'Empty', finish: false }));
  const worker = insertWorker(db, lead, 'alpha-g1-1', conversationFor(db, lead.id), 7);
  addHelperRow(db, goal.id, worker, 'worker', 'screens');
  const text = describeGoal(findGoal(db, goal.id) as Goal);
  assert.match(text, /No plan yet\./);
  assert.match(text, /Helper alpha-g1-1, worker with its own screen: screens/);
  assert.doesNotMatch(text, /Results:|Next from the owner:/);

  const temp = insertAgent(db, 'alpha-g1-2') as Agent;
  addHelperRow(db, goal.id, temp, 'agent', 'stays');
  keepHelper(db, goal.id, 'alpha-g1-2');
  assert.match(describeGoal(findGoal(db, goal.id) as Goal), /alpha-g1-2, temporary agent, kept by the owner: stays/);
});

test('a goal waiting on the owner shows under Needs you until it is done or cleared', async () => {
  const { db, lead } = fresh();
  assert.deepEqual(goalNeeds(db), []);
  const quiet = goalOf(applyGoalUpdate(db, lead, { title: 'Quiet', finish: false }, 1_000));
  const waiting = goalOf(applyGoalUpdate(db, lead, { title: 'Waiting', nextFromYou: ['Pay', 'Sign'], finish: false }, 2_000));

  const needs = goalNeeds(db);
  assert.deepEqual(needs, [
    {
      id: `goal:${waiting.id}`,
      kind: 'goal',
      agent: 'alpha',
      conversationId: conversationFor(db, lead.id),
      title: 'Next from you: Waiting',
      detail: 'Pay\nSign',
      goalId: waiting.id,
      createdAt: 2_000,
      actions: ['open'],
    },
  ]);
  assert.ok(!needs.some((item) => item.goalId === quiet.id));

  goalOf(applyGoalUpdate(db, lead, { goal: waiting.id, addResults: ['later'], finish: false }, 3_000));
  assert.equal(goalNeeds(db)[0]?.createdAt, 2_000, 'it dates from when the ask was made');

  goalOf(applyGoalUpdate(db, lead, { goal: waiting.id, nextFromYou: [], finish: false }));
  assert.deepEqual(goalNeeds(db), [], 'an empty list clears it');

  goalOf(applyGoalUpdate(db, lead, { goal: waiting.id, nextFromYou: ['Again'], finish: false }));
  goalOf(await finishGoal(ops(db).ops, waiting.id));
  assert.deepEqual(goalNeeds(db), [], 'a done goal needs nothing');
});

test('add_helper arguments are checked, and both tool definitions match their parsers', () => {
  const ok = { goal: 1, kind: 'worker', reason: ' check  the build ', brief: 'Run the tests.' };
  assert.deepEqual(parseAddHelper(ok), { goal: 1, kind: 'worker', reason: 'check the build', brief: 'Run the tests.' });
  assert.match(errorOf(parseAddHelper({ ...ok, goal: 'one' })), /goal must be the id/);
  assert.match(errorOf(parseAddHelper({ ...ok, kind: 'robot' })), /kind is one of worker, agent/);
  assert.match(errorOf(parseAddHelper({ ...ok, reason: '' })), /reason must be one line/);
  assert.match(errorOf(parseAddHelper({ ...ok, reason: 'x'.repeat(301) })), /1 to 300/);
  assert.match(errorOf(parseAddHelper({ ...ok, brief: '   ' })), /brief must be/);
  assert.match(errorOf(parseAddHelper({ ...ok, brief: 'x'.repeat(MAX_BRIEF_CHARS + 1) })), new RegExp(`1 to ${MAX_BRIEF_CHARS}`));
  assert.ok(!('error' in parseAddHelper({ ...ok, brief: 'x'.repeat(MAX_BRIEF_CHARS) })));

  const helperDef = addHelperToolDef();
  assert.equal(helperDef.name, ADD_HELPER);
  assert.match(helperDef.description, new RegExp(`at most ${MAX_HELPERS} per goal`));
  const helperProps = helperDef.parameters['properties'] as Record<string, Record<string, unknown>>;
  assert.deepEqual(helperProps['kind']?.['enum'], ['worker', 'agent']);
  assert.equal(helperProps['brief']?.['maxLength'], MAX_BRIEF_CHARS);
  assert.deepEqual(helperDef.parameters['required'], ['goal', 'kind', 'reason', 'brief']);

  const goalDef = updateGoalToolDef();
  assert.equal(goalDef.name, UPDATE_GOAL);
  const goalProps = goalDef.parameters['properties'] as Record<string, Record<string, unknown>>;
  assert.equal(goalProps['title']?.['maxLength'], 120);
  assert.equal(goalProps['steps']?.['maxItems'], 30);
  assert.equal(goalProps['addResults']?.['maxItems'], 50);
  assert.equal(goalProps['nextFromYou']?.['maxItems'], 10);
  const stepItems = goalProps['steps']?.['items'] as Record<string, unknown>;
  const stepProps = stepItems['properties'] as Record<string, Record<string, unknown>>;
  assert.deepEqual(stepProps['state']?.['enum'], ['todo', 'doing', 'done', 'blocked']);
});
