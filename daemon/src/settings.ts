import { eq } from 'drizzle-orm';
import type { ProviderSettings } from '@schermes/shared';
import type { Db } from './db.ts';
import { settings } from './schema.ts';
import { decrypt, encrypt } from './secrets.ts';

const BASE_URL = 'provider.baseUrl';
const MODEL = 'provider.model';
const API_KEY = 'provider.apiKey';

function read(db: Db, key: string): string | undefined {
  return db.select().from(settings).where(eq(settings.key, key)).get()?.value;
}

function write(db: Db, key: string, value: string, encrypted: boolean): void {
  db.insert(settings)
    .values({ key, value, encrypted })
    .onConflictDoUpdate({ target: settings.key, set: { value, encrypted } })
    .run();
}

/** The shape the API returns. The API key is reported as present or absent, never echoed. */
export function readProviderSettings(db: Db): ProviderSettings {
  return {
    baseUrl: read(db, BASE_URL) ?? '',
    model: read(db, MODEL) ?? '',
    apiKeySet: read(db, API_KEY) !== undefined,
  };
}

export function writeBaseUrl(db: Db, value: string): void {
  write(db, BASE_URL, value, false);
}

export function writeModel(db: Db, value: string): void {
  write(db, MODEL, value, false);
}

export function writeApiKey(db: Db, masterKey: Buffer, value: string): void {
  write(db, API_KEY, encrypt(masterKey, value), true);
}

export function readApiKey(db: Db, masterKey: Buffer): string | undefined {
  const stored = read(db, API_KEY);
  return stored === undefined ? undefined : decrypt(masterKey, stored);
}
