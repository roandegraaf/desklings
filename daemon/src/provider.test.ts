import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { LiveReply } from '@schermes/shared';
import { MAX_ATTEMPTS, ProviderError, openAiProvider, parseRetryAfter, withRetries } from './provider.ts';
import type { Provider } from './provider.ts';

function sse(lines: readonly string[]): Response {
  const encoder = new TextEncoder();
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      // Two chunks split mid-line, which is how a real socket delivers it.
      const whole = lines.map((line) => `${line}\n\n`).join('');
      const cut = Math.floor(whole.length / 2);
      controller.enqueue(encoder.encode(whole.slice(0, cut)));
      controller.enqueue(encoder.encode(whole.slice(cut)));
      controller.close();
    },
  });
  return new Response(body, { status: 200, headers: { 'content-type': 'text/event-stream' } });
}

const delta = (d: Record<string, unknown>) => `data: ${JSON.stringify({ choices: [{ delta: d }] })}`;

async function withFetch<T>(
  reply: Response | (() => Response),
  run: () => Promise<T>,
): Promise<{ result: T; sent: unknown; calls: number }> {
  const original = globalThis.fetch;
  let sent: unknown;
  let calls = 0;
  globalThis.fetch = (_url, init) => {
    calls += 1;
    sent = JSON.parse(String(init?.body));
    return Promise.resolve(typeof reply === 'function' ? reply() : reply);
  };
  try {
    return { result: await run(), sent, calls };
  } finally {
    globalThis.fetch = original;
  }
}

const plainOk = () =>
  new Response(JSON.stringify({ choices: [{ message: { content: 'ok', tool_calls: [] } }] }), {
    status: 200,
    headers: { 'content-type': 'application/json' },
  });

const provider = openAiProvider({ baseUrl: 'http://stub/v1/', model: 'm', apiKey: 'secret-key' });

const instant = () => Promise.resolve();
const retried = (inner: Provider) =>
  withRetries({ primary: { provider: inner, modelId: 1, name: 'Main' }, sleep: instant }).provider;

test('a streamed reply is assembled from deltas and heard while it arrives', async () => {
  const heard: LiveReply[] = [];
  const stream = sse([
    ': OPENROUTER PROCESSING',
    delta({ reasoning: 'Let me ' }),
    delta({ reasoning_content: 'look.' }),
    delta({ content: 'Sure' }),
    delta({ content: ', doing it.' }),
    delta({ tool_calls: [{ index: 0, id: 'call_a', function: { name: 'computer', arguments: '{"action":' } }] }),
    delta({ tool_calls: [{ index: 0, function: { arguments: '"screenshot"}' } }] }),
    delta({ tool_calls: [{ index: 1, id: 'call_b', function: { name: 'run_command', arguments: '' } }] }),
    'data: [DONE]',
  ]);
  const { result, sent } = await withFetch(stream, () =>
    provider([{ role: 'user', text: 'hi' }], [], (partial) => heard.push({ ...partial })),
  );

  assert.equal((sent as { stream: boolean }).stream, true);
  assert.deepEqual(result, {
    text: 'Sure, doing it.',
    toolCalls: [
      { id: 'call_a', name: 'computer', arguments: '{"action":"screenshot"}' },
      { id: 'call_b', name: 'run_command', arguments: '{}' },
    ],
  });
  assert.deepEqual(heard[0], { text: '', reasoning: 'Let me ' });
  assert.deepEqual(heard.at(-1), { text: 'Sure, doing it.', reasoning: 'Let me look.' });
});

test('an endpoint that answers with plain JSON is still read', async () => {
  const plain = new Response(
    JSON.stringify({ choices: [{ message: { content: 'ok', tool_calls: [] } }] }),
    { status: 200, headers: { 'content-type': 'application/json' } },
  );
  const { result } = await withFetch(plain, () => provider([{ role: 'user', text: 'hi' }], []));
  assert.deepEqual(result, { text: 'ok', toolCalls: [] });
});

test('an error inside the stream fails the call with the key stripped', async () => {
  const stream = sse([`data: ${JSON.stringify({ error: { message: 'bad key secret-key' } })}`]);
  await assert.rejects(
    withFetch(stream, () => provider([{ role: 'user', text: 'hi' }], [])),
    (error: Error) => error.message.includes('[redacted]') && !error.message.includes('secret-key'),
  );
});

test('a 5xx is asked once more, and the extra body rides under every request', async () => {
  const replies = [new Response('upstream sad', { status: 503 }), plainOk()];
  const routed = openAiProvider({
    baseUrl: 'http://stub/v1',
    model: 'm',
    apiKey: 'k',
    extraBody: { provider: { order: ['DeepSeek'] }, model: 'not-this-one' },
  });
  const { result, sent, calls } = await withFetch(
    () => replies.shift() ?? plainOk(),
    () => retried(routed)([{ role: 'user', text: 'hi' }], []),
  );
  assert.equal(calls, 2);
  assert.deepEqual(result, { text: 'ok', toolCalls: [] });
  const body = sent as { model: string; provider: unknown };
  assert.deepEqual(body.provider, { order: ['DeepSeek'] });
  assert.equal(body.model, 'm', 'the daemon keeps the fields it owns');
});

test('an upstream timeout reported inside the stream is asked once more', async () => {
  const replies = [
    sse([`data: ${JSON.stringify({ error: { code: 504, message: 'Provider timed out' } })}`]),
    plainOk(),
  ];
  const { result, calls } = await withFetch(
    () => replies.shift() ?? plainOk(),
    () => retried(provider)([{ role: 'user', text: 'hi' }], []),
  );
  assert.equal(calls, 2);
  assert.deepEqual(result, { text: 'ok', toolCalls: [] });
});

test('a rejection reported inside the stream is not repeated', async () => {
  const { calls } = await withFetch(
    () => sse([`data: ${JSON.stringify({ error: { code: 400, message: 'context too long' } })}`]),
    async () => {
      await assert.rejects(provider([{ role: 'user', text: 'hi' }], []), /stream failed/);
    },
  );
  assert.equal(calls, 1);
});

test('a request the endpoint rejects outright is not repeated', async () => {
  const { calls } = await withFetch(
    () => new Response('{"error":"bad request"}', { status: 400 }),
    async () => {
      await assert.rejects(provider([{ role: 'user', text: 'hi' }], []), /HTTP 400/);
    },
  );
  assert.equal(calls, 1);
});

test('usage is read from the last streamed chunk and from a plain reply, and is asked for', async () => {
  const stream = sse([
    delta({ content: 'hi' }),
    `data: ${JSON.stringify({ choices: [], usage: { prompt_tokens: 12, completion_tokens: 3 } })}`,
    'data: [DONE]',
  ]);
  const { result, sent } = await withFetch(stream, () => provider([{ role: 'user', text: 'hi' }], []));
  assert.deepEqual(result.usage, { promptTokens: 12, completionTokens: 3 });
  assert.deepEqual((sent as { stream_options: unknown }).stream_options, { include_usage: true });

  const plain = new Response(
    JSON.stringify({ choices: [{ message: { content: 'ok' } }], usage: { prompt_tokens: 5, completion_tokens: 1 } }),
    { status: 200, headers: { 'content-type': 'application/json' } },
  );
  const { result: read } = await withFetch(plain, () => provider([{ role: 'user', text: 'hi' }], []));
  assert.deepEqual(read.usage, { promptTokens: 5, completionTokens: 1 });
});

test('a stopped call ends at once and is not retried', async () => {
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = (_url, init) =>
    new Promise((_, reject) => {
      calls += 1;
      init?.signal?.addEventListener('abort', () => reject(init.signal?.reason), { once: true });
    });
  try {
    const controller = new AbortController();
    const call = provider([{ role: 'user', text: 'hi' }], [], undefined, controller.signal);
    controller.abort(new Error('stopped by the owner'));
    await assert.rejects(call, /stopped by the owner/);
    assert.equal(calls, 1);
  } finally {
    globalThis.fetch = original;
  }
});

test('a 429 is tried 5 times in all, waiting longer each time, and the last error names the attempts', async () => {
  const waited: number[] = [];
  const seen: (number | undefined)[] = [];
  const { provider: calling } = withRetries({
    primary: { provider, modelId: 1, name: 'Main' },
    baseMs: 10,
    sleep: (ms) => {
      waited.push(ms);
      return Promise.resolve();
    },
    onWait: (state) => seen.push(state?.attempt),
  });
  const { calls } = await withFetch(
    () => new Response('slow down', { status: 429 }),
    async () => {
      await assert.rejects(calling([{ role: 'user', text: 'hi' }], []), (error: ProviderError) => {
        assert.match(error.message, /^after 5 attempts, provider returned HTTP 429/);
        assert.equal(error.status, 429);
        return true;
      });
    },
  );
  assert.equal(calls, MAX_ATTEMPTS);
  assert.deepEqual(waited, [10, 20, 40, 80]);
  assert.deepEqual(seen, [2, 3, 4, 5, undefined], 'each wait is shown, and cleared at the end');
});

test('Retry-After decides the wait, in seconds or as a date', async () => {
  assert.equal(parseRetryAfter('3'), 3000);
  assert.equal(parseRetryAfter('Wed, 30 Sep 2026 12:00:10 GMT', Date.parse('Wed, 30 Sep 2026 12:00:00 GMT')), 10_000);
  assert.equal(parseRetryAfter('soon'), undefined);
  assert.equal(parseRetryAfter(null), undefined);

  const waited: number[] = [];
  const replies = [new Response('busy', { status: 503, headers: { 'retry-after': '7' } }), plainOk()];
  const { provider: calling } = withRetries({
    primary: { provider, modelId: 1, name: 'Main' },
    sleep: (ms) => {
      waited.push(ms);
      return Promise.resolve();
    },
  });
  await withFetch(() => replies.shift() ?? plainOk(), () => calling([{ role: 'user', text: 'hi' }], []));
  assert.deepEqual(waited, [7000]);
});

test('a refused key is not asked again and is reported against its model', async () => {
  const refused: (number | undefined)[] = [];
  const { provider: calling } = withRetries({
    primary: { provider, modelId: 4, name: 'Main' },
    sleep: instant,
    onAuthFailure: (call) => refused.push(call.modelId),
  });
  const { calls } = await withFetch(
    () => new Response('bad key', { status: 401 }),
    async () => {
      await assert.rejects(calling([{ role: 'user', text: 'hi' }], []), /HTTP 401/);
    },
  );
  assert.equal(calls, 1);
  assert.deepEqual(refused, [4]);
});

test('a plain error from outside the endpoint is not retried', async () => {
  let calls = 0;
  const failing: Provider = () => {
    calls += 1;
    return Promise.reject(new Error('the script ran out of replies'));
  };
  await assert.rejects(retried(failing)([{ role: 'user', text: 'hi' }], []), /ran out/);
  assert.equal(calls, 1);
});

const busy = (): Promise<never> => Promise.reject(new ProviderError('provider returned HTTP 503: busy', true, 503));
const ok: Provider = () => Promise.resolve({ text: 'ok', toolCalls: [] });

test('Retry now cuts the wait short', async () => {
  let calls = 0;
  const flaky: Provider = (...args) => (++calls === 1 ? busy() : ok(...args));
  const { provider: calling, control } = withRetries({
    primary: { provider: flaky, modelId: 1, name: 'Main' },
    baseMs: 60_000,
    onWait: (state) => {
      if (state !== undefined) setImmediate(() => assert.equal(control.now(), true));
    },
  });
  const started = Date.now();
  assert.equal((await calling([{ role: 'user', text: 'hi' }], [])).text, 'ok');
  assert.ok(Date.now() - started < 5_000);
  assert.equal(control.now(), false, 'nothing is waiting any more');
});

test('Use backup model sends the rest of the turn to the backup, and is offered only while it can', async () => {
  const used: string[] = [];
  const offered: (string | undefined)[] = [];
  const primary: Provider = () => {
    used.push('main');
    return busy();
  };
  const backup: Provider = (...args) => {
    used.push('backup');
    return ok(...args);
  };
  const { provider: calling, control } = withRetries({
    primary: { provider: primary, modelId: 1, name: 'Main' },
    backup: { provider: backup, modelId: 2, name: 'Spare' },
    baseMs: 60_000,
    onWait: (state) => {
      if (state === undefined) return;
      offered.push(state.backup);
      setImmediate(() => assert.equal(control.useBackup(), true));
    },
  });
  await calling([{ role: 'user', text: 'hi' }], []);
  await calling([{ role: 'user', text: 'again' }], []);
  assert.deepEqual(used, ['main', 'backup', 'backup']);
  assert.deepEqual(offered, ['Spare']);

  const { control: alone } = withRetries({ primary: { provider: primary, modelId: 1, name: 'Main' } });
  assert.equal(alone.useBackup(), false);
});

test('a stop during the wait ends the call at once', async () => {
  const controller = new AbortController();
  let calls = 0;
  const { provider: calling } = withRetries({
    primary: {
      provider: () => {
        calls += 1;
        return busy();
      },
      modelId: 1,
      name: 'Main',
    },
    baseMs: 60_000,
    onWait: (state) => {
      if (state !== undefined) setImmediate(() => controller.abort(new Error('stopped by the owner')));
    },
  });
  const started = Date.now();
  await assert.rejects(calling([{ role: 'user', text: 'hi' }], [], undefined, controller.signal), /stopped by the owner/);
  assert.ok(Date.now() - started < 5_000);
  assert.equal(calls, 1);
});
