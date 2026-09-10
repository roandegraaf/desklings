import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { asc, eq } from 'drizzle-orm';
import type { Agent } from '@schermes/shared';
import { config } from './config.ts';
import { log } from './log.ts';
import { agents } from './schema.ts';
import type { Db } from './db.ts';

const run = promisify(execFile);

export const AGENT_NAME = /^[a-z0-9][a-z0-9-]{0,30}$/;

// `:0` is reserved for a physical console and start-desktop.sh takes at most three digits.
const MAX_DISPLAY = 999;

export type DesktopOutcome = 'adopted' | 'started';

export type DesktopOps = {
  ensure(name: string, display: number): Promise<DesktopOutcome>;
};

export const systemDesktop: DesktopOps = {
  async ensure(name, display) {
    await run('sudo', ['-n', `${config.desktopScripts}/create-agent-user.sh`, name]);
    const { stdout } = await run(
      `${config.desktopScripts}/start-desktop.sh`,
      [name, String(display)],
      { env: { ...process.env, SCHERMES_STATE_DIR: config.dataDir } },
    );
    return stdout.startsWith('adopted') ? 'adopted' : 'started';
  },
};

export function listAgents(db: Db): Agent[] {
  return db.select().from(agents).orderBy(asc(agents.display)).all();
}

export function findAgent(db: Db, name: string): Agent | undefined {
  return db.select().from(agents).where(eq(agents.name, name)).get();
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
export function insertAgent(db: Db, name: string): Agent | undefined {
  if (findAgent(db, name) !== undefined) return undefined;
  const display = nextDisplay(listAgents(db).map((agent) => agent.display));
  return db.insert(agents).values({ name, display, createdAt: Date.now() }).returning().get();
}

/** Drops the row only. The Linux user and its home stay, and a retry reuses them. */
export function forgetAgent(db: Db, name: string): void {
  db.delete(agents).where(eq(agents.name, name)).run();
}

export async function reconcileDesktops(db: Db, desktop: DesktopOps): Promise<void> {
  for (const agent of listAgents(db)) {
    try {
      const outcome = await desktop.ensure(agent.name, agent.display);
      log.info('desktop reconciled', { agent: agent.name, display: agent.display, outcome });
    } catch (error) {
      log.error('desktop unavailable', { agent: agent.name, display: agent.display, error });
    }
  }
}
