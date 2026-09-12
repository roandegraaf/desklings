import { BlockList, isIP } from 'node:net';
import { lookup } from 'node:dns/promises';
import { convert } from 'html-to-text';
import { withoutKey } from './provider.ts';
import type { ToolDef } from './provider.ts';

/**
 * Brave, and only Brave. The key travels as a request header rather than in a JSON body, which
 * keeps it out of anything that logs a request; and `web.results[]` is already
 * `{title, url, description}`, which is the answer this tool has to give. The URL is a setting
 * so it can be pointed at a proxy or a mirror, not so a differently shaped API can be swapped
 * in: the parser below is Brave's response and nothing else.
 */
export const BRAVE_SEARCH_URL = 'https://api.search.brave.com/res/v1/web/search';

export const MAX_SEARCH_RESULTS = 8;
const MAX_QUERY_CHARS = 400;
const MAX_URL_CHARS = 2_000;

/** How much of a page is read off the socket, before any of it becomes text. The observation
 * cap is a character count applied after extraction; this one stops a stream nobody asked for
 * from being buffered at all. */
export const MAX_PAGE_BYTES = 2_000_000;

const REQUEST_TIMEOUT_MS = 20_000;
const ERROR_BODY_CHARS = 300;
const USER_AGENT = 'schermes/0.1 (+https://github.com/schermes)';

export type SearchConfig = { url: string; apiKey: string };

/**
 * Ranges a URL the model chose may not reach. The daemon is the one process here that can talk
 * to cloud metadata, to its own API and to whatever else shares this network, so a hostname is
 * checked against these before a request is made and again after it resolves.
 *
 * `BlockList` maps an IPv4-mapped IPv6 address onto the IPv4 rules by itself, so
 * `[::ffff:169.254.169.254]` is caught by the `169.254.0.0/16` line and needs no entry of its
 * own — adding `::ffff:0:0/96` here would block every IPv4 address on the internet instead.
 */
const BLOCKED = new BlockList();
for (const [network, prefix] of [
  ['0.0.0.0', 8],
  ['10.0.0.0', 8],
  ['100.64.0.0', 10],
  ['127.0.0.0', 8],
  ['169.254.0.0', 16],
  ['172.16.0.0', 12],
  ['192.0.0.0', 24],
  ['192.168.0.0', 16],
  ['198.18.0.0', 15],
  ['224.0.0.0', 4],
  ['240.0.0.0', 4],
] as const) {
  BLOCKED.addSubnet(network, prefix, 'ipv4');
}
for (const [network, prefix] of [
  ['::', 128],
  ['::1', 128],
  ['fc00::', 7],
  ['fe80::', 10],
  ['ff00::', 8],
] as const) {
  BLOCKED.addSubnet(network, prefix, 'ipv6');
}

/** `URL.hostname` keeps the brackets an IPv6 literal is written with, and `isIP` rejects them. */
function bare(hostname: string): string {
  return hostname.startsWith('[') ? hostname.slice(1, -1) : hostname;
}

/** Why this address may not be reached, or undefined. Exported because it is the whole decision
 * the guard makes, and the one thing in this file worth testing range by range. */
export function refuseAddress(address: string): string | undefined {
  const family = isIP(address);
  if (family === 0) return undefined;
  return BLOCKED.check(address, family === 4 ? 'ipv4' : 'ipv6')
    ? `${address} is a loopback, link-local or private address and will not be fetched`
    : undefined;
}

/** The half of the guard that needs no network: the scheme, an address written out in the URL,
 * and the one name everybody reaches loopback with. */
function refuseUrl(url: URL): string | undefined {
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    return 'only http and https URLs can be fetched';
  }
  const host = bare(url.hostname);
  if (host === 'localhost' || host.endsWith('.localhost')) {
    return 'localhost will not be fetched';
  }
  return refuseAddress(host);
}

/** How a hostname becomes addresses. A parameter so a test can hand back a loopback answer for
 * a public name, which is the attack this guard exists for and cannot be staged offline. */
export type Resolve = (host: string) => Promise<{ address: string }[]>;

const systemResolve: Resolve = (host) => lookup(host, { all: true });

/**
 * The other half: what the name actually resolves to. A public name pointed at `127.0.0.1` is
 * the ordinary way this guard is walked past, so every address the resolver returns is checked,
 * not just the first.
 *
 * ponytail: `fetch` resolves the name a second time, so an answer that changes between these
 * two lookups is not caught. Closing it means connecting to the address checked here and
 * carrying the name in a Host header, which needs a dispatcher `fetch` does not expose.
 */
async function refuseResolved(url: URL, resolve: Resolve): Promise<string | undefined> {
  const host = bare(url.hostname);
  if (isIP(host) !== 0) return undefined;
  let found: { address: string }[];
  try {
    found = await resolve(host);
  } catch {
    return `${host} does not resolve`;
  }
  for (const entry of found) {
    if (refuseAddress(entry.address) !== undefined) {
      return `${host} resolves to ${entry.address}, which is a loopback, link-local or private address`;
    }
  }
  return undefined;
}

export function parseWebFetch(body: Record<string, unknown>): { url: string } | { error: string } {
  const raw = body['url'];
  if (typeof raw !== 'string' || raw.trim() === '') {
    return { error: 'url must be a non-empty http(s) URL' };
  }
  if (raw.length > MAX_URL_CHARS) {
    return { error: `url must be at most ${MAX_URL_CHARS} characters` };
  }
  let url: URL;
  try {
    url = new URL(raw.trim());
  } catch {
    return { error: `${raw.trim()} is not a URL` };
  }
  const refusal = refuseUrl(url);
  return refusal === undefined ? { url: url.toString() } : { error: refusal };
}

export function parseWebSearch(body: Record<string, unknown>): { query: string } | { error: string } {
  const query = body['query'];
  if (typeof query !== 'string' || query.trim() === '') {
    return { error: 'query must be a non-empty string' };
  }
  if (query.length > MAX_QUERY_CHARS) {
    return { error: `query must be at most ${MAX_QUERY_CHARS} characters` };
  }
  return { query: query.trim() };
}

export type SearchResult = { title: string; url: string; description: string };

export function field(value: unknown, name: string): unknown {
  return value !== null && typeof value === 'object'
    ? (value as Record<string, unknown>)[name]
    : undefined;
}

function text(value: unknown): string {
  // Brave marks query terms in descriptions with <strong>; the model wants the words.
  return typeof value === 'string' ? value.replace(/<[^>]*>/g, '').trim() : '';
}

export function parseBraveResults(payload: unknown): SearchResult[] {
  const results = field(field(payload, 'web'), 'results');
  if (!Array.isArray(results)) return [];
  return results.flatMap((entry): SearchResult[] => {
    const url = field(entry, 'url');
    if (typeof url !== 'string' || url === '') return [];
    return [{ title: text(field(entry, 'title')) || url, url, description: text(field(entry, 'description')) }];
  });
}

export function searchPrompt(query: string, results: readonly SearchResult[]): string {
  if (results.length === 0) return `Nothing came back for ${JSON.stringify(query)}.`;
  return [
    `Results for ${JSON.stringify(query)}:`,
    ...results.map((result, index) =>
      result.description === ''
        ? `${index + 1}. ${result.title} — ${result.url}`
        : `${index + 1}. ${result.title} — ${result.url}\n   ${result.description}`,
    ),
    'Use web_fetch on one of these URLs to read the page itself.',
  ].join('\n');
}

/** What an agent is told when nobody has configured a key. The normal state of a fresh install,
 * so it is an observation it can work around rather than a failure. */
export const NO_SEARCH_KEY =
  'no web search key is configured, so web_search cannot run. Only the owner can set one. ' +
  'Until then, fetch a URL you already know with web_fetch, or use run_command with curl.';

export async function webSearch(
  config: SearchConfig,
  query: string,
): Promise<{ results: SearchResult[] } | { error: string }> {
  const url = new URL(config.url);
  url.searchParams.set('q', query);
  url.searchParams.set('count', String(MAX_SEARCH_RESULTS));
  let response: Response;
  try {
    response = await fetch(url, {
      headers: {
        accept: 'application/json',
        'x-subscription-token': config.apiKey,
        'user-agent': USER_AGENT,
      },
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
  } catch (error) {
    // Stripped here too: a transport failure's message can carry the request back with it.
    const why = withoutKey((error as Error).message, config.apiKey);
    return { error: `the search endpoint could not be reached: ${why}` };
  }
  if (!response.ok) {
    // An endpoint or a proxy in front of it may echo the request back, headers and all, and
    // that body reaches an event and the log. Stripped here for the same reason `provider.ts`
    // strips it there.
    const detail = withoutKey(await response.text(), config.apiKey).slice(0, ERROR_BODY_CHARS);
    return { error: `the search endpoint returned HTTP ${response.status}: ${detail}` };
  }
  try {
    return { results: parseBraveResults(await response.json()) };
  } catch {
    return { error: 'the search endpoint did not answer with JSON' };
  }
}

/** The page as text. Links keep their words and lose their hrefs, and the furniture around the
 * content is dropped: a model reading a page wants the prose, not the navigation twice. */
export function toText(html: string): string {
  return convert(html, {
    wordwrap: false,
    selectors: [
      { selector: 'a', options: { ignoreHref: true } },
      { selector: 'img', format: 'skip' },
      { selector: 'nav', format: 'skip' },
      { selector: 'footer', format: 'skip' },
      { selector: 'h1', options: { uppercase: false } },
      { selector: 'h2', options: { uppercase: false } },
    ],
  }).trim();
}

async function readCapped(body: ReadableStream<Uint8Array>, bytes: number): Promise<string> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let out = '';
  let read = 0;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    read += value.length;
    out += decoder.decode(value, { stream: true });
    if (read >= bytes) {
      await reader.cancel();
      break;
    }
  }
  return out;
}

export type Page = { url: string; status: number; text: string };

/**
 * One page as readable text, clipped to `limit` characters by the caller's observation budget.
 *
 * Redirects are **not followed**. A 3xx comes back as the target URL in an error the agent can
 * read, so its next call is an ordinary `web_fetch` that re-enters the guard above with the new
 * host — which is both cheaper and safer than following a hop and re-resolving it here.
 */
export async function fetchPage(
  target: string,
  limit: number,
  resolve: Resolve = systemResolve,
): Promise<Page | { error: string }> {
  const url = new URL(target);
  const refusal = refuseUrl(url) ?? (await refuseResolved(url, resolve));
  if (refusal !== undefined) return { error: refusal };

  let response: Response;
  try {
    response = await fetch(url, {
      redirect: 'manual',
      headers: { accept: 'text/html,text/plain;q=0.9,*/*;q=0.5', 'user-agent': USER_AGENT },
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
  } catch (error) {
    return { error: `${url.host} could not be reached: ${(error as Error).message}` };
  }

  if (response.status >= 300 && response.status < 400) {
    const location = response.headers.get('location');
    if (location === null) return { error: `${url.host} answered HTTP ${response.status} with no location` };
    let moved: string;
    try {
      moved = new URL(location, url).toString();
    } catch {
      return { error: `${url.host} answered HTTP ${response.status} with an unreadable location` };
    }
    return {
      error:
        `${target} redirects to ${moved}. Redirects are not followed: call web_fetch again ` +
        'with that URL if you want it.',
    };
  }
  if (!response.ok) return { error: `${url.host} answered HTTP ${response.status}` };

  const type = response.headers.get('content-type') ?? '';
  const kind = type.split(';')[0]?.trim().toLowerCase() ?? '';
  if (kind !== '' && !kind.startsWith('text/') && !kind.includes('json') && !kind.includes('xml')) {
    return {
      error:
        `${target} is ${kind}, which web_fetch does not read. Use run_command with curl if you ` +
        'need the bytes.',
    };
  }

  const body = response.body === null ? '' : await readCapped(response.body, MAX_PAGE_BYTES);
  const extracted = kind.startsWith('text/html') || kind === '' ? toText(body) : body.trim();
  const clipped =
    extracted.length <= limit ? extracted : `${extracted.slice(0, limit)}\n[page truncated]`;
  return { url: target, status: response.status, text: clipped };
}

export function webSearchToolDef(): ToolDef {
  return {
    name: 'web_search',
    description:
      'Search the web and get back titled results with their URLs. Use it to find a page ' +
      'rather than guessing a URL, then read one with web_fetch. This is faster and cheaper ' +
      'than driving Chromium, so reach for it first.',
    parameters: {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          maxLength: MAX_QUERY_CHARS,
          description: 'what to search for, as you would type it into a search box',
        },
      },
      required: ['query'],
      additionalProperties: false,
    },
  };
}

export function webFetchToolDef(): ToolDef {
  return {
    name: 'web_fetch',
    description:
      'Read one web page as text, as the server sends it. Scripts do not run, so whatever the ' +
      'page fills in or filters in the browser is missing, and a URL parameter it handles in ' +
      'JavaScript has no effect here. Markup and navigation are stripped, and a long page is ' +
      'cut off at the end. Prefer this over opening the page in Chromium and taking a ' +
      'screenshot. Redirects are not followed: you are told where the page moved to and call ' +
      'this again. Private, loopback and link-local addresses are refused.',
    parameters: {
      type: 'object',
      properties: {
        url: {
          type: 'string',
          maxLength: MAX_URL_CHARS,
          description: 'the full http or https URL of the page',
        },
      },
      required: ['url'],
      additionalProperties: false,
    },
  };
}
