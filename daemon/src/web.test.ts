import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  MAX_PAGE_BYTES,
  fetchPage,
  parseBraveResults,
  parseWebFetch,
  parseWebSearch,
  refuseAddress,
  searchPrompt,
  toText,
  webSearch,
} from './web.ts';
import type { Resolve } from './web.ts';

const KEY = 'brave-secret-key';
const CONFIG = { url: 'https://api.search.brave.com/res/v1/web/search', apiKey: KEY };

type Sent = { url: string; headers: Record<string, string> };

/** Every request the code under test made, and the answers it was given. */
async function withFetch<T>(
  reply: Response | (() => Response),
  run: () => Promise<T>,
): Promise<{ result: T; sent: Sent[] }> {
  const original = globalThis.fetch;
  const sent: Sent[] = [];
  globalThis.fetch = (input, init) => {
    sent.push({
      url: String(input),
      headers: Object.fromEntries(new Headers(init?.headers).entries()),
    });
    return Promise.resolve(typeof reply === 'function' ? reply() : reply);
  };
  try {
    return { result: await run(), sent };
  } finally {
    globalThis.fetch = original;
  }
}

const json = (payload: unknown, status = 200) =>
  new Response(JSON.stringify(payload), {
    status,
    headers: { 'content-type': 'application/json' },
  });

const html = (body: string, type = 'text/html; charset=utf-8') =>
  new Response(body, { status: 200, headers: { 'content-type': type } });

const nowhere: Resolve = () => Promise.reject(new Error('the test resolver was not stubbed'));
const public4: Resolve = () => Promise.resolve([{ address: '93.184.216.34' }]);

const BRAVE = {
  web: {
    results: [
      {
        title: 'Cron expression <strong>format</strong>',
        url: 'https://example.com/cron',
        description: 'Five fields, or <strong>six</strong> with seconds.',
      },
      { title: 'Second hit', url: 'https://example.org/second', description: '' },
      { title: 'No url', description: 'dropped' },
    ],
  },
};

test('a search result list becomes titled results with their urls', async () => {
  const { result, sent } = await withFetch(json(BRAVE), () => webSearch(CONFIG, 'cron format'));
  assert.ok(!('error' in result));
  assert.deepEqual(result.results, [
    {
      title: 'Cron expression format',
      url: 'https://example.com/cron',
      description: 'Five fields, or six with seconds.',
    },
    { title: 'Second hit', url: 'https://example.org/second', description: '' },
  ]);

  const text = searchPrompt('cron format', result.results);
  assert.match(text, /1\. Cron expression format — https:\/\/example\.com\/cron/);
  assert.match(text, /Five fields, or six with seconds\./);
  assert.match(text, /2\. Second hit — https:\/\/example\.org\/second/);

  // The key travels as a header, never in the query string a proxy or an access log would keep.
  assert.equal(sent[0]?.headers['x-subscription-token'], KEY);
  assert.ok(!sent[0]?.url.includes(KEY), 'the key is not in the request url');
  assert.match(sent[0]?.url ?? '', /[?&]q=cron\+format/);
});

test('an endpoint that echoes the request back does not hand the key on', async () => {
  const echoed = new Response(`rejected: x-subscription-token: ${KEY}`, { status: 401 });
  const { result } = await withFetch(echoed, () => webSearch(CONFIG, 'anything'));
  assert.ok('error' in result);
  assert.match(result.error, /HTTP 401/);
  assert.ok(!result.error.includes(KEY), 'the key survived into the observation');
  assert.match(result.error, /\[redacted\]/);
});

test('a search endpoint that is not JSON is an error, not a crash', async () => {
  const { result } = await withFetch(html('<h1>nope</h1>'), () => webSearch(CONFIG, 'x'));
  assert.ok('error' in result);
});

test('a payload with no results at all reads as nothing found', () => {
  assert.deepEqual(parseBraveResults({ web: {} }), []);
  assert.deepEqual(parseBraveResults('not json at all'), []);
  assert.match(searchPrompt('nothing', []), /Nothing came back/);
});

test('a fetched page comes back as text, not markup', async () => {
  const page = html(
    '<html><head><title>t</title><style>a{color:red}</style></head><body>' +
      '<nav>Home About</nav><h1>Scheduled tasks</h1>' +
      '<p>A job fires in the <a href="https://example.com/deep">owner thread</a>.</p>' +
      '<script>alert(1)</script><footer>copyright</footer></body></html>',
  );
  const { result } = await withFetch(page, () =>
    fetchPage('https://example.com/doc', 10_000, public4),
  );
  assert.ok(!('error' in result));
  assert.match(result.text, /Scheduled tasks/);
  assert.match(result.text, /A job fires in the owner thread\./);
  for (const noise of ['<p>', 'color:red', 'alert(1)', 'href', 'Home About', 'copyright']) {
    assert.ok(!result.text.includes(noise), `${noise} reached the agent`);
  }
  assert.equal(result.status, 200);
});

test('an oversized page is clipped to the limit it was given', async () => {
  const long = html(`<html><body><p>${'word '.repeat(5_000)}</p></body></html>`);
  const { result } = await withFetch(long, () => fetchPage('https://example.com/', 500, public4));
  assert.ok(!('error' in result));
  assert.ok(result.text.length < 600, `got ${result.text.length} characters`);
  assert.match(result.text, /\[page truncated\]$/);
});

test('a page larger than the byte cap is not read past it', async () => {
  const chunk = new TextEncoder().encode('x'.repeat(500_000));
  let served = 0;
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      served += 1;
      controller.enqueue(chunk);
      if (served > 40) controller.close();
    },
  });
  const huge = new Response(body, { status: 200, headers: { 'content-type': 'text/plain' } });
  const { result } = await withFetch(huge, () =>
    fetchPage('https://example.com/', 1_000_000, public4),
  );
  assert.ok(!('error' in result));
  assert.ok(served * chunk.length <= MAX_PAGE_BYTES + chunk.length, `read ${served} chunks`);
});

test('a redirect is reported rather than followed', async () => {
  const moved = new Response('', { status: 302, headers: { location: '/somewhere-else' } });
  const { result, sent } = await withFetch(moved, () =>
    fetchPage('https://example.com/old', 10_000, public4),
  );
  assert.ok('error' in result);
  assert.match(result.error, /redirects to https:\/\/example\.com\/somewhere-else/);
  assert.equal(sent.length, 1, 'the hop was not followed');
});

test('a page that is not text is refused rather than converted', async () => {
  const image = new Response('\x89PNG', { status: 200, headers: { 'content-type': 'image/png' } });
  const { result } = await withFetch(image, () => fetchPage('https://example.com/a.png', 10_000, public4));
  assert.ok('error' in result);
  assert.match(result.error, /image\/png/);
});

test('every blocked range is refused and ordinary addresses are not', () => {
  const blocked = [
    '127.0.0.1',
    '0.0.0.0',
    '10.1.2.3',
    '169.254.169.254',
    '172.16.5.5',
    '192.168.1.1',
    '100.64.0.1',
    '198.18.0.1',
    '255.255.255.255',
    '::1',
    'fe80::1',
    'fd00::1',
    // Written as an IPv6 literal, which is the way this table gets walked past.
    '::ffff:169.254.169.254',
    '::ffff:7f00:1',
  ];
  for (const address of blocked) {
    assert.ok(refuseAddress(address) !== undefined, `${address} was allowed`);
  }
  for (const address of ['93.184.216.34', '1.1.1.1', '8.8.8.8', '2606:4700::1111']) {
    assert.equal(refuseAddress(address), undefined, `${address} was refused`);
  }
});

test('a refused url never reaches a request', async () => {
  const refused = [
    'http://127.0.0.1:7777/api/agents',
    'http://169.254.169.254/latest/meta-data/',
    'http://localhost:7777/',
    'http://anything.localhost/',
    'http://[::1]:7777/',
    'http://[::ffff:127.0.0.1]/',
    'file:///etc/passwd',
    'ftp://example.com/x',
  ];
  for (const url of refused) {
    const parsed = parseWebFetch({ url });
    assert.ok('error' in parsed, `${url} passed the parse`);
    const { sent } = await withFetch(html('<p>should never be served</p>'), async () => {
      // Even handed straight to the fetcher, past the parse, it makes no request.
      const result = await fetchPage(url.startsWith('http') ? url : 'http://127.0.0.1/', 100, nowhere);
      assert.ok('error' in result);
    });
    assert.equal(sent.length, 0, `${url} was requested anyway`);
  }
});

test('a public name that resolves onto a blocked range is refused after the lookup', async () => {
  const rebound: Resolve = () => Promise.resolve([{ address: '93.184.216.34' }, { address: '127.0.0.1' }]);
  const { result, sent } = await withFetch(html('<p>secret</p>'), () =>
    fetchPage('https://harmless.example/', 10_000, rebound),
  );
  assert.ok('error' in result);
  assert.match(result.error, /resolves to 127\.0\.0\.1/);
  assert.equal(sent.length, 0, 'the request went out anyway');
});

test('a name that does not resolve is an observation', async () => {
  const missing: Resolve = () => Promise.reject(new Error('ENOTFOUND'));
  const { result } = await withFetch(html('<p>x</p>'), () =>
    fetchPage('https://nope.example/', 10_000, missing),
  );
  assert.ok('error' in result);
  assert.match(result.error, /does not resolve/);
});

test('arguments are validated before anything else happens', () => {
  assert.ok('error' in parseWebSearch({}));
  assert.ok('error' in parseWebSearch({ query: '   ' }));
  assert.ok('error' in parseWebSearch({ query: 'x'.repeat(401) }));
  assert.deepEqual(parseWebSearch({ query: '  cron  ' }), { query: 'cron' });

  assert.ok('error' in parseWebFetch({}));
  assert.ok('error' in parseWebFetch({ url: 'not a url' }));
  assert.deepEqual(parseWebFetch({ url: ' https://example.com/a ' }), {
    url: 'https://example.com/a',
  });
});

test('text extraction keeps the words and drops the furniture', () => {
  assert.equal(toText('<h2>Heading</h2><p>Body <em>here</em>.</p>'), 'Heading\n\nBody here.');
  assert.equal(toText('<p>a</p><script>var x = "<p>b</p>";</script>'), 'a');
});

test('a transport failure carrying the key does not hand it on either', async () => {
  const original = globalThis.fetch;
  globalThis.fetch = () => Promise.reject(new Error(`socket hang up for token ${KEY}`));
  try {
    const result = await webSearch(CONFIG, 'anything');
    assert.ok('error' in result);
    assert.match(result.error, /could not be reached/);
    assert.ok(!result.error.includes(KEY), 'the key survived a rejected request');
  } finally {
    globalThis.fetch = original;
  }
});
