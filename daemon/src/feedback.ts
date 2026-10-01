import { and, eq, inArray } from 'drizzle-orm';
import type { Db } from './db.ts';
import { feedback, messages } from './schema.ts';
import type { FeedbackRating, Message, MessageFeedback } from '@schermes/shared';

export const MAX_FEEDBACK_REASON_CHARS = 500;
const EXCERPT_CHARS = 120;
export const FEEDBACK_HEADING = '## Feedback';

export type FeedbackUpdate = { rating: FeedbackRating | null; reason?: string };

export function parseFeedback(body: Record<string, unknown>): FeedbackUpdate | { error: string } {
  const rating = body['rating'];
  if (rating !== 'up' && rating !== 'down' && rating !== null) {
    return { error: "rating must be 'up', 'down' or null" };
  }
  const reason = body['reason'];
  if (reason !== undefined && reason !== null && typeof reason !== 'string') {
    return { error: 'reason must be a string' };
  }
  if (typeof reason === 'string' && reason.length > MAX_FEEDBACK_REASON_CHARS) {
    return { error: `reason must be at most ${MAX_FEEDBACK_REASON_CHARS} characters` };
  }
  const cleaned = typeof reason === 'string' ? oneLine(reason) : '';
  return cleaned === '' ? { rating } : { rating, reason: cleaned };
}

/** An agent's reply the owner can rate: an assistant row with an agent behind it. */
export function findReply(db: Db, messageId: number): { content: string; sender: string } | undefined {
  const row = db
    .select({ content: messages.content, sender: messages.sender })
    .from(messages)
    .where(and(eq(messages.id, messageId), eq(messages.role, 'assistant')))
    .get();
  return row?.sender == null ? undefined : { content: row.content, sender: row.sender };
}

export function findFeedback(db: Db, messageId: number): MessageFeedback | undefined {
  const row = db.select().from(feedback).where(eq(feedback.messageId, messageId)).get();
  return row === undefined ? undefined : toFeedback(row);
}

export function setFeedback(db: Db, messageId: number, update: FeedbackUpdate): MessageFeedback | undefined {
  if (update.rating === null) {
    db.delete(feedback).where(eq(feedback.messageId, messageId)).run();
    return undefined;
  }
  const row = { rating: update.rating, reason: update.reason ?? null, createdAt: Date.now() };
  db.insert(feedback)
    .values({ messageId, ...row })
    .onConflictDoUpdate({ target: feedback.messageId, set: row })
    .run();
  return findFeedback(db, messageId);
}

export function withFeedback(db: Db, rows: Message[]): Message[] {
  const ids = rows.filter((row) => row.role === 'assistant').map((row) => row.id);
  if (ids.length === 0) return rows;
  const found = new Map(
    db.select().from(feedback).where(inArray(feedback.messageId, ids)).all().map((row) => [row.messageId, toFeedback(row)]),
  );
  return rows.map((row) => {
    const given = found.get(row.id);
    return given === undefined ? row : { ...row, feedback: given };
  });
}

/** The memory line a thumbs down leaves: one line, so neither the reply nor the reason can start
 * a heading or break the list. */
export function feedbackLine(reply: string, reason: string | undefined, now = new Date()): string {
  const said = oneLine(reply);
  const excerpt = said.length > EXCERPT_CHARS ? `${said.slice(0, EXCERPT_CHARS - 1)}…` : said;
  const why = reason === undefined ? 'no reason given' : `"${reason}"`;
  return `${now.toISOString().slice(0, 10)}: the owner gave a thumbs down on "${excerpt}": ${why}`;
}

function oneLine(text: string): string {
  return text.trim().replace(/\s+/g, ' ');
}

function toFeedback(row: typeof feedback.$inferSelect): MessageFeedback {
  return {
    rating: row.rating as FeedbackRating,
    ...(row.reason === null ? {} : { reason: row.reason }),
  };
}
