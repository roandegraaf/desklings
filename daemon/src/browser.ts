import { setTimeout as sleep } from 'node:timers/promises';
import WebSocket from 'ws';
import { asAgent } from './agents.ts';
import type { AgentTarget } from './agents.ts';
import type { Exec } from './exec.ts';
import type { ToolDef } from './provider.ts';
import { commandArgv } from './terminal.ts';
import { field } from './web.ts';

/** The same arithmetic as `/etc/chromium.d/schermes`, which is where Chromium learns it. */
export function debugPort(display: number): number {
  return 9222 + display;
}

const MAX_URL_CHARS = 2_000;
const MAX_EXPRESSION_CHARS = 8_000;
const LIST_TIMEOUT_MS = 2_000;
const COMMAND_TIMEOUT_MS = 30_000;
const LOAD_TIMEOUT_MS = 30_000;
const START_TIMEOUT_MS = 20_000;
const START_POLL_MS = 250;

const START_CHROMIUM = 'exec chromium --user-data-dir="$HOME/.chromium-profile" about:blank';

const READ_PAGE =
  '({ url: location.href, title: document.title, text: document.body ? document.body.innerText : "" })';

export type BrowserAction =
  | { action: 'navigate'; url: string }
  | { action: 'read' }
  | { action: 'evaluate'; expression: string };

export function parseBrowserAction(body: Record<string, unknown>): BrowserAction | { error: string } {
  switch (body['action']) {
    case 'read':
      return { action: 'read' };

    case 'navigate': {
      const raw = body['url'];
      if (typeof raw !== 'string' || raw.trim() === '') return { error: 'url must be a non-empty http(s) URL' };
      if (raw.length > MAX_URL_CHARS) return { error: `url must be at most ${MAX_URL_CHARS} characters` };
      let url: URL;
      try {
        url = new URL(raw.trim());
      } catch {
        return { error: `${raw.trim()} is not a URL` };
      }
      if (url.protocol !== 'http:' && url.protocol !== 'https:') {
        return { error: 'only http and https URLs can be opened' };
      }
      return { action: 'navigate', url: url.toString() };
    }

    case 'evaluate': {
      const expression = body['expression'];
      if (typeof expression !== 'string' || expression.trim() === '') {
        return { error: 'expression must be a non-empty string' };
      }
      if (expression.length > MAX_EXPRESSION_CHARS) {
        return { error: `expression must be at most ${MAX_EXPRESSION_CHARS} characters` };
      }
      return { action: 'evaluate', expression };
    }

    default:
      return { error: `unknown action ${JSON.stringify(body['action'])}` };
  }
}

export function browserToolDef(): ToolDef {
  return {
    name: 'browser',
    description:
      'Your own Chromium, the one on your desktop, driven through its debugging port; it is ' +
      'started if it is not running. navigate opens a URL in the current tab, waits for it to ' +
      'load and returns the rendered text; read returns the rendered text of the current tab; ' +
      'evaluate runs a JavaScript expression in the page and returns its value, which is how ' +
      'you get links, fill fields or click elements without pixels. Unlike web_fetch, scripts ' +
      'run and your logins apply. Take a screenshot with the computer tool when you need to see ' +
      'the page rather than read it.',
    parameters: {
      type: 'object',
      properties: {
        action: { type: 'string', enum: ['navigate', 'read', 'evaluate'] },
        url: { type: 'string', maxLength: MAX_URL_CHARS, description: 'for navigate' },
        expression: {
          type: 'string',
          maxLength: MAX_EXPRESSION_CHARS,
          description: 'for evaluate: a JavaScript expression, awaited if it is a promise',
        },
      },
      required: ['action'],
      additionalProperties: false,
    },
  };
}

/** One DevTools session on one page. */
export type Session = {
  send(method: string, params?: Record<string, unknown>): Promise<unknown>;
  /** Resolves with the next occurrence of the event. Register before the command that causes it. */
  once(event: string): Promise<unknown>;
  close(): void;
};

/** Reaches the page in the agent's Chromium, or undefined when nothing answers on the port. */
export type Connect = (port: number) => Promise<Session | undefined>;

// ponytail: the first page target wins. Chromium lists the most recently focused tab first in
// practice; add a tab argument if an agent starts juggling several.
export const cdpConnect: Connect = async (port) => {
  let targets: unknown;
  try {
    const response = await fetch(`http://127.0.0.1:${port}/json/list`, {
      signal: AbortSignal.timeout(LIST_TIMEOUT_MS),
    });
    targets = await response.json();
  } catch {
    return undefined;
  }
  const page = (Array.isArray(targets) ? targets : []).find(
    (target) => field(target, 'type') === 'page' && typeof field(target, 'webSocketDebuggerUrl') === 'string',
  );
  return page === undefined ? undefined : open(field(page, 'webSocketDebuggerUrl') as string);
};

type Pending = { resolve: (value: unknown) => void; reject: (error: Error) => void };

function open(url: string): Promise<Session> {
  return new Promise((resolve, reject) => {
    // No Origin header goes out, which is what lets Chromium accept this without
    // --remote-allow-origins; that flag would let a page in the browser reach the port too.
    const socket = new WebSocket(url);
    const pending = new Map<number, Pending>();
    const waiting = new Map<string, Array<(params: unknown) => void>>();
    let nextId = 0;

    socket.on('message', (raw) => {
      const message: unknown = JSON.parse(raw.toString());
      const id = field(message, 'id');
      if (typeof id === 'number') {
        const call = pending.get(id);
        pending.delete(id);
        const error = field(message, 'error');
        if (error !== undefined) call?.reject(new Error(String(field(error, 'message'))));
        else call?.resolve(field(message, 'result'));
        return;
      }
      const method = field(message, 'method');
      if (typeof method === 'string') {
        const listeners = waiting.get(method) ?? [];
        waiting.delete(method);
        for (const listener of listeners) listener(field(message, 'params'));
      }
    });
    socket.on('error', reject);
    socket.on('close', () => {
      for (const call of pending.values()) call.reject(new Error('the browser closed the connection'));
      pending.clear();
    });
    socket.on('open', () =>
      resolve({
        send: (method, params = {}) =>
          new Promise((res, rej) => {
            nextId += 1;
            pending.set(nextId, { resolve: res, reject: rej });
            socket.send(JSON.stringify({ id: nextId, method, params }));
          }),
        once: (event) =>
          new Promise((res) => {
            waiting.set(event, [...(waiting.get(event) ?? []), res]);
          }),
        close: () => socket.close(),
      }),
    );
  });
}

function timed<T>(promise: Promise<T>, ms: number, what: string): Promise<T> {
  return Promise.race([
    promise,
    sleep(ms, undefined, { ref: false }).then(() => {
      throw new Error(what);
    }),
  ]);
}

async function ensureSession(
  exec: Exec,
  target: AgentTarget,
  connect: Connect,
): Promise<Session | { error: string }> {
  const port = debugPort(target.display);
  const running = await connect(port);
  if (running !== undefined) return running;

  const argv = commandArgv({ command: START_CHROMIUM, timeoutMs: 0, background: true });
  const started = await exec('sudo', asAgent(target, argv));
  if (started.code !== 0) return { error: `chromium could not be started: ${started.stderr.trim()}` };

  const deadline = Date.now() + START_TIMEOUT_MS;
  while (Date.now() < deadline) {
    await sleep(START_POLL_MS);
    const session = await connect(port);
    if (session !== undefined) return session;
  }
  return {
    error:
      `chromium was started but nothing answers on port ${port}; check that DISPLAY=:${target.display} ` +
      'is up and that /etc/chromium.d/schermes sets --remote-debugging-port',
  };
}

function clip(text: string, limit: number): string {
  return text.length <= limit ? text : `${text.slice(0, limit)}\n[truncated]`;
}

async function readPage(session: Session, limit: number): Promise<string> {
  const result = await timed(
    session.send('Runtime.evaluate', { expression: READ_PAGE, returnByValue: true }),
    COMMAND_TIMEOUT_MS,
    'the page did not answer',
  );
  const page = field(field(result, 'result'), 'value');
  const title = String(field(page, 'title') ?? '');
  const url = String(field(page, 'url') ?? '');
  const text = String(field(page, 'text') ?? '').trim();
  const head = title === '' ? url : `${title}\n${url}`;
  return text === '' ? `${head}\n\nThe page has no readable text.` : `${head}\n\n${clip(text, limit)}`;
}

export type Browsed = { text: string; url: string } | { error: string };

export async function browse(
  exec: Exec,
  target: AgentTarget,
  connect: Connect,
  action: BrowserAction,
  limit: number,
): Promise<Browsed> {
  const session = await ensureSession(exec, target, connect);
  if ('error' in session) return session;
  try {
    switch (action.action) {
      case 'navigate': {
        await timed(session.send('Page.enable'), COMMAND_TIMEOUT_MS, 'the browser did not answer');
        const loaded = session.once('Page.loadEventFired');
        const navigated = await timed(
          session.send('Page.navigate', { url: action.url }),
          COMMAND_TIMEOUT_MS,
          'the browser did not answer',
        );
        const refused = field(navigated, 'errorText');
        if (typeof refused === 'string' && refused !== '') return { error: `${action.url}: ${refused}` };
        // A page that keeps a request open never fires load; what has rendered is still worth reading.
        await timed(loaded, LOAD_TIMEOUT_MS, 'load timed out').catch(() => undefined);
        return { text: await readPage(session, limit), url: action.url };
      }

      case 'read':
        return { text: await readPage(session, limit), url: '' };

      case 'evaluate': {
        const result = await timed(
          session.send('Runtime.evaluate', {
            expression: action.expression,
            returnByValue: true,
            awaitPromise: true,
            userGesture: true,
          }),
          COMMAND_TIMEOUT_MS,
          'the expression did not finish',
        );
        const thrown = field(result, 'exceptionDetails');
        if (thrown !== undefined) {
          const description = field(field(thrown, 'exception'), 'description') ?? field(thrown, 'text');
          return { error: clip(String(description), limit) };
        }
        const remote = field(result, 'result');
        const value = field(remote, 'value');
        const text =
          typeof value === 'string'
            ? value
            : (JSON.stringify(value) ?? String(field(remote, 'description') ?? field(remote, 'type')));
        return { text: clip(text, limit), url: '' };
      }
    }
  } catch (error) {
    return { error: (error as Error).message };
  } finally {
    session.close();
  }
}
