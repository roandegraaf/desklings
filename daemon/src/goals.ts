import { and, asc, eq, isNull } from 'drizzle-orm';
import { GOAL_STEP_STATES, HELPER_KINDS } from '@schermes/shared';
import type { Agent, AgentState, Goal, GoalHelper, GoalStep, GoalStepState, HelperKind, NeedsYouItem } from '@schermes/shared';
import { deleteAgent, findAgentById, nextWorkerDisplay } from './agents.ts';
import type { DesktopOps } from './agents.ts';
import { conversationFor } from './conversations.ts';
import { log } from './log.ts';
import { agents, goalHelpers, goals } from './schema.ts';
import type { Db } from './db.ts';
import type { Runner } from './loop.ts';
import type { ToolDef } from './provider.ts';

export const UPDATE_GOAL = 'update_goal';
export const ADD_HELPER = 'add_helper';
export const MAX_HELPERS = 6;
export const MAX_BRIEF_CHARS = 4_096;
const MAX_OPEN_GOALS = 10;
const MAX_TITLE_CHARS = 120;
const MAX_STEPS = 30;
const MAX_LINE_CHARS = 300;
const MAX_RESULTS = 50;
const MAX_RESULT_CHARS = 1_000;
const MAX_NEXT = 10;
const MAX_REASON_CHARS = 300;

type Row = typeof goals.$inferSelect;
type HelperRow = typeof goalHelpers.$inferSelect;

export type HelperOps = { db: Db; desktop: DesktopOps; runner: Runner };

function helperRows(db: Db, goalId: number): HelperRow[] {
  return db.select().from(goalHelpers).where(eq(goalHelpers.goalId, goalId)).orderBy(asc(goalHelpers.createdAt)).all();
}

function toGoal(db: Db, row: Row): Goal {
  const helpers = helperRows(db, row.id).flatMap((helper): GoalHelper[] => {
    const agent = findAgentById(db, helper.agentId);
    if (agent === undefined) return [];
    return [
      {
        name: agent.name,
        kind: helper.kind as HelperKind,
        reason: helper.reason,
        state: agent.state as AgentState,
        ...(helper.keptAt === null ? {} : { keptAt: helper.keptAt }),
        createdAt: helper.createdAt,
      },
    ];
  });
  return {
    id: row.id,
    title: row.title,
    lead: findAgentById(db, row.leadId)?.name ?? '',
    state: row.state as Goal['state'],
    steps: JSON.parse(row.steps) as GoalStep[],
    results: JSON.parse(row.results) as string[],
    nextFromYou: JSON.parse(row.nextFromYou) as string[],
    helpers,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    ...(row.doneAt === null ? {} : { doneAt: row.doneAt }),
  };
}

export function listGoals(db: Db): Goal[] {
  return db.select().from(goals).orderBy(asc(goals.id)).all().map((row) => toGoal(db, row));
}

export function findGoal(db: Db, id: number): Goal | undefined {
  const row = db.select().from(goals).where(eq(goals.id, id)).get();
  return row === undefined ? undefined : toGoal(db, row);
}

export function helperGoal(db: Db, agent: Agent): Goal | undefined {
  const helper = db.select().from(goalHelpers).where(eq(goalHelpers.agentId, agent.id)).get();
  const goal = helper === undefined ? undefined : findGoal(db, helper.goalId);
  return goal?.state === 'open' ? goal : undefined;
}

/** A helper the owner has not kept: it works for its lead and starts no goals or helpers of its own. */
export function isHelper(db: Db, agent: Agent): boolean {
  return (
    db
      .select()
      .from(goalHelpers)
      .where(and(eq(goalHelpers.agentId, agent.id), isNull(goalHelpers.keptAt)))
      .get() !== undefined
  );
}

export function helperCount(db: Db, goalId: number): number {
  return helperRows(db, goalId).length;
}

/** A helper is held to its lead's rules and runs on its model, as a worker does; one-shot grants stay the lead's. */
export function inheritFromLead(db: Db, lead: Agent, helper: Agent): void {
  const row = db.select().from(agents).where(eq(agents.id, lead.id)).get();
  if (row === undefined) return;
  db.update(agents).set({ rules: row.rules, modelId: row.modelId }).where(eq(agents.id, helper.id)).run();
}

export function addHelperRow(db: Db, goalId: number, agent: Agent, kind: HelperKind, reason: string): void {
  db.insert(goalHelpers).values({ agentId: agent.id, goalId, kind, reason, createdAt: Date.now() }).run();
}

export function leadGoal(db: Db, lead: Agent, id: number): Row | { error: string } {
  const row = db.select().from(goals).where(eq(goals.id, id)).get();
  if (row === undefined || row.leadId !== lead.id) return { error: `you lead no goal ${id}` };
  if (row.state !== 'open') return { error: `goal ${id} is done` };
  return row;
}

/** Names never repeat within a goal, and goal ids are never reused, so a helper never lands in an
 * older helper's Linux home. */
export function nextHelperName(db: Db, lead: Agent, goal: Row): string {
  const made = goal.helpersMade + 1;
  db.update(goals).set({ helpersMade: made }).where(eq(goals.id, goal.id)).run();
  return `${lead.name}-g${goal.id}-${made}`;
}

function line(value: unknown, max: number): string | undefined {
  if (typeof value !== 'string') return undefined;
  const text = value.trim().replace(/\s+/g, ' ');
  return text === '' || text.length > max ? undefined : text;
}

function lines(value: unknown, most: number, max: number, what: string): string[] | { error: string } {
  if (!Array.isArray(value) || value.length > most) return { error: `${what} must be a list of at most ${most}` };
  const out: string[] = [];
  for (const item of value) {
    const text = line(item, max);
    if (text === undefined) return { error: `each of ${what} must be one line of 1 to ${max} characters` };
    out.push(text);
  }
  return out;
}

type StepDraft = { text: string; owner?: string; state: GoalStepState };

export type GoalUpdate = {
  goal?: number;
  title?: string;
  steps?: StepDraft[];
  addResults?: string[];
  nextFromYou?: string[];
  finish: boolean;
};

export function parseGoalUpdate(args: Record<string, unknown>): GoalUpdate | { error: string } {
  const update: GoalUpdate = { finish: args['finish'] === true };
  if (args['goal'] !== undefined) {
    if (!Number.isSafeInteger(args['goal'])) return { error: 'goal must be a goal id' };
    update.goal = args['goal'] as number;
  }
  if (args['title'] !== undefined) {
    const title = line(args['title'], MAX_TITLE_CHARS);
    if (title === undefined) return { error: `title must be one line of 1 to ${MAX_TITLE_CHARS} characters` };
    update.title = title;
  }
  if (update.goal === undefined && update.title === undefined) {
    return { error: 'a new goal needs a title; to change one, pass its goal id' };
  }
  if (args['steps'] !== undefined) {
    const raw = args['steps'];
    if (!Array.isArray(raw) || raw.length > MAX_STEPS) return { error: `steps must be a list of at most ${MAX_STEPS}` };
    const steps: StepDraft[] = [];
    for (const item of raw as unknown[]) {
      const step = (item ?? {}) as Record<string, unknown>;
      const text = line(step['text'], MAX_LINE_CHARS);
      if (text === undefined) return { error: `each step needs a text of 1 to ${MAX_LINE_CHARS} characters` };
      const state = step['state'] ?? 'todo';
      if (!GOAL_STEP_STATES.includes(state as GoalStepState)) {
        return { error: `a step's state is one of ${GOAL_STEP_STATES.join(', ')}` };
      }
      const owner = step['owner'];
      if (owner !== undefined && typeof owner !== 'string') return { error: "a step's owner is an agent's name" };
      steps.push({ text, state: state as GoalStepState, ...(owner === undefined ? {} : { owner }) });
    }
    update.steps = steps;
  }
  for (const [key, most, max] of [
    ['addResults', MAX_RESULTS, MAX_RESULT_CHARS],
    ['nextFromYou', MAX_NEXT, MAX_LINE_CHARS],
  ] as const) {
    if (args[key] === undefined) continue;
    const parsed = lines(args[key], most, max, key);
    if ('error' in parsed) return parsed;
    update[key] = parsed;
  }
  return update;
}

export function applyGoalUpdate(db: Db, lead: Agent, update: GoalUpdate, now = Date.now()): Goal | { error: string } {
  let found: Row | undefined;
  if (update.goal === undefined) {
    const open = db
      .select()
      .from(goals)
      .where(and(eq(goals.leadId, lead.id), eq(goals.state, 'open')))
      .all().length;
    if (open >= MAX_OPEN_GOALS) return { error: `you already lead ${MAX_OPEN_GOALS} open goals; finish one first` };
  } else {
    const led = leadGoal(db, lead, update.goal);
    if ('error' in led) return led;
    found = led;
  }

  const helpers = found === undefined ? [] : toGoal(db, found).helpers.map((helper) => helper.name);
  const steps = update.steps?.map((step): GoalStep => ({ ...step, owner: step.owner ?? lead.name }));
  const stranger = steps?.find((step) => step.owner !== lead.name && !helpers.includes(step.owner));
  if (stranger !== undefined) {
    return { error: `${stranger.owner} is neither you nor a helper on this goal; add it with add_helper first` };
  }
  const results = [...(found === undefined ? [] : (JSON.parse(found.results) as string[])), ...(update.addResults ?? [])];
  if (results.length > MAX_RESULTS) return { error: `a goal keeps at most ${MAX_RESULTS} results` };

  const row =
    found ??
    db.insert(goals).values({ leadId: lead.id, title: update.title as string, createdAt: now, updatedAt: now }).returning().get();

  db.update(goals)
    .set({
      updatedAt: now,
      ...(update.title === undefined ? {} : { title: update.title }),
      ...(steps === undefined ? {} : { steps: JSON.stringify(steps) }),
      ...(update.addResults === undefined ? {} : { results: JSON.stringify(results) }),
      ...(update.nextFromYou === undefined ? {} : { nextFromYou: JSON.stringify(update.nextFromYou), nextAt: now }),
    })
    .where(eq(goals.id, row.id))
    .run();
  return findGoal(db, row.id) as Goal;
}

function busyHelper(ops: HelperOps, goal: Goal): string | undefined {
  const busy = goal.helpers.find((helper) => helper.keptAt === undefined && ops.runner.running(helper.name));
  return busy === undefined ? undefined : `${busy.name} is still working; wait for it or stop it first`;
}

/**
 * Every helper the owner did not keep. A temporary agent goes the way a deleted agent does; a
 * screen worker loses its display and stays behind as an ordinary finished worker, because its
 * report lives in the lead's own thread.
 */
async function removeHelpers(ops: HelperOps, goalId: number): Promise<void> {
  for (const helper of helperRows(ops.db, goalId).filter((row) => row.keptAt === null)) {
    const agent = findAgentById(ops.db, helper.agentId);
    if (agent === undefined) continue;
    if (helper.kind === 'agent') {
      await ops.desktop.stop(agent.name).catch((error: unknown) => log.error('desktop would not stop', { agent: agent.name, error }));
      deleteAgent(ops.db, agent);
    } else {
      const parent = agent.parentId === undefined ? undefined : findAgentById(ops.db, agent.parentId);
      if (parent !== undefined) {
        await ops.desktop
          .stopDisplay(parent.name, agent.display)
          .catch((error: unknown) => log.error('helper display would not stop', { agent: agent.name, error }));
      }
      ops.db.update(agents).set({ display: nextWorkerDisplay(ops.db) }).where(eq(agents.id, agent.id)).run();
      ops.db.delete(goalHelpers).where(eq(goalHelpers.agentId, agent.id)).run();
    }
    log.info('goal helper removed', { goal: goalId, helper: agent.name, kind: helper.kind });
  }
}

export async function finishGoal(ops: HelperOps, id: number, now = Date.now()): Promise<Goal | { error: string; status: 404 | 409 }> {
  const goal = findGoal(ops.db, id);
  if (goal === undefined) return { error: 'no such goal', status: 404 };
  if (goal.state === 'done') return { error: `goal ${id} is already done`, status: 409 };
  const busy = busyHelper(ops, goal);
  if (busy !== undefined) return { error: busy, status: 409 };
  ops.db.update(goals).set({ state: 'done', doneAt: now, updatedAt: now }).where(eq(goals.id, id)).run();
  await removeHelpers(ops, id);
  return findGoal(ops.db, id) as Goal;
}

/** The goal and its helpers, except the kept ones, which stay as normal agents. */
export async function deleteGoal(ops: HelperOps, id: number): Promise<{ ok: true } | { error: string; status: 404 | 409 }> {
  const goal = findGoal(ops.db, id);
  if (goal === undefined) return { error: 'no such goal', status: 404 };
  const busy = busyHelper(ops, goal);
  if (busy !== undefined) return { error: busy, status: 409 };
  await removeHelpers(ops, id);
  ops.db.delete(goals).where(eq(goals.id, id)).run();
  return { ok: true };
}

/** "Keep as agent". Only a temporary agent has an account of its own to keep. */
export function keepHelper(db: Db, goalId: number, name: string, now = Date.now()): Goal | { error: string; status: 400 | 404 } {
  const goal = findGoal(db, goalId);
  const helper = goal?.helpers.find((candidate) => candidate.name === name);
  if (goal === undefined || helper === undefined) return { error: 'no such helper on this goal', status: 404 };
  if (helper.kind !== 'agent') {
    return { error: `${name} runs as ${goal.lead} and has no account of its own to keep`, status: 400 };
  }
  const agent = db.select().from(agents).where(eq(agents.name, name)).get();
  if (helper.keptAt === undefined && agent !== undefined) {
    db.update(goalHelpers).set({ keptAt: now }).where(eq(goalHelpers.agentId, agent.id)).run();
  }
  return findGoal(db, goalId) as Goal;
}

const HELPER_WORDS: Record<HelperKind, string> = { worker: 'worker with its own screen', agent: 'temporary agent' };

export function describeGoal(goal: Goal): string {
  const out = [`Goal ${goal.id}: ${goal.title} (${goal.state}), led by ${goal.lead}.`];
  out.push(goal.steps.length === 0 ? 'No plan yet.' : 'Plan:');
  for (const step of goal.steps) out.push(`- [${step.state}] ${step.text} (${step.owner})`);
  for (const helper of goal.helpers) {
    out.push(`Helper ${helper.name}, ${HELPER_WORDS[helper.kind]}${helper.keptAt === undefined ? '' : ', kept by the owner'}: ${helper.reason}`);
  }
  if (goal.results.length > 0) out.push('Results:', ...goal.results.map((result) => `- ${result}`));
  if (goal.nextFromYou.length > 0) out.push('Next from the owner:', ...goal.nextFromYou.map((next) => `- ${next}`));
  return out.join('\n');
}

export function goalPrompt(db: Db, agent: Agent): string {
  const led = db
    .select()
    .from(goals)
    .where(and(eq(goals.leadId, agent.id), eq(goals.state, 'open')))
    .orderBy(asc(goals.id))
    .all()
    .map((row) => toGoal(db, row));
  const helping = helperGoal(db, agent);
  const parts = led.map(
    (goal) => `${describeGoal(goal)}\nYou lead it: keep the plan, results and "next from the owner" current with update_goal.`,
  );
  if (helping !== undefined) {
    parts.push(`${describeGoal(helping)}\nYou are a helper on it. Report to ${helping.lead} with send_message; it keeps the plan.`);
  }
  if (parts.length === 0) {
    return 'You lead no goals. When the owner gives you a larger aim, update_goal starts one with a plan, and add_helper brings in help.';
  }
  return ['Your goals:', ...parts].join('\n\n');
}

export function goalNeeds(db: Db): NeedsYouItem[] {
  return listGoals(db)
    .filter((goal) => goal.state === 'open' && goal.nextFromYou.length > 0)
    .flatMap((goal): NeedsYouItem[] => {
      const row = db.select().from(goals).where(eq(goals.id, goal.id)).get() as Row;
      return [
        {
          id: `goal:${goal.id}`,
          kind: 'goal',
          agent: goal.lead,
          conversationId: conversationFor(db, row.leadId),
          title: `Next from you: ${goal.title}`,
          detail: goal.nextFromYou.join('\n'),
          goalId: goal.id,
          createdAt: row.nextAt ?? row.updatedAt,
          actions: ['open'],
        },
      ];
    });
}

export type HelperRequest = { goal: number; kind: HelperKind; reason: string; brief: string };

export function parseAddHelper(args: Record<string, unknown>): HelperRequest | { error: string } {
  const goal = args['goal'];
  if (!Number.isSafeInteger(goal)) return { error: 'goal must be the id of a goal you lead' };
  const kind = args['kind'];
  if (!HELPER_KINDS.includes(kind as HelperKind)) return { error: `kind is one of ${HELPER_KINDS.join(', ')}` };
  const reason = line(args['reason'], MAX_REASON_CHARS);
  if (reason === undefined) return { error: `reason must be one line of 1 to ${MAX_REASON_CHARS} characters` };
  const brief = args['brief'];
  if (typeof brief !== 'string' || brief.trim() === '' || brief.length > MAX_BRIEF_CHARS) {
    return { error: `brief must be 1 to ${MAX_BRIEF_CHARS} characters` };
  }
  return { goal: goal as number, kind: kind as HelperKind, reason, brief };
}

export function helperProfile(lead: Agent, goal: Row, reason: string): string {
  return `A helper of ${lead.name} on the goal "${goal.title}", with a desktop of your own. Why you were brought in: ${reason}\n\nWork on what ${lead.name} asks and report back to it; it keeps the plan.`;
}

export function updateGoalToolDef(): ToolDef {
  return {
    name: UPDATE_GOAL,
    description:
      'Start or keep up a goal you lead: a larger aim with a plan the owner follows on the goal page. ' +
      'Without goal it starts a new one (title needed). steps replaces the whole plan; each step has an owner, ' +
      'you or one of the goal\'s helpers. addResults appends what came out of the work; nextFromYou replaces the list ' +
      'of what only the owner can do (an empty list clears it), shown to them under Needs you. finish marks it done ' +
      'and removes its helpers, except those the owner kept. The result is the goal as it now stands.',
    parameters: {
      type: 'object',
      properties: {
        goal: { type: 'integer', description: 'the goal id; leave out to start a new goal' },
        title: { type: 'string', maxLength: MAX_TITLE_CHARS },
        steps: {
          type: 'array',
          maxItems: MAX_STEPS,
          items: {
            type: 'object',
            properties: {
              text: { type: 'string', maxLength: MAX_LINE_CHARS },
              owner: { type: 'string', description: 'who does it: your name (the default) or a helper\'s' },
              state: { type: 'string', enum: [...GOAL_STEP_STATES] },
            },
            required: ['text', 'state'],
            additionalProperties: false,
          },
        },
        addResults: { type: 'array', maxItems: MAX_RESULTS, items: { type: 'string', maxLength: MAX_RESULT_CHARS } },
        nextFromYou: { type: 'array', maxItems: MAX_NEXT, items: { type: 'string', maxLength: MAX_LINE_CHARS } },
        finish: { type: 'boolean' },
      },
      additionalProperties: false,
    },
  };
}

export function addHelperToolDef(): ToolDef {
  return {
    name: ADD_HELPER,
    description:
      `Bring a helper onto a goal you lead, at most ${MAX_HELPERS} per goal. kind worker: a task worker that runs as ` +
      'your own Linux user with a screen of its own (computer tool and shell), does the brief and reports back ' +
      'once; right for a self-contained job. kind agent: a temporary agent with its own Linux user and desktop that ' +
      'you talk to with send_message for as long as the goal runs; right for ongoing work or work that must stay out ' +
      'of your files. Both are removed when the goal is finished unless the owner keeps one. Your turn keeps going; ' +
      'the helper\'s answer arrives later as a message.',
    parameters: {
      type: 'object',
      properties: {
        goal: { type: 'integer' },
        kind: { type: 'string', enum: [...HELPER_KINDS] },
        reason: {
          type: 'string',
          maxLength: MAX_REASON_CHARS,
          description: 'one line for the owner: why this helper, and why this kind',
        },
        brief: {
          type: 'string',
          maxLength: MAX_BRIEF_CHARS,
          description: 'the job, in enough detail that someone with no other context can do it',
        },
      },
      required: ['goal', 'kind', 'reason', 'brief'],
      additionalProperties: false,
    },
  };
}
