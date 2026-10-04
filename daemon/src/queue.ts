import { asc, eq, max } from 'drizzle-orm';
import type { Db } from './db.ts';
import { agents, messages, turnQueue } from './schema.ts';

/** What put a turn in line. Only recorded: the row the turn will read is already in the thread. */
export type TurnKind =
  | 'message'
  | 'request'
  | 'reply'
  | 'report'
  | 'schedule'
  | 'trigger'
  | 'approval'
  | 'answer'
  | 'kickoff'
  | 'requeue'
  /** The owner rewound and asked again: no new row, so it runs whatever the read mark says. */
  | 'retry';

export type QueuedTurn = {
  id: number;
  agentId: number;
  conversationId: number;
  kind: TurnKind;
  createdAt: number;
};

/** One entry per agent and thread: a second arrival is read by the same turn as the first. A
 * retry keeps the entry's place in line and makes it one. */
export function enqueueTurn(db: Db, agentId: number, conversationId: number, kind: TurnKind): void {
  const insert = db.insert(turnQueue).values({ agentId, conversationId, kind, createdAt: Date.now() });
  if (kind === 'retry') {
    insert.onConflictDoUpdate({ target: [turnQueue.agentId, turnQueue.conversationId], set: { kind } }).run();
  } else {
    insert.onConflictDoNothing().run();
  }
}

export function queuedTurns(db: Db): QueuedTurn[] {
  return db
    .select()
    .from(turnQueue)
    .orderBy(asc(turnQueue.id))
    .all()
    .map((row) => ({ ...row, kind: row.kind as TurnKind }));
}

export function dequeueTurn(db: Db, id: number): void {
  db.delete(turnQueue).where(eq(turnQueue.id, id)).run();
}

export function isQueued(db: Db, agentId: number): boolean {
  return db.select({ id: turnQueue.id }).from(turnQueue).where(eq(turnQueue.agentId, agentId)).get() !== undefined;
}

/** Written as a turn starts, never later: a turn that kills the daemon has read its input, and
 * boot must not run it again. */
export function markRead(db: Db, agentId: number, through: number): void {
  db.update(agents).set({ readThrough: through }).where(eq(agents.id, agentId)).run();
}

/** Past this, a message to the agent is one no turn of its has started from. */
export function readThrough(db: Db, agentId: number, name: string): number {
  const row = db.select({ id: agents.readThrough }).from(agents).where(eq(agents.id, agentId)).get();
  const own = db.select({ id: max(messages.id) }).from(messages).where(eq(messages.sender, name)).get()?.id ?? 0;
  return Math.max(row?.id ?? 0, own);
}
