import { Hono } from 'hono';
import { getCookie } from 'hono/cookie';
import { MIN_PASSWORD_LENGTH } from '@schermes/shared';
import type {
  Agent,
  Approval,
  CompactResult,
  Conversation,
  HealthResponse,
  McpServerSummary,
  McpTestResult,
  Message,
  ProviderTestResult,
  PushTestResult,
  AgentFile,
  UploadResult,
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
  parseExtraBody,
  providerConfig,
  pushConfig,
  readProviderSettings,
  readPushSettings,
  readWebSettings,
  searchConfig,
  writeApiKey,
  writeBaseUrl,
  writeExtraBody,
  writeMcpServers,
  writeModel,
  writeSearchKey,
  writePushIds,
  writePushKey,
  writePushSandbox,
  writeSearchUrl,
} from './settings.ts';
import { MAX_PUSH_BODY_CHARS, deleteDevice, listDevices, sendPush, upsertDevice } from './push.ts';
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
  listAgents,
  setAgentCosmetics,
} from './agents.ts';
import {
  describeApproval,
  dropApproval,
  findApproval,
  listApprovals,
} from './approvals.ts';
import type { DesktopOps } from './agents.ts';
import { parseComputerAction, performComputerAction } from './computer.ts';
import { parseCommand, runCommand } from './terminal.ts';
import {
  appendMessage,
  conversationFor,
  conversationWith,
  deleteConversation,
  findConversation,
  listConversations,
  listEvents,
  listMessages,
  pageMessages,
  participantAgents,
  recordEvent,
  rewindConversation,
  searchMessages,
} from './conversations.ts';
import type { MessagePage } from './conversations.ts';
import {
  deleteSchedule,
  findSchedule,
  insertSchedule,
  listSchedules,
  parseSchedule,
  setPaused,
} from './schedules.ts';
import { isHttpServer, openMcp, parseMcpServers, withStoredSecrets } from './mcp.ts';
import type { McpServerSpec } from './mcp.ts';
import { compactNow, createRunner, liveReply } from './loop.ts';
import {
  MAX_FILE_BYTES,
  MAX_MEMORY_FILE_CHARS,
  homePath,
  readHomeFile,
  readMemory,
  writeMemory,
} from './home.ts';
import { CONTROL_REFUSAL, createControl } from './control.ts';
import { KICKOFF, MAX_PROFILE_CHARS } from './interview.ts';
import { openAiProvider } from './provider.ts';
import type { Image, Provider, ProviderConfig } from './provider.ts';
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
const MAX_SEARCH_CHARS = 200;

/** An uploaded file's name: one path segment of ordinary characters, nothing hidden. */
const UPLOAD_NAME = /^[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,127}$/;
// Base64 is four characters per three bytes.
const MAX_UPLOAD_BASE64_CHARS = Math.ceil(MAX_FILE_BYTES / 3) * 4;
const UPLOAD_SCRIPT = `set -eu
mkdir -p "$HOME/uploads"
base64 -d > "$HOME/uploads/$1"
`;

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
};

export function createApp({
  db,
  masterKey,
  desktop,
  exec,
  makeProvider,
  maxLoops = config.maxLoops,
  maxWorkers = config.maxWorkers,
}: AppDeps) {
  const app = new Hono();
  const buildProvider = makeProvider ?? openAiProvider;
  // Owns the one-turn-per-agent rule. Both the routes below and `send_message` inside a turn
  // start turns through it, which is why it cannot live in a route closure.
  const control = createControl();
  const runner = createRunner({
    db,
    exec,
    control,
    screen: config.screen,
    maxLoops,
    maxWorkers,
    // The one channel: what an agent said at the end of a turn in its own thread with the
    // owner, and a deletion request wherever it was made, become a push to every registered
    // device. Fire and forget; nothing configured or nobody registered is silence, and a
    // failed delivery is a log line.
    // Called from inside a turn, so a throw here would fail a turn that already finished.
    deliver: (agent, conversationId, text, kind) => {
      try {
        if (agent.parentId !== undefined) return;
        if (kind !== 'approval' && participantAgents(db, conversationId).length !== 1) return;
        const push = pushConfig(db, masterKey);
        if (push === undefined) return;
        sendPush(
          { db, config: push },
          { title: agent.label ?? agent.name, body: text, agent: agent.name, conversationId },
        ).catch((error: unknown) => log.error('push failed', { agent: agent.name, error }));
      } catch (error) {
        log.error('push failed', { agent: agent.name, error });
      }
    },
    provider: () => {
      const settings = providerConfig(db, masterKey);
      return settings === undefined ? undefined : buildProvider(settings);
    },
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

    if (baseUrl !== undefined) writeBaseUrl(db, baseUrl);
    if (extraBody !== undefined) writeExtraBody(db, extraBody);
    const model = stringField(body, 'model');
    if (model !== undefined) writeModel(db, model);
    const apiKey = stringField(body, 'apiKey');
    if (apiKey !== undefined) writeApiKey(db, masterKey, apiKey);
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
    try {
      const reply = await buildProvider(settings)(
        [
          { role: 'system', text: 'Answer with the single word: ok' },
          { role: 'user', text: 'Are you there?' },
        ],
        [],
      );
      const first = reply.text.trim().split('\n')[0] ?? '';
      return c.json<ProviderTestResult>({ ok: true, reply: first.slice(0, 200) });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return c.json<ProviderTestResult>({ ok: false, error: message });
    }
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
  async function removeAgent(agent: Agent): Promise<void> {
    try {
      await desktop.stop(agent.name);
    } catch (error) {
      log.error('desktop would not stop', { agent: agent.name, error });
    }
    deleteAgent(db, agent);
    log.info('agent deleted', { agent: agent.name, display: agent.display });
  }

  /** The outcome, written into the thread the request came from as the owner's own words, and a
   * turn so the agent reads it. A thread or an agent that is already gone is nobody to tell. */
  function tellTheAsker(approval: Approval, text: string): void {
    const asker = findAgent(db, approval.agent);
    if (asker === undefined || findConversation(db, approval.conversationId) === undefined) return;
    appendMessage(db, approval.conversationId, { role: 'user', content: text });
    runner.start(asker, approval.conversationId);
  }

  app.get('/api/agents', (c) => c.json(listAgents(db)));

  app.get('/api/agents/:name', (c) => {
    const agent = findAgent(db, c.req.param('name'));
    return agent === undefined ? c.json({ error: 'no such agent' }, 404) : c.json(agent);
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

    const agent = insertAgent(db, name, cosmetics);
    if (agent === undefined) return c.json({ error: 'agent already exists' }, 409);

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
      if (providerConfig(db, masterKey) !== undefined && runner.atCapacity(agent.name) === undefined) {
        const conversationId = conversationFor(db, agent.id);
        appendMessage(db, conversationId, { role: 'user', content: KICKOFF });
        runner.start(agent, conversationId);
      }
    } else {
      setAgentCosmetics(db, agent.name, { profile });
    }

    return c.json(findAgent(db, name) ?? agent, 201);
  });

  /** The owner's name, avatar and profile for an agent. Nothing here needs what creating one
   * needs: no desktop, no Linux user, nothing but the row. */
  app.patch('/api/agents/:name', async (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);

    const fields = agentFields(await jsonBody(c));
    if ('error' in fields) return c.json({ error: fields.error }, 400);
    if (Object.keys(fields).length === 0) {
      return c.json({ error: 'nothing to change: send a label, a look or a profile' }, 400);
    }

    setAgentCosmetics(db, agent.name, fields);
    return c.json(findAgent(db, agent.name));
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
      const target = await agentTarget(exec, agent);
      const { code, stderr } = await exec(
        'sudo',
        asAgent(target, ['bash', '-c', UPLOAD_SCRIPT, 'schermes-upload', name]),
        { input: base64, timeoutMs: 60_000 },
      );
      if (code !== 0) throw new Error(stderr.trim() || `exit ${code}`);
      log.info('file uploaded', { agent: agent.name, bytes });
      return c.json<UploadResult>({ path: `${target.home}/uploads/${name}`, bytes }, 201);
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
    return c.json(withImages(c, pageMessages(db, conversationFor(db, agent.id), page)));
  });

  app.get('/api/agents/:name/live', (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    return c.json(liveReply(agent.name) ?? { text: '', reasoning: '' });
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
    if (providerConfig(db, masterKey) === undefined) {
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

  // Input ownership. Taking it does not interrupt a tool call already in flight — there is no
  // result to hand back and a half-finished drag would leave a button down — it refuses what
  // the agent asks for next, which ends that turn in `waiting_for_user`.
  app.get('/api/agents/:name/control', (c) => {
    const agent = desktopAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    return c.json({ held: control.held(agent.display) });
  });

  app.post('/api/agents/:name/control', (c) => {
    const agent = desktopAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    control.hold(agent.display);
    recordEvent(db, agent.id, 'control', { held: true });
    return c.json({ held: true });
  });

  app.delete('/api/agents/:name/control', (c) => {
    const agent = desktopAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    control.release(agent.display);
    recordEvent(db, agent.id, 'control', { held: false });
    return c.json({ held: false });
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
    return c.json(withImages(c, pageMessages(db, conversation.id, page)));
  });

  app.post('/api/conversations/:id/messages', async (c) => {
    const conversation = conversationParam(db, c.req.param('id'));
    if (conversation === undefined) return c.json({ error: 'no such conversation' }, 404);

    const sent = messageBody(await jsonBody(c));
    if ('error' in sent) return c.json({ error: sent.error }, 400);
    if (providerConfig(db, masterKey) === undefined) {
      return c.json({ error: 'set a provider base url, model and api key first' }, 400);
    }

    // Every agent in the thread answers, so the whole fan-out has to fit under the cap.
    const agents = participantAgents(db, conversation.id);
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

  /** With `retry` the message left last is asked again, so its author must not answer itself. */
  async function rewind(c: Context, conversationId: number) {
    const body = await jsonBody(c);
    const from = body['from'];
    const retry = body['retry'] === true;
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
      if (providerConfig(db, masterKey) === undefined) {
        return c.json({ error: 'set a provider base url, model and api key first' }, 400);
      }
      const refusal = askers.map((agent) => runner.atCapacity(agent.name)).find(Boolean);
      if (refusal !== undefined) return c.json({ error: refusal }, 429);
    }
    rewindConversation(db, conversationId, from);
    if (retry) for (const agent of askers) runner.start(agent, conversationId);
    return c.json({ ok: true });
  }

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
    const settings = providerConfig(db, masterKey);
    if (settings === undefined) {
      return c.json({ error: 'set a provider base url, model and api key first' }, 400);
    }
    const provider = buildProvider(settings);
    const compacted: Record<string, number> = {};
    for (const agent of agents) {
      // The model call for the agent before gave the owner's next message time to start a turn.
      if (runner.running(agent.name)) {
        return c.json({ error: `${agent.name} is in the middle of a turn; stop it first` }, 409);
      }
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

  /** Every thread at once, for a reader who remembers a phrase and not where it was said. */
  app.get('/api/search', (c) => {
    const needle = (c.req.query('q') ?? '').trim();
    if (needle === '' || needle.length > MAX_SEARCH_CHARS) {
      return c.json({ error: `q must be 1-${MAX_SEARCH_CHARS} characters` }, 400);
    }
    return c.json(searchMessages(db, needle));
  });

  /** The owner's answer. Either way the request is gone afterwards and the agent that asked is
   * told, in the thread it asked in, so it learns the outcome the same way it learns anything. */
  app.post('/api/approvals/:id', async (c) => {
    const approval = findApproval(db, Number(c.req.param('id')));
    if (approval === undefined) return c.json({ error: 'no such request' }, 404);
    const approve = (await jsonBody(c))['approve'];
    if (typeof approve !== 'boolean') return c.json({ error: 'approve must be true or false' }, 400);

    const asker = findAgent(db, approval.agent);
    const target = approval.kind === 'agent' ? findAgent(db, approval.target) : undefined;
    const inFlight = [asker, target].find((agent) => agent !== undefined && runner.running(agent.name));
    if (approve && inFlight !== undefined) {
      return c.json({ error: `${inFlight.name} is in the middle of a turn; try again in a moment` }, 409);
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
      return c.json({ ok: true });
    }

    if (approval.kind === 'conversation') {
      deleteConversation(db, Number(approval.target));
      return c.json({ ok: true });
    }
    if (target === undefined) {
      tellTheAsker(approval, `The agent ${approval.target} was already gone, so nothing was deleted.`);
      return c.json({ ok: true });
    }
    // Told before it is done: deleting the asker takes the thread the answer would go in.
    tellTheAsker(approval, `The owner approved: ${approval.target} has been deleted.`);
    await removeAgent(target);
    return c.json({ ok: true });
  });

  // The runner comes back out because the scheduler tick starts turns through it too, and it
  // cannot be built twice: the one-turn-per-agent set is process state inside this one.
  return { app, runner };
}
