import { and, desc, eq, gt, gte, inArray, isNull, ne, notInArray, or, sql } from 'drizzle-orm';
import { IDLE_CONDITIONS } from '@schermes/shared';
import type {
  Agent,
  IdleCondition,
  IdleOutput,
  IdleOutputResolution,
  IdlePass,
  IdlePassOutcome,
  IdleSettings,
} from '@schermes/shared';
import { agentTarget, asAgent, findAgent, findAgentById, isWorker, listAgents } from './agents.ts';
import { CATEGORY_WORDS } from './approvals.ts';
import { SYSTEM_SENDER, appendMessage, conversationFor } from './conversations.ts';
import { MAX_MEMORY_CHARS, MAX_MEMORY_FILE_CHARS, readMemory, writeMemory } from './home.ts';
import { findModel } from './models.ts';
import { classifyCommand, commandNames } from './rules.ts';
import { SCHEDULE_TICK_MS, insertSchedule } from './schedules.ts';
import { agents, conversationParticipants, feedback, idleOutputs, idlePasses, messages } from './schema.ts';
import { log } from './log.ts';
import { TRIGGER_SENDER } from './triggers.ts';
import type { Db } from './db.ts';
import type { Exec } from './exec.ts';
import type { Runner } from './loop.ts';
import type { ToolDef } from './provider.ts';

export const DEFAULT_IDLE: IdleSettings = {
  enabled: false,
  conditions: [...IDLE_CONDITIONS],
  dailyTokens: 200_000,
  turnCap: 20,
  modelId: null,
  startHour: 1,
  endHour: 6,
  pausedReason: null,
};

const MAX_DAILY_TOKENS = 10_000_000;
const MAX_TURN_CAP = 200;
/** A home file untouched this long is stale. */
export const STALE_DAYS = 30;
const MAX_STALE_COUNTED = 1_000;
export const IDLE_FACTS = 'schermes-idle-facts';
/** Who the note that opens an idle turn is from. Not a valid agent name, so never an agent's. */
export const IDLE_SENDER = 'Idle work';
export const LEAVE_NOTE = 'leave_note';
const MAX_NOTE_CHARS = 2_000;
const BACKOFF_DISMISSALS = 3;

export type FileFacts = { memoryBytes: number; staleFiles: number };

export function readIdle(db: Db, agent: Agent): IdleSettings {
  const row = db.select({ idle: agents.idle }).from(agents).where(eq(agents.id, agent.id)).get();
  const stored = row?.idle == null ? {} : (JSON.parse(row.idle) as Partial<IdleSettings>);
  const settings = { ...DEFAULT_IDLE, ...stored };
  // A model deleted from the registry since falls back to the agent's own.
  if (settings.modelId !== null && findModel(db, settings.modelId) === undefined) settings.modelId = null;
  return settings;
}

function wholeIn(value: unknown, min: number, max: number): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= min && value <= max;
}

export function updateIdle(db: Db, agent: Agent, body: Record<string, unknown>): IdleSettings | { error: string } {
  const next = readIdle(db, agent);
  const { enabled, conditions, dailyTokens, turnCap, modelId, startHour, endHour } = body;
  if (enabled !== undefined) {
    if (typeof enabled !== 'boolean') return { error: 'enabled must be true or false' };
    next.enabled = enabled;
    if (enabled) next.pausedReason = null;
  }
  if (conditions !== undefined) {
    if (!Array.isArray(conditions) || !conditions.every((c) => (IDLE_CONDITIONS as readonly unknown[]).includes(c))) {
      return { error: `conditions must be a list of ${IDLE_CONDITIONS.join(', ')}` };
    }
    next.conditions = IDLE_CONDITIONS.filter((c) => conditions.includes(c));
  }
  if (dailyTokens !== undefined) {
    if (!wholeIn(dailyTokens, 1, MAX_DAILY_TOKENS)) return { error: `dailyTokens must be 1 to ${MAX_DAILY_TOKENS}` };
    next.dailyTokens = dailyTokens;
  }
  if (turnCap !== undefined) {
    if (!wholeIn(turnCap, 1, MAX_TURN_CAP)) return { error: `turnCap must be 1 to ${MAX_TURN_CAP}` };
    next.turnCap = turnCap;
  }
  if (modelId !== undefined) {
    if (modelId !== null && (!wholeIn(modelId, 1, Number.MAX_SAFE_INTEGER) || findModel(db, modelId) === undefined)) {
      return { error: 'modelId must be a model in the registry, or null for the agent\'s own' };
    }
    next.modelId = modelId;
  }
  for (const [key, value] of [['startHour', startHour], ['endHour', endHour]] as const) {
    if (value === undefined) continue;
    if (!wholeIn(value, 0, 23)) return { error: `${key} must be an hour from 0 to 23` };
    next[key] = value;
  }
  db.update(agents).set({ idle: JSON.stringify(next) }).where(eq(agents.id, agent.id)).run();
  return next;
}

/** When the window that holds `now` opened, or undefined outside it. */
export function windowOpenedAt(settings: IdleSettings, now: number): number | undefined {
  const open = new Date(now);
  open.setHours(settings.startHour, 0, 0, 0);
  if (open.getTime() > now) open.setDate(open.getDate() - 1);
  const hours = (settings.endHour - settings.startHour + 24) % 24 || 24;
  const close = new Date(open);
  close.setHours(close.getHours() + hours);
  return now < close.getTime() ? open.getTime() : undefined;
}

/** Where the next pre-check looks from: the end of the last pass that ran or was skipped. A
 * matched pass that never ran leaves its signals for the next one. */
function lastFinishedAt(db: Db, agent: Agent): number | undefined {
  const row = db
    .select({ startedAt: idlePasses.startedAt, endedAt: idlePasses.endedAt })
    .from(idlePasses)
    .where(and(eq(idlePasses.agentId, agent.id), ne(idlePasses.outcome, 'due')))
    .orderBy(desc(idlePasses.startedAt), desc(idlePasses.id))
    .get();
  return row === undefined ? undefined : (row.endedAt ?? row.startedAt);
}

function tokensToday(db: Db, agent: Agent, now: number): number {
  const day = new Date(now);
  day.setHours(0, 0, 0, 0);
  const row = db
    .select({ total: sql<number>`coalesce(sum(${idlePasses.tokens}), 0)` })
    .from(idlePasses)
    .where(and(eq(idlePasses.agentId, agent.id), gte(idlePasses.startedAt, day.getTime())))
    .get();
  return row?.total ?? 0;
}

function lastPass(db: Db, agent: Agent) {
  return db
    .select()
    .from(idlePasses)
    .where(eq(idlePasses.agentId, agent.id))
    .orderBy(desc(idlePasses.startedAt), desc(idlePasses.id))
    .get();
}

function toPass(row: typeof idlePasses.$inferSelect, agent: string, outputs: IdleOutput[] = []): IdlePass {
  return {
    id: row.id,
    agent,
    startedAt: row.startedAt,
    matched: JSON.parse(row.matched) as IdleCondition[],
    outcome: row.outcome as IdlePassOutcome,
    tokens: row.tokens,
    endedAt: row.endedAt,
    reason: row.reason,
    outputs,
  };
}

function toOutput(row: typeof idleOutputs.$inferSelect): IdleOutput {
  return {
    id: row.id,
    createdAt: row.createdAt,
    resolved: row.resolved as IdleOutputResolution | null,
    kind: row.kind,
    ...(JSON.parse(row.body) as object),
  } as IdleOutput;
}

type OutputBody<O = IdleOutput> = O extends IdleOutput ? Omit<O, 'id' | 'createdAt' | 'resolved'> : never;

export function addIdleOutput(db: Db, passId: number, output: OutputBody): void {
  const { kind, ...body } = output;
  db.insert(idleOutputs).values({ passId, kind, body: JSON.stringify(body), createdAt: Date.now() }).run();
}

/** Every pass since `since`, oldest first, with what each one left behind. */
export function listIdlePasses(db: Db, since: number): IdlePass[] {
  const rows = db
    .select({ pass: idlePasses, agent: agents.name })
    .from(idlePasses)
    .innerJoin(agents, eq(agents.id, idlePasses.agentId))
    .where(gte(idlePasses.startedAt, since))
    .orderBy(idlePasses.startedAt, idlePasses.id)
    .all();
  const outputs =
    rows.length === 0
      ? []
      : db.select().from(idleOutputs).where(inArray(idleOutputs.passId, rows.map((row) => row.pass.id))).orderBy(idleOutputs.id).all();
  return rows.map((row) =>
    toPass(row.pass, row.agent, outputs.filter((output) => output.passId === row.pass.id).map(toOutput)),
  );
}

/** Which of the agent's enabled conditions hold since `since`. Database reads only, never a
 * model call; file facts are passed in, and missing ones match nothing. */
export function idlePreCheck(db: Db, agent: Agent, since: number, facts: FileFacts | undefined): IdleCondition[] {
  const { conditions } = readIdle(db, agent);
  const holds: Record<IdleCondition, () => boolean> = {
    new_messages: () =>
      db
        .select({ id: messages.id })
        .from(messages)
        .innerJoin(conversationParticipants, eq(conversationParticipants.conversationId, messages.conversationId))
        .where(
          and(
            eq(conversationParticipants.agentId, agent.id),
            gt(messages.createdAt, since),
            ne(messages.role, 'tool'),
            // The note that opened a pass is not news, whenever the pass ended; a fired trigger
            // already had its turn.
            or(isNull(messages.sender), notInArray(messages.sender, [agent.name, IDLE_SENDER, TRIGGER_SENDER, SYSTEM_SENDER])),
          ),
        )
        .get() !== undefined,
    new_feedback: () => {
      const workers = db.select({ name: agents.name }).from(agents).where(eq(agents.parentId, agent.id)).all();
      return (
        db
          .select({ id: feedback.messageId })
          .from(feedback)
          .innerJoin(messages, eq(messages.id, feedback.messageId))
          .where(and(gt(feedback.createdAt, since), inArray(messages.sender, [agent.name, ...workers.map((w) => w.name)])))
          .get() !== undefined
      );
    },
    memory_size: () => facts !== undefined && facts.memoryBytes > MAX_MEMORY_CHARS,
    stale_files: () => facts !== undefined && facts.staleFiles > 0,
  };
  return conditions.filter((condition) => holds[condition]());
}

const FACTS_SCRIPT = `set -u
m="$HOME/memory/MEMORY.md"
if [ -f "$m" ]; then stat -c %s -- "$m"; else echo 0; fi
find "$HOME" -mindepth 1 -maxdepth 3 -type f -mmin +$1 -mmin -$2 -not -path '*/.*' \\
  -not -path "$HOME/memory/*" -not -path "$HOME/skills/*" 2>/dev/null | head -n ${MAX_STALE_COUNTED} | wc -l
`;

export function parseFacts(stdout: string): FileFacts | undefined {
  const [memory, stale] = stdout.trim().split(/\s+/).map(Number);
  return Number.isSafeInteger(memory) && Number.isSafeInteger(stale)
    ? { memoryBytes: memory as number, staleFiles: stale as number }
    : undefined;
}

/** Files that went stale since the last pass, not every old file: otherwise one old download
 * would match every night and the free gate would filter nothing. */
async function fileFacts(exec: Exec, agent: Agent, since: number, now: number): Promise<FileFacts | undefined> {
  const staleMinutes = STALE_DAYS * 1_440;
  const window = [String(staleMinutes), String(staleMinutes + Math.ceil((now - since) / 60_000))];
  try {
    const argv = ['bash', '-c', FACTS_SCRIPT, IDLE_FACTS, ...window];
    const result = await exec('sudo', asAgent(await agentTarget(exec, agent), argv));
    return result.code === 0 ? parseFacts(result.stdout.toString()) : undefined;
  } catch (error) {
    log.error('idle facts failed', { agent: agent.name, error });
    return undefined;
  }
}

const CONDITION_WORDS: Record<IdleCondition, string> = {
  new_messages: 'there are new messages in your threads',
  new_feedback: 'the owner rated replies of yours or your workers',
  memory_size: `your MEMORY.md is past ${MAX_MEMORY_CHARS} bytes`,
  stale_files: `files in your home went ${STALE_DAYS} days untouched`,
};

export function idleNote(matched: readonly IdleCondition[], turnCap: number): string {
  return [
    `Idle work: nobody is waiting on this turn. It runs because ${matched.map((c) => CONDITION_WORDS[c]).join('; ')}.`,
    'What you may leave behind: a tidier ~/memory/MEMORY.md (remember, or rewrite it with run_command; the',
    'owner can undo it), a routine suggestion with schedule_task (it runs only once the owner turns it on),',
    'a note with leave_note, and a cleanup proposal with request_deletion or request_approval in category',
    'delete_files (nothing is deleted). You cannot send, delete, spend or install, and nobody reads your',
    `reply tonight. You have at most ${turnCap} model calls. If nothing is worth doing, say so in one line and stop.`,
  ].join(' ');
}

export function leaveNoteToolDef(): ToolDef {
  return {
    name: LEAVE_NOTE,
    description:
      'Leave the owner a short read-only note, read with the rest of the night\'s work in the morning: ' +
      'something you noticed, a suggestion, a question for later. Nothing is sent.',
    parameters: {
      type: 'object',
      properties: { text: { type: 'string', maxLength: MAX_NOTE_CHARS } },
      required: ['text'],
      additionalProperties: false,
    },
  };
}

export function parseNote(args: Record<string, unknown>): string | { error: string } {
  const text = args['text'];
  if (typeof text !== 'string' || text.trim() === '') return { error: 'text must be a non-empty string' };
  if (text.length > MAX_NOTE_CHARS) return { error: `text must be at most ${MAX_NOTE_CHARS} characters` };
  return text.trim();
}

export const MAIL_SENDERS = new Set(['mail', 'mailx', 'sendmail', 'mutt', 'neomutt', 'msmtp', 'ssmtp', 'swaks']);

/**
 * Why an idle pass may not run this command, whatever the rules say.
 * ponytail: words in command position, like the rules guard. `bash -c`, `curl -X POST`, a script
 * or a file written into place get past it; the idle tool set (no browser, computer, MCP or
 * messaging) is the fence that holds.
 */
export function idleCommandRefusal(command: string): string | undefined {
  const found = classifyCommand(command)[0];
  if (found !== undefined) {
    return (
      `idle work never may ${CATEGORY_WORDS[found.category]}, whatever the rules say. Nothing was run. ` +
      'Propose it instead: request_approval with category delete_files for a cleanup, or leave_note.'
    );
  }
  const sender = commandNames(command).find((name) => MAIL_SENDERS.has(name));
  return sender === undefined ? undefined : `idle work never sends anything (${sender}). Nothing was run. Use leave_note.`;
}

/** MEMORY.md as the agent, or undefined when it cannot be read whole: a copy cut at the read cap
 * would make an undo drop the rest of the file. */
async function memorySnapshot(exec: Exec, agent: Agent): Promise<string | undefined> {
  try {
    const { lasting } = await readMemory(exec, await agentTarget(exec, agent));
    return Buffer.byteLength(lasting) >= MAX_MEMORY_FILE_CHARS ? undefined : lasting;
  } catch (error) {
    log.error('idle memory snapshot failed', { agent: agent.name, error });
    return undefined;
  }
}

/** Closes a pass: its memory diff, its outcome and what it spent. Never throws; it runs in the
 * turn's `finally`. `tokens` undefined means no turn ran (no model). */
async function endPass(
  db: Db,
  exec: Exec,
  agent: Agent,
  pass: { id: number; startedAt: number },
  before: string | undefined,
  tokens: number | undefined,
): Promise<void> {
  try {
    if (tokens === undefined) {
      db.update(idlePasses).set({ reason: 'no model is set up for it' }).where(eq(idlePasses.id, pass.id)).run();
      return;
    }
    if (before !== undefined) {
      const after = await memorySnapshot(exec, agent);
      if (after !== undefined && after !== before) addIdleOutput(db, pass.id, { kind: 'memory', before, after });
    }
    const made = db.select({ id: idleOutputs.id }).from(idleOutputs).where(eq(idleOutputs.passId, pass.id)).get();
    db.update(idlePasses)
      .set({ outcome: made === undefined ? 'wasted' : 'ran', tokens, endedAt: Math.max(Date.now(), pass.startedAt) })
      .where(eq(idlePasses.id, pass.id))
      .run();
    log.info('idle pass ended', { agent: agent.name, pass: pass.id, tokens, wasted: made === undefined });
  } catch (error) {
    log.error('idle pass end failed', { agent: agent.name, pass: pass.id, error });
  }
}

/**
 * One pass of the idle tick: every permanent agent with idle work on, inside its window and not
 * yet checked in this window, is pre-checked and gets a pass row. A match starts a guarded turn
 * in the agent's own thread, unless the day's budget is spent or the agent is busy; then the row
 * stays `due` with the reason.
 */
export async function runIdleChecks(db: Db, exec: Exec, runner: Runner, now: number = Date.now()): Promise<IdlePass[]> {
  const recorded: IdlePass[] = [];
  for (const agent of listAgents(db).filter((candidate) => !isWorker(candidate))) {
    const settings = readIdle(db, agent);
    const opened = windowOpenedAt(settings, now);
    if (!settings.enabled || opened === undefined) continue;
    const last = lastPass(db, agent);
    if (last !== undefined && last.startedAt >= opened) continue;

    const wantsFiles = settings.conditions.some((c) => c === 'memory_size' || c === 'stale_files');
    const since = lastFinishedAt(db, agent) ?? agent.createdAt;
    const facts = wantsFiles ? await fileFacts(exec, agent, since, now) : undefined;
    const matched = idlePreCheck(db, agent, since, facts);
    log.info('idle pre-check', { agent: agent.name, matched });
    if (matched.length === 0) {
      const row = db
        .insert(idlePasses)
        .values({ agentId: agent.id, startedAt: now, endedAt: now, matched: '[]', outcome: 'skipped' })
        .returning()
        .get();
      recorded.push(toPass(row, agent.name));
      continue;
    }

    const spent = tokensToday(db, agent, now);
    const before = spent < settings.dailyTokens && !runner.running(agent.name) ? await memorySnapshot(exec, agent) : undefined;
    // Synchronous from here to the start: a turn begun during an await above would swallow it.
    // Only from rest: an idle turn ends in waiting_for_user, which would hide a failure from
    // Needs you or strand an agent waiting on another's reply or on its worker.
    const state = findAgent(db, agent.name)?.state;
    const reason =
      spent >= settings.dailyTokens
        ? 'the daily token budget is spent'
        : runner.running(agent.name)
          ? `${agent.name} was busy`
          : state !== 'idle' && state !== 'waiting_for_user'
            ? `${agent.name} was ${state ?? 'gone'}`
            : runner.atCapacity(agent.name);
    const row = db
      .insert(idlePasses)
      .values({ agentId: agent.id, startedAt: now, matched: JSON.stringify(matched), outcome: 'due', reason: reason ?? null })
      .returning()
      .get();
    recorded.push(toPass(row, agent.name));
    if (reason !== undefined) continue;
    const thread = conversationFor(db, agent.id);
    appendMessage(db, thread, { role: 'user', content: idleNote(matched, settings.turnCap), sender: IDLE_SENDER });
    runner.start(agent, thread, {
      passId: row.id,
      modelId: settings.modelId,
      turnCap: settings.turnCap,
      tokenLimit: settings.dailyTokens - spent,
      end: (tokens) => endPass(db, exec, agent, row, before, tokens),
    });
  }
  return recorded;
}

/** Stops idle work once the owner has dismissed `BACKOFF_DISMISSALS` notes in a row, and again
 * after each further run of that many, so turning it back on gives the agent fresh strikes. */
function backOff(db: Db, agent: Agent): void {
  const notes = db
    .select({ resolved: idleOutputs.resolved })
    .from(idleOutputs)
    .innerJoin(idlePasses, eq(idlePasses.id, idleOutputs.passId))
    .where(and(eq(idlePasses.agentId, agent.id), eq(idleOutputs.kind, 'note')))
    .orderBy(desc(idleOutputs.id))
    .all();
  const open = notes.findIndex((note) => note.resolved !== 'dismissed');
  const inARow = open === -1 ? notes.length : open;
  if (inARow === 0 || inARow % BACKOFF_DISMISSALS !== 0) return;
  const paused = {
    ...readIdle(db, agent),
    enabled: false,
    pausedReason: `The owner dismissed ${BACKOFF_DISMISSALS} notes in a row.`,
  };
  db.update(agents).set({ idle: JSON.stringify(paused) }).where(eq(agents.id, agent.id)).run();
  log.info('idle work paused', { agent: agent.name, dismissed: inARow });
}

const ACTIONS: Record<IdleOutput['kind'], readonly string[]> = {
  memory: ['undo'],
  routine: ['accept', 'dismiss'],
  note: ['dismiss'],
  cleanup: [],
};

/** The owner acting on one output. */
export async function resolveIdleOutput(
  db: Db,
  exec: Exec,
  id: number,
  action: unknown,
): Promise<IdleOutput | { error: string; status: 400 | 404 | 409 }> {
  const row = db
    .select({ output: idleOutputs, agentId: idlePasses.agentId })
    .from(idleOutputs)
    .innerJoin(idlePasses, eq(idlePasses.id, idleOutputs.passId))
    .where(eq(idleOutputs.id, id))
    .get();
  const agent = row === undefined ? undefined : findAgentById(db, row.agentId);
  if (row === undefined || agent === undefined) return { error: 'no such output', status: 404 };
  const output = toOutput(row.output);
  const allowed = ACTIONS[output.kind];
  if (typeof action !== 'string' || !allowed.includes(action)) {
    return {
      error:
        allowed.length === 0
          ? 'a cleanup is answered as its request in Needs you'
          : `action must be ${allowed.join(' or ')} for a ${output.kind}`,
      status: 400,
    };
  }
  if (output.resolved !== null) return { error: `already ${output.resolved}`, status: 409 };

  if (output.kind === 'memory') {
    const target = await agentTarget(exec, agent);
    if ((await readMemory(exec, target)).lasting !== output.after) {
      return { error: 'MEMORY.md changed after this pass; edit it by hand instead', status: 409 };
    }
    if ((await writeMemory(exec, target, output.before)) !== undefined) {
      return { error: 'MEMORY.md is too large to restore', status: 409 };
    }
  }
  if (output.kind === 'routine' && action === 'accept') {
    const created = insertSchedule(db, agent, { cron: output.cron, prompt: output.prompt }, Date.now());
    if ('error' in created) return { error: created.error, status: 409 };
  }
  const resolved: IdleOutputResolution = action === 'undo' ? 'undone' : action === 'accept' ? 'accepted' : 'dismissed';
  db.update(idleOutputs).set({ resolved }).where(eq(idleOutputs.id, id)).run();
  if (output.kind === 'note') backOff(db, agent);
  return { ...output, resolved };
}

export function startIdleScheduler(db: Db, exec: Exec, runner: Runner): () => void {
  let running = false;
  const pass = async () => {
    if (running) return;
    running = true;
    try {
      await runIdleChecks(db, exec, runner);
    } catch (error) {
      log.error('idle tick failed', { error });
    } finally {
      running = false;
    }
  };
  void pass();
  const timer = setInterval(() => void pass(), SCHEDULE_TICK_MS);
  timer.unref();
  return () => clearInterval(timer);
}
