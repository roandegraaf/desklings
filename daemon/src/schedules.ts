import { Cron } from 'croner';
import { and, asc, eq, lte } from 'drizzle-orm';
import type { Agent, Schedule } from '@schermes/shared';
import { findAgentById } from './agents.ts';
import { appendMessage, conversationFor, recordEvent } from './conversations.ts';
import { log } from './log.ts';
import { schedules } from './schema.ts';
import type { Db } from './db.ts';
import type { Runner } from './loop.ts';
import type { ToolDef } from './provider.ts';

/**
 * How often the daemon looks for due rows. It is also the real floor on how often a job can
 * fire: a cron finer than this advances to a time that has already passed by the next tick, so
 * it fires once per tick rather than once per slot.
 */
export const SCHEDULE_TICK_MS = 30_000;

const MAX_CRON_CHARS = 100;
const MAX_PROMPT_CHARS = 2_000;

/** How many schedules one agent may hold. Every one of them is a turn that starts itself. */
export const MAX_SCHEDULES = 20;

export type ScheduleRequest = { cron: string; prompt: string };

/**
 * When this expression next fires after `after`, or undefined when it never does. A pattern can
 * be syntactically fine and still have no future — `0 0 30 2 *` is February the 30th — which is
 * a row that would otherwise sit permanently due.
 */
export function nextRun(cron: string, after: number): number | undefined {
  try {
    // No callback: croner only starts a timer of its own when it is given a function, and this
    // is the daemon's tick asking a question, not a second scheduler.
    return new Cron(cron).nextRun(new Date(after))?.getTime();
  } catch {
    return undefined;
  }
}

export function parseSchedule(body: Record<string, unknown>): ScheduleRequest | { error: string } {
  const cron = body['cron'];
  if (typeof cron !== 'string' || cron.trim() === '') {
    return { error: 'cron must be a non-empty cron expression' };
  }
  if (cron.length > MAX_CRON_CHARS) {
    return { error: `cron must be at most ${MAX_CRON_CHARS} characters` };
  }
  const prompt = body['prompt'];
  if (typeof prompt !== 'string' || prompt.trim() === '') {
    return { error: 'prompt must be a non-empty string' };
  }
  if (prompt.length > MAX_PROMPT_CHARS) {
    return { error: `prompt must be at most ${MAX_PROMPT_CHARS} characters` };
  }
  if (nextRun(cron.trim(), Date.now()) === undefined) {
    return { error: `${cron.trim()} is not a cron expression with a next run` };
  }
  return { cron: cron.trim(), prompt: prompt.trim() };
}

function toSchedule(row: typeof schedules.$inferSelect, agent: string): Schedule {
  const { agentId, lastRunAt, ...rest } = row;
  return { ...rest, agent, ...(lastRunAt === null ? {} : { lastRunAt }) };
}

export function listSchedules(db: Db, agent: Agent): Schedule[] {
  return db
    .select()
    .from(schedules)
    .where(eq(schedules.agentId, agent.id))
    .orderBy(asc(schedules.id))
    .all()
    .map((row) => toSchedule(row, agent.name));
}

/** One schedule, and only if it is this agent's: an id is a number the model can guess. */
export function findSchedule(db: Db, agent: Agent, id: number): Schedule | undefined {
  const row = db
    .select()
    .from(schedules)
    .where(and(eq(schedules.id, id), eq(schedules.agentId, agent.id)))
    .get();
  return row === undefined ? undefined : toSchedule(row, agent.name);
}

export function insertSchedule(
  db: Db,
  agent: Agent,
  request: ScheduleRequest,
  now: number,
): Schedule | { error: string } {
  const held = listSchedules(db, agent).length;
  if (held >= MAX_SCHEDULES) {
    return { error: `you already hold ${MAX_SCHEDULES} schedules; cancel one before adding another` };
  }
  const due = nextRun(request.cron, now);
  if (due === undefined) return { error: `${request.cron} has no next run` };
  const row = db
    .insert(schedules)
    .values({
      agentId: agent.id,
      cron: request.cron,
      prompt: request.prompt,
      nextRunAt: due,
      createdAt: now,
    })
    .returning()
    .get();
  return toSchedule(row, agent.name);
}

/**
 * Pause or resume. Resuming recomputes the next run from now: a row paused over a month would
 * otherwise be due the instant it came back and fire a turn nobody asked for.
 */
export function setPaused(db: Db, schedule: Schedule, paused: boolean, now: number): Schedule {
  const nextRunAt = paused ? schedule.nextRunAt : (nextRun(schedule.cron, now) ?? schedule.nextRunAt);
  db.update(schedules).set({ paused, nextRunAt }).where(eq(schedules.id, schedule.id)).run();
  return { ...schedule, paused, nextRunAt };
}

export function deleteSchedule(db: Db, schedule: Schedule): void {
  db.delete(schedules).where(eq(schedules.id, schedule.id)).run();
}

function dueRows(db: Db, now: number): (typeof schedules.$inferSelect)[] {
  return db
    .select()
    .from(schedules)
    .where(and(eq(schedules.paused, false), lte(schedules.nextRunAt, now)))
    .orderBy(asc(schedules.id))
    .all();
}

/** What a due job says when it wakes an agent. It names itself, because the row it lands in is
 * an owner message and would otherwise read as the owner typing at four in the morning. */
function delivery(schedule: Schedule): string {
  return (
    `Scheduled task ${schedule.id} (${schedule.cron}) is due. This is your own schedule ` +
    `firing, not the owner writing, so answer here with what came of it.\n\n${schedule.prompt}`
  );
}

/**
 * One pass of the tick: every due row starts a turn in its agent's own thread with the owner.
 *
 * Delivery is the messaging path and nothing else — a row and a `runner.start` — so a busy agent
 * picks the job up through the same drain a peer's message goes through, and no queue or second
 * runner is needed. The message is written as the owner's, because an agent-authored one is
 * excluded from `pendingConversation` (the agent would never wake) or counted by `agentChain`
 * (six fired jobs would refuse its next `send_message`).
 *
 * Synchronous, and the column is advanced *before* the turn is started: `runner.start` returns
 * at once, and a tick that awaited anything here would let the next one see the same rows.
 */
export function runDue(db: Db, runner: Runner, now: number = Date.now()): number {
  let fired = 0;
  for (const row of dueRows(db, now)) {
    const agent = findAgentById(db, row.agentId);
    if (agent === undefined) {
      log.error('schedule belongs to no agent, dropping it', { schedule: row.id });
      db.delete(schedules).where(eq(schedules.id, row.id)).run();
      continue;
    }
    const schedule = toSchedule(row, agent.name);
    // From now, never from the slot that was missed: that is the whole of "a run missed while
    // the daemon was down runs once at boot".
    const due = nextRun(schedule.cron, now);
    if (due === undefined) {
      log.error('schedule has no next run left, dropping it', { schedule: row.id, cron: row.cron });
      // The owner's only trace of a row that vanished on its own. The drop above it gets none:
      // an event needs an agent to belong to and that is the case where there is not one.
      recordEvent(db, agent.id, 'schedule_dropped', { schedule: row.id, cron: row.cron });
      db.delete(schedules).where(eq(schedules.id, row.id)).run();
      continue;
    }
    db.update(schedules).set({ nextRunAt: due, lastRunAt: now }).where(eq(schedules.id, row.id)).run();

    const conversationId = conversationFor(db, agent.id);
    appendMessage(db, conversationId, { role: 'user', content: delivery(schedule) });
    runner.start(agent, conversationId);
    fired += 1;
    log.info('schedule fired', { schedule: schedule.id, agent: agent.name, nextRunAt: due });
  }
  return fired;
}

/**
 * The daemon's one clock. Fires once immediately so a run missed while it was down is picked up
 * at boot rather than up to a tick later, then every `SCHEDULE_TICK_MS`. Unref'd: a timer is not
 * a reason for the process to stay alive.
 */
export function startScheduler(db: Db, runner: Runner): () => void {
  const pass = () => {
    try {
      runDue(db, runner);
    } catch (error) {
      log.error('schedule tick failed', { error });
    }
  };
  pass();
  const timer = setInterval(pass, SCHEDULE_TICK_MS);
  timer.unref();
  return () => clearInterval(timer);
}

/** The agent's own schedules, for the once-per-turn prompt tail, so it knows what it already
 * set up and does not set it up again. */
export function schedulePrompt(list: readonly Schedule[]): string {
  if (list.length === 0) {
    return (
      'You have no scheduled tasks. schedule_task is how you get a turn without anyone writing ' +
      'to you: use it for anything you are asked to do regularly, or to check on something later.'
    );
  }
  return [
    'Your scheduled tasks. Each one starts a turn here when it is due, with the prompt shown:',
    ...list.map(
      (schedule) =>
        `- ${schedule.id}: ${schedule.cron}${schedule.paused ? ' (paused)' : ''} — ${schedule.prompt}`,
    ),
  ].join('\n');
}

const CRON_HELP =
  'a cron expression in the daemon\'s local time, five fields (minute hour day-of-month month ' +
  'day-of-week) or six with seconds in front. Natural language is not accepted: translate it ' +
  'yourself, so "every weekday at 9" is "0 9 * * 1-5".';

/** Built from the constants `parseSchedule` enforces, so the two cannot disagree. */
export function scheduleTaskToolDef(): ToolDef {
  return {
    name: 'schedule_task',
    description:
      'Give yourself a standing job. When it is due you are started with the prompt you give ' +
      'here, in your own thread with the owner, whether or not anyone is awake. The turn it ' +
      `starts is an ordinary one: every tool you have now, you have then. At most ${MAX_SCHEDULES} at a time, ` +
      `and no job fires more often than once every ${SCHEDULE_TICK_MS / 1000} seconds.`,
    parameters: {
      type: 'object',
      properties: {
        cron: { type: 'string', maxLength: MAX_CRON_CHARS, description: CRON_HELP },
        prompt: {
          type: 'string',
          maxLength: MAX_PROMPT_CHARS,
          description:
            'what to do when it fires, written for a future you with none of this conversation ' +
            'in front of it',
        },
      },
      required: ['cron', 'prompt'],
      additionalProperties: false,
    },
  };
}

export function listSchedulesToolDef(): ToolDef {
  return {
    name: 'list_schedules',
    description:
      'Your scheduled tasks with their ids, so you can pause or cancel one. The same list is ' +
      'in your prompt at the start of every turn; use this to see one you just created.',
    parameters: { type: 'object', properties: {}, additionalProperties: false },
  };
}

export function pauseScheduleToolDef(): ToolDef {
  return {
    name: 'pause_schedule',
    description:
      'Stop one of your scheduled tasks firing without losing it, or start it again. Resuming ' +
      'does not make up the runs it missed: the next one is the next time the expression comes ' +
      'round.',
    parameters: {
      type: 'object',
      properties: {
        id: { type: 'integer', description: 'the schedule id, from list_schedules' },
        paused: { type: 'boolean', description: 'true to pause it, false to start it again' },
      },
      required: ['id', 'paused'],
      additionalProperties: false,
    },
  };
}

export function cancelScheduleToolDef(): ToolDef {
  return {
    name: 'cancel_schedule',
    description: 'Delete one of your scheduled tasks. Use pause_schedule if you may want it back.',
    parameters: {
      type: 'object',
      properties: { id: { type: 'integer', description: 'the schedule id, from list_schedules' } },
      required: ['id'],
      additionalProperties: false,
    },
  };
}

/** The id a tool call names, validated before it reaches a query. */
export function parseScheduleId(body: Record<string, unknown>): number | { error: string } {
  const id = body['id'];
  return typeof id === 'number' && Number.isSafeInteger(id) && id > 0
    ? id
    : { error: 'id must be a schedule id' };
}
