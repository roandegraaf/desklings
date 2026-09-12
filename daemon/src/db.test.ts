import assert from 'node:assert/strict';
import test from 'node:test';
import { cpSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import Database from 'better-sqlite3';
import { sql } from 'drizzle-orm';
import { openDb } from './db.ts';
import { findAgent } from './agents.ts';
import { appendMessage, conversationFor, listMessages } from './conversations.ts';

const MIGRATIONS = resolve(import.meta.dirname, '../migrations');

/** A copy of the migrations folder holding only the first `count` of them, which is what a
 * database that last ran an older schermes has applied. Drizzle reads the journal, not the
 * directory listing, so trimming it is enough to stop there. */
function migrationsUpTo(count: number): string {
  const dir = mkdtempSync(join(tmpdir(), 'schermes-migrations-'));
  cpSync(MIGRATIONS, dir, { recursive: true });
  const journal = JSON.parse(readFileSync(join(MIGRATIONS, 'meta/_journal.json'), 'utf8')) as {
    entries: unknown[];
  };
  journal.entries = journal.entries.slice(0, count);
  writeFileSync(join(dir, 'meta/_journal.json'), JSON.stringify(journal));
  return dir;
}

function dbFile(): string {
  return join(mkdtempSync(join(tmpdir(), 'schermes-db-')), 'schermes.db');
}

test('the migrations run against a database that already holds an agent, a thread and messages', () => {
  const file = dbFile();

  // The schema as of 0002: a conversation belonged to one agent and carried its id, so these
  // rows cannot be written through the current drizzle tables.
  const old = openDb(file, migrationsUpTo(3));
  old.run(sql`INSERT INTO agents (name, display, state, created_at) VALUES ('veteran', 1, 'idle', 1)`);
  old.run(sql`INSERT INTO conversations (agent_id, created_at) VALUES (1, 10)`);
  old.run(sql`INSERT INTO messages (conversation_id, role, content, created_at) VALUES (1, 'user', 'hello', 11)`);
  old.run(sql`INSERT INTO messages (conversation_id, role, content, created_at) VALUES (1, 'assistant', 'hi', 12)`);
  old.run(sql`INSERT INTO events (agent_id, type, data, created_at) VALUES (1, 'state', '{}', 13)`);
  old.$client.close();

  const db = openDb(file, MIGRATIONS);
  const agent = findAgent(db, 'veteran');
  assert.ok(agent !== undefined);
  assert.equal(agent.state, 'idle');

  // 0003's backfill is the one statement in the repo that only does anything on a populated
  // database: the thread that belonged to this agent is now the thread it participates in.
  assert.equal(conversationFor(db, agent.id), 1);
  assert.deepEqual(
    listMessages(db, 1).map((message) => message.content),
    ['hello', 'hi'],
  );

  // The recreated table really is the new shape, and it still takes writes.
  appendMessage(db, 1, { role: 'user', content: 'still here' });
  assert.equal(listMessages(db, 1).length, 3);
});

test('a database with a dangling reference refuses to open', () => {
  const file = dbFile();
  openDb(file, MIGRATIONS).$client.close();

  // What a migration that dropped the wrong table would leave behind. Foreign keys are off here
  // for the same reason they are off across the migrations: this is the shape being simulated.
  const broken = new Database(file);
  broken.pragma('foreign_keys = OFF');
  broken.exec(
    "INSERT INTO messages (conversation_id, role, content, created_at) VALUES (4242, 'user', 'orphan', 1)",
  );
  broken.close();

  assert.throws(() => openDb(file, MIGRATIONS), /dangling references/);
});

test('a migrated database still enforces its foreign keys', () => {
  const db = openDb(dbFile(), MIGRATIONS);
  // Drizzle wraps the driver's error, so the constraint failure is the cause rather than the
  // message: what matters is that the pragma the migrations turned off was turned back on.
  assert.throws(
    () =>
      db.run(
        sql`INSERT INTO messages (conversation_id, role, content, created_at) VALUES (4242, 'user', 'x', 1)`,
      ),
    (error: Error) => /FOREIGN KEY/.test(String((error as { cause?: unknown }).cause)),
  );
});
