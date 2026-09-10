import { Hono } from 'hono';
import { getCookie } from 'hono/cookie';
import { MIN_PASSWORD_LENGTH } from '@schermes/shared';
import type { HealthResponse } from '@schermes/shared';
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
  readProviderSettings,
  writeApiKey,
  writeBaseUrl,
  writeModel,
} from './settings.ts';
import {
  AGENT_NAME,
  findAgent,
  forgetAgent,
  insertAgent,
  listAgents,
} from './agents.ts';
import type { DesktopOps } from './agents.ts';
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

function validBaseUrl(value: string): boolean {
  if (value === '') return true;
  try {
    return ['http:', 'https:'].includes(new URL(value).protocol);
  } catch {
    return false;
  }
}

export type AppDeps = { db: Db; masterKey: Buffer; desktop: DesktopOps };

export function createApp({ db, masterKey, desktop }: AppDeps) {
  const app = new Hono();

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

  app.get('/api/settings', (c) => c.json(readProviderSettings(db)));

  app.put('/api/settings', async (c) => {
    const body = await jsonBody(c);

    const baseUrl = stringField(body, 'baseUrl');
    if (baseUrl !== undefined && !validBaseUrl(baseUrl)) {
      return c.json({ error: 'baseUrl must be an http(s) URL' }, 400);
    }

    if (baseUrl !== undefined) writeBaseUrl(db, baseUrl);
    const model = stringField(body, 'model');
    if (model !== undefined) writeModel(db, model);
    const apiKey = stringField(body, 'apiKey');
    if (apiKey !== undefined) writeApiKey(db, masterKey, apiKey);

    return c.json(readProviderSettings(db));
  });

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

  return app;
}
