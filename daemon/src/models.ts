import { eq, inArray, like } from 'drizzle-orm';
import type { Agent, ModelEntry, ProviderSettings } from '@schermes/shared';
import { findAgentById } from './agents.ts';
import type { Db } from './db.ts';
import type { ProviderConfig } from './provider.ts';
import { agents, models, settings } from './schema.ts';
import { decrypt, encrypt } from './secrets.ts';

const DEFAULT = 'models.default';
const BACKUP = 'models.backup';
const AUTH_FAILED = 'models.authFailed.';
const LEGACY = {
  baseUrl: 'provider.baseUrl',
  model: 'provider.model',
  apiKey: 'provider.apiKey',
  extraBody: 'provider.extraBody',
} as const;

export type ModelFields = {
  name?: string | undefined;
  baseUrl?: string | undefined;
  model?: string | undefined;
  /** Plain text in, encrypted at rest; empty removes the key. */
  apiKey?: string | undefined;
  extraBody?: string | undefined;
};

type Row = typeof models.$inferSelect;

function readSetting(db: Db, key: string): string | undefined {
  return db.select().from(settings).where(eq(settings.key, key)).get()?.value;
}

function writeSetting(db: Db, key: string, value: number | undefined): void {
  if (value === undefined) {
    db.delete(settings).where(eq(settings.key, key)).run();
    return;
  }
  db.insert(settings)
    .values({ key, value: String(value), encrypted: false })
    .onConflictDoUpdate({ target: settings.key, set: { value: String(value) } })
    .run();
}

function roleId(db: Db, key: string): number | undefined {
  const value = readSetting(db, key);
  return value === undefined ? undefined : Number(value);
}

export const defaultModelId = (db: Db) => roleId(db, DEFAULT);
export const backupModelId = (db: Db) => roleId(db, BACKUP);

function row(db: Db, id: number): Row | undefined {
  return db.select().from(models).where(eq(models.id, id)).get();
}

function toEntry(db: Db, entry: Row): ModelEntry {
  return {
    id: entry.id,
    name: entry.name,
    baseUrl: entry.baseUrl,
    model: entry.model,
    apiKeySet: entry.apiKey !== null,
    extraBody: entry.extraBody,
    isDefault: defaultModelId(db) === entry.id,
    isBackup: backupModelId(db) === entry.id,
    createdAt: entry.createdAt,
  };
}

export function listModels(db: Db): ModelEntry[] {
  return db.select().from(models).orderBy(models.id).all().map((entry) => toEntry(db, entry));
}

export function findModel(db: Db, id: number): ModelEntry | undefined {
  const entry = row(db, id);
  return entry === undefined ? undefined : toEntry(db, entry);
}

function columns(masterKey: Buffer, fields: ModelFields) {
  return {
    ...(fields.name === undefined ? {} : { name: fields.name }),
    ...(fields.baseUrl === undefined ? {} : { baseUrl: fields.baseUrl }),
    ...(fields.model === undefined ? {} : { model: fields.model }),
    ...(fields.extraBody === undefined ? {} : { extraBody: fields.extraBody }),
    ...(fields.apiKey === undefined ? {} : { apiKey: fields.apiKey === '' ? null : encrypt(masterKey, fields.apiKey) }),
  };
}

/** The first model there is becomes the default: with none, no agent could run at all. */
export function createModel(db: Db, masterKey: Buffer, fields: ModelFields): ModelEntry {
  const created = db
    .insert(models)
    .values({
      name: fields.name ?? '',
      baseUrl: fields.baseUrl ?? '',
      model: fields.model ?? '',
      createdAt: Date.now(),
      ...columns(masterKey, fields),
    })
    .returning()
    .get();
  if (defaultModelId(db) === undefined) writeSetting(db, DEFAULT, created.id);
  return toEntry(db, created);
}

export function updateModel(db: Db, masterKey: Buffer, id: number, fields: ModelFields): ModelEntry | undefined {
  const set = columns(masterKey, fields);
  if (fields.apiKey !== undefined) clearAuthFailure(db, id);
  if (Object.keys(set).length > 0) db.update(models).set(set).where(eq(models.id, id)).run();
  return findModel(db, id);
}

/** Refused while an agent is assigned to it, and for the default while another model could take
 * its place; the owner picks that one. Deleting the backup just leaves no backup. */
export function deleteModel(db: Db, id: number): { ok: true } | { error: string; status: 404 | 409 } {
  if (row(db, id) === undefined) return { error: 'no such model', status: 404 };
  const assigned = db.select({ name: agents.name }).from(agents).where(eq(agents.modelId, id)).all();
  if (assigned.length > 0) {
    return { error: `${assigned.map((agent) => agent.name).join(', ')} still use this model`, status: 409 };
  }
  if (defaultModelId(db) === id && listModels(db).length > 1) {
    return { error: 'make another model the default first', status: 409 };
  }
  db.delete(models).where(eq(models.id, id)).run();
  clearAuthFailure(db, id);
  if (defaultModelId(db) === id) writeSetting(db, DEFAULT, undefined);
  if (backupModelId(db) === id) writeSetting(db, BACKUP, undefined);
  return { ok: true };
}

export function setDefaultModel(db: Db, id: number): boolean {
  if (row(db, id) === undefined) return false;
  writeSetting(db, DEFAULT, id);
  return true;
}

export function setBackupModel(db: Db, id: number | null): boolean {
  if (id !== null && row(db, id) === undefined) return false;
  writeSetting(db, BACKUP, id ?? undefined);
  return true;
}

export function assignModel(db: Db, agentName: string, id: number | null): boolean {
  if (id !== null && row(db, id) === undefined) return false;
  db.update(agents).set({ modelId: id }).where(eq(agents.name, agentName)).run();
  return true;
}

function config(masterKey: Buffer, entry: Row | undefined): ProviderConfig | undefined {
  if (entry === undefined || !entry.baseUrl || !entry.model || entry.apiKey === null) return undefined;
  const apiKey = decrypt(masterKey, entry.apiKey);
  if (apiKey === '') return undefined;
  const extraBody = parseExtraBody(entry.extraBody);
  return { baseUrl: entry.baseUrl, model: entry.model, apiKey, ...(extraBody === undefined ? {} : { extraBody }) };
}

export function modelConfig(db: Db, masterKey: Buffer, id: number): ProviderConfig | undefined {
  return config(masterKey, row(db, id));
}

/**
 * The one place a model call finds its endpoint: the agent's own model, else the default. A
 * worker runs on its parent's. Undefined until the owner has finished setting one up.
 */
export function providerConfig(db: Db, masterKey: Buffer, agent?: Agent): ProviderConfig | undefined {
  const id = modelIdFor(db, agent);
  return id === undefined ? undefined : modelConfig(db, masterKey, id);
}

export function modelIdFor(db: Db, agent?: Agent): number | undefined {
  const owner = agent === undefined ? undefined : findAgentById(db, agent.parentId ?? agent.id);
  return owner?.modelId ?? defaultModelId(db);
}

/** The backup a turn on `activeId` may switch to: set, usable, and not the model already in use. */
export function backupConfig(
  db: Db,
  masterKey: Buffer,
  activeId: number | undefined,
): { id: number; name: string; config: ProviderConfig } | undefined {
  const id = backupModelId(db);
  if (id === undefined || id === activeId) return undefined;
  const entry = row(db, id);
  const resolved = config(masterKey, entry);
  return entry === undefined || resolved === undefined ? undefined : { id, name: entry.name, config: resolved };
}

/** A model whose key the endpoint refused: one per model, whichever agent hit it first. */
export type AuthFailure = {
  modelId: number;
  modelName: string;
  agent: string;
  conversationId: number;
  error: string;
  at: number;
};

/**
 * A settings row per refused model, so the owner sees it once however many agents run on it. The
 * first refusal is kept; a changed key, a delete or any call that answers clears it.
 */
export function recordAuthFailure(db: Db, failure: Omit<AuthFailure, 'modelName' | 'at'>): void {
  db.insert(settings)
    .values({
      key: `${AUTH_FAILED}${failure.modelId}`,
      value: JSON.stringify({ ...failure, at: Date.now() }),
      encrypted: false,
    })
    .onConflictDoNothing()
    .run();
}

export function clearAuthFailure(db: Db, modelId: number): void {
  const key = `${AUTH_FAILED}${modelId}`;
  if (readSetting(db, key) !== undefined) db.delete(settings).where(eq(settings.key, key)).run();
}

export function listAuthFailures(db: Db): AuthFailure[] {
  return db
    .select()
    .from(settings)
    .where(like(settings.key, `${AUTH_FAILED}%`))
    .all()
    .flatMap((entry) => {
      const failure = JSON.parse(entry.value) as Omit<AuthFailure, 'modelName'>;
      const model = row(db, failure.modelId);
      return model === undefined ? [] : [{ ...failure, modelName: model.name }];
    });
}

/** The stored text as the request body fields it stands for; undefined when it is not a JSON
 * object, which is also what an empty setting is. */
export function parseExtraBody(text: string | undefined): Record<string, unknown> | undefined {
  if (text === undefined || text.trim() === '') return undefined;
  try {
    const parsed: unknown = JSON.parse(text);
    return parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : undefined;
  } catch {
    return undefined;
  }
}

/** The old single-provider settings, now the default entry, for the settings screen that still
 * reads and writes them. */
export function readProviderSettings(db: Db): ProviderSettings {
  const id = defaultModelId(db);
  const entry = id === undefined ? undefined : row(db, id);
  return {
    baseUrl: entry?.baseUrl ?? '',
    model: entry?.model ?? '',
    apiKeySet: entry !== undefined && entry.apiKey !== null,
    extraBody: entry?.extraBody ?? '',
  };
}

export function writeProviderSettings(db: Db, masterKey: Buffer, fields: Omit<ModelFields, 'name'>): void {
  if (Object.values(fields).every((value) => value === undefined)) return;
  const id = defaultModelId(db);
  if (id === undefined) createModel(db, masterKey, { name: fields.model || 'Default', ...fields });
  else updateModel(db, masterKey, id, fields);
}

/**
 * Boot step, after the migrations: the single `provider.*` setting becomes the first model and
 * the default, and its rows go. In code rather than in the generated SQL, which stays generated.
 * The key moves as ciphertext, so no master key is needed. Runs once: the rows it reads are gone
 * afterwards, and it never runs over a registry that already has entries.
 */
export function migrateProviderSettings(db: Db): void {
  const legacy = Object.fromEntries(
    Object.entries(LEGACY).map(([field, key]) => [field, readSetting(db, key)]),
  ) as Record<keyof typeof LEGACY, string | undefined>;
  if (Object.values(legacy).every((value) => value === undefined)) return;
  db.transaction((tx) => {
    if (tx.select().from(models).limit(1).get() === undefined) {
      const created = tx
        .insert(models)
        .values({
          name: legacy.model || 'Default',
          baseUrl: legacy.baseUrl ?? '',
          model: legacy.model ?? '',
          apiKey: legacy.apiKey ?? null,
          extraBody: legacy.extraBody ?? '',
          createdAt: Date.now(),
        })
        .returning()
        .get();
      tx.insert(settings)
        .values({ key: DEFAULT, value: String(created.id), encrypted: false })
        .onConflictDoUpdate({ target: settings.key, set: { value: String(created.id) } })
        .run();
    }
    tx.delete(settings).where(inArray(settings.key, Object.values(LEGACY))).run();
  });
}
