import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { and, asc, eq } from 'drizzle-orm';
import type { Agent, AgentState } from '@schermes/shared';
import { config } from './config.ts';
import { log } from './log.ts';
import { deleteConversation } from './conversations.ts';
import {
  agents,
  approvals,
  conversationParticipants,
  events,
  messages,
  schedules,
  summaries,
} from './schema.ts';
import type { Db } from './db.ts';
import type { Exec } from './exec.ts';

const run = promisify(execFile);

export const AGENT_NAME = /^[a-z0-9][a-z0-9-]{0,30}$/;

export const MAX_LABEL_CHARS = 64;

/**
 * A label is free text, because it is only ever displayed: no Linux user, no path, no shell and
 * no tool schema is built from one. The rule is a one-line string of a readable length — control
 * characters are out because a label is shown in a row, not a paragraph. A look, the token a
 * client draws the avatar from, is held to the same rule: the daemon stores it and reads none
 * of it.
 */
export function cleanLabel(raw: string): string | undefined {
  const label = raw.trim();
  if (label === '' || [...label].length > MAX_LABEL_CHARS) return undefined;
  return /[\u0000-\u001f\u007f]/.test(label) ? undefined : label;
}

// `:0` is reserved for a physical console and start-desktop.sh takes at most three digits.
export const MAX_DISPLAY = 999;

export type DesktopOutcome = 'adopted' | 'started';

export type DesktopOps = {
  ensure(name: string, display: number): Promise<DesktopOutcome>;
  /** Everything this agent is running, stopped. Called when the agent is deleted: its display
   * number goes back in the pool, and an Xvnc still holding it would take the next agent's. */
  stop(name: string): Promise<void>;
  /** Moves the Linux user and its home to a new name. Only with the desktop stopped: usermod
   * refuses a user that still has processes. */
  rename(from: string, to: string): Promise<void>;
};

export const systemDesktop: DesktopOps = {
  async stop(name) {
    const user = `agent-${name}`;
    // Xvnc, the window manager, the dock and whatever the agent left running, in one signal.
    // `pkill` exits 1 when nothing matched, which is a desktop that was already down.
    await run('sudo', ['-n', '-u', user, 'pkill', '-u', user]).catch(() => undefined);
  },

  async rename(from, to) {
    await run('sudo', ['-n', `${config.desktopScripts}/rename-agent-user.sh`, from, to]);
  },

  async ensure(name, display) {
    await run('sudo', ['-n', `${config.desktopScripts}/create-agent-user.sh`, name]);
    const { stdout } = await run(
      `${config.desktopScripts}/start-desktop.sh`,
      [name, String(display)],
      {
        env: {
          ...process.env,
          SCHERMES_STATE_DIR: config.dataDir,
          SCHERMES_GEOMETRY: `${config.screen.display.width}x${config.screen.display.height}`,
        },
      },
    );
    return stdout.startsWith('adopted') ? 'adopted' : 'started';
  },
};

/**
 * Everything needed to act as an agent: who to become, where it lives, which display it owns.
 * `cwd` is where its commands start, which is its home unless a task worker is running as it,
 * in which case the worker's own directory under the workspace is.
 */
export type AgentTarget = { user: string; home: string; display: number; cwd?: string };

export async function agentTarget(exec: Exec, agent: Agent): Promise<AgentTarget> {
  const user = `agent-${agent.name}`;
  const { code, stdout } = await exec('getent', ['passwd', user]);
  const home = stdout.toString().trim().split(':')[5];
  if (code !== 0 || home === undefined || home === '') {
    throw new Error(`no home directory for ${user}`);
  }
  return { user, home, display: agent.display };
}

/**
 * The argv that turns a command into that command run as the agent. `sudo` strips the
 * environment, so all five variables an X client needs are passed explicitly, and `--chdir`
 * comes before them because `env` treats the first non-assignment operand as the command.
 */
export function asAgent(target: AgentTarget, argv: readonly string[]): string[] {
  return [
    '-n',
    '-u',
    target.user,
    'env',
    `--chdir=${target.cwd ?? target.home}`,
    `HOME=${target.home}`,
    `USER=${target.user}`,
    `LOGNAME=${target.user}`,
    `DISPLAY=:${target.display}`,
    `XAUTHORITY=${target.home}/.Xauthority`,
    ...argv,
  ];
}

function toAgent(row: typeof agents.$inferSelect): Agent {
  const { label, look, profile, parentId, parentConversationId, ...rest } = row;
  return {
    ...rest,
    state: row.state as AgentState,
    ...(label === null ? {} : { label }),
    ...(look === null ? {} : { look }),
    ...(profile === null ? {} : { profile }),
    ...(parentId === null ? {} : { parentId }),
    ...(parentConversationId === null ? {} : { parentConversationId }),
  };
}

/** A task worker is an agent row with a parent. Everything else here is a permanent agent. */
export function isWorker(agent: Agent): boolean {
  return agent.parentId !== undefined;
}

export function listAgents(db: Db): Agent[] {
  return db.select().from(agents).orderBy(asc(agents.display)).all().map(toAgent);
}

export function findAgent(db: Db, name: string): Agent | undefined {
  const row = db.select().from(agents).where(eq(agents.name, name)).get();
  return row === undefined ? undefined : toAgent(row);
}

/** An agent with a desktop of its own, which is what a viewer and an input owner need. A task
 * worker shares its parent's and its `display` is a placeholder, so it is not one. */
export function desktopAgent(db: Db, name: string): Agent | undefined {
  const agent = findAgent(db, name);
  return agent === undefined || isWorker(agent) ? undefined : agent;
}

export function findAgentById(db: Db, id: number): Agent | undefined {
  const row = db.select().from(agents).where(eq(agents.id, id)).get();
  return row === undefined ? undefined : toAgent(row);
}

export function setAgentState(db: Db, name: string, state: AgentState): void {
  db.update(agents).set({ state }).where(eq(agents.name, name)).run();
}

export function nextDisplay(taken: readonly number[]): number {
  const used = new Set(taken);
  for (let display = 1; display <= MAX_DISPLAY; display += 1) {
    if (!used.has(display)) return display;
  }
  throw new Error(`every display up to :${MAX_DISPLAY} is taken`);
}

/**
 * Synchronous from the name check to the insert, so two in-flight requests cannot read the
 * same set of taken displays. Returns undefined when the name is already taken.
 */
export function insertAgent(
  db: Db,
  name: string,
  cosmetics: { label?: string; look?: string } = {},
): Agent | undefined {
  if (findAgent(db, name) !== undefined) return undefined;
  const display = nextDisplay(listAgents(db).map((agent) => agent.display));
  return toAgent(
    db
      .insert(agents)
      .values({
        name,
        label: cosmetics.label ?? null,
        look: cosmetics.look ?? null,
        display,
        createdAt: Date.now(),
      })
      .returning()
      .get(),
  );
}

/** Changes what the owner sees and what the agent is told it is. A null profile clears it. */
export function setAgentCosmetics(
  db: Db,
  name: string,
  cosmetics: { label?: string; look?: string; profile?: string | null },
): void {
  db.update(agents).set(cosmetics).where(eq(agents.name, name)).run();
}

/**
 * The row and every string that spells its name: what it sent, the summaries written for it,
 * and a pending request to delete it. Rows keyed on its id need nothing. Its task workers keep
 * the names they were born with; the next one is named after the new stem.
 */
export function renameAgent(db: Db, agent: Agent, name: string): Agent {
  return db.transaction((tx) => {
    tx.update(agents).set({ name }).where(eq(agents.id, agent.id)).run();
    tx.update(messages).set({ sender: name }).where(eq(messages.sender, agent.name)).run();
    tx.update(summaries).set({ sender: name }).where(eq(summaries.sender, agent.name)).run();
    tx.update(approvals)
      .set({ target: name })
      .where(and(eq(approvals.kind, 'agent'), eq(approvals.target, agent.name)))
      .run();
    return toAgent(tx.select().from(agents).where(eq(agents.id, agent.id)).get()!);
  });
}

/**
 * A worker drives no display of its own — it shares its parent's — but the column is unique and
 * not null, so its row takes the next number above the range a desktop can use. `nextDisplay`
 * stops at `MAX_DISPLAY`, so the two allocators can never hand out the same number.
 */
function nextWorkerDisplay(db: Db): number {
  return Math.max(MAX_DISPLAY, ...listAgents(db).map((agent) => agent.display)) + 1;
}

/**
 * The name the parent's next worker gets, or undefined when none is left. It counts every
 * worker this parent has ever had rather than the live ones, so a finished worker's name is
 * never handed out twice — and a parent named close to the length limit runs out of names.
 */
export function nextWorkerName(db: Db, parent: Agent): string | undefined {
  const born = db.select().from(agents).where(eq(agents.parentId, parent.id)).all().length;
  const name = `${parent.name}-w${born + 1}`;
  return AGENT_NAME.test(name) && findAgent(db, name) === undefined ? name : undefined;
}

/**
 * A task worker: an agent row with a parent, so the loop, the event log and the conversations
 * work on it unchanged. What it does not get is a Linux user, a desktop or a display of its
 * own — it runs as its parent, in the directory its parent made for it.
 */
export function insertWorker(
  db: Db,
  parent: Agent,
  name: string,
  parentConversationId: number,
): Agent {
  return toAgent(
    db
      .insert(agents)
      .values({
        name,
        display: nextWorkerDisplay(db),
        parentId: parent.id,
        parentConversationId,
        createdAt: Date.now(),
      })
      .returning()
      .get(),
  );
}

/** Drops the row only. The Linux user and its home stay, and a retry reuses them. */
export function forgetAgent(db: Db, name: string): void {
  db.delete(agents).where(eq(agents.name, name)).run();
}

/**
 * An agent and everything hanging off it: its task workers, their threads, its schedules, its
 * events, the approvals it asked for, and every thread it was the only agent in. A thread it
 * shared with somebody else outlives it, minus its own messages and its seat in it.
 *
 * The Linux user and its home stay, as `forgetAgent` leaves them: a home is the agent's work,
 * and nothing here is worth destroying it for. Stopping the desktop is `DesktopOps.stop`, which
 * the route calls before this — the row is what frees the display number.
 */
export function deleteAgent(db: Db, agent: Agent): void {
  for (const worker of db.select().from(agents).where(eq(agents.parentId, agent.id)).all()) {
    deleteAgent(db, toAgent(worker));
  }

  const seats = db
    .select()
    .from(conversationParticipants)
    .where(eq(conversationParticipants.agentId, agent.id))
    .all();

  db.delete(approvals).where(eq(approvals.agentId, agent.id)).run();
  db.delete(schedules).where(eq(schedules.agentId, agent.id)).run();
  db.delete(events).where(eq(events.agentId, agent.id)).run();
  db.delete(conversationParticipants).where(eq(conversationParticipants.agentId, agent.id)).run();
  db.delete(messages).where(eq(messages.sender, agent.name)).run();
  db.delete(summaries).where(eq(summaries.sender, agent.name)).run();
  db.delete(agents).where(eq(agents.id, agent.id)).run();

  // A thread nobody is left in is nobody's: an approval pointing at it would outlive what it
  // names, and the owner could never reach it again.
  for (const seat of seats) {
    const left = db
      .select()
      .from(conversationParticipants)
      .where(eq(conversationParticipants.conversationId, seat.conversationId))
      .all();
    if (left.length === 0) deleteConversation(db, seat.conversationId);
  }
}

/**
 * Only permanent agents get here. A task worker has no Linux user and no display of its own —
 * its `display` is a placeholder above the range — so handing one to `start-desktop.sh`, which
 * takes at most three digits, would break the boot rather than start anything.
 */
export async function reconcileDesktops(db: Db, desktop: DesktopOps): Promise<void> {
  for (const agent of listAgents(db).filter((candidate) => !isWorker(candidate))) {
    try {
      const outcome = await desktop.ensure(agent.name, agent.display);
      log.info('desktop reconciled', { agent: agent.name, display: agent.display, outcome });
    } catch (error) {
      log.error('desktop unavailable', { agent: agent.name, display: agent.display, error });
    }
  }
}
