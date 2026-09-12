import { Hono } from 'hono';
import { getCookie } from 'hono/cookie';
import { MIN_PASSWORD_LENGTH } from '@schermes/shared';
import type {
  Agent,
  Approval,
  Conversation,
  HealthResponse,
  McpServerSummary,
  McpTestResult,
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
  readProviderSettings,
  readWebSettings,
  searchConfig,
  writeApiKey,
  writeBaseUrl,
  writeExtraBody,
  writeMcpServers,
  writeModel,
  writeSearchKey,
  writeSearchUrl,
} from './settings.ts';
import {
  AGENT_NAME,
  agentTarget,
  deleteAgent,
  desktopAgent,
  findAgent,
  forgetAgent,
  insertAgent,
  listAgents,
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
  pageMessages,
  participantAgents,
  recordEvent,
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
import { isHttpServer, openMcp, parseMcpServers } from './mcp.ts';
import type { McpServerSpec } from './mcp.ts';
import { createRunner, liveReply } from './loop.ts';
import { CONTROL_REFUSAL, createControl } from './control.ts';
import { openAiProvider } from './provider.ts';
import type { Provider, ProviderConfig } from './provider.ts';
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

function messageText(body: Record<string, unknown>): string | undefined {
  const text = stringField(body, 'text');
  return text === undefined || text.trim() === '' ? undefined : text;
}

/** One configured server as the owner may see it: what it is and which secrets it carries by
 * name. A value an owner stored is never read back out, the provider key's rule. */
function summarise(spec: McpServerSpec): McpServerSummary {
  return isHttpServer(spec)
    ? { name: spec.name, transport: 'http', url: spec.url, secretKeys: Object.keys(spec.headers) }
    : {
        name: spec.name,
        transport: 'stdio',
        command: [spec.command, ...spec.args].join(' '),
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

  app.get('/api/settings', (c) => c.json({ ...readProviderSettings(db), ...readWebSettings(db) }));

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

    if (baseUrl !== undefined) writeBaseUrl(db, baseUrl);
    if (extraBody !== undefined) writeExtraBody(db, extraBody);
    const model = stringField(body, 'model');
    if (model !== undefined) writeModel(db, model);
    const apiKey = stringField(body, 'apiKey');
    if (apiKey !== undefined) writeApiKey(db, masterKey, apiKey);
    if (searchUrl !== undefined) writeSearchUrl(db, searchUrl);
    const searchKey = stringField(body, 'searchKey');
    if (searchKey !== undefined) writeSearchKey(db, masterKey, searchKey);

    return c.json({ ...readProviderSettings(db), ...readWebSettings(db) });
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
    const name = stringField(await jsonBody(c), 'name') ?? '';
    // The scripts validate too; this keeps an unchecked name from reaching a shell at all.
    if (!AGENT_NAME.test(name)) {
      return c.json({ error: `name must match ${AGENT_NAME.source}` }, 400);
    }

    const agent = insertAgent(db, name);
    if (agent === undefined) return c.json({ error: 'agent already exists' }, 409);

    try {
      await desktop.ensure(agent.name, agent.display);
    } catch (error) {
      forgetAgent(db, name);
      log.error('agent creation failed', { agent: name, display: agent.display, error });
      return c.json({ error: 'could not start the agent desktop' }, 500);
    }

    return c.json(agent, 201);
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
    return c.json(pageMessages(db, conversationFor(db, agent.id), page));
  });

  app.get('/api/agents/:name/live', (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    return c.json(liveReply(agent.name) ?? { text: '', reasoning: '' });
  });

  app.get('/api/agents/:name/events', (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);
    return c.json(listEvents(db, agent.id));
  });

  app.post('/api/agents/:name/messages', async (c) => {
    const agent = findAgent(db, c.req.param('name'));
    if (agent === undefined) return c.json({ error: 'no such agent' }, 404);

    const text = messageText(await jsonBody(c));
    if (text === undefined) return c.json({ error: 'text must be a non-empty string' }, 400);
    if (providerConfig(db, masterKey) === undefined) {
      return c.json({ error: 'set a provider base url, model and api key first' }, 400);
    }

    // Synchronous from here to the start, so nothing can take the last free loop in between.
    const refusal = runner.atCapacity(agent.name);
    if (refusal !== undefined) return c.json({ error: refusal }, 429);

    // Never a 409: a busy agent's running turn picks this row up before it releases the agent.
    const conversationId = conversationFor(db, agent.id);
    const message = appendMessage(db, conversationId, { role: 'user', content: text });
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
    return c.json(pageMessages(db, conversation.id, page));
  });

  app.post('/api/conversations/:id/messages', async (c) => {
    const conversation = conversationParam(db, c.req.param('id'));
    if (conversation === undefined) return c.json({ error: 'no such conversation' }, 404);

    const text = messageText(await jsonBody(c));
    if (text === undefined) return c.json({ error: 'text must be a non-empty string' }, 400);
    if (providerConfig(db, masterKey) === undefined) {
      return c.json({ error: 'set a provider base url, model and api key first' }, 400);
    }

    // Every agent in the thread answers, so the whole fan-out has to fit under the cap.
    const agents = participantAgents(db, conversation.id);
    const refusal = agents.map((agent) => runner.atCapacity(agent.name)).find(Boolean);
    if (refusal !== undefined) return c.json({ error: refusal }, 429);

    const message = appendMessage(db, conversation.id, { role: 'user', content: text });
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
