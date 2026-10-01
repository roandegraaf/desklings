import { and, eq, inArray, isNull, like } from 'drizzle-orm';
import type { Agent, ModelEntry, ProviderEntry, ProviderSettings } from '@schermes/shared';
import { findAgentById } from './agents.ts';
import type { Db } from './db.ts';
import type { ProviderConfig } from './provider.ts';
import { agents, models, providers, settings } from './schema.ts';
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
  providerId?: number | undefined;
  model?: string | undefined;
  extraBody?: string | undefined;
};

export type ProviderFields = {
  name?: string | undefined;
  baseUrl?: string | undefined;
  /** Plain text in, encrypted at rest; empty removes the key. */
  apiKey?: string | undefined;
};

type Row = typeof models.$inferSelect;
type ProviderRow = typeof providers.$inferSelect;

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

function providerRow(db: Db, id: number | null): ProviderRow | undefined {
  return id === null ? undefined : db.select().from(providers).where(eq(providers.id, id)).get();
}

function toEntry(db: Db, entry: Row): ModelEntry {
  const provider = providerRow(db, entry.providerId);
  return {
    id: entry.id,
    name: entry.name,
    providerId: entry.providerId,
    providerName: provider?.name ?? '',
    baseUrl: provider?.baseUrl ?? '',
    model: entry.model,
    apiKeySet: provider !== undefined && provider.apiKey !== null,
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

function columns(fields: ModelFields) {
  return {
    ...(fields.name === undefined ? {} : { name: fields.name }),
    ...(fields.providerId === undefined ? {} : { providerId: fields.providerId }),
    ...(fields.model === undefined ? {} : { model: fields.model }),
    ...(fields.extraBody === undefined ? {} : { extraBody: fields.extraBody }),
  };
}

/** The first model there is becomes the default: with none, no agent could run at all. */
export function createModel(db: Db, fields: ModelFields): ModelEntry {
  const created = db
    .insert(models)
    .values({ name: '', model: '', legacyBaseUrl: '', createdAt: Date.now(), ...columns(fields) })
    .returning()
    .get();
  if (defaultModelId(db) === undefined) writeSetting(db, DEFAULT, created.id);
  return toEntry(db, created);
}

export function updateModel(db: Db, id: number, fields: ModelFields): ModelEntry | undefined {
  const set = columns(fields);
  if (fields.providerId !== undefined && fields.providerId !== row(db, id)?.providerId) clearAuthFailure(db, id);
  if (Object.keys(set).length > 0) db.update(models).set(set).where(eq(models.id, id)).run();
  return findModel(db, id);
}

function toProviderEntry(entry: ProviderRow): ProviderEntry {
  return {
    id: entry.id,
    name: entry.name,
    baseUrl: entry.baseUrl,
    apiKeySet: entry.apiKey !== null,
    createdAt: entry.createdAt,
  };
}

export function listProviders(db: Db): ProviderEntry[] {
  return db.select().from(providers).orderBy(providers.id).all().map(toProviderEntry);
}

export function findProvider(db: Db, id: number): ProviderEntry | undefined {
  const entry = providerRow(db, id);
  return entry === undefined ? undefined : toProviderEntry(entry);
}

function providerColumns(masterKey: Buffer, fields: ProviderFields) {
  return {
    ...(fields.name === undefined ? {} : { name: fields.name }),
    ...(fields.baseUrl === undefined ? {} : { baseUrl: fields.baseUrl }),
    ...(fields.apiKey === undefined ? {} : { apiKey: fields.apiKey === '' ? null : encrypt(masterKey, fields.apiKey) }),
  };
}

export function createProvider(db: Db, masterKey: Buffer, fields: ProviderFields): ProviderEntry {
  return toProviderEntry(
    db
      .insert(providers)
      .values({ name: '', baseUrl: '', createdAt: Date.now(), ...providerColumns(masterKey, fields) })
      .returning()
      .get(),
  );
}

/** A new key or endpoint is a fresh chance for every model on it, so their refusals go. */
export function updateProvider(db: Db, masterKey: Buffer, id: number, fields: ProviderFields): ProviderEntry | undefined {
  const set = providerColumns(masterKey, fields);
  if (fields.apiKey !== undefined || fields.baseUrl !== undefined) {
    for (const model of db.select({ id: models.id }).from(models).where(eq(models.providerId, id)).all()) {
      clearAuthFailure(db, model.id);
    }
  }
  if (Object.keys(set).length > 0) db.update(providers).set(set).where(eq(providers.id, id)).run();
  return findProvider(db, id);
}

/** Refused while a model still runs on it. */
export function deleteProvider(db: Db, id: number): { ok: true } | { error: string; status: 404 | 409 } {
  if (providerRow(db, id) === undefined) return { error: 'no such provider', status: 404 };
  const using = db.select({ name: models.name }).from(models).where(eq(models.providerId, id)).all();
  if (using.length > 0) {
    return { error: `${using.map((model) => model.name).join(', ')} still use this provider`, status: 409 };
  }
  db.delete(providers).where(eq(providers.id, id)).run();
  return { ok: true };
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

function config(db: Db, masterKey: Buffer, entry: Row | undefined): ProviderConfig | undefined {
  const provider = entry === undefined ? undefined : providerRow(db, entry.providerId);
  if (entry === undefined || provider === undefined || !provider.baseUrl || !entry.model || provider.apiKey === null) {
    return undefined;
  }
  const apiKey = decrypt(masterKey, provider.apiKey);
  if (apiKey === '') return undefined;
  const extraBody = parseExtraBody(entry.extraBody);
  return { baseUrl: provider.baseUrl, model: entry.model, apiKey, ...(extraBody === undefined ? {} : { extraBody }) };
}

export function modelConfig(db: Db, masterKey: Buffer, id: number): ProviderConfig | undefined {
  return config(db, masterKey, row(db, id));
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
  const resolved = config(db, masterKey, entry);
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

/** The old single-provider settings, now the default entry and its provider, for the settings
 * screen that still reads and writes them. */
export function readProviderSettings(db: Db): ProviderSettings {
  const id = defaultModelId(db);
  const entry = id === undefined ? undefined : findModel(db, id);
  return {
    baseUrl: entry?.baseUrl ?? '',
    model: entry?.model ?? '',
    apiKeySet: entry?.apiKeySet ?? false,
    extraBody: entry?.extraBody ?? '',
  };
}

export function writeProviderSettings(
  db: Db,
  masterKey: Buffer,
  fields: Omit<ModelFields, 'name' | 'providerId'> & Omit<ProviderFields, 'name'>,
): void {
  if (Object.values(fields).every((value) => value === undefined)) return;
  const { baseUrl, apiKey, ...modelFields } = fields;
  const id = defaultModelId(db);
  const providerId = id === undefined ? null : (row(db, id)?.providerId ?? null);
  const provider =
    providerId === null
      ? createProvider(db, masterKey, { name: providerName(baseUrl ?? ''), baseUrl, apiKey })
      : updateProvider(db, masterKey, providerId, { baseUrl, apiKey });
  if (id === undefined) createModel(db, { name: fields.model || 'Default', providerId: provider?.id, ...modelFields });
  else updateModel(db, id, { providerId: provider?.id, ...modelFields });
}

function providerName(baseUrl: string): string {
  try {
    return new URL(baseUrl).host || 'Provider';
  } catch {
    return 'Provider';
  }
}

/**
 * Boot step, after the master key is loaded: every model still carrying its own endpoint and key
 * gets a provider instead. Models with the same endpoint and the same key share one, which takes
 * comparing the keys decrypted; the ciphertext moves as it is. A key that will not decrypt gets a
 * provider of its own rather than stopping the boot. Touches only models without a provider.
 */
export function migrateModelProviders(db: Db, masterKey: Buffer): void {
  const pending = db
    .select()
    .from(models)
    .where(isNull(models.providerId))
    .orderBy(models.id)
    .all()
    .filter((entry) => entry.legacyBaseUrl !== '' || entry.legacyApiKey !== null);
  if (pending.length === 0) return;
  const plain = (blob: string | null): string | undefined => {
    if (blob === null) return '';
    try {
      return decrypt(masterKey, blob);
    } catch {
      return undefined;
    }
  };
  db.transaction((tx) => {
    const made: { id: number; baseUrl: string; key: string }[] = [];
    for (const entry of pending) {
      const key = plain(entry.legacyApiKey);
      let id = key === undefined ? undefined : made.find((p) => p.baseUrl === entry.legacyBaseUrl && p.key === key)?.id;
      if (id === undefined) {
        id = tx
          .insert(providers)
          .values({
            name: providerName(entry.legacyBaseUrl),
            baseUrl: entry.legacyBaseUrl,
            apiKey: entry.legacyApiKey,
            createdAt: Date.now(),
          })
          .returning()
          .get().id;
        if (key !== undefined) made.push({ id, baseUrl: entry.legacyBaseUrl, key });
      }
      tx.update(models)
        .set({ providerId: id, legacyBaseUrl: '', legacyApiKey: null })
        .where(and(eq(models.id, entry.id), isNull(models.providerId)))
        .run();
    }
  });
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
          legacyBaseUrl: legacy.baseUrl ?? '',
          model: legacy.model ?? '',
          legacyApiKey: legacy.apiKey ?? null,
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
