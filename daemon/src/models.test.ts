import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { resolve } from 'node:path';
import test from 'node:test';
import { conversationFor } from './conversations.ts';
import { findAgent, insertAgent, insertWorker } from './agents.ts';
import { openDb } from './db.ts';
import type { Db } from './db.ts';
import {
  assignModel,
  backupConfig,
  backupModelId,
  clearAuthFailure,
  contextWindowFor,
  createModel,
  createProvider,
  defaultModelId,
  deleteModel,
  deleteProvider,
  findModel,
  findProvider,
  listAuthFailures,
  listModels,
  listProviders,
  modelConfig,
  modelIdFor,
  parseExtraBody,
  providerConfig,
  readProviderSettings,
  recordAuthFailure,
  setBackupModel,
  setDefaultModel,
  updateModel,
  updateProvider,
  writeProviderSettings,
} from './models.ts';

const MIGRATIONS = resolve(import.meta.dirname, '../migrations');

function fresh(): { db: Db; key: Buffer } {
  return { db: openDb(':memory:', MIGRATIONS), key: randomBytes(32) };
}

function storedKey(db: Db, id: number): string | null {
  return (db.$client.prepare('select api_key as k from providers where id = ?').get(id) as { k: string | null }).k;
}

test('the first model becomes the default, and entries carry their provider', () => {
  const { db, key } = fresh();
  assert.deepEqual(listModels(db), []);
  assert.equal(defaultModelId(db), undefined);
  const provider = createProvider(db, key, { name: 'One', baseUrl: 'https://one.example/v1', apiKey: 'sk-1' });
  assert.equal(provider.apiKeySet, true);
  assert.notEqual(storedKey(db, provider.id), 'sk-1', 'the key is encrypted at rest');

  const first = createModel(db, { name: 'First', providerId: provider.id, model: 'm1', contextWindow: 128_000, vision: true });
  const second = createModel(db, { name: 'Second', providerId: provider.id, model: 'm2' });
  assert.equal(first.isDefault, true);
  assert.equal(second.isDefault, false, 'only the first takes the default');
  assert.equal(defaultModelId(db), first.id);
  assert.deepEqual(
    { providerName: first.providerName, baseUrl: first.baseUrl, apiKeySet: first.apiKeySet, contextWindow: first.contextWindow, vision: first.vision },
    { providerName: 'One', baseUrl: 'https://one.example/v1', apiKeySet: true, contextWindow: 128_000, vision: true },
  );
  assert.equal(second.contextWindow, null);
  assert.deepEqual(listModels(db).map((m) => m.name), ['First', 'Second']);
  assert.equal(findModel(db, 999), undefined);

  const orphan = createModel(db, { name: 'Orphan' });
  assert.deepEqual({ providerName: orphan.providerName, baseUrl: orphan.baseUrl, apiKeySet: orphan.apiKeySet }, { providerName: '', baseUrl: '', apiKeySet: false });
});

test('updates change only the fields given, and an emptied key removes it', () => {
  const { db, key } = fresh();
  const provider = createProvider(db, key, { name: 'One', baseUrl: 'https://one.example/v1', apiKey: 'sk-1' });
  const model = createModel(db, { name: 'M', providerId: provider.id, model: 'm1', extraBody: '{"a":1}' });

  const renamed = updateModel(db, model.id, { name: 'Renamed' });
  assert.deepEqual({ name: renamed?.name, model: renamed?.model, extraBody: renamed?.extraBody }, { name: 'Renamed', model: 'm1', extraBody: '{"a":1}' });
  assert.equal(updateModel(db, model.id, { contextWindow: 32_000 })?.contextWindow, 32_000);
  assert.equal(updateModel(db, model.id, { contextWindow: null })?.contextWindow, null, 'null clears the window');
  assert.equal(updateModel(db, model.id, {})?.name, 'Renamed', 'no fields is a no-op read');
  assert.equal(updateModel(db, 999, { name: 'x' }), undefined);

  assert.equal(updateProvider(db, key, provider.id, { name: 'Uno' })?.name, 'Uno');
  assert.equal(updateProvider(db, key, provider.id, {})?.baseUrl, 'https://one.example/v1');
  assert.equal(updateProvider(db, key, provider.id, { apiKey: '' })?.apiKeySet, false);
  assert.equal(storedKey(db, provider.id), null);
  assert.equal(updateProvider(db, key, 999, { name: 'x' }), undefined);
  assert.deepEqual(listProviders(db).map((p) => p.name), ['Uno']);
  assert.equal(findProvider(db, 999), undefined);
});

test('a provider in use and an assigned or replaceable default refuse deletion', () => {
  const { db, key } = fresh();
  const provider = createProvider(db, key, { name: 'One', baseUrl: 'https://one.example/v1', apiKey: 'sk-1' });
  const a = createModel(db, { name: 'A', providerId: provider.id, model: 'a' });
  const b = createModel(db, { name: 'B', providerId: provider.id, model: 'b' });
  const alpha = insertAgent(db, 'alpha');
  assert.ok(alpha !== undefined);

  assert.deepEqual(deleteProvider(db, 999), { error: 'no such provider', status: 404 });
  assert.deepEqual(deleteProvider(db, provider.id), { error: 'A, B still use this provider', status: 409 });
  assert.deepEqual(deleteModel(db, 999), { error: 'no such model', status: 404 });

  assert.equal(assignModel(db, 'alpha', b.id), true);
  assert.deepEqual(deleteModel(db, b.id), { error: 'alpha still use this model', status: 409 });
  assert.equal(assignModel(db, 'alpha', null), true);
  assert.equal(findAgent(db, 'alpha')?.modelId, undefined);

  assert.deepEqual(deleteModel(db, a.id), { error: 'make another model the default first', status: 409 });
  assert.equal(setBackupModel(db, b.id), true);
  assert.deepEqual(deleteModel(db, b.id), { ok: true });
  assert.equal(backupModelId(db), undefined, 'deleting the backup leaves no backup');
  assert.deepEqual(deleteModel(db, a.id), { ok: true }, 'the last model may go even as the default');
  assert.equal(defaultModelId(db), undefined);
  assert.deepEqual(deleteProvider(db, provider.id), { ok: true });
  assert.deepEqual(listProviders(db), []);
});

test('role setters and assignment refuse unknown models', () => {
  const { db } = fresh();
  insertAgent(db, 'alpha');
  const a = createModel(db, { name: 'A' });
  const b = createModel(db, { name: 'B' });
  assert.equal(setDefaultModel(db, 999), false);
  assert.equal(setDefaultModel(db, b.id), true);
  assert.equal(defaultModelId(db), b.id);
  assert.equal(findModel(db, a.id)?.isDefault, false);
  assert.equal(setBackupModel(db, 999), false);
  assert.equal(setBackupModel(db, a.id), true);
  assert.equal(findModel(db, a.id)?.isBackup, true);
  assert.equal(setBackupModel(db, null), true);
  assert.equal(backupModelId(db), undefined);
  assert.equal(assignModel(db, 'alpha', 999), false);
  assert.equal(findAgent(db, 'alpha')?.modelId, undefined);
});

test('a config needs an endpoint, a model and a key; vision off and extra body ride along', () => {
  const { db, key } = fresh();
  const provider = createProvider(db, key, { name: 'One', baseUrl: 'https://one.example/v1', apiKey: 'sk-1' });
  const blind = createModel(db, { name: 'Blind', providerId: provider.id, model: 'm1', vision: false, extraBody: '{"reasoning":{"effort":"low"}}' });
  assert.deepEqual(modelConfig(db, key, blind.id), {
    baseUrl: 'https://one.example/v1',
    model: 'm1',
    apiKey: 'sk-1',
    extraBody: { reasoning: { effort: 'low' } },
    vision: false,
  });
  const seeing = createModel(db, { name: 'Seeing', providerId: provider.id, model: 'm2', extraBody: 'not json' });
  assert.equal(seeing.vision, true, 'vision is on unless the owner turns it off');
  assert.deepEqual(modelConfig(db, key, seeing.id), { baseUrl: 'https://one.example/v1', model: 'm2', apiKey: 'sk-1' });

  assert.equal(modelConfig(db, key, createModel(db, { name: 'No model', providerId: provider.id }).id), undefined);
  assert.equal(modelConfig(db, key, createModel(db, { name: 'No provider', model: 'm' }).id), undefined);
  assert.equal(modelConfig(db, key, 999), undefined);
  const keyless = createProvider(db, key, { name: 'Keyless', baseUrl: 'https://two.example/v1' });
  assert.equal(modelConfig(db, key, createModel(db, { name: 'K', providerId: keyless.id, model: 'm' }).id), undefined);
  assert.throws(() => modelConfig(db, randomBytes(32), blind.id), 'a key encrypted under another master key does not decrypt');
});

test('an agent resolves to its own model, a worker to its parent\'s, others to the default', () => {
  const { db, key } = fresh();
  const provider = createProvider(db, key, { name: 'One', baseUrl: 'https://one.example/v1', apiKey: 'sk-1' });
  assert.equal(providerConfig(db, key), undefined, 'no model at all');
  const def = createModel(db, { name: 'Default', providerId: provider.id, model: 'def', contextWindow: 200_000 });
  const own = createModel(db, { name: 'Own', providerId: provider.id, model: 'own', contextWindow: 64_000 });
  const alpha = insertAgent(db, 'alpha');
  const bravo = insertAgent(db, 'bravo');
  assert.ok(alpha !== undefined && bravo !== undefined);
  assignModel(db, 'alpha', own.id);
  const worker = insertWorker(db, alpha, 'alpha-w1', conversationFor(db, alpha.id));

  assert.equal(providerConfig(db, key)?.model, 'def');
  assert.equal(providerConfig(db, key, alpha)?.model, 'own', 'read fresh, not from the stale agent object');
  assert.equal(providerConfig(db, key, worker)?.model, 'own');
  assert.equal(providerConfig(db, key, bravo)?.model, 'def');
  assert.equal(modelIdFor(db, worker), own.id);

  assert.equal(contextWindowFor(db, alpha), 64_000);
  assert.equal(contextWindowFor(db, worker), 64_000);
  assert.equal(contextWindowFor(db, bravo), 200_000);
  assert.equal(contextWindowFor(db, bravo, own.id), 64_000, 'an explicit pick wins');
  assert.equal(contextWindowFor(db, bravo, null), 200_000, 'null falls back to the agent\'s model');
  assert.equal(contextWindowFor(db, bravo, 999), null, 'an unknown model has no window');
  updateModel(db, def.id, { contextWindow: null });
  assert.equal(contextWindowFor(db, bravo), null);
});

test('the backup is offered only when set, usable, not active and not refused', () => {
  const { db, key } = fresh();
  const provider = createProvider(db, key, { name: 'One', baseUrl: 'https://one.example/v1', apiKey: 'sk-1' });
  const main = createModel(db, { name: 'Main', providerId: provider.id, model: 'main' });
  const spare = createModel(db, { name: 'Spare', providerId: provider.id, model: 'spare' });
  assert.equal(backupConfig(db, key, main.id), undefined, 'no backup set');
  setBackupModel(db, spare.id);
  assert.deepEqual(backupConfig(db, key, main.id), { id: spare.id, name: 'Spare', config: { baseUrl: 'https://one.example/v1', model: 'spare', apiKey: 'sk-1' } });
  assert.equal(backupConfig(db, key, spare.id), undefined, 'already running on it');
  assert.equal(backupConfig(db, key, undefined)?.id, spare.id);

  recordAuthFailure(db, { modelId: spare.id, agent: 'alpha', conversationId: 1, error: '401' });
  assert.equal(backupConfig(db, key, main.id), undefined, 'its key was refused');
  clearAuthFailure(db, spare.id);
  assert.equal(backupConfig(db, key, main.id)?.id, spare.id);

  updateModel(db, spare.id, { model: '' });
  assert.equal(backupConfig(db, key, main.id), undefined, 'unusable');
});

test('auth failures keep the first refusal per model and clear on a key, endpoint, provider change or delete', () => {
  const { db, key } = fresh();
  const one = createProvider(db, key, { name: 'One', baseUrl: 'https://one.example/v1', apiKey: 'sk-1' });
  const two = createProvider(db, key, { name: 'Two', baseUrl: 'https://two.example/v1', apiKey: 'sk-2' });
  const a = createModel(db, { name: 'A', providerId: one.id, model: 'a' });
  const b = createModel(db, { name: 'B', providerId: one.id, model: 'b' });
  const refuse = (modelId: number, agent: string) => recordAuthFailure(db, { modelId, agent, conversationId: 7, error: `401 for ${agent}` });

  refuse(a.id, 'alpha');
  refuse(a.id, 'bravo');
  const [only, ...rest] = listAuthFailures(db);
  assert.equal(rest.length, 0, 'one row per model');
  assert.deepEqual({ modelId: only?.modelId, modelName: only?.modelName, agent: only?.agent, error: only?.error }, { modelId: a.id, modelName: 'A', agent: 'alpha', error: '401 for alpha' });
  assert.equal(typeof only?.at, 'number');

  refuse(b.id, 'alpha');
  updateProvider(db, key, one.id, { name: 'Renamed' });
  assert.equal(listAuthFailures(db).length, 2, 'a rename is no fresh chance');
  updateProvider(db, key, one.id, { apiKey: 'sk-new' });
  assert.deepEqual(listAuthFailures(db), [], 'a new key clears every model on the provider');

  refuse(a.id, 'alpha');
  refuse(b.id, 'alpha');
  updateProvider(db, key, one.id, { baseUrl: 'https://uno.example/v1' });
  assert.deepEqual(listAuthFailures(db), []);

  refuse(a.id, 'alpha');
  updateModel(db, a.id, { providerId: one.id });
  assert.equal(listAuthFailures(db).length, 1, 'the same provider keeps it');
  updateModel(db, a.id, { providerId: two.id });
  assert.deepEqual(listAuthFailures(db), [], 'moving to another provider clears it');

  refuse(b.id, 'alpha');
  setDefaultModel(db, b.id);
  deleteModel(db, a.id);
  setDefaultModel(db, b.id);
  assert.equal(listAuthFailures(db).length, 1);
  clearAuthFailure(db, 999);
  assert.equal(listAuthFailures(db).length, 1, 'clearing an unknown model is a no-op');
});

test('extra body is a JSON object or nothing', () => {
  assert.equal(parseExtraBody(undefined), undefined);
  assert.equal(parseExtraBody(''), undefined);
  assert.equal(parseExtraBody('   '), undefined);
  assert.equal(parseExtraBody('{'), undefined);
  assert.equal(parseExtraBody('[1,2]'), undefined);
  assert.equal(parseExtraBody('null'), undefined);
  assert.equal(parseExtraBody('"text"'), undefined);
  assert.equal(parseExtraBody('42'), undefined);
  assert.deepEqual(parseExtraBody(' {"top_k": 20, "nested": {"a": [1]}} '), { top_k: 20, nested: { a: [1] } });
  assert.deepEqual(parseExtraBody('{}'), {});
});

test('the legacy provider settings read and write the default model and its provider', () => {
  const { db, key } = fresh();
  assert.deepEqual(readProviderSettings(db), { baseUrl: '', model: '', apiKeySet: false, extraBody: '' });
  writeProviderSettings(db, key, {});
  assert.deepEqual(listModels(db), [], 'nothing given writes nothing');

  writeProviderSettings(db, key, { baseUrl: 'https://api.example.com/v1', model: 'gpt-x', apiKey: 'sk-1' });
  assert.deepEqual(readProviderSettings(db), { baseUrl: 'https://api.example.com/v1', model: 'gpt-x', apiKeySet: true, extraBody: '' });
  const [model] = listModels(db);
  assert.deepEqual({ name: model?.name, providerName: model?.providerName, isDefault: model?.isDefault }, { name: 'gpt-x', providerName: 'api.example.com', isDefault: true });

  writeProviderSettings(db, key, { extraBody: '{"a":1}', model: 'gpt-y' });
  assert.deepEqual(readProviderSettings(db), { baseUrl: 'https://api.example.com/v1', model: 'gpt-y', apiKeySet: true, extraBody: '{"a":1}' });
  assert.equal(listModels(db).length, 1, 'updates the default rather than adding one');
  assert.equal(listProviders(db).length, 1);
  assert.equal(modelConfig(db, key, model?.id ?? -1)?.apiKey, 'sk-1', 'an absent key is kept');

  const other = fresh();
  writeProviderSettings(other.db, other.key, { baseUrl: 'not a url' });
  assert.deepEqual(listModels(other.db).map((m) => [m.name, m.providerName]), [['Default', 'Provider']]);
});
