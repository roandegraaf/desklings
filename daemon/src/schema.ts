import { integer, sqliteTable, text } from 'drizzle-orm/sqlite-core';

/** Single-row table: schermes has one owner, not a user list. */
export const owner = sqliteTable('owner', {
  id: integer('id').primaryKey(),
  passwordHash: text('password_hash').notNull(),
  createdAt: integer('created_at').notNull(),
});

export const sessions = sqliteTable('sessions', {
  id: text('id').primaryKey(),
  createdAt: integer('created_at').notNull(),
  expiresAt: integer('expires_at').notNull(),
});

export const settings = sqliteTable('settings', {
  key: text('key').primaryKey(),
  value: text('value').notNull(),
  encrypted: integer('encrypted', { mode: 'boolean' }).notNull().default(false),
});
