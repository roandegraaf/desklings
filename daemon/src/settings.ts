import { readFileSync } from 'node:fs';
import { basename } from 'node:path';
import { eq } from 'drizzle-orm';
import type { ProviderSettings, PushSettings, WebSettings } from '@schermes/shared';
import type { Db } from './db.ts';
import { log } from './log.ts';
import { parseMcpServers } from './mcp.ts';
import type { McpServerSpec } from './mcp.ts';
import type { ProviderConfig } from './provider.ts';
import { settings } from './schema.ts';
import { decrypt, encrypt } from './secrets.ts';
import { BRAVE_SEARCH_URL } from './web.ts';
import type { SearchConfig } from './web.ts';

const BASE_URL = 'provider.baseUrl';
const MODEL = 'provider.model';
const API_KEY = 'provider.apiKey';
const EXTRA_BODY = 'provider.extraBody';
const SEARCH_URL = 'web.searchUrl';
const SEARCH_KEY = 'web.searchKey';
const MCP_SERVERS = 'mcp.servers';
const PUSH_KEY_ID = 'push.keyId';
const PUSH_TEAM_ID = 'push.teamId';
const PUSH_BUNDLE_ID = 'push.bundleId';
const PUSH_KEY = 'push.key';
const PUSH_SANDBOX = 'push.sandbox';

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
    extraBody: read(db, EXTRA_BODY) ?? '',
  };
}

export function writeExtraBody(db: Db, value: string): void {
  write(db, EXTRA_BODY, value, false);
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

/** Everything the model client needs, or undefined when the owner has not finished setting up. */
export function providerConfig(db: Db, masterKey: Buffer): ProviderConfig | undefined {
  const baseUrl = read(db, BASE_URL);
  const model = read(db, MODEL);
  const apiKey = readApiKey(db, masterKey);
  if (!baseUrl || !model || !apiKey) return undefined;
  const extraBody = parseExtraBody(read(db, EXTRA_BODY));
  return { baseUrl, model, apiKey, ...(extraBody === undefined ? {} : { extraBody }) };
}

/** The web half of the settings screen. The key is reported as present or absent, like the
 * provider's, and an unset endpoint reads as the default rather than as empty. */
export function readWebSettings(db: Db): WebSettings {
  return {
    searchUrl: read(db, SEARCH_URL) ?? '',
    searchKeySet: read(db, SEARCH_KEY) !== undefined,
  };
}

export function writeSearchUrl(db: Db, value: string): void {
  write(db, SEARCH_URL, value, false);
}

export function writeSearchKey(db: Db, masterKey: Buffer, value: string): void {
  write(db, SEARCH_KEY, encrypt(masterKey, value), true);
}

/** What `web_search` needs, or undefined when no key is stored — which is what a fresh install
 * looks like and what the tool turns into an observation rather than a failure. */
export function searchConfig(db: Db, masterKey: Buffer): SearchConfig | undefined {
  const stored = read(db, SEARCH_KEY);
  if (stored === undefined) return undefined;
  const apiKey = decrypt(masterKey, stored);
  if (apiKey === '') return undefined;
  const url = read(db, SEARCH_URL);
  return { url: url === undefined || url.trim() === '' ? BRAVE_SEARCH_URL : url.trim(), apiKey };
}

export function readPushSettings(db: Db): PushSettings {
  return {
    keyId: read(db, PUSH_KEY_ID) ?? '',
    teamId: read(db, PUSH_TEAM_ID) ?? '',
    bundleId: read(db, PUSH_BUNDLE_ID) ?? '',
    keySet: read(db, PUSH_KEY) !== undefined,
    sandbox: read(db, PUSH_SANDBOX) === 'true',
  };
}

export function writePushIds(db: Db, ids: { keyId?: string | undefined; teamId?: string | undefined; bundleId?: string | undefined }): void {
  if (ids.keyId !== undefined) write(db, PUSH_KEY_ID, ids.keyId, false);
  if (ids.teamId !== undefined) write(db, PUSH_TEAM_ID, ids.teamId, false);
  if (ids.bundleId !== undefined) write(db, PUSH_BUNDLE_ID, ids.bundleId, false);
}

/** The `.p8` text, encrypted like the provider key. Empty removes it. */
export function writePushKey(db: Db, masterKey: Buffer, pem: string): void {
  if (pem === '') db.delete(settings).where(eq(settings.key, PUSH_KEY)).run();
  else write(db, PUSH_KEY, encrypt(masterKey, pem), true);
}

export function writePushSandbox(db: Db, sandbox: boolean): void {
  write(db, PUSH_SANDBOX, sandbox ? 'true' : 'false', false);
}

/**
 * The `.p8` mounted into the container, stored at boot the way a pasted one is, so the screen
 * never has to see it. Apple names the download `AuthKey_<KEYID>.p8`, which is where the key id
 * comes from unless one is given. An empty file is no file: compose mounts /dev/null when the
 * owner has not set one.
 */
export function seedPushKey(db: Db, masterKey: Buffer, path: string, keyId?: string): boolean {
  let pem: string;
  try {
    pem = readFileSync(path, 'utf8').trim();
  } catch {
    return false;
  }
  if (!pem.includes('-----BEGIN PRIVATE KEY-----')) return false;
  const id = keyId?.trim() || /^AuthKey_([A-Z0-9]+)\.p8$/i.exec(basename(path))?.[1];
  if (!id) throw new Error(`the APNs key id is not in ${JSON.stringify(basename(path))}: set SCHERMES_APNS_KEY_ID`);
  writePushKey(db, masterKey, pem);
  writePushIds(db, { keyId: id });
  return true;
}

export type PushConfig = { keyId: string; teamId: string; bundleId: string; key: string; sandbox: boolean };

/** Everything a push needs, or undefined while any of it is missing. */
export function pushConfig(db: Db, masterKey: Buffer): PushConfig | undefined {
  const { keyId, teamId, bundleId, sandbox } = readPushSettings(db);
  const stored = read(db, PUSH_KEY);
  if (!keyId || !teamId || !bundleId || stored === undefined) return undefined;
  return { keyId, teamId, bundleId, key: decrypt(masterKey, stored), sandbox };
}

/**
 * The owner's MCP servers, as one encrypted JSON row rather than a table: a stdio server's `env`
 * block is where an API key goes and an http server's headers are where a bearer token goes, so
 * the whole list is encrypted with the master key like the provider key beside it.
 *
 * A row that cannot be read is no servers rather than a throw. This is called at the start of
 * every turn, and an unreadable setting must cost the agent its MCP tools, not the turn.
 */
export function mcpServers(db: Db, masterKey: Buffer): McpServerSpec[] {
  const stored = read(db, MCP_SERVERS);
  if (stored === undefined) return [];
  try {
    const parsed = parseMcpServers(JSON.parse(decrypt(masterKey, stored)));
    if ('error' in parsed) throw new Error(parsed.error);
    return parsed.servers;
  } catch (error) {
    log.error('the stored MCP servers could not be read', { error });
    return [];
  }
}

export function writeMcpServers(db: Db, masterKey: Buffer, servers: readonly McpServerSpec[]): void {
  write(db, MCP_SERVERS, encrypt(masterKey, JSON.stringify(servers)), true);
}
