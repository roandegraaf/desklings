import { Hono } from 'hono';
import { getCookie } from 'hono/cookie';
import { bodyLimit } from 'hono/body-limit';
import { MIN_PASSWORD_LENGTH } from '@schermes/shared';
import type {
  Agent,
  Approval,
  CompactResult,
  Conversation,
  FileChanges,
  Goal,
  HealthResponse,
  McpServerSummary,
  McpTestResult,
  Message,
  ModelEntry,
  ProviderEntry,
  ProviderTestResult,
  PushTestResult,
  RetryState,
  RewindPreview,
  SearchAnswer,
  AgentSuggestion,
  ApprovalCategory,
  NeedsYouAction,
  RuleLevel,
  AgentFile,
  UploadResult,
  ForwardResult,
} from '@schermes/shared';
import type { Context } from 'hono';
import type { Db } from './db.ts';
import {
  SESSION_COOKIE,
  checkPassword,
  claimOwner,
  dropSession,
  issueSession,
  ownerExists,
  sessionValid,
} from './auth.ts';
import {
  mcpServers,
  pushConfig,
  readPushSettings,
  readWebSettings,
  searchConfig,
  writeMcpServers,
  writeSearchKey,
  writePushIds,
  writePushKey,
  writePushSandbox,
  writeSearchUrl,
} from './settings.ts';
import {
  assignModel,
  backupConfig,
  clearAuthFailure,
  createModel,
  createProvider,
  deleteModel,
  deleteProvider,
  findModel,
  findProvider,
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
import type { ModelFields, ProviderFields } from './models.ts';
import { MAX_QUESTION_CHARS, answerSearch } from './search.ts';
import { MAX_DESCRIPTION_CHARS, suggestAgent } from './suggest.ts';
import { alwaysAllow, alwaysAllowable, grantOnce, parseLevels, readRules, updateRules } from './rules.ts';
import { listIdlePasses, readIdle, resolveIdleOutput, updateIdle } from './idle.ts';
import { MAX_HOOK_BYTES, SECRET_HEADER, actOnTrigger, fireWebhook, listTriggers, loginRequests, saveLogin } from './triggers.ts';
import { ATTENDING_HEADER, MAX_PUSH_BODY_CHARS, PRESENCE, deleteDevice, listDevices, pushCategory, sendPush, upsertDevice } from './push.ts';
import type { Presence, PushSend } from './push.ts';
import { createLiveActivities } from './liveactivity.ts';
import {
  AGENT_NAME,
  MAX_LABEL_CHARS,
  agentTarget,
  asAgent,
  cleanLabel,
  deleteAgent,
  desktopAgent,
  findAgent,
  findAgentById,
  forgetAgent,
  insertAgent,
  isWorker,
  listAgents,
  renameAgent,
  setAgentCosmetics,
} from './agents.ts';
import {
  APPROVED,
  CATEGORY_WORDS,
  GO_AHEAD,
  describeApproval,
  dropApproval,
  findApproval,
  listApprovals,
} from './approvals.ts';
import { cdpConnect, fillForm, focusedField, stopBrowser } from './browser.ts';
import { createRecorder, saveRecording, shownLine } from './recording.ts';
import type { Recording } from './recording.ts';
import type { Connect } from './browser.ts';
import { filledLine, fillSteps, findForm, hideFromAgent, rememberSteps } from './forms.ts';
import { formRequests, handOvers, hungBrowsers, listNeedsYou, pushedItem, threadsOf } from './needs.ts';
import type { DesktopOps } from './agents.ts';
import { deleteGoal, findGoal, finishGoal, keepHelper, listGoals } from './goals.ts';
import { parseComputerAction, performComputerAction } from './computer.ts';
import { parseCommand, runCommand } from './terminal.ts';
import {
  appendMessage,
  conversationFor,
  conversationWith,
  deleteConversation,
  findConversation,
  findMessage,
  listConversations,
  listEvents,
  listMessages,
  pageMessages,
  participantAgents,
  recordEvent,
  rewindConversation,
  rewoundRows,
  SYSTEM_SENDER,
} from './conversations.ts';
import type { MessagePage } from './conversations.ts';
import { cantUndo, fileChanges, restoreFiles, restoredLine } from './snapshots.ts';
import {
  deleteSchedule,
  findSchedule,
  insertSchedule,
  listSchedules,
  parseSchedule,
  setPaused,
} from './schedules.ts';
import type { ScheduleRequest } from './schedules.ts';
import { isHttpServer, openMcp, parseMcpServers, withStoredSecrets } from './mcp.ts';
import type { McpServerSpec } from './mcp.ts';
import { compactNow, contextFullness, createRunner, liveReply, workersBusy } from './loop.ts';
import {
  MAX_FILE_BYTES,
  MAX_MEMORY_FILE_CHARS,
  homePath,
  readHomeFile,
  readMemory,
  remember,
  writeMemory,
} from './home.ts';
import { FEEDBACK_HEADING, feedbackLine, findFeedback, findReply, parseFeedback, setFeedback, withFeedback } from './feedback.ts';
import { CONTROL_REFUSAL, createControl, HANDS_BACK } from './control.ts';
import { KICKOFF, MAX_PROFILE_CHARS, describedKickoff } from './interview.ts';
import { RETRY_BASE_MS, openAiProvider, withRetries } from './provider.ts';
import type { Image, Provider, ProviderConfig, RetryControl } from './provider.ts';
import { config } from './config.ts';
import type { Exec } from './exec.ts';
import { log } from './log.ts';

const PUBLIC_PATHS = new Set(['/api/health', '/api/auth/setup', '/api/auth/login']);

async function jsonBody(c: Context): Promise<Record<string, unknown>> {
  try {
    const body: unknown = await c.req.json();
    if (body === null || typeof body !== 'object' || Array.isArray(body)) return {};
    return body as Record<string, unknown>;
  } catch {
    return {};
  }
}

function stringField(body: Record<string, unknown>, name: string): string | undefined {
  const value = body[name];
  return typeof value === 'string' ? value : undefined;
}

/** A path segment is user input, so it never reaches a query as anything but a whole number. */
function conversationParam(db: Db, raw: string): Conversation | undefined {
  const id = Number(raw);
  return Number.isSafeInteger(id) ? findConversation(db, id) : undefined;
}

const DEFAULT_PAGE = 50;
const MAX_PAGE = 200;
const PAGE_REFUSAL =
  `limit must be a whole number between 1 and ${MAX_PAGE}, and before or after — never both — ` +
  'a message id';

function messageId(raw: string | undefined): number | undefined {
  const id = Number(raw);
  return Number.isSafeInteger(id) && id > 0 ? id : undefined;
}

/**
 * The window a reader asked for, or undefined when it asked for something that is not one.
 * A thread carries base64 screenshots, so the whole of one is not a response anybody wants;
 * the newest page is what a chat view opens on, `before` walks it backwards and `after` is how
 * a reader watching a live thread asks for only what it has not seen — an empty array when
 * nothing happened, which is what makes polling cheap. A page shorter than `limit` is the start
 * of the thread, which is why nothing here counts the rest.
 */
function messagePage(c: Context): MessagePage | undefined {
  const limit = Number(c.req.query('limit') ?? DEFAULT_PAGE);
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > MAX_PAGE) return undefined;

  const rawBefore = c.req.query('before');
  const rawAfter = c.req.query('after');
  if (rawBefore !== undefined && rawAfter !== undefined) return undefined;
  if (rawBefore === undefined && rawAfter === undefined) return { limit };

  const id = messageId(rawBefore ?? rawAfter);
  if (id === undefined) return undefined;
  return rawBefore === undefined ? { limit, after: id } : { limit, before: id };
}

/** `?images=0` keeps each image's media type and drops its bytes, for a reader that only shows
 * that a screenshot is there: a sidebar polling every agent's newest row would otherwise carry it. */
function withImages(c: Context, rows: Message[]): Message[] {
  if (c.req.query('images') !== '0') return rows;
  return rows.map((row) => (row.image === undefined ? row : { ...row, image: { ...row.image, base64: '' } }));
}

const MAX_EVENTS = 1_000;
const DEVICE_TOKEN = /^[0-9a-f]{32,200}$/i;
const TEAM_ID = /^[A-Z0-9]{10}$/;
const BUNDLE_ID = /^[A-Za-z0-9.-]{1,155}$/;
/** A picture the owner sends an agent. Decoded size, the model request carries it as base64. */
export const MAX_IMAGE_BYTES = 5_000_000;

/** An uploaded file's name: one path segment of ordinary characters, nothing hidden. */
const UPLOAD_NAME = /^[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,127}$/;
// Base64 is four characters per three bytes.
const MAX_UPLOAD_BASE64_CHARS = Math.ceil(MAX_FILE_BYTES / 3) * 4;
const UPLOAD_SCRIPT = `set -eu
mkdir -p "$HOME/uploads"
base64 -d > "$HOME/uploads/$1"
`;

/** A file's own name made into one `UPLOAD_NAME`: whatever an agent called it, it lands whole. */
export function uploadName(name: string): string {
  const plain = name
    .replace(/[^A-Za-z0-9 ._()+-]/g, '_')
    .replace(/\.{2,}/g, '.')
    .replace(/^[^A-Za-z0-9]+/, '')
    .slice(0, 128);
  return plain === '' ? 'file' : plain;
}

type Forward = { messageId?: number; file?: { agent: string; path: string }; note?: string };

function parseForward(body: Record<string, unknown>): Forward | { error: string } {
  const out: Forward = {};
  const id = body['messageId'];
  if (id !== undefined) {
    if (typeof id !== 'number' || !Number.isSafeInteger(id) || id < 1) return { error: 'messageId must be a message id' };
    out.messageId = id;
  }
  const file = body['file'];
  if (file !== undefined) {
    const fields = typeof file === 'object' && file !== null ? (file as Record<string, unknown>) : {};
    const agent = stringField(fields, 'agent') ?? '';
    const path = stringField(fields, 'path') ?? '';
    if (agent === '' || path === '') return { error: 'file must be {agent, path}' };
    out.file = { agent, path };
  }
  const note = body['note'];
  if (note !== undefined && typeof note !== 'string') return { error: 'note must be a string' };
  if (typeof note === 'string' && note.trim() !== '') out.note = note.trim();
  if (out.messageId === undefined && out.file === undefined) return { error: 'forward a message, a file or both' };
  return out;
}

/** The owner's line in the target's thread: their note, then what they passed on, quoted. */
export function forwardedText(note: string | undefined, source: { from: string; text: string } | undefined, file: string | undefined): string {
  const parts = [note ?? 'Forwarding this to you.'];
  if (source !== undefined && source.text.trim() !== '') {
    parts.push(`Forwarded from ${source.from}:\n${source.text.trim().replace(/^/gm, '> ')}`);
  }
  if (file !== undefined) parts.push(`I put the file in your home: ${file}`);
  return parts.join('\n\n');
}

type AgentFields = { label?: string; look?: string; profile?: string | null };

/** The fields the owner may set on an agent: the label and the look under the one rule both
 * follow, and the profile. A blank profile clears it, which puts the agent back to asking. */
function agentFields(body: Record<string, unknown>): AgentFields | { error: string } {
  const out: AgentFields = {};
  for (const key of ['label', 'look'] as const) {
    const wanted = stringField(body, key);
    if (wanted === undefined) continue;
    const clean = cleanLabel(wanted);
    if (clean === undefined) {
      return { error: `${key} must be 1-${MAX_LABEL_CHARS} characters on one line` };
    }
    out[key] = clean;
  }
  const profile = stringField(body, 'profile');
  if (profile !== undefined) {
    if (profile.length > MAX_PROFILE_CHARS) {
      return { error: `profile must be at most ${MAX_PROFILE_CHARS} characters` };
    }
    out.profile = profile.trim() === '' ? null : profile.trim();
  }
  return out;
}

type DescribedStart = {
  description?: string;
  tagline?: string;
  levels?: Partial<Record<ApprovalCategory, RuleLevel>>;
  routine?: ScheduleRequest;
};

/** The parts of a new agent that come from a description, checked before anything is created. */
function describedStart(body: Record<string, unknown>): DescribedStart | { error: string } {
  const out: DescribedStart = {};
  const description = stringField(body, 'description')?.trim();
  if (description !== undefined) {
    if (description === '' || description.length > MAX_DESCRIPTION_CHARS) {
      return { error: `description must be 1-${MAX_DESCRIPTION_CHARS} characters` };
    }
    out.description = description;
  }
  const extras = ['tagline', 'levels', 'routine'].filter((key) => body[key] !== undefined);
  if (out.description === undefined) {
    return extras.length === 0 ? out : { error: `${extras.join(', ')} come with a description` };
  }
  const tagline = stringField(body, 'tagline');
  if (tagline !== undefined) {
    const clean = cleanLabel(tagline);
    if (clean === undefined) return { error: `tagline must be 1-${MAX_LABEL_CHARS} characters on one line` };
    out.tagline = clean;
  }
  if (body['levels'] !== undefined) {
    const levels = parseLevels(body['levels']);
    if ('error' in levels) return levels;
    out.levels = levels;
  }
  const routine = body['routine'];
  if (routine !== undefined) {
    if (routine === null || typeof routine !== 'object') return { error: 'routine must be {cron, prompt}' };
    const parsed = parseSchedule(routine as Record<string, unknown>);
    if ('error' in parsed) return { error: `routine: ${parsed.error}` };
    out.routine = parsed;
  }
  return out;
}

/**
 * What the owner sent: text, a picture, or both. Text alone must be non-empty; a picture may
 * travel with none, then the row's content is empty and the picture is the message.
 */
function messageBody(
  body: Record<string, unknown>,
): { text: string; image?: Image } | { error: string } {
  const text = stringField(body, 'text') ?? '';
  const raw = body['image'];
  if (raw === undefined) {
    return text.trim() === '' ? { error: 'text must be a non-empty string' } : { text };
  }
  const mediaType = stringField(raw as Record<string, unknown>, 'mediaType');
  const base64 = stringField(raw as Record<string, unknown>, 'base64') ?? '';
  if ((mediaType !== 'image/png' && mediaType !== 'image/jpeg') || !/^[A-Za-z0-9+/=\s]+$/.test(base64)) {
    return { error: 'image must be {mediaType: image/png | image/jpeg, base64}' };
  }
  if (Buffer.from(base64, 'base64').length > MAX_IMAGE_BYTES) {
    return { error: `an image may be at most ${MAX_IMAGE_BYTES / 1_000_000} MB` };
  }
  return { text: text.trim() === '' ? '' : text, image: { mediaType, base64 } };
}

/** One configured server as the owner may see it: what it is and which secrets it carries by
 * name. A value an owner stored is never read back out, the provider key's rule. */
function summarise(spec: McpServerSpec): McpServerSummary {
  return isHttpServer(spec)
    ? { name: spec.name, transport: 'http', url: spec.url, secretKeys: Object.keys(spec.headers) }
    : {
        name: spec.name,
        transport: 'stdio',
        command: spec.command,
        args: spec.args,
        secretKeys: Object.keys(spec.env),
      };
}

function validBaseUrl(value: string): boolean {
  if (value === '') return true;
  try {
    return ['http:', 'https:'].includes(new URL(value).protocol);
  } catch {
    return false;
  }
}

export type AppDeps = {
  db: Db;
  masterKey: Buffer;
  desktop: DesktopOps;
  exec: Exec;
  /** Swapped for a scripted stand-in in tests; production always builds the real client. */
  makeProvider?: (config: ProviderConfig) => Provider;
  /** The resource caps, which come from the environment unless a test wants smaller ones. */
  maxLoops?: number;
  maxWorkers?: number;
  /** The first wait before a failed model call is asked again; tests shrink it. */
  retryBaseMs?: number;
  /** How turns and form fills reach an agent's Chromium; tests hand in a fake page. */
  connect?: Connect;
  /** How a push reaches APNs; tests capture it instead. */
  pushSend?: PushSend;
  /** When the owner counts as at a screen and how long a push waits for them; tests shrink it. */
  presence?: Presence;
  /** The Live Activity update throttle; tests shrink it. */
  activityThrottleMs?: number;
};

export function createApp({
  db,
  masterKey,
  desktop,
  exec,
  makeProvider,
  maxLoops = config.maxLoops,
  maxWorkers = config.maxWorkers,
  retryBaseMs = RETRY_BASE_MS,
  connect = cdpConnect,
  pushSend,
  presence = PRESENCE,
  activityThrottleMs,
}: AppDeps) {
  const app = new Hono();
  let attendedAt = -Infinity;
  const attended = () => Date.now() - attendedAt < presence.attendedMs;
  const activities = createLiveActivities({
    db,
    config: () => pushConfig(db, masterKey),
    send: pushSend,
    ...(activityThrottleMs === undefined ? {} : { throttleMs: activityThrottleMs }),
  });
  const buildProvider = makeProvider ?? openAiProvider;
  /** The model call each agent is waiting to ask again, with the owner's levers over it. */
  const waits = new Map<string, { state: RetryState; control: RetryControl }>();

  /**
   * An agent's turn provider: its model, retried, with the backup on offer while it waits. A
   * refused key is recorded against the model under the agent that owns the thread, since a
   * worker has no place in Needs you.
   */
  function agentProvider(agent: Agent, modelId?: number): Provider | undefined {
    const id = modelId ?? modelIdFor(db, agent);
    const settings = id === undefined ? undefined : modelConfig(db, masterKey, id);
    if (id === undefined || settings === undefined) return undefined;
    const backup = backupConfig(db, masterKey, id);
    const owner = agent.parentId === undefined ? agent : (findAgentById(db, agent.parentId) ?? agent);
    const { provider, control } = withRetries({
      primary: { provider: buildProvider(settings), modelId: id, name: findModel(db, id)?.name ?? settings.model },
      ...(backup === undefined
        ? {}
        : { backup: { provider: buildProvider(backup.config), modelId: backup.id, name: backup.name } }),
      baseMs: retryBaseMs,
      onWait: (state) => {
        if (state === undefined) waits.delete(agent.name);
        else waits.set(agent.name, { state, control });
      },
      onAuthFailure: (call, error) => {
        if (call.modelId === undefined) return;
        recordAuthFailure(db, {
          modelId: call.modelId,
          agent: owner.name,
          conversationId: conversationFor(db, owner.id),
          error: error.message,
        });
      },
      onSuccess: (call) => {
        if (call.modelId !== undefined) clearAuthFailure(db, call.modelId);
      },
    });
    return provider;
  }
  // Owns the one-turn-per-agent rule. Both the routes below and `send_message` inside a turn
  // start turns through it, which is why it cannot live in a route closure.
  const control = createControl();
  const recorder = createRecorder({
    screen: config.screen,
    focused: (display) => focusedField(connect, display),
    screenshot: async (target) => {
      const shot = await performComputerAction(exec, target, { action: 'screenshot' }, config.screen);
      if (shot.action !== 'screenshot' || shot.image === undefined) throw new Error('no screenshot');
      return shot.image;
    },
  });
  const runner = createRunner({
    db,
    exec,
    control,
    connect,
    screen: config.screen,
    maxLoops,
    maxWorkers,
    // The one channel: what an agent said at the end of a turn in its own thread with the
    // owner, and a deletion request wherever it was made, become a push to every registered
    // device. Fire and forget; nothing configured or nobody registered is silence, and a
    // failed delivery is a log line.
    rename: (agent, name) => moveAgent(agent, name).then(() => undefined),
    turn: (agent, phase) => (phase === 'start' ? activities.started(agent) : activities.ended(agent)),
    progress: (agent) => activities.changed(agent),
    desktop,
    // Called from inside a turn, so a throw here would fail a turn that already finished.
    deliver: (agent, conversationId, text, kind) => {
      try {
        if (agent.parentId !== undefined) return;
        if (kind === 'approval') activities.changed(agent);
        if (kind !== 'approval' && participantAgents(db, conversationId).length !== 1) return;
        const push = pushConfig(db, masterKey);
        if (push === undefined) return;
        const item = pushedItem(db, agent.name, conversationId, kind);
        const send = () =>
          sendPush(
            { db, config: push, ...(pushSend === undefined ? {} : { send: pushSend }) },
            {
              title: agent.label ?? agent.name,
              body: text,
              agent: agent.name,
              conversationId,
              ...(item === undefined ? {} : { needsYou: item.id, category: pushCategory(item) }),
            },
          ).catch((error: unknown) => log.error('push failed', { agent: agent.name, error }));
        if (!attended()) {
          void send();
          return;
        }
        // ponytail: dropped if still attended at the deadline, read or not; server-side read state would let an unread reply follow the owner away later
        setTimeout(() => {
          if (!attended()) void send();
        }, presence.holdMs).unref();
      } catch (error) {
        log.error('push failed', { agent: agent.name, error });
      }
    },
    provider: agentProvider,
    search: () => searchConfig(db, masterKey),
    // Reads the row every turn like the provider and the search key do, and resolves the agent's
    // Linux user only when there is something to connect to: a daemon with no MCP server
    // configured starts no process and runs no `getent` for one.
    mcp: async (agent) => {
      const specs = mcpServers(db, masterKey);
      return specs.length === 0 ? undefined : openMcp(specs, await agentTarget(exec, agent));
    },
  });

  // Registered before any route so unlisted paths are denied by default.
  app.use('/api/*', async (c, next) => {
    if (PUBLIC_PATHS.has(c.req.path)) return next();
    const id = getCookie(c, SESSION_COOKIE);
    if (id === undefined || !sessionValid(db, id)) return c.json({ error: 'unauthorized' }, 401);
    return next();
  });

  app.get('/api/health', (c) =>
    c.json<HealthResponse>({ status: 'ok', setupRequired: !ownerExists(db) }),
  );

  app.post('/api/auth/setup', async (c) => {
    const password = stringField(await jsonBody(c), 'password') ?? '';
    if (password.length < MIN_PASSWORD_LENGTH) {
      return c.json({ error: `password must be at least ${MIN_PASSWORD_LENGTH} characters` }, 400);
    }
    if (!claimOwner(db, password)) return c.json({ error: 'owner password is already set' }, 409);
    issueSession(c, db);
    return c.json({ ok: true }, 201);
  });

  app.post('/api/auth/login', async (c) => {
    const password = stringField(await jsonBody(c), 'password') ?? '';
    if (!checkPassword(db, password)) return c.json({ error: 'invalid password' }, 401);
    issueSession(c, db);
    return c.json({ ok: true });
  });

  app.post('/api/auth/logout', (c) => {
    const id = getCookie(c, SESSION_COOKIE);
    if (id !== undefined) dropSession(db, id);
    return c.json({ ok: true });
  });

  const allSettings = () => ({
    ...readProviderSettings(db),
    ...readWebSettings(db),
    push: readPushSettings(db),
  });

  app.get('/api/settings', (c) => c.json(allSettings()));

  app.put('/api/settings', async (c) => {
    const body = await jsonBody(c);

    const baseUrl = stringField(body, 'baseUrl');
    if (baseUrl !== undefined && !validBaseUrl(baseUrl)) {
      return c.json({ error: 'baseUrl must be an http(s) URL' }, 400);
    }

    // Empty is allowed and means the built-in Brave endpoint; anything else must be a URL.
    const searchUrl = stringField(body, 'searchUrl');
    if (searchUrl !== undefined && searchUrl.trim() !== '' && !validBaseUrl(searchUrl)) {
      return c.json({ error: 'searchUrl must be an http(s) URL' }, 400);
    }

    const extraBody = stringField(body, 'extraBody');
    if (extraBody !== undefined && extraBody.trim() !== '' && parseExtraBody(extraBody) === undefined) {
      return c.json({ error: 'extraBody must be a JSON object' }, 400);
    }

    // The `.p8` text as Apple hands it out. Empty clears it; anything else has to be a key.
    const pushKey = stringField(body, 'pushKey');
    if (pushKey !== undefined && pushKey.trim() !== '' && !pushKey.includes('-----BEGIN PRIVATE KEY-----')) {
      return c.json({ error: 'pushKey must be the contents of a .p8 file' }, 400);
    }
    const pushSandbox = body['pushSandbox'];
    if (pushSandbox !== undefined && typeof pushSandbox !== 'boolean') {
      return c.json({ error: 'pushSandbox must be a boolean' }, 400);
    }

    writeProviderSettings(db, masterKey, {
      baseUrl,
      extraBody,
      model: stringField(body, 'model'),
      apiKey: stringField(body, 'apiKey'),
    });
    if (searchUrl !== undefined) writeSearchUrl(db, searchUrl);
    const searchKey = stringField(body, 'searchKey');
    if (searchKey !== undefined) writeSearchKey(db, masterKey, searchKey);
    writePushIds(db, {
      keyId: stringField(body, 'pushKeyId')?.trim(),
      teamId: stringField(body, 'pushTeamId')?.trim(),
      bundleId: stringField(body, 'pushBundleId')?.trim(),
    });
    if (pushKey !== undefined) writePushKey(db, masterKey, pushKey.trim());
    if (pushSandbox !== undefined) writePushSandbox(db, pushSandbox);

    return c.json(allSettings());
  });

  /** One push to every registered device, so the owner sees on the settings screen whether
   * the key, the ids and the phone line up, rather than a turn later at four in the morning. */
  app.post('/api/settings/push/test', async (c) => {
    const config = pushConfig(db, masterKey);
    if (config === undefined) return c.json({ error: 'set the push key, key id, team id and bundle id first' }, 400);
    if (listDevices(db).length === 0) return c.json({ error: 'no device is registered: open the app on a phone with push enabled' }, 400);
    const result = await sendPush({ db, config }, { title: 'schermes', body: 'Push works.' });
    return c.json<PushTestResult>({ ok: result.sent > 0, ...result });
  });

  // The devices a push goes to. The app registers its token on every launch, because Apple
  // may hand it a new one; a token Apple reports dead is dropped by the push itself. The build
  // that registers also says who it is: its bundle id, team and `aps-environment` are read off
  // its own signature, which is where APNs learnt them too, so nobody types them.
  app.get('/api/devices', (c) => c.json(listDevices(db)));

  app.post('/api/devices', async (c) => {
    const body = await jsonBody(c);
    const token = stringField(body, 'token') ?? '';
    const platform = stringField(body, 'platform');
    const teamId = stringField(body, 'teamId');
    const bundleId = stringField(body, 'bundleId');
    const environment = stringField(body, 'environment');
    if (!DEVICE_TOKEN.test(token)) return c.json({ error: 'token must be the hex APNs device token' }, 400);
    if (platform !== 'ios' && platform !== 'macos') return c.json({ error: 'platform must be ios or macos' }, 400);
    if (teamId !== undefined && !TEAM_ID.test(teamId)) return c.json({ error: 'teamId must be the ten-character Apple team id' }, 400);
    if (bundleId !== undefined && !BUNDLE_ID.test(bundleId)) return c.json({ error: 'bundleId must be a bundle identifier' }, 400);
    if (environment !== undefined && environment !== 'development' && environment !== 'production') {
      return c.json({ error: 'environment must be development or production' }, 400);
    }
    upsertDevice(db, token.toLowerCase(), platform);
    // ponytail: one gateway for every device; the last build to register picks it. Store the
    // environment per device and group the send by host if a TestFlight and an Xcode build
    // ever have to be pushed to at once.
    writePushIds(db, { teamId, bundleId });
    if (environment !== undefined) writePushSandbox(db, environment === 'development');
    return c.json({ ok: true }, 201);
  });

  // A phone's push-to-start token, and each running activity's own token with the agent it shows.
  app.post('/api/live-activities', async (c) => {
    const body = await jsonBody(c);
    const token = stringField(body, 'token') ?? '';
    const kind = stringField(body, 'kind');
    const agent = stringField(body, 'agent');
    if (!DEVICE_TOKEN.test(token)) return c.json({ error: 'token must be a hex APNs token' }, 400);
    if (kind !== 'start' && kind !== 'update') return c.json({ error: 'kind must be start or update' }, 400);
    if (kind === 'update' && (agent === undefined || findAgent(db, agent) === undefined)) {
      return c.json({ error: 'an update token names the agent its activity shows' }, 400);
    }
    activities.registered(token.toLowerCase(), kind, kind === 'update' ? agent : undefined);
    return c.json({ ok: true }, 201);
  });

  app.delete('/api/devices/:token', (c) => {
    if (!deleteDevice(db, c.req.param('token').toLowerCase())) return c.json({ error: 'no such device' }, 404);
    return c.json({ ok: true });
  });

  /**
   * One model call against what is stored, tools withheld. The first message an owner sends
   * otherwise finds out for them, a turn later and in an agent's thread; this answers on the
   * settings screen, where the mistake is.
   */
  app.post('/api/settings/test', async (c) => {
    const settings = providerConfig(db, masterKey);
    if (settings === undefined) {
      return c.json({ error: 'set a provider base url, model and api key first' }, 400);
    }
    return c.json<ProviderTestResult>(await testProvider(settings));
  });

  async function testProvider(settings: ProviderConfig): Promise<ProviderTestResult> {
    try {
      const reply = await buildProvider(settings)(
        [
          { role: 'system', text: 'Answer with the single word: ok' },
          { role: 'user', text: 'Are you there?' },
        ],
        [],
      );
      const first = reply.text.trim().split('\n')[0] ?? '';
      return { ok: true, reply: first.slice(0, 200) };
    } catch (error) {
      return { ok: false, error: error instanceof Error ? error.message : String(error) };
    }
  }

  function modelFields(body: Record<string, unknown>, creating: boolean): ModelFields | { error: string } {
    const fields: ModelFields = {};
    for (const name of ['name', 'model', 'extraBody'] as const) {
      const value = body[name];
      if (value === undefined) continue;
      if (typeof value !== 'string') return { error: `${name} must be a string` };
      fields[name] = name === 'extraBody' ? value : value.trim();
    }
    for (const name of ['name', 'model'] as const) {
      if ((creating || fields[name] !== undefined) && !fields[name]) return { error: `${name} is required` };
    }
    if (body['providerId'] !== undefined || creating) {
      const providerId = modelId(body['providerId']);
      if (providerId === undefined || findProvider(db, providerId) === undefined) return { error: 'no such provider' };
      fields.providerId = providerId;
    }
    if (fields.extraBody !== undefined && fields.extraBody.trim() !== '' && parseExtraBody(fields.extraBody) === undefined) {
      return { error: 'extraBody must be a JSON object' };
    }
    return fields;
  }

  function providerFields(body: Record<string, unknown>, creating: boolean): ProviderFields | { error: string } {
    const fields: ProviderFields = {};
    for (const name of ['name', 'baseUrl', 'apiKey'] as const) {
      const value = body[name];
      if (value === undefined) continue;
      if (typeof value !== 'string') return { error: `${name} must be a string` };
      fields[name] = name === 'apiKey' ? value : value.trim();
    }
    for (const name of ['name', 'baseUrl'] as const) {
      if ((creating || fields[name] !== undefined) && !fields[name]) return { error: `${name} is required` };
    }
    if (fields.baseUrl !== undefined && !validBaseUrl(fields.baseUrl)) return { error: 'baseUrl must be an http(s) URL' };
    return fields;
  }

  function modelId(value: unknown): number | undefined {
    return typeof value === 'number' && Number.isSafeInteger(value) && value > 0 ? value : undefined;
  }

  app.get('/api/providers', (c) => c.json<ProviderEntry[]>(listProviders(db)));

  app.post('/api/providers', async (c) => {
    const fields = providerFields(await jsonBody(c), true);
    if ('error' in fields) return c.json({ error: fields.error }, 400);
    return c.json<ProviderEntry>(createProvider(db, masterKey, fields), 201);
  });

  app.put('/api/providers/:id', async (c) => {
    const id = Number(c.req.param('id'));
    if (findProvider(db, id) === undefined) return c.json({ error: 'no such provider' }, 404);
    const fields = providerFields(await jsonBody(c), false);
    if ('error' in fields) return c.json({ error: fields.error }, 400);
    return c.json<ProviderEntry | undefined>(updateProvider(db, masterKey, id, fields));
  });

  app.delete('/api/providers/:id', (c) => {
    const result = deleteProvider(db, Number(c.req.param('id')));
    if ('error' in result) return c.json({ error: result.error }, result.status);
    return c.json({ ok: true });
  });

  app.get('/api/models', (c) => c.json<ModelEntry[]>(listModels(db)));

  app.post('/api/models', async (c) => {
    const fields = modelFields(await jsonBody(c), true);
    if ('error' in fields) return c.json({ error: fields.error }, 400);
    return c.json<ModelEntry>(createModel(db, fields), 201);
  });

  app.put('/api/models/default', async (c) => {
    const id = modelId((await jsonBody(c))['id']);
    if (id === undefined || !setDefaultModel(db, id)) return c.json({ error: 'no such model' }, 404);
    return c.json<ModelEntry[]>(listModels(db));
  });

  /** `id: null` leaves no backup. */
  app.put('/api/models/backup', async (c) => {
    const raw = (await jsonBody(c))['id'];
    const id = raw === null ? null : modelId(raw);
    if (id === undefined || !setBackupModel(db, id)) return c.json({ error: 'no such model' }, 404);
    return c.json<ModelEntry[]>(listModels(db));
  });

  app.put('/api/models/:id', async (c) => {
    const id = Number(c.req.param('id'));
    if (findModel(db, id) === undefined) return c.json({ error: 'no such model' }, 404);
    const fields = modelFields(await jsonBody(c), false);
    if ('error' in fields) return c.json({ error: fields.error }, 400);
    return c.json<ModelEntry | undefined>(updateModel(db, id, fields));
  });

  app.delete('/api/models/:id', (c) => {
    const result = deleteModel(db, Number(c.req.param('id')));
    if ('error' in result) return c.json({ error: result.error }, result.status);
    return c.json({ ok: true });
  });

  app.post('/api/models/:id/test', async (c) => {
    const id = Number(c.req.param('id'));
    if (findModel(db, id) === undefined) return c.json({ error: 'no such model' }, 404);
    const settings = modelConfig(db, masterKey, id);
    if (settings === undefined) return c.json({ error: 'this model needs a provider with a base url and an api key, and a model id' }, 400);
    const result = await testProvider(settings);
    if (result.ok) clearAuthFailure(db, id);
    return c.json<ProviderTestResult>(result);
  });

  /** `id: null` puts the agent back on the default. A worker runs on its parent's model. */
  app.put('/api/agents/:name/model', async (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined || agent.parentId !== undefined) return c.json({ error: 'no such agent' }, 404);
    const raw = (await jsonBody(c))['id'];
    const id = raw === null ? null : modelId(raw);
    if (id === undefined || !assignModel(db, agent.name, id)) return c.json({ error: 'no such model' }, 404);
    return c.json(findAgent(db, agent.name));
  });

  // The owner's MCP servers. Their own routes rather than fields on `PUT /api/settings`: the
  // list is a whole object per server, the secrets in it are never echoed back, and testing one
  // is a request of its own.
  app.get('/api/mcp/servers', (c) => c.json(mcpServers(db, masterKey).map(summarise)));

  app.put('/api/mcp/servers', async (c) => {
    // The same parse the loader uses, so what may be stored and what may be run cannot drift.
    const parsed = parseMcpServers((await jsonBody(c))['servers']);
    if ('error' in parsed) return c.json({ error: parsed.error }, 400);
    writeMcpServers(db, masterKey, parsed.servers);
    return c.json(parsed.servers.map(summarise));
  });

  /**
   * One server, added or changed, without retyping the rest of the list or the secrets in it.
   * The stored list is one encrypted blob, so this reads it, replaces or appends by name, and
   * writes the whole thing back through the loader's own parse — which is also what enforces the
   * server cap on an append. The name in the path wins over any name in the body.
   */
  app.put('/api/mcp/servers/:name', async (c) => {
    const name = c.req.param('name');
    const current = mcpServers(db, masterKey);
    const stored = current.find((s) => s.name === name);
    const sent = withStoredSecrets({ ...(await jsonBody(c)), name }, stored);
    const parsed = parseMcpServers(
      stored === undefined ? [...current, sent] : current.map((s) => (s.name === name ? sent : s)),
    );
    if ('error' in parsed) return c.json({ error: parsed.error }, 400);
    writeMcpServers(db, masterKey, parsed.servers);
    return c.json(parsed.servers.map(summarise));
  });

  app.delete('/api/mcp/servers/:name', (c) => {
    const name = c.req.param('name');
    const current = mcpServers(db, masterKey);
    const left = current.filter((s) => s.name !== name);
    if (left.length === current.length) return c.json({ error: 'no such MCP server' }, 404);
    writeMcpServers(db, masterKey, left);
    return c.json({ ok: true });
  });

  /**
   * Connects to one server as one agent and says what came back. Agent-scoped because a stdio
   * server must run as that agent's Linux user, and this is the same `openMcp` a turn calls:
   * one connect path, so a test cannot be right about a spawn a turn gets wrong.
   *
   * A server that could not be reached is `ok: false` with the reason, not a failed request.
   */
  app.post('/api/agents/:name/mcp/:server/test', async (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    const spec = mcpServers(db, masterKey).find((s) => s.name === c.req.param('server'));
    if (spec === undefined) return c.json({ error: 'no such MCP server' }, 404);

    let session;
    try {
      session = await openMcp([spec], await agentTarget(exec, agent));
    } catch (error) {
      const why = error instanceof Error ? error.message : String(error);
      return c.json<McpTestResult>({ ok: false, tools: [], error: why });
    }
    try {
      const failure = session.failures[0];
      return c.json<McpTestResult>({
        ok: failure === undefined,
        tools: session.tools.map((tool) => tool.name),
        ...(failure === undefined ? {} : { error: failure.error }),
      });
    } finally {
      await session.close();
    }
  });


  /** The desktop first: the row is what frees the display number, and an Xvnc still holding it
   * would be adopted by whichever agent is given that number next. */
  /**
   * The desktop first, because usermod refuses a user with processes; the row last, because a
   * user that would not move is a rename that did not happen. The turn cap is the caller's:
   * nothing here runs while the agent does.
   */
  async function moveAgent(agent: Agent, name: string): Promise<Agent> {
    await desktop.stop(agent.name);
    try {
      await desktop.rename(agent.name, name);
    } catch (error) {
      await desktop.ensure(agent.name, agent.display);
      throw error;
    }
    const moved = renameAgent(db, agent, name);
    log.info('agent renamed', { from: agent.name, to: name });
    await desktop.ensure(moved.name, moved.display);
    return moved;
  }

  async function removeAgent(agent: Agent): Promise<void> {
    try {
      await desktop.stop(agent.name);
    } catch (error) {
      log.error('desktop would not stop', { agent: agent.name, error });
    }
    deleteAgent(db, agent);
    log.info('agent deleted', { agent: agent.name, display: agent.display });
  }

  /** The outcome, written into the thread the request came from as a system line, and a
   * turn so the agent reads it. A thread or an agent that is already gone is nobody to tell. */
  function tellTheAsker(approval: Approval, text: string): void {
    const asker = findAgent(db, approval.agent);
    if (asker === undefined || findConversation(db, approval.conversationId) === undefined) return;
    appendMessage(db, approval.conversationId, { role: 'user', content: text, sender: SYSTEM_SENDER });
    runner.start(asker, approval.conversationId);
  }

  app.get('/api/agents', (c) => {
    if (c.req.header(ATTENDING_HEADER) !== undefined) attendedAt = Date.now();
    return c.json(listAgents(db).map((agent) => ({ ...agent, contextFullness: contextFullness(db, agent) })));
  });

  app.get('/api/agents/:name', (c) => {
    const agent = findAgent(db, c.req.param('name'));
    return agent === undefined ? c.json({ error: 'no such agent' }, 404) : c.json(agent);
  });

  /** A starting point for a new agent from what the owner wants it for; nothing is created. */
  app.post('/api/agents/suggest', async (c) => {
    const description = (stringField(await jsonBody(c), 'description') ?? '').trim();
    if (description === '' || description.length > MAX_DESCRIPTION_CHARS) {
      return c.json({ error: `description must be 1-${MAX_DESCRIPTION_CHARS} characters` }, 400);
    }
    const settings = providerConfig(db, masterKey);
    const reader =
      settings === undefined
        ? undefined
        : withRetries({ primary: { provider: buildProvider(settings), modelId: undefined, name: '' }, baseMs: retryBaseMs })
            .provider;
    return c.json<AgentSuggestion>(await suggestAgent(db, description, reader));
  });

  app.post('/api/agents', async (c) => {
    const body = await jsonBody(c);
    const name = stringField(body, 'name') ?? '';
    // The scripts validate too; this keeps an unchecked name from reaching a shell at all.
    if (!AGENT_NAME.test(name)) {
      return c.json({ error: `name must match ${AGENT_NAME.source}` }, 400);
    }
    const fields = agentFields(body);
    if ('error' in fields) return c.json({ error: fields.error }, 400);
    const { profile, ...cosmetics } = fields;
    const described = describedStart(body);
    if ('error' in described) return c.json({ error: described.error }, 400);
    if (described.description !== undefined && profile !== undefined && profile !== null) {
      return c.json({ error: 'send a description or a profile, not both' }, 400);
    }

    const agent = insertAgent(db, name, cosmetics);
    if (agent === undefined) return c.json({ error: 'agent already exists' }, 409);

    if (described.description !== undefined) {
      const { description, tagline, levels, routine } = described;
      if (levels !== undefined) updateRules(db, agent, { levels });
      if (routine !== undefined) insertSchedule(db, agent, routine, Date.now());
      // The interview needs no screen, so it starts now and the desktop catches up; one that
      // will not start is logged, and a restart of it or of the daemon brings it up later.
      if (providerConfig(db, masterKey, agent) !== undefined && runner.atCapacity(agent.name) === undefined) {
        const conversationId = conversationFor(db, agent.id);
        appendMessage(db, conversationId, { role: 'user', content: describedKickoff(description, tagline) });
        runner.start(agent, conversationId);
      }
      void desktop.ensure(agent.name, agent.display).catch((error: unknown) => {
        log.error('agent desktop did not start', { agent: name, display: agent.display, error });
      });
      return c.json(findAgent(db, name) ?? agent, 201);
    }

    try {
      await desktop.ensure(agent.name, agent.display);
    } catch (error) {
      forgetAgent(db, name);
      log.error('agent creation failed', { agent: name, display: agent.display, error });
      return c.json({ error: 'could not start the agent desktop' }, 500);
    }

    // A new agent's first turn is the interview, started the way a routine starts one. With no
    // provider yet it cannot run, and the prompt tells a profile-less agent to ask anyway, so
    // the owner's first message gets the same interview later.
    if (profile === undefined || profile === null) {
      if (providerConfig(db, masterKey, agent) !== undefined && runner.atCapacity(agent.name) === undefined) {
        const conversationId = conversationFor(db, agent.id);
        appendMessage(db, conversationId, { role: 'user', content: KICKOFF });
        runner.start(agent, conversationId);
      }
    } else {
      setAgentCosmetics(db, agent.name, { profile });
    }

    return c.json(findAgent(db, name) ?? agent, 201);
  });

  /** The owner's name, avatar and profile for an agent are the row alone. A new `name` is the
   * Linux user and the desktop too, so it waits for a turn that is running to end. */
  app.patch('/api/agents/:name', async (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);

    const body = await jsonBody(c);
    const fields = agentFields(body);
    if ('error' in fields) return c.json({ error: fields.error }, 400);
    const name = stringField(body, 'name');
    if (name === undefined && Object.keys(fields).length === 0) {
      return c.json({ error: 'nothing to change: send a name, a label, a look or a profile' }, 400);
    }
    if (name !== undefined && !AGENT_NAME.test(name)) {
      return c.json({ error: `name must match ${AGENT_NAME.source}` }, 400);
    }

    if (Object.keys(fields).length > 0) setAgentCosmetics(db, agent.name, fields);
    if (name === undefined || name === agent.name) return c.json(findAgent(db, agent.name));

    if (isWorker(agent)) return c.json({ error: 'a task worker keeps its name' }, 400);
    if (findAgent(db, name) !== undefined) return c.json({ error: 'agent already exists' }, 409);
    if (runner.running(agent.name) || workersBusy(db, runner, agent)) {
      return c.json({ error: `${agent.name} is in the middle of a turn; try again in a moment` }, 409);
    }
    try {
      return c.json(await moveAgent(agent, name));
    } catch (error) {
      log.error('agent rename failed', { agent: agent.name, to: name, error });
      return c.json({ error: `could not rename ${agent.name}: ${(error as Error).message}` }, 500);
    }
  });

  /** Ends the turn an agent is in the middle of. Nothing is deleted: the transcript keeps
   * everything up to the stop, and the owner's next message starts the agent again. */
  app.post('/api/agents/:name/stop', (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    return c.json({ stopped: runner.stop(agent.name) });
  });

  /**
   * A file the owner hands to an agent lands in that agent's own `~/uploads`, written as the
   * agent so it owns what it is given. The bytes travel as base64 in JSON like a screenshot
   * does, which keeps one request shape and one body parser. The name is an operand to the
   * script, never a word in it, so a space in it is a space in the filename and nothing else.
   */
  async function writeUpload(agent: Agent, name: string, base64: string): Promise<string> {
    const target = await agentTarget(exec, agent);
    const { code, stderr } = await exec(
      'sudo',
      asAgent(target, ['bash', '-c', UPLOAD_SCRIPT, 'schermes-upload', name]),
      { input: base64, timeoutMs: 60_000 },
    );
    if (code !== 0) throw new Error(stderr.trim() || `exit ${code}`);
    return `${target.home}/uploads/${name}`;
  }

  app.post('/api/agents/:name/uploads', async (c) => {
    const agent = desktopAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);

    const body = await jsonBody(c);
    const name = stringField(body, 'name') ?? '';
    if (!UPLOAD_NAME.test(name) || name.includes('..')) {
      return c.json({ error: 'name must be a plain filename without a path' }, 400);
    }
    const base64 = stringField(body, 'base64') ?? '';
    if (base64.length > MAX_UPLOAD_BASE64_CHARS) {
      return c.json({ error: `a file may be at most ${MAX_FILE_BYTES / 1_000_000} MB` }, 400);
    }
    if (!/^[A-Za-z0-9+/=\s]*$/.test(base64)) return c.json({ error: 'base64 must be base64' }, 400);
    const bytes = Buffer.from(base64, 'base64').length;

    try {
      const path = await writeUpload(agent, name, base64);
      log.info('file uploaded', { agent: agent.name, bytes });
      return c.json<UploadResult>({ path, bytes }, 201);
    } catch (error) {
      log.error('upload failed', { agent: agent.name, error });
      return c.json({ error: 'upload failed' }, 500);
    }
  });

  /**
   * A file an agent mentions, handed to the owner to preview or keep. Only inside the agent's
   * home, and read as the agent: the owner can already reach all of it through the terminal.
   */
  app.get('/api/agents/:name/files', async (c) => {
    const named = findAgent(db, c.req.param('name'));
    // A task worker runs as the agent that spawned it, so what it names is in that agent's home.
    const agent = named?.parentId === undefined ? named : findAgentById(db, named.parentId);
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    try {
      const target = await agentTarget(exec, agent);
      const path = homePath(target.home, c.req.query('path') ?? '');
      if (path === undefined) {
        return c.json({ error: "path must point inside the agent's home" }, 400);
      }
      const file = await readHomeFile(exec, target, path);
      if ('error' in file) {
        return file.error === 'missing'
          ? c.json({ error: 'no such file' }, 404)
          : c.json({ error: `a file may be at most ${MAX_FILE_BYTES / 1_000_000} MB` }, 413);
      }
      return c.json<AgentFile>(file);
    } catch (error) {
      log.error('file read failed', { agent: agent.name, error });
      return c.json({ error: 'could not read the file' }, 500);
    }
  });

  // The agent's memory files, read and written as the agent. `MEMORY.md` is the owner's to
  // correct; the daily note is the agent's own and is shown, not edited.
  app.get('/api/agents/:name/memory', async (c) => {
    const agent = desktopAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    try {
      return c.json(await readMemory(exec, await agentTarget(exec, agent)));
    } catch (error) {
      log.error('memory read failed', { agent: agent.name, error });
      return c.json({ error: 'could not read memory' }, 500);
    }
  });

  app.put('/api/agents/:name/memory', async (c) => {
    const agent = desktopAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    const lasting = stringField(await jsonBody(c), 'lasting');
    if (lasting === undefined || lasting.length > MAX_MEMORY_FILE_CHARS) {
      return c.json({ error: `lasting must be a string of at most ${MAX_MEMORY_FILE_CHARS} characters` }, 400);
    }
    try {
      const target = await agentTarget(exec, agent);
      if ((await writeMemory(exec, target, lasting)) !== undefined) {
        return c.json(
          { error: `MEMORY.md is over ${MAX_MEMORY_FILE_CHARS} bytes, more than this screen was shown; edit it in the terminal` },
          413,
        );
      }
      return c.json(await readMemory(exec, target));
    } catch (error) {
      log.error('memory write failed', { agent: agent.name, error });
      return c.json({ error: 'could not write memory' }, 500);
    }
  });

  app.post('/api/agents/:name/computer', async (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    // The other half of the gate is in the loop's tool dispatch. While a human holds the mouse
    // nothing else drives this display, the owner's own puppet route included.
    if (control.held(agent.display)) return c.json({ error: CONTROL_REFUSAL }, 409);

    const action = parseComputerAction(await jsonBody(c), config.screen);
    if ('error' in action) return c.json({ error: action.error }, 400);

    try {
      const target = await agentTarget(exec, agent);
      // The result carries screenshot bytes, so it never goes near the logger.
      return c.json(await performComputerAction(exec, target, action, config.screen));
    } catch (error) {
      log.error('computer action failed', { agent: agent.name, action: action.action, error });
      return c.json({ error: 'computer action failed' }, 500);
    }
  });

  app.post('/api/agents/:name/command', async (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);

    const request = parseCommand(await jsonBody(c));
    if ('error' in request) return c.json({ error: request.error }, 400);

    try {
      const result = await runCommand(exec, await agentTarget(exec, agent), request);
      // Neither the command nor its output is logged: both are free text the agent chose.
      log.info('command run', {
        agent: agent.name,
        exitCode: result.exitCode,
        timedOut: result.timedOut,
        background: result.background,
      });
      return c.json(result);
    } catch (error) {
      log.error('command failed', { agent: agent.name, error });
      return c.json({ error: 'command failed' }, 500);
    }
  });

  app.get('/api/agents/:name/messages', (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    const page = messagePage(c);
    if (page === undefined) return c.json({ error: PAGE_REFUSAL }, 400);
    return c.json(withImages(c, withFeedback(db, pageMessages(db, conversationFor(db, agent.id), page))));
  });

  app.get('/api/agents/:name/live', (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    const retry = waits.get(agent.name)?.state;
    return c.json({ ...(liveReply(agent.name) ?? { text: '', reasoning: '' }), ...(retry === undefined ? {} : { retry }) });
  });

  /** "Retry now" (`now`) or "Use backup model" (`backup`) on a model call that is waiting. */
  app.post('/api/agents/:name/retry', async (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    const action = (await jsonBody(c))['action'];
    if (action !== 'now' && action !== 'backup') return c.json({ error: 'action must be now or backup' }, 400);
    const wait = waits.get(agent.name);
    if (wait === undefined) return c.json({ error: `${agent.name} is not waiting to try again` }, 409);
    const done = action === 'now' ? wait.control.now() : wait.control.useBackup();
    if (!done) return c.json({ error: 'there is no backup model to switch to' }, 409);
    return c.json({ ok: true });
  });

  /** The whole log by default, or `?limit=` the newest that many: the log grows for the life
   * of the install and a screen that polls it wants the tail. */
  app.get('/api/agents/:name/events', (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    const raw = c.req.query('limit');
    const limit = raw === undefined ? undefined : Number(raw);
    if (limit !== undefined && (!Number.isSafeInteger(limit) || limit < 1 || limit > MAX_EVENTS)) {
      return c.json({ error: `limit must be a whole number between 1 and ${MAX_EVENTS}` }, 400);
    }
    return c.json(listEvents(db, agent.id, limit));
  });

  app.post('/api/agents/:name/messages', async (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);

    const sent = messageBody(await jsonBody(c));
    if ('error' in sent) return c.json({ error: sent.error }, 400);
    if (providerConfig(db, masterKey, agent) === undefined) {
      return c.json({ error: 'set a provider base url, model and api key first' }, 400);
    }

    // Synchronous from here to the start, so nothing can take the last free loop in between.
    const refusal = runner.atCapacity(agent.name);
    if (refusal !== undefined) return c.json({ error: refusal }, 429);

    // Never a 409: a busy agent's running turn picks this row up before it releases the agent.
    const conversationId = conversationFor(db, agent.id);
    const message = appendMessage(db, conversationId, { role: 'user', content: sent.text, ...(sent.image === undefined ? {} : { image: sent.image }) });
    runner.start(agent, conversationId);
    return c.json({ message }, 202);
  });

  /**
   * The owner passes a message or a file (or a file with the message it came in) on to another
   * agent. The file is copied into the target's `~/uploads` as the target; the note and the
   * quoted message become one owner line in the target's own thread, and a turn starts there.
   */
  app.post('/api/agents/:name/forward', async (c) => {
    const agent = desktopAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    const wanted = parseForward(await jsonBody(c));
    if ('error' in wanted) return c.json({ error: wanted.error }, 400);

    const source = wanted.messageId === undefined ? undefined : findMessage(db, wanted.messageId);
    if (wanted.messageId !== undefined && source === undefined) return c.json({ error: 'no such message' }, 404);
    const named = wanted.file === undefined ? undefined : findAgent(db, wanted.file.agent);
    // A task worker runs as its parent, so what it names is in the parent's home.
    const holder = named?.parentId === undefined ? named : findAgentById(db, named.parentId);
    if (wanted.file !== undefined && holder === undefined) return c.json({ error: 'no such agent' }, 404);
    if (providerConfig(db, masterKey, agent) === undefined) {
      return c.json({ error: 'set a provider base url, model and api key first' }, 400);
    }
    const busy = runner.atCapacity(agent.name);
    if (busy !== undefined) return c.json({ error: busy }, 429);

    let copied: UploadResult | undefined;
    if (wanted.file !== undefined && holder !== undefined) {
      try {
        const home = await agentTarget(exec, holder);
        const path = homePath(home.home, wanted.file.path);
        if (path === undefined) return c.json({ error: "path must point inside the agent's home" }, 400);
        const file = await readHomeFile(exec, home, path);
        if ('error' in file) {
          return file.error === 'missing'
            ? c.json({ error: 'no such file' }, 404)
            : c.json({ error: `a file may be at most ${MAX_FILE_BYTES / 1_000_000} MB` }, 413);
        }
        copied = { path: await writeUpload(agent, uploadName(file.name), file.base64), bytes: file.bytes };
      } catch (error) {
        log.error('forward copy failed', { agent: agent.name, error });
        return c.json({ error: `could not copy the file to ${agent.name}` }, 500);
      }
    }

    // Checked again: the copy awaited, and something else may have taken the last free loop.
    const refusal = runner.atCapacity(agent.name);
    if (refusal !== undefined) return c.json({ error: refusal }, 429);
    const from = source?.sender === undefined ? 'something I wrote earlier' : (findAgent(db, source.sender)?.label ?? source.sender);
    const content = forwardedText(wanted.note, source === undefined ? undefined : { from, text: source.content }, copied?.path);
    const conversationId = conversationFor(db, agent.id);
    const message = appendMessage(db, conversationId, { role: 'user', content });
    runner.start(agent, conversationId);
    return c.json<ForwardResult>({ message, ...(copied === undefined ? {} : { file: copied }) }, 202);
  });

  // Input ownership. Taking it does not interrupt a tool call already in flight — there is no
  // result to hand back and a half-finished drag would leave a button down — it refuses what
  // the agent asks for next, which ends that turn in `waiting_for_user`.
  app.get('/api/agents/:name/control', (c) => {
    const agent = desktopAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    const recording = recorder.state(agent.display);
    return c.json({
      held: control.held(agent.display),
      handOver: screenAsked(agent) !== undefined,
      ...(recording === undefined ? {} : { recording }),
    });
  });

  /** "Show the agent how": takes the screen and records the owner's hands until it is given back.
   * Only an agent with a home of its own learns a skill, so a goal's screen worker is refused. */
  app.post('/api/agents/:name/recording', async (c) => {
    const agent = desktopAgent(db, c.req.param('name'));
    if (agent === undefined || agent.parentId !== undefined) return c.json({ error: 'no such agent' }, 404);
    if (recorder.state(agent.display) !== undefined) return c.json({ error: 'already recording' }, 409);
    let target;
    try {
      target = await agentTarget(exec, agent);
    } catch (error) {
      log.error('recording could not start', { agent: agent.name, error });
      return c.json({ error: 'could not reach the agent\'s desktop' }, 500);
    }
    if (recorder.state(agent.display) !== undefined) return c.json({ error: 'already recording' }, 409);
    control.hold(agent.display);
    recordEvent(db, agent.id, 'control', { held: true, recording: true });
    const recording = recorder.start(target);
    return c.json({ held: true, handOver: screenAsked(agent) !== undefined, recording });
  });

  app.put('/api/agents/:name/recording', async (c) => {
    const agent = desktopAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    const secret = (await jsonBody(c))['secret'];
    if (typeof secret !== 'boolean') return c.json({ error: 'secret must be true or false' }, 400);
    const recording = recorder.setSecret(agent.display, secret);
    if (recording === undefined) return c.json({ error: 'not recording' }, 404);
    return c.json({ held: control.held(agent.display), handOver: screenAsked(agent) !== undefined, recording });
  });

  app.post('/api/agents/:name/control', (c) => {
    const agent = desktopAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    control.hold(agent.display);
    recordEvent(db, agent.id, 'control', { held: true });
    return c.json({ held: true });
  });

  app.delete('/api/agents/:name/control', async (c) => {
    const agent = desktopAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    control.release(agent.display);
    recordEvent(db, agent.id, 'control', { held: false });
    // Only when the agent asked for hands or a form: an ordinary take-over is given back silently.
    const asked = screenAsked(agent);
    if (asked !== undefined) {
      appendMessage(db, asked.conversationId, { role: 'user', content: HANDS_BACK });
      runner.start(agent, asked.conversationId);
    }
    const recording = await recorder.stop(agent.display);
    if (recording !== undefined && recording.steps.length > 0) await handOver(agent, recording);
    return c.json({ held: false, handOver: false });
  });

  /**
   * The owner fills a form the agent asked for. The daemon types the values into the page itself
   * and writes a line naming the fields, secret ones marked hidden, so no value reaches the model
   * or the transcript. Remembered values fill what the owner left out; nothing is filled without
   * the owner sending this.
   */
  app.post('/api/agents/:name/forms/:id', async (c) => {
    const agent = desktopAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    const id = Number(c.req.param('id'));
    const login = loginRequests(db, agent).find((i) => i.form?.id === id);
    const loginForm = login === undefined ? undefined : findForm(db, id);
    if (loginForm?.triggerId != null) {
      const saved = saveLogin(db, masterKey, loginForm, loginForm.triggerId, await jsonBody(c));
      return 'error' in saved ? c.json({ error: saved.error }, 400) : c.json(saved);
    }
    const item = formRequests(db, agent).find((i) => i.form?.id === id);
    const form = item?.form === undefined ? undefined : findForm(db, item.form.id);
    if (item === undefined || form === undefined) return c.json({ error: 'no such form is waiting' }, 404);
    if (runner.running(agent.name)) {
      return c.json({ error: `${agent.name} is in the middle of a turn; stop it first` }, 409);
    }
    const parsed = fillSteps(db, masterKey, form, await jsonBody(c));
    if ('error' in parsed) return c.json({ error: parsed.error }, 400);
    hideFromAgent(agent.id, parsed.steps.filter((s) => s.secret).map((s) => s.value));
    const filled = await fillForm(connect, agent.display, form.origin, parsed.steps);
    if ('error' in filled) return c.json({ error: filled.error }, 409);
    if (parsed.remember) rememberSteps(db, masterKey, form, parsed.steps);
    appendMessage(db, item.conversationId, { role: 'user', content: filledLine(form.origin, parsed.steps) });
    runner.start(agent, item.conversationId);
    return c.json({ ok: true });
  });

  /** The recording goes to the agent's own thread as the owner's line, with the shots beside it. */
  async function handOver(agent: Agent, recording: Recording) {
    let saved: Awaited<ReturnType<typeof saveRecording>> = { dir: '~/recordings', picture: 'none' };
    try {
      saved = await saveRecording(exec, await agentTarget(exec, agent), recording);
    } catch (error) {
      log.error('recording not saved', { agent: agent.name, error });
    }
    const thread = conversationFor(db, agent.id);
    appendMessage(db, thread, {
      role: 'user',
      content: shownLine(recording, saved.dir, saved.picture),
      ...(saved.image === undefined ? {} : { image: saved.image }),
    });
    runner.start(agent, thread);
  }

  /** The newest request of the agent's that the owner answers on its screen. */
  function screenAsked(agent: Agent) {
    const threads = threadsOf(db, agent);
    return [...handOvers(db, agent, threads), ...formRequests(db, agent, threads)].sort((a, b) => b.createdAt - a.createdAt)[0];
  }

  /**
   * The owner's way out of a browser the watchdog could not bring back: kill it (the agent's next
   * browse starts it) or restart the whole desktop, then tell the agent in the thread it hung in
   * and start a turn there. That line is also what clears the card and the Needs you item.
   */
  app.post('/api/agents/:name/browser/restart', async (c) => {
    const agent = desktopAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    const what = (await jsonBody(c))['what'];
    if (what !== 'browser' && what !== 'desktop') return c.json({ error: 'what must be browser or desktop' }, 400);
    if (runner.running(agent.name)) {
      return c.json({ error: `${agent.name} is in the middle of a turn; stop it first` }, 409);
    }
    try {
      if (what === 'desktop') {
        await desktop.stop(agent.name);
        await desktop.ensure(agent.name, agent.display);
      } else {
        const stopped = await stopBrowser(exec, await agentTarget(exec, agent));
        if ('error' in stopped) return c.json({ error: stopped.error }, 500);
      }
    } catch (error) {
      log.error('restart failed', { agent: agent.name, what, error });
      return c.json({ error: `the ${what} could not be restarted` }, 500);
    }
    const hang = hungBrowsers(db, agent).sort((a, b) => b.createdAt - a.createdAt)[0];
    if (hang !== undefined) {
      const done = what === 'desktop' ? 'I restarted your desktop, browser included.' : 'I restarted your browser.';
      appendMessage(db, hang.conversationId, { role: 'user', content: `${done} Try again.` });
      runner.start(agent, hang.conversationId);
    }
    return c.json({ ok: true });
  });

  /** The schedule two path segments name, and only if the second belongs to the first. */
  function ownSchedule(c: Context) {
    const agent = findAgent(db, c.req.param('name') ?? '');
    const id = Number(c.req.param('id'));
    if (agent === undefined || !Number.isSafeInteger(id)) return undefined;
    return findSchedule(db, agent, id);
  }

  // Scheduled tasks. Scoped to the agent like everything else here, so an id is only ever looked
  // up inside the set the caller already named and a stale one is a 404 rather than a stranger's.
  app.get('/api/agents/:name/schedules', (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    return c.json(listSchedules(db, agent));
  });

  app.post('/api/agents/:name/schedules', async (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    // The same parse the tool uses, so what the owner may write and what the model may write
    // cannot drift apart.
    const request = parseSchedule(await jsonBody(c));
    if ('error' in request) return c.json({ error: request.error }, 400);
    const created = insertSchedule(db, agent, request, Date.now());
    return 'error' in created ? c.json(created, 409) : c.json(created, 201);
  });

  app.patch('/api/agents/:name/schedules/:id', async (c) => {
    const schedule = ownSchedule(c);
    if (schedule === undefined) return c.json({ error: 'no such schedule' }, 404);
    const paused = (await jsonBody(c))['paused'];
    if (typeof paused !== 'boolean') return c.json({ error: 'paused must be true or false' }, 400);
    return c.json(setPaused(db, schedule, paused, Date.now()));
  });

  app.delete('/api/agents/:name/schedules/:id', (c) => {
    const schedule = ownSchedule(c);
    if (schedule === undefined) return c.json({ error: 'no such schedule' }, 404);
    deleteSchedule(db, schedule);
    return c.json({ ok: true });
  });

  // A thumbs down is written into the memory of the agent that answered (a worker's goes to its
  // parent) before it is stored, so a failed write can be tried again.
  app.put('/api/messages/:id/feedback', async (c) => {
    const id = Number(c.req.param('id'));
    const reply = Number.isSafeInteger(id) ? findReply(db, id) : undefined;
    const sender = reply === undefined ? undefined : findAgent(db, reply.sender);
    if (reply === undefined || sender === undefined) return c.json({ error: 'no such reply' }, 404);
    const update = parseFeedback(await jsonBody(c));
    if ('error' in update) return c.json(update, 400);

    const before = findFeedback(db, id);
    const changed = before?.rating !== 'down' || before.reason !== update.reason;
    if (update.rating === 'down' && changed) {
      const agent = sender.parentId === undefined ? sender : (findAgentById(db, sender.parentId) ?? sender);
      try {
        const written = await remember(
          exec,
          await agentTarget(exec, agent),
          { text: feedbackLine(reply.content, update.reason), scope: 'lasting' },
          FEEDBACK_HEADING,
        );
        if ('error' in written) throw new Error(written.error);
      } catch (error) {
        log.error('feedback memory write failed', { agent: agent.name, error });
        return c.json({ error: `could not write to ${agent.name}'s memory` }, 500);
      }
    }
    return c.json({ feedback: setFeedback(db, id, update) ?? null });
  });

  // A worker runs under its parent's rules and has none of its own.
  app.get('/api/agents/:name/rules', (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined || isWorker(agent)) return c.json({ error: 'no such agent' }, 404);
    return c.json(readRules(db, agent));
  });

  app.put('/api/agents/:name/rules', async (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined || isWorker(agent)) return c.json({ error: 'no such agent' }, 404);
    const rules = updateRules(db, agent, await jsonBody(c));
    return 'error' in rules ? c.json(rules, 400) : c.json(rules);
  });

  app.get('/api/agents/:name/idle', (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined || isWorker(agent)) return c.json({ error: 'no such agent' }, 404);
    return c.json(readIdle(db, agent));
  });

  app.put('/api/agents/:name/idle', async (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined || isWorker(agent)) return c.json({ error: 'no such agent' }, 404);
    const idle = updateIdle(db, agent, await jsonBody(c));
    return 'error' in idle ? c.json(idle, 400) : c.json(idle);
  });

  // Every agent's idle passes since `since` (ms, default the last day), with their outputs.
  app.get('/api/idle/passes', (c) => {
    const since = Number(c.req.query('since') ?? Date.now() - 86_400_000);
    if (!Number.isSafeInteger(since)) return c.json({ error: 'since must be a time in milliseconds' }, 400);
    return c.json(listIdlePasses(db, since));
  });

  app.post('/api/idle/outputs/:id', async (c) => {
    const id = Number(c.req.param('id'));
    if (!Number.isSafeInteger(id)) return c.json({ error: 'no such output' }, 404);
    try {
      const result = await resolveIdleOutput(db, exec, id, (await jsonBody(c))['action']);
      return 'error' in result ? c.json({ error: result.error }, result.status) : c.json(result);
    } catch (error) {
      log.error('idle output action failed', { id, error });
      return c.json({ error: 'could not reach the agent\'s memory' }, 500);
    }
  });

  app.get('/api/agents/:name/triggers', (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined || isWorker(agent)) return c.json({ error: 'no such agent' }, 404);
    return c.json(listTriggers(db, masterKey, agent));
  });

  app.post('/api/triggers/:id', async (c) => {
    const id = Number(c.req.param('id'));
    if (!Number.isSafeInteger(id)) return c.json({ error: 'no such trigger' }, 404);
    const result = actOnTrigger(db, masterKey, runner, id, (await jsonBody(c))['action']);
    return 'error' in result ? c.json({ error: result.error }, result.status) : c.json(result);
  });

  // Outside /api on purpose: the caller is another service with a secret, not the owner's session.
  app.post(
    '/hooks/:token',
    bodyLimit({ maxSize: MAX_HOOK_BYTES, onError: (c) => c.json({ error: `the body is over ${MAX_HOOK_BYTES} bytes` }, 413) }),
    async (c) => {
      const result = fireWebhook(db, masterKey, runner, c.req.param('token'), c.req.header(SECRET_HEADER), await c.req.text());
      return c.json(result.body, result.status);
    },
  );

  app.get('/api/agents/:name/conversations', (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    return c.json(listConversations(db, agent.id));
  });

  app.post('/api/conversations', async (c) => {
    const names = (await jsonBody(c))['participants'];
    if (!Array.isArray(names) || names.length === 0) {
      return c.json({ error: 'participants must be a non-empty array of agent names' }, 400);
    }

    const agents = names.map((name) =>
      typeof name === 'string' ? findAgent(db, name) : undefined,
    );
    const unknown = names.filter((_, index) => agents[index] === undefined);
    if (unknown.length > 0) {
      return c.json({ error: `no such agent: ${unknown.map(String).join(', ')}` }, 400);
    }

    const id = conversationWith(db, agents.map((agent) => (agent as Agent).id));
    return c.json(findConversation(db, id), 201);
  });

  app.get('/api/conversations/:id/messages', (c) => {
    const conversation = conversationParam(db, c.req.param('id'));
    if (conversation === undefined) return c.json({ error: 'no such conversation' }, 404);
    const page = messagePage(c);
    if (page === undefined) return c.json({ error: PAGE_REFUSAL }, 400);
    return c.json(withImages(c, withFeedback(db, pageMessages(db, conversation.id, page))));
  });

  app.post('/api/conversations/:id/messages', async (c) => {
    const conversation = conversationParam(db, c.req.param('id'));
    if (conversation === undefined) return c.json({ error: 'no such conversation' }, 404);

    const sent = messageBody(await jsonBody(c));
    if ('error' in sent) return c.json({ error: sent.error }, 400);

    // Every agent in the thread answers, so the whole fan-out has to fit under the cap.
    const agents = participantAgents(db, conversation.id);
    if (agents.some((agent) => providerConfig(db, masterKey, agent) === undefined)) {
      return c.json({ error: 'set a provider base url, model and api key first' }, 400);
    }
    const refusal = agents.map((agent) => runner.atCapacity(agent.name)).find(Boolean);
    if (refusal !== undefined) return c.json({ error: refusal }, 429);

    const message = appendMessage(db, conversation.id, { role: 'user', content: sent.text, ...(sent.image === undefined ? {} : { image: sent.image }) });
    // One message from the owner, a turn for every agent in the thread.
    for (const agent of agents) runner.start(agent, conversation.id);
    return c.json({ message }, 202);
  });


  /**
   * Everything an agent is and everything of its own: its workers, its threads, its routines,
   * its history. Its Linux user and its home stay — that is the agent's work, and nothing here
   * is worth destroying it for. Refused while a turn is running, because pulling the rows out
   * from under a live loop turns its next write into a foreign-key failure.
   */
  app.delete('/api/agents/:name', async (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    if (runner.running(agent.name)) {
      return c.json({ error: `${agent.name} is in the middle of a turn; try again in a moment` }, 409);
    }
    await removeAgent(agent);
    return c.json({ ok: true });
  });

  /** The permanent agents whose files a rewind of this thread would put back. */
  function fileOwners(conversationId: number): Agent[] {
    return participantAgents(db, conversationId).filter((agent) => agent.parentId === undefined);
  }

  /** What a rewind from `from` takes away and what it can't: the confirmation's preview. */
  async function rewindPreview(c: Context, conversationId: number) {
    const from = Number(c.req.query('from'));
    if (!Number.isSafeInteger(from) || from < 1) return c.json({ error: 'from must be a message id' }, 400);
    const stored = listMessages(db, conversationId);
    const gone = rewoundRows(stored, from);
    const preview: RewindPreview = { removed: gone.length, files: [], noSnapshot: [], cantUndo: cantUndo(gone, stored) };
    const now = Date.now();
    for (const agent of fileOwners(conversationId)) {
      try {
        const found = await fileChanges(exec, agent, from, now);
        if (found === undefined) preview.noSnapshot.push(agent.name);
        else preview.files.push(found.changes);
      } catch (error) {
        log.error('reading a snapshot failed', { agent: agent.name, error });
        preview.noSnapshot.push(agent.name);
      }
    }
    return c.json(preview);
  }

  /**
   * With `retry` the message left last is asked again, so its author must not answer itself.
   * With `files` every agent in the thread gets its home back as it was before the first turn
   * the rewind removes, or nothing happens: files first, because they can fail and rows can't.
   */
  async function rewind(c: Context, conversationId: number) {
    const body = await jsonBody(c);
    const from = body['from'];
    const retry = body['retry'] === true;
    const files = body['files'] === true;
    if (typeof from !== 'number' || !Number.isSafeInteger(from) || from < 1) {
      return c.json({ error: 'from must be a message id' }, 400);
    }
    const agents = participantAgents(db, conversationId);
    const busy = agents.find((agent) => runner.running(agent.name));
    if (busy !== undefined) {
      return c.json({ error: `${busy.name} is in the middle of a turn; stop it first` }, 409);
    }
    const prompt = listMessages(db, conversationId).findLast((message) => message.id < from);
    const askers = agents.filter((agent) => agent.name !== prompt?.sender);
    if (retry) {
      if (prompt?.role !== 'user') return c.json({ error: 'only a message to the agents can be retried' }, 400);
      if (askers.some((agent) => providerConfig(db, masterKey, agent) === undefined)) {
        return c.json({ error: 'set a provider base url, model and api key first' }, 400);
      }
      const refusal = askers.map((agent) => runner.atCapacity(agent.name)).find(Boolean);
      if (refusal !== undefined) return c.json({ error: refusal }, 429);
    }
    const restored: FileChanges[] = [];
    if (files) {
      const now = Date.now();
      const owners = fileOwners(conversationId);
      for (const agent of owners) {
        const found = await fileChanges(exec, agent, from, now).catch(() => undefined);
        if (found === undefined) {
          return c.json({ error: `there is no snapshot of ${agent.name}'s files from before that point` }, 409);
        }
      }
      // The snapshot reads awaited, and a message, routine, trigger or idle tick may have started a turn.
      const started = agents.find((agent) => runner.running(agent.name));
      if (started !== undefined) {
        return c.json({ error: `${started.name} is in the middle of a turn; stop it first` }, 409);
      }
      const already = () =>
        restored.length === 0 ? '' : `, but ${restored.map((done) => done.agent).join(' and ')}'s files were already put back`;
      for (const agent of owners) {
        let changes: FileChanges | undefined;
        try {
          changes = await restoreFiles(exec, agent, from, now);
        } catch (error) {
          log.error('restoring files failed', { agent: agent.name, error });
          return c.json({ error: `could not put ${agent.name}'s files back; the thread was left as it was${already()}` }, 500);
        }
        if (changes === undefined) {
          return c.json({ error: `there is no snapshot of ${agent.name}'s files from before that point${already()}` }, 409);
        }
        restored.push(changes);
      }
      const late = agents.find((agent) => runner.running(agent.name));
      if (late !== undefined) {
        return c.json(
          { error: `${late.name} started a turn while its files were put back; the files are restored, the thread is not` },
          409,
        );
      }
    }
    rewindConversation(db, conversationId, from);
    for (const changes of restored) appendMessage(db, conversationId, { role: 'user', content: restoredLine(changes), sender: SYSTEM_SENDER });
    if (retry) for (const agent of askers) runner.start(agent, conversationId);
    return c.json({ ok: true, ...(files ? { files: restored } : {}) });
  }

  app.get('/api/agents/:name/rewind', async (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    return rewindPreview(c, conversationFor(db, agent.id));
  });

  app.get('/api/conversations/:id/rewind', async (c) => {
    const conversation = conversationParam(db, c.req.param('id'));
    if (conversation === undefined) return c.json({ error: 'no such conversation' }, 404);
    return rewindPreview(c, conversation.id);
  });

  app.post('/api/agents/:name/rewind', async (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    return rewind(c, conversationFor(db, agent.id));
  });

  app.post('/api/conversations/:id/rewind', async (c) => {
    const conversation = conversationParam(db, c.req.param('id'));
    if (conversation === undefined) return c.json({ error: 'no such conversation' }, 404);
    return rewind(c, conversation.id);
  });

  /**
   * The owner's compaction, for every agent in the thread on its own projection, the way a turn
   * does it when the budget says so. Refused mid-turn like a rewind: the summary has to cover
   * a thread whose every call is answered, and a running loop is still writing them.
   */
  async function compact(c: Context, conversationId: number) {
    const agents = participantAgents(db, conversationId);
    const busy = agents.find((agent) => runner.running(agent.name));
    if (busy !== undefined) {
      return c.json({ error: `${busy.name} is in the middle of a turn; stop it first` }, 409);
    }
    const settings = agents.map((agent) => providerConfig(db, masterKey, agent));
    if (settings.some((entry) => entry === undefined)) {
      return c.json({ error: 'set a provider base url, model and api key first' }, 400);
    }
    const compacted: Record<string, number> = {};
    for (const [index, agent] of agents.entries()) {
      // The model call for the agent before gave the owner's next message time to start a turn.
      if (runner.running(agent.name)) {
        return c.json({ error: `${agent.name} is in the middle of a turn; stop it first` }, 409);
      }
      const { provider } = withRetries({
        primary: { provider: buildProvider(settings[index]!), modelId: undefined, name: '' },
        baseMs: retryBaseMs,
      });
      const result = await compactNow({ db, provider }, agent, conversationId);
      if ('error' in result) return c.json({ error: result.error }, 500);
      compacted[agent.name] = result.covered;
    }
    return c.json<CompactResult>({ compacted });
  }

  app.post('/api/agents/:name/compact', async (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    return compact(c, conversationFor(db, agent.id));
  });

  app.post('/api/conversations/:id/compact', async (c) => {
    const conversation = conversationParam(db, c.req.param('id'));
    if (conversation === undefined) return c.json({ error: 'no such conversation' }, 404);
    return compact(c, conversation.id);
  });

  app.delete('/api/conversations/:id', (c) => {
    const conversation = conversationParam(db, c.req.param('id'));
    if (conversation === undefined) return c.json({ error: 'no such conversation' }, 404);
    const busy = participantAgents(db, conversation.id).find((agent) => runner.running(agent.name));
    if (busy !== undefined) {
      return c.json({ error: `${busy.name} is in the middle of a turn; try again in a moment` }, 409);
    }
    deleteConversation(db, conversation.id);
    return c.json({ ok: true });
  });

  app.get('/api/approvals', (c) => c.json(listApprovals(db)));

  app.get('/api/needs-you', (c) => c.json(listNeedsYou(db)));

  app.get('/api/goals', (c) => c.json<Goal[]>(listGoals(db)));

  app.get('/api/goals/:id', (c) => {
    const goal = findGoal(db, Number(c.req.param('id')));
    return goal === undefined ? c.json({ error: 'no such goal' }, 404) : c.json(goal);
  });

  app.post('/api/goals/:id/finish', async (c) => {
    const done = await finishGoal({ db, desktop, runner }, Number(c.req.param('id')));
    return 'error' in done ? c.json({ error: done.error }, done.status) : c.json(done);
  });

  app.delete('/api/goals/:id', async (c) => {
    const gone = await deleteGoal({ db, desktop, runner }, Number(c.req.param('id')));
    return 'error' in gone ? c.json({ error: gone.error }, gone.status) : c.json(gone);
  });

  app.post('/api/goals/:id/helpers/:name/keep', (c) => {
    const kept = keepHelper(db, Number(c.req.param('id')), c.req.param('name'));
    return 'error' in kept ? c.json({ error: kept.error }, kept.status) : c.json(kept);
  });

  /** A question rather than a phrase: the default model reads it into filters over the index. */
  app.post('/api/search', async (c) => {
    const question = (stringField(await jsonBody(c), 'q') ?? '').trim();
    if (question === '' || question.length > MAX_QUESTION_CHARS) {
      return c.json({ error: `q must be 1-${MAX_QUESTION_CHARS} characters` }, 400);
    }
    const settings = providerConfig(db, masterKey);
    const reader =
      settings === undefined
        ? undefined
        : withRetries({ primary: { provider: buildProvider(settings), modelId: undefined, name: '' }, baseMs: retryBaseMs })
            .provider;
    return c.json<SearchAnswer>(await answerSearch(db, question, reader, Date.now()));
  });

  /** The owner's answer. Either way the request is gone afterwards and the agent that asked is
   * told, in the thread it asked in, so it learns the outcome the same way it learns anything. */
  const answered = { status: 200 as const, body: { ok: true as const } };
  /** The owner's answer to an approval, from the app's buttons or a notification's. */
  async function decide(
    approval: Approval,
    approve: boolean,
    always: boolean,
  ): Promise<{ status: 200 | 400 | 409; body: { ok: true } | { error: string } }> {
    const allowed = alwaysAllowable(approval);
    if (always && (!approve || allowed === undefined)) {
      return { status: 400, body: { error: 'only an approved action with a site or recipient can be always allowed' } };
    }

    const asker = findAgent(db, approval.agent);
    const target = approval.kind === 'agent' ? findAgent(db, approval.target) : undefined;
    const inFlight = [asker, target].find((agent) => agent !== undefined && runner.running(agent.name));
    // An action is not performed here, and its asker was told to carry on meanwhile.
    if (approve && approval.kind !== 'action' && inFlight !== undefined) {
      return { status: 409, body: { error: `${inFlight.name} is in the middle of a turn; try again in a moment` } };
    }

    dropApproval(db, approval.id);
    if (asker !== undefined) {
      recordEvent(db, asker.id, 'approval', {
        decided: approval.id,
        kind: approval.kind,
        target: approval.target,
        approved: approve,
      });
    }

    if (!approve) {
      tellTheAsker(approval, `The owner said no to your request to ${describeApproval(approval)}.`);
      return answered;
    }

    if (approval.kind === 'action') {
      if (asker !== undefined && readRules(db, asker).levels[approval.category] === 'hand_to_you') {
        tellTheAsker(
          approval,
          `The owner saw your request to ${describeApproval(approval)} and will do it themselves. Do not do it.`,
        );
        return answered;
      }
      if (asker !== undefined && always && allowed !== undefined) {
        alwaysAllow(db, asker, approval.category, allowed);
      } else if (asker !== undefined) {
        grantOnce(db, asker, approval);
      }
      const standing = always ? ` ${allowed} is on your pre-approved list to ${CATEGORY_WORDS[approval.category]} from now on.` : '';
      tellTheAsker(approval, `${APPROVED}${describeApproval(approval)}${GO_AHEAD}${standing}`);
      return answered;
    }
    if (approval.kind === 'conversation') {
      deleteConversation(db, Number(approval.target));
      return answered;
    }
    if (target === undefined) {
      tellTheAsker(approval, `The agent ${approval.target} was already gone, so nothing was deleted.`);
      return answered;
    }
    // Told before it is done: deleting the asker takes the thread the answer would go in.
    tellTheAsker(approval, `The owner approved: ${approval.target} has been deleted.`);
    await removeAgent(target);
    return answered;
  }

  app.post('/api/approvals/:id', async (c) => {
    const approval = findApproval(db, Number(c.req.param('id')));
    if (approval === undefined) return c.json({ error: 'no such request' }, 404);
    const body = await jsonBody(c);
    const approve = body['approve'];
    if (typeof approve !== 'boolean') return c.json({ error: 'approve must be true or false' }, 400);
    const always = body['always'] ?? false;
    if (typeof always !== 'boolean') return c.json({ error: 'always must be true or false' }, 400);
    const decided = await decide(approval, approve, always);
    return c.json(decided.body, decided.status);
  });

  // What a notification button answers, with no app state: the item is found again by id, so a
  // stale one (already answered from the app) is a 404 rather than a second answer.
  app.post('/api/needs-you/:id/action', async (c) => {
    const id = c.req.param('id');
    const item = listNeedsYou(db).find((candidate) => candidate.id === id);
    if (item === undefined) return c.json({ error: 'nothing is waiting under that id any more' }, 404);
    const action = (await jsonBody(c))['action'];
    if (typeof action !== 'string' || !item.actions.includes(action as NeedsYouAction)) {
      return c.json({ error: `this item does not offer ${JSON.stringify(action)}` }, 400);
    }
    if (item.approval === undefined || !['approve', 'always', 'deny'].includes(action)) {
      return c.json({ error: `${action} happens in the app` }, 400);
    }
    const decided = await decide(item.approval, action !== 'deny', action === 'always');
    return c.json(decided.body, decided.status);
  });

  // The runner comes back out because the scheduler tick starts turns through it too, and it
  // cannot be built twice: the one-turn-per-agent set is process state inside this one.
  return { app, runner, recorder };
}
