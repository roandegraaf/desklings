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
const PROBE_TIMEOUT_MS = 5_000;
const STOP_TIMEOUT_MS = 10_000;

const START_CHROMIUM = 'exec chromium --user-data-dir="$HOME/.chromium-profile" about:blank';
// pkill only signals: a start while the old instance still holds the profile hands the request
// to the dying one and exits, so the stop waits until none is left.
const STOP_CHROMIUM =
  'pkill -KILL -u "$(id -u)" -x chromium\n' +
  'for _ in $(seq 50); do pgrep -u "$(id -u)" -x chromium >/dev/null || exit 0; sleep 0.1; done\n' +
  'exit 1';

/** The start of the tool text when a restart did not bring the browser back. The app's chat card
 * and Needs you both find the hang by it. */
export const BROWSER_HUNG = 'your browser stopped answering';

export type BrowserTimings = { probeMs: number; startMs: number; pollMs: number };
const TIMINGS: BrowserTimings = { probeMs: PROBE_TIMEOUT_MS, startMs: START_TIMEOUT_MS, pollMs: START_POLL_MS };

const READ_PAGE =
  '({ url: location.href, title: document.title, text: document.body ? document.body.innerText : "" })';

export type BrowserAction =
  | { action: 'navigate'; url: string }
  | { action: 'read' }
  | { action: 'evaluate'; expression: string }
  | { action: 'dialog'; accept: boolean; promptText?: string };

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

    case 'dialog': {
      const accept = body['accept'];
      const promptText = body['promptText'];
      if (typeof accept !== 'boolean') return { error: 'accept must be true or false' };
      if (promptText !== undefined && typeof promptText !== 'string') return { error: 'promptText must be a string' };
      return { action: 'dialog', accept, ...(promptText === undefined ? {} : { promptText }) };
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
      'the page rather than read it. When the page opens an alert, confirm or prompt dialog you ' +
      'are told what it says, and dialog answers it: accept true or false. A dialog opened any ' +
      'other way, by a computer-tool click or a page timer, is not seen here: close it with the ' +
      'computer tool before you use the browser again.',
    parameters: {
      type: 'object',
      properties: {
        action: { type: 'string', enum: ['navigate', 'read', 'evaluate', 'dialog'] },
        accept: { type: 'boolean', description: 'for dialog: true accepts it, false dismisses it' },
        promptText: { type: 'string', maxLength: MAX_EXPRESSION_CHARS, description: 'for dialog: the answer to a prompt' },
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

/** Not a DevTools event: `once` resolves on it when the socket closes, as it does when Chromium dies. */
const SOCKET_CLOSED = 'socket closed';

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
      const listeners = waiting.get(SOCKET_CLOSED) ?? [];
      waiting.delete(SOCKET_CLOSED);
      for (const listener of listeners) listener(undefined);
    });
    socket.on('open', () =>
      resolve({
        send: (method, params = {}) =>
          new Promise((res, rej) => {
            if (socket.readyState !== WebSocket.OPEN) return rej(new Error('the browser closed the connection'));
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

/** A browser that took the command and never answered, as opposed to one that said no. */
class Hung extends Error {}

function timed<T>(promise: Promise<T>, ms: number, what: string, Failure: new (what: string) => Error = Error): Promise<T> {
  return Promise.race([
    promise,
    sleep(ms, undefined, { ref: false }).then(() => {
      throw new Failure(what);
    }),
  ]);
}

/** A session that answers `1`, `absent` when nothing listens, `hung` when something does but stalls. */
async function reach(connect: Connect, port: number, ms: number): Promise<Session | 'absent' | 'hung'> {
  const connecting = connect(port);
  let session: Session | undefined;
  try {
    session = await timed(connecting, ms, 'hung');
  } catch {
    connecting.then((late) => late?.close(), () => undefined);
    return 'hung';
  }
  if (session === undefined) return 'absent';
  try {
    await timed(session.send('Runtime.evaluate', { expression: '1', returnByValue: true }), ms, 'hung');
    return session;
  } catch {
    session.close();
    return 'hung';
  }
}

type Failed = { error: string; hung?: boolean };

/** The agent's browser, started if nothing answers; `fresh` kills whatever is there first. */
async function ensureSession(
  exec: Exec,
  target: AgentTarget,
  connect: Connect,
  timings: BrowserTimings,
  fresh: boolean,
): Promise<Session | Failed> {
  const port = debugPort(target.display);
  if (fresh) {
    const stopped = await stopBrowser(exec, target);
    if ('error' in stopped) return stopped;
  } else {
    const running = await reach(connect, port, timings.probeMs);
    if (running === 'hung') return { error: `chromium on port ${port} does not answer`, hung: true };
    if (running !== 'absent') return running;
  }

  const argv = commandArgv({ command: START_CHROMIUM, timeoutMs: 0, background: true });
  const started = await exec('sudo', asAgent(target, argv));
  if (started.code !== 0) return { error: `chromium could not be started: ${started.stderr.trim()}` };

  const deadline = Date.now() + timings.startMs;
  while (Date.now() < deadline) {
    await sleep(timings.pollMs);
    const session = await reach(connect, port, timings.probeMs);
    if (session !== 'absent' && session !== 'hung') return session;
  }
  return {
    error:
      `chromium was started but nothing answers on port ${port}; check that DISPLAY=:${target.display} ` +
      'is up and that /etc/chromium.d/schermes sets --remote-debugging-port',
    hung: true,
  };
}

/**
 * A dialog the page opened during an action, with the session that saw it. Only that session can
 * answer it: a new one neither sees it nor gets past it, and its probe stalls like a hung browser.
 */
// ponytail: in memory per port; after a daemon restart an open dialog reads as hung again.
const openDialogs = new Map<number, { session: Session; text: string }>();

function dialogText(params: unknown): string {
  const type = String(field(params, 'type') ?? 'alert');
  return (
    `the page opened a ${type} dialog: ${JSON.stringify(String(field(params, 'message') ?? ''))}. ` +
    `Nothing on the page answers until it is closed: use the dialog action, accept true or false` +
    (type === 'prompt' ? ', with promptText for the answer' : '')
  );
}

/** Kills the agent's Chromium, as the agent, and waits until it is gone. The next browse starts it. */
export async function stopBrowser(exec: Exec, target: AgentTarget): Promise<{ ok: true } | { error: string }> {
  const port = debugPort(target.display);
  openDialogs.get(port)?.session.close();
  openDialogs.delete(port);
  const argv = commandArgv({ command: STOP_CHROMIUM, timeoutMs: STOP_TIMEOUT_MS, background: false });
  const stopped = await exec('sudo', asAgent(target, argv), { timeoutMs: STOP_TIMEOUT_MS + 5_000 });
  return stopped.code === 0 ? { ok: true } : { error: `chromium could not be stopped: ${stopped.stderr.trim()}` };
}

function clip(text: string, limit: number): string {
  return text.length <= limit ? text : `${text.slice(0, limit)}\n[truncated]`;
}

async function readPage(session: Session, limit: number): Promise<string> {
  const result = await timed(
    session.send('Runtime.evaluate', { expression: READ_PAGE, returnByValue: true }),
    COMMAND_TIMEOUT_MS,
    'the page did not answer',
    Hung,
  );
  const page = field(field(result, 'result'), 'value');
  const title = String(field(page, 'title') ?? '');
  const url = String(field(page, 'url') ?? '');
  const text = String(field(page, 'text') ?? '').trim();
  const head = title === '' ? url : `${title}\n${url}`;
  return text === '' ? `${head}\n\nThe page has no readable text.` : `${head}\n\n${clip(text, limit)}`;
}

export type Browsed = { text: string; url: string; restarted?: boolean } | { error: string; hung?: boolean; restarted?: boolean };

/**
 * One browser action, with a watchdog: a browser that stalls before the action, or on a
 * navigate or read, is killed and started again once and the action done again. An evaluate
 * that times out is not redone, since it may already have clicked. A second stall is `hung`.
 */
export async function browse(
  exec: Exec,
  target: AgentTarget,
  connect: Connect,
  action: BrowserAction,
  limit: number,
  timings: BrowserTimings = TIMINGS,
): Promise<Browsed> {
  const first = await attempt(exec, target, connect, action, limit, timings, false);
  if (!('error' in first) || first.hung !== true) return first;
  const second = await attempt(exec, target, connect, action, limit, timings, true);
  if ('error' in second && second.hung === true) {
    return { error: `${BROWSER_HUNG} and a restart did not bring it back: ${second.error}`, hung: true, restarted: true };
  }
  return { ...second, restarted: true };
}

async function attempt(
  exec: Exec,
  target: AgentTarget,
  connect: Connect,
  action: BrowserAction,
  limit: number,
  timings: BrowserTimings,
  fresh: boolean,
): Promise<Browsed> {
  const port = debugPort(target.display);
  if (action.action === 'dialog') return answerDialog(port, action);
  const open = openDialogs.get(port);
  if (open !== undefined) return { error: open.text };
  const session = await ensureSession(exec, target, connect, timings, fresh);
  if ('error' in session) return session;
  let parked = false;
  const act = async (): Promise<Browsed> => {
    switch (action.action) {
      case 'navigate': {
        const loaded = session.once('Page.loadEventFired');
        const navigated = await timed(
          session.send('Page.navigate', { url: action.url }),
          COMMAND_TIMEOUT_MS,
          'the browser did not answer',
          Hung,
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
  };
  try {
    await timed(session.send('Page.enable'), COMMAND_TIMEOUT_MS, 'the browser did not answer', Hung);
    const opened = session.once('Page.javascriptDialogOpening').then((params): Browsed => {
      parked = true;
      const text = dialogText(params);
      openDialogs.set(port, { session, text });
      void Promise.race([session.once('Page.javascriptDialogClosed'), session.once(SOCKET_CLOSED)]).then(() => {
        if (openDialogs.get(port)?.session !== session) return;
        openDialogs.delete(port);
        session.close();
      });
      return { error: text };
    });
    return await Promise.race([act(), opened]);
  } catch (error) {
    return { error: (error as Error).message, ...(error instanceof Hung ? { hung: true } : {}) };
  } finally {
    if (!parked) session.close();
  }
}

async function answerDialog(port: number, action: { accept: boolean; promptText?: string }): Promise<Browsed> {
  const open = openDialogs.get(port);
  if (open === undefined) return { error: 'no dialog is waiting; take a screenshot if one is on the screen' };
  openDialogs.delete(port);
  try {
    await timed(
      open.session.send('Page.handleJavaScriptDialog', { accept: action.accept, ...(action.promptText === undefined ? {} : { promptText: action.promptText }) }),
      COMMAND_TIMEOUT_MS,
      'the browser did not answer',
    );
    return { text: action.accept ? 'Accepted the dialog.' : 'Dismissed the dialog.', url: '' };
  } catch (error) {
    return { error: (error as Error).message };
  } finally {
    open.session.close();
  }
}

/**
 * Reads the form the page is showing: the focused control's form, else the first with a control
 * the owner can fill, else the whole page. Tags each control with `data-schermes-field` so the
 * fill finds it again. It reads labels, types and options, never a control's current value:
 * a prefilled or autofilled password would otherwise land in the tool text.
 */
const FORM_SCRIPT = String.raw`((token) => {
  const shown = (el) => {
    const box = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    return box.width > 0 && box.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
  };
  const skipped = ['hidden', 'submit', 'button', 'reset', 'image'];
  const kind = (el) => el.tagName === 'SELECT' ? 'select' : el.tagName === 'TEXTAREA' ? 'textarea' : (el.getAttribute('type') || 'text').toLowerCase();
  const usable = (el) => !skipped.includes(kind(el)) && !el.disabled && !el.readOnly && shown(el);
  const controls = 'input, select, textarea';
  const active = document.activeElement;
  const focused = active && active.closest ? active.closest('form') : null;
  const scope = focused || [...document.forms].find((form) => [...form.querySelectorAll(controls)].some(usable)) || document.body;
  const clean = (text) => (text || '').replace(/\s+/g, ' ').trim().slice(0, 200);
  const labelOf = (el) => clean(el.getAttribute('aria-label') || (el.labels && el.labels[0] ? el.labels[0].innerText : '') || el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('name') || el.id);
  const fields = [];
  const unfillable = [];
  const groups = new Map();
  for (const el of scope.querySelectorAll(controls)) {
    if (!usable(el) || fields.length >= 50) continue;
    const type = kind(el);
    if (type === 'file') { unfillable.push({ label: labelOf(el) || 'A file upload', reason: 'file' }); continue; }
    const name = el.getAttribute('name') || '';
    if (type === 'radio' && name !== '' && groups.has(name)) {
      const group = groups.get(name);
      el.setAttribute('data-schermes-field', group.id);
      group.options.push({ value: el.getAttribute('value') || 'on', label: labelOf(el) });
      continue;
    }
    const id = token + '-' + fields.length;
    el.setAttribute('data-schermes-field', id);
    const field = { id, label: labelOf(el), type, name, autocomplete: clean(el.getAttribute('autocomplete')).toLowerCase(), required: el.required === true };
    if (type === 'select') field.options = [...el.options].map((option) => ({ value: option.value, label: clean(option.text) }));
    if (type === 'radio') {
      const legend = el.closest('fieldset') ? el.closest('fieldset').querySelector('legend') : null;
      field.label = clean(legend ? legend.innerText : '') || name || labelOf(el);
      field.options = [{ value: el.getAttribute('value') || 'on', label: labelOf(el) }];
      if (name !== '') groups.set(name, field);
    }
    fields.push(field);
  }
  const captcha = '.g-recaptcha, .h-captcha, .cf-turnstile, iframe[src*="captcha"], iframe[src*="turnstile"]';
  if ([...document.querySelectorAll(captcha)].some(shown)) unfillable.push({ label: 'CAPTCHA', reason: 'captcha' });
  for (const frame of scope.querySelectorAll('iframe')) {
    if (!shown(frame) || frame.matches(captcha)) continue;
    if (frame.contentDocument === null) unfillable.push({ label: clean(frame.title || frame.name) || 'An embedded frame', reason: 'cross_origin_frame' });
  }
  const widgets = '[contenteditable=""], [contenteditable="true"], [role="textbox"], [role="combobox"], [role="listbox"], [role="checkbox"], [role="radio"], [role="switch"], [role="spinbutton"], [role="slider"]';
  for (const el of scope.querySelectorAll(widgets)) {
    if (el.matches(controls) || el.querySelector(controls) || !shown(el)) continue;
    unfillable.push({ label: labelOf(el) || 'A custom control', reason: 'unknown_widget' });
  }
  return { fields, unfillable };
})`;

const tagged = (id: string) => `document.querySelectorAll('[data-schermes-field=${JSON.stringify(id)}]')`;

/** Focuses the control and answers whether it really has focus, so a typed value can only land there. */
const focusScript = (id: string) =>
  `(() => { const el = ${tagged(id)}[0]; if (!el) return false; el.focus(); try { el.select(); } catch (error) {} return document.activeElement === el; })()`;

/** Controls that take a choice rather than typing. Their values are options, not secrets. */
const chooseScript = (id: string, value: string) =>
  `(() => { const els = [...${tagged(id)}]; const value = ${JSON.stringify(value)}; const el = els[0]; if (!el) return false;
  if (el.type === 'radio') { const pick = els.find((radio) => (radio.getAttribute('value') || 'on') === value); if (!pick) return false; pick.click(); return true; }
  if (el.type === 'checkbox') { if (el.checked !== (value === 'true')) el.click(); return true; }
  el.value = value; el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true })); return true; })()`;

export const CHOICE_TYPES: ReadonlySet<string> = new Set(['select', 'radio', 'checkbox']);

export type PageForm = { origin: string; fields: unknown; unfillable: unknown };

/** The top frame's origin as Chromium reports it: the page's claim about itself, not the model's. */
async function pageOrigin(session: Session): Promise<string> {
  const tree = await timed(session.send('Page.getFrameTree'), COMMAND_TIMEOUT_MS, 'the browser did not answer');
  const frame = field(field(tree, 'frameTree'), 'frame');
  const origin = field(frame, 'securityOrigin');
  if (typeof origin === 'string' && origin !== '' && origin !== 'null') return origin;
  return new URL(String(field(frame, 'url'))).origin;
}

async function reachRunning(connect: Connect, display: number, timings: BrowserTimings): Promise<Session | { error: string }> {
  const session = await reach(connect, debugPort(display), timings.probeMs);
  if (session === 'absent') return { error: 'your browser is not running; open the page with the browser tool first' };
  if (session === 'hung') return { error: 'your browser does not answer' };
  return session;
}

async function evaluate(session: Session, expression: string): Promise<unknown> {
  const result = await timed(
    session.send('Runtime.evaluate', { expression, returnByValue: true }),
    COMMAND_TIMEOUT_MS,
    'the page did not answer',
  );
  const thrown = field(result, 'exceptionDetails');
  if (thrown !== undefined) throw new Error(String(field(field(thrown, 'exception'), 'description') ?? field(thrown, 'text')));
  return field(field(result, 'result'), 'value');
}

/** The raw fields of the form on the agent's page, tagged with `token`. Never starts a browser. */
export async function readForm(
  connect: Connect,
  display: number,
  token: string,
  timings: BrowserTimings = TIMINGS,
): Promise<PageForm | { error: string }> {
  const session = await reachRunning(connect, display, timings);
  if ('error' in session) return session;
  try {
    const page = await evaluate(session, `${FORM_SCRIPT}(${JSON.stringify(token)})`);
    return { origin: await pageOrigin(session), fields: field(page, 'fields'), unfillable: field(page, 'unfillable') };
  } catch (error) {
    return { error: (error as Error).message };
  } finally {
    session.close();
  }
}

export type FillStep = { id: string; label: string; type: string; value: string };

/**
 * Types the owner's values into the tagged controls with `Input.insertText`, which puts text
 * wherever focus is: each field is focused first and checked to have it, and the page must still
 * be on `origin`. Nothing is typed once either check fails.
 */
export async function fillForm(
  connect: Connect,
  display: number,
  origin: string,
  steps: readonly FillStep[],
  timings: BrowserTimings = TIMINGS,
): Promise<{ ok: true } | { error: string }> {
  const session = await reachRunning(connect, display, timings);
  if ('error' in session) return session;
  try {
    const now = await pageOrigin(session);
    if (now !== origin) return { error: `the page is on ${now} now, not ${origin}` };
    const missing = await evaluate(
      session,
      `${JSON.stringify(steps.map((step) => step.id))}.filter((id) => document.querySelector('[data-schermes-field="' + id + '"]') === null)`,
    );
    if (Array.isArray(missing) && missing.length > 0) {
      const labels = steps.filter((step) => missing.includes(step.id)).map((step) => step.label);
      return { error: `the page changed and no longer has ${labels.join(', ')}` };
    }
    for (const step of steps) {
      if (CHOICE_TYPES.has(step.type)) {
        if ((await evaluate(session, chooseScript(step.id, step.value))) !== true) {
          return { error: `could not choose ${step.label}` };
        }
        continue;
      }
      if ((await evaluate(session, focusScript(step.id))) !== true) return { error: `could not put the cursor in ${step.label}` };
      await timed(session.send('Input.insertText', { text: step.value }), COMMAND_TIMEOUT_MS, 'the browser did not answer');
    }
    return { ok: true };
  } catch (error) {
    return { error: (error as Error).message };
  } finally {
    session.close();
  }
}

/** The control the owner is typing into, through shadow roots and same-origin frames. `null` when
 * the page does not have the keyboard; `frame` when focus sits in a frame this cannot look into. */
const FOCUSED_SCRIPT = `(() => {
  if (!document.hasFocus()) return null;
  let el = document.activeElement;
  while (el) {
    if (el.shadowRoot && el.shadowRoot.activeElement) { el = el.shadowRoot.activeElement; continue; }
    if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') {
      try { const inner = el.contentDocument; if (!inner) return { frame: true }; el = inner.activeElement; continue; } catch (error) { return { frame: true }; }
    }
    break;
  }
  if (!el) return null;
  return { type: String(el.type || ''), autocomplete: String((el.getAttribute && el.getAttribute('autocomplete')) || '') };
})()`;

export type Focused = { type: string; autocomplete: string } | { frame: true } | 'elsewhere' | { error: string };

/**
 * What has the keyboard in the agent's browser. `elsewhere` when no browser answers or its page
 * is not focused, so typing went to another window.
 *
 * ponytail: `cdpConnect` looks at the first page target only; typing into a second tab reads as
 * `elsewhere`. Pick the focused target from `/json/list` if agents start using several tabs.
 */
export async function focusedField(connect: Connect, display: number, ms = PROBE_TIMEOUT_MS): Promise<Focused> {
  const session = await reach(connect, debugPort(display), ms);
  if (session === 'absent') return 'elsewhere';
  if (session === 'hung') return { error: 'the browser does not answer' };
  try {
    const result = await timed(
      session.send('Runtime.evaluate', { expression: FOCUSED_SCRIPT, returnByValue: true }),
      ms,
      'the page did not answer',
    );
    const value = field(field(result, 'result'), 'value');
    if (value === null || value === undefined) return 'elsewhere';
    if (field(value, 'frame') === true) return { frame: true };
    return { type: String(field(value, 'type') ?? ''), autocomplete: String(field(value, 'autocomplete') ?? '') };
  } catch (error) {
    return { error: (error as Error).message };
  } finally {
    session.close();
  }
}
