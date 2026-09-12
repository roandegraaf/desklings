import Database from 'better-sqlite3';
import { drizzle } from 'drizzle-orm/better-sqlite3';
import { migrate } from 'drizzle-orm/better-sqlite3/migrator';
import * as schema from './schema.ts';

export type Db = ReturnType<typeof openDb>;

/**
 * Foreign keys are off across the migrations and on for everything after. That is step 1 of
 * SQLite's own table-recreate procedure, and it has to happen *outside* the transaction: drizzle
 * wraps every migration file in one, where `PRAGMA foreign_keys` is a documented no-op, so a
 * generated recreate drops a table its children still reference and the whole upgrade fails on
 * any database that has rows in them. `foreign_key_check` is the same procedure's last step and
 * is fatal here: a daemon that booted on a referentially broken database would write more rows
 * into it.
 */
export function openDb(path: string, migrationsFolder: string) {
  const sqlite = new Database(path);
  sqlite.pragma('journal_mode = WAL');
  sqlite.pragma('foreign_keys = OFF');
  const db = drizzle(sqlite, { schema });
  migrate(db, { migrationsFolder });
  const dangling = sqlite.pragma('foreign_key_check') as unknown[];
  if (dangling.length > 0) {
    throw new Error(`migrations left dangling references: ${JSON.stringify(dangling)}`);
  }
  sqlite.pragma('foreign_keys = ON');
  return db;
}
