import { sql } from 'drizzle-orm';
import type { Db } from './db.ts';
import { readMarks } from './schema.ts';

export function listReadMarks(db: Db): Record<string, number> {
  return Object.fromEntries(db.select().from(readMarks).all().map((row) => [row.thread, row.messageId]));
}

/** Only ever moves forward, so a slow device reporting an older mark cannot unread a thread. */
export function markRead(db: Db, thread: string, messageId: number): void {
  db.insert(readMarks)
    .values({ thread, messageId })
    .onConflictDoUpdate({ target: readMarks.thread, set: { messageId: sql`max(${readMarks.messageId}, excluded.message_id)` } })
    .run();
}
