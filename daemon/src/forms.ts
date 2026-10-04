import { randomBytes } from 'node:crypto';
import { and, eq } from 'drizzle-orm';
import type { FormField, FormRequest, UnfillableField } from '@schermes/shared';
import { CHOICE_TYPES, readForm } from './browser.ts';
import type { BrowserTimings, Connect, FillStep } from './browser.ts';
import type { Db } from './db.ts';
import type { ToolDef } from './provider.ts';
import { MAX_HANDS_REASON_CHARS } from './control.ts';
import { forms, formVault, hiddenValues } from './schema.ts';
import { decrypt, encrypt } from './secrets.ts';
import { field } from './web.ts';

export function requestFormToolDef(): ToolDef {
  return {
    name: 'request_form',
    description:
      'Ask the owner to fill the form on the page your browser shows now: a login, a checkout, ' +
      'anything asking for their details. The daemon reads the fields from the page and types ' +
      'the owner\'s answers in; you never see a password or code. It submits nothing: once they ' +
      'have filled it, you hear which fields were filled and carry on, such as clicking the ' +
      'button. Open the page with the browser tool first. Calling this ends your turn.',
    parameters: {
      type: 'object',
      properties: {
        reason: {
          type: 'string',
          maxLength: MAX_HANDS_REASON_CHARS,
          description: 'what the form is for and why you need the owner to fill it',
        },
      },
      required: ['reason'],
    },
  };
}

export type StoredField = Omit<FormField, 'saved'> & { key: string };
export type StoredForm = Omit<FormRequest, 'fields'> & {
  agentId: number;
  conversationId: number;
  callId: string;
  fields: StoredField[];
  triggerId: number | null;
};

export const SECRET_AUTOCOMPLETE = /(^|\s)(current-password|new-password|one-time-code|cc-[a-z-]+)(\s|$)/;
const LOOPBACK = new Set(['localhost', '127.0.0.1', '[::1]']);

export function secureOrigin(origin: string): boolean {
  try {
    const url = new URL(origin);
    return url.protocol === 'https:' || LOOPBACK.has(url.hostname);
  } catch {
    return false;
  }
}

/** What a remembered value is saved under: the autocomplete token, else the name, else the label. */
function keyOf(autocomplete: string, name: string, label: string): string {
  const token = autocomplete.split(/\s+/).at(-1) ?? '';
  if (token !== '' && token !== 'on' && token !== 'off') return token;
  return name !== '' ? name : label.toLowerCase();
}

const text = (value: unknown, limit = 200): string => (typeof value === 'string' ? value.slice(0, limit) : '');

/**
 * The page's raw answer as fields the owner may fill, and the rest routed to the screen. A secret
 * field on a page that is neither HTTPS nor loopback goes to the screen too: its value would
 * cross the network in the clear.
 */
export function shapeForm(
  origin: string,
  rawFields: unknown,
  rawUnfillable: unknown,
): { secure: boolean; fields: StoredField[]; unfillable: UnfillableField[] } {
  const secure = secureOrigin(origin);
  const fields: StoredField[] = [];
  const unfillable: UnfillableField[] = (Array.isArray(rawUnfillable) ? rawUnfillable : []).map((entry) => ({
    label: text(field(entry, 'label')),
    reason: text(field(entry, 'reason'), 40),
  }));
  for (const raw of Array.isArray(rawFields) ? rawFields : []) {
    const id = text(field(raw, 'id'), 40);
    if (id === '') continue;
    const type = text(field(raw, 'type'), 40) || 'text';
    const autocomplete = text(field(raw, 'autocomplete'));
    const label = text(field(raw, 'label')) || type;
    const secret = type === 'password' || SECRET_AUTOCOMPLETE.test(autocomplete);
    if (secret && !secure) {
      unfillable.push({ label, reason: 'insecure' });
      continue;
    }
    const options = field(raw, 'options');
    fields.push({
      id,
      key: keyOf(autocomplete, text(field(raw, 'name')), label),
      label,
      type,
      ...(autocomplete === '' ? {} : { autocomplete }),
      required: field(raw, 'required') === true,
      ...(Array.isArray(options)
        ? { options: options.slice(0, 200).map((o) => ({ value: text(field(o, 'value')), label: text(field(o, 'label')) })) }
        : {}),
      secret,
    });
  }
  return { secure, fields, unfillable };
}

/** Reads the form on the agent's page and stores it against the call that asked for it. */
export async function captureForm(
  db: Db,
  connect: Connect,
  request: { agentId: number; display: number; conversationId: number; callId: string; reason: string },
  timings?: BrowserTimings,
): Promise<StoredForm | { error: string }> {
  const page = await readForm(connect, request.display, randomBytes(4).toString('hex'), timings);
  if ('error' in page) return page;
  const shaped = shapeForm(page.origin, page.fields, page.unfillable);
  if (shaped.fields.length === 0 && shaped.unfillable.length === 0) return { error: 'there is no form on the page' };
  const row = db
    .insert(forms)
    .values({
      agentId: request.agentId,
      conversationId: request.conversationId,
      callId: request.callId,
      origin: page.origin,
      reason: request.reason,
      fields: JSON.stringify(shaped.fields),
      unfillable: JSON.stringify(shaped.unfillable),
      createdAt: Date.now(),
    })
    .returning()
    .get();
  return toStored(row);
}

export function toStored(row: typeof forms.$inferSelect): StoredForm {
  return {
    id: row.id,
    agentId: row.agentId,
    conversationId: row.conversationId,
    callId: row.callId,
    origin: row.origin,
    // A trigger's login goes to its server over TLS only, never through a page.
    secure: row.triggerId !== null || secureOrigin(row.origin),
    reason: row.reason,
    fields: JSON.parse(row.fields) as StoredField[],
    unfillable: JSON.parse(row.unfillable) as UnfillableField[],
    createdAt: row.createdAt,
    triggerId: row.triggerId,
  };
}

export function findForm(db: Db, id: number): StoredForm | undefined;
export function findForm(db: Db, conversationId: number, callId: string): StoredForm | undefined;
export function findForm(db: Db, idOrThread: number, callId?: string): StoredForm | undefined {
  const where =
    callId === undefined ? eq(forms.id, idOrThread) : and(eq(forms.conversationId, idOrThread), eq(forms.callId, callId));
  const row = db.select().from(forms).where(where).get();
  return row === undefined ? undefined : toStored(row);
}

/** The wire shape, with `saved` read from the vault's plain key list. */
export function formRequest(db: Db, form: StoredForm): FormRequest {
  const saved = savedKeys(db, form.agentId, form.origin);
  return {
    id: form.id,
    origin: form.origin,
    secure: form.secure,
    reason: form.reason,
    fields: form.fields.map(({ key, ...rest }) => ({ ...rest, saved: saved.has(key) })),
    unfillable: form.unfillable,
    createdAt: form.createdAt,
  };
}

function vaultRow(db: Db, agentId: number, origin: string) {
  return db
    .select()
    .from(formVault)
    .where(and(eq(formVault.agentId, agentId), eq(formVault.origin, origin)))
    .get();
}

function savedKeys(db: Db, agentId: number, origin: string): Set<string> {
  const row = vaultRow(db, agentId, origin);
  return new Set(row === undefined ? [] : (JSON.parse(row.keys) as string[]));
}

function savedValues(db: Db, masterKey: Buffer, agentId: number, origin: string): Record<string, string> {
  const row = vaultRow(db, agentId, origin);
  return row === undefined ? {} : (JSON.parse(decrypt(masterKey, row.values)) as Record<string, string>);
}

function saveValues(db: Db, masterKey: Buffer, agentId: number, origin: string, values: Record<string, string>): void {
  const merged = { ...savedValues(db, masterKey, agentId, origin), ...values };
  const set = { keys: JSON.stringify(Object.keys(merged)), values: encrypt(masterKey, JSON.stringify(merged)), updatedAt: Date.now() };
  db.insert(formVault)
    .values({ agentId, origin, ...set })
    .onConflictDoUpdate({ target: [formVault.agentId, formVault.origin], set })
    .run();
}

const MAX_VALUE_CHARS = 2_000;

/**
 * The owner's values as fill steps, with remembered ones for fields they left out. Values go to
 * the page and, when asked, to the vault; nothing here reaches a prompt.
 */
export function fillSteps(
  db: Db,
  masterKey: Buffer,
  form: StoredForm,
  body: Record<string, unknown>,
): { steps: (FillStep & { secret: boolean; key: string })[]; remember: boolean } | { error: string } {
  const values = body['values'] ?? {};
  if (values === null || typeof values !== 'object' || Array.isArray(values)) return { error: 'values must be an object' };
  const given = values as Record<string, unknown>;
  for (const [id, value] of Object.entries(given)) {
    if (!form.fields.some((f) => f.id === id)) return { error: `${id} is not a field of this form` };
    if (typeof value !== 'string' || value.length > MAX_VALUE_CHARS) {
      return { error: `the value for ${id} must be a string of at most ${MAX_VALUE_CHARS} characters` };
    }
  }
  const saved = savedValues(db, masterKey, form.agentId, form.origin);
  const steps = form.fields.flatMap((f) => {
    const value = (given[f.id] as string | undefined) ?? saved[f.key];
    if (value === undefined || (value === '' && !CHOICE_TYPES.has(f.type))) return [];
    return [{ id: f.id, label: f.label, type: f.type, value, secret: f.secret, key: f.key }];
  });
  if (steps.length === 0) return { error: 'there is nothing to fill' };
  return { steps, remember: body['remember'] === true };
}

export function rememberSteps(
  db: Db,
  masterKey: Buffer,
  form: StoredForm,
  steps: readonly { key: string; value: string }[],
): void {
  saveValues(db, masterKey, form.agentId, form.origin, Object.fromEntries(steps.map((s) => [s.key, s.value])));
}

/** The owner line the agent reads after a fill: which fields, never a secret's value. */
export const FILLED = 'I filled the form on ';

export function filledLine(origin: string, steps: readonly { label: string; secret: boolean }[]): string {
  const names = steps.map((s) => (s.secret ? `${s.label} (hidden)` : s.label)).join(', ');
  return `${FILLED}${origin}: ${names}. Nothing was submitted; carry on from there.`;
}

const typed = new WeakMap<Db, Map<number, Set<string>>>();
const MIN_HIDDEN_CHARS = 4;
const MAX_HIDDEN_VALUES = 200;
export const HIDDEN = '[hidden]';

function hiddenFor(db: Db): Map<number, Set<string>> {
  const cached = typed.get(db) ?? new Map<number, Set<string>>();
  typed.set(db, cached);
  return cached;
}

/** Fills the cache from the stored rows; run once at boot, before any turn can read a page. */
export function loadHidden(db: Db, masterKey: Buffer): void {
  const cache = new Map<number, Set<string>>();
  for (const row of db.select().from(hiddenValues).all()) {
    cache.set(row.agentId, new Set(JSON.parse(decrypt(masterKey, row.values)) as string[]));
  }
  typed.set(db, cache);
}

/** Secret values just typed for this agent, hidden from whatever its tools read back, now and
 * after a restart. The oldest are forgotten past `MAX_HIDDEN_VALUES`. */
export function hideFromAgent(db: Db, masterKey: Buffer, agentId: number, values: readonly string[]): void {
  const cache = hiddenFor(db);
  const set = cache.get(agentId) ?? new Set<string>();
  for (const value of values) {
    if (value.length < MIN_HIDDEN_CHARS) continue;
    set.delete(value);
    set.add(value);
  }
  for (const oldest of [...set].slice(0, Math.max(0, set.size - MAX_HIDDEN_VALUES))) set.delete(oldest);
  cache.set(agentId, set);
  const row = { values: encrypt(masterKey, JSON.stringify([...set])), updatedAt: Date.now() };
  db.insert(hiddenValues)
    .values({ agentId, ...row })
    .onConflictDoUpdate({ target: hiddenValues.agentId, set: row })
    .run();
}

export function redactSecrets(db: Db, agentId: number, text: string): string {
  let out = text;
  for (const value of typed.get(db)?.get(agentId) ?? []) out = out.replaceAll(value, HIDDEN);
  return out;
}
