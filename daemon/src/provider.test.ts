import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { LiveReply } from '@schermes/shared';
import {
  MAX_ATTEMPTS,
  NO_VISION,
  ProviderError,
  UNSIGNED_CALL,
  alternate,
  geminiSchema,
  isContextOverflow,
  isGemini,
  openAiProvider,
  parseRetryAfter,
  withRetries,
} from './provider.ts';
import type { Echo, Provider, ProviderMessage } from './provider.ts';

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
    echo: { source: 'http://stub/v1 m', reasoningContent: 'look.' },
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
  assert.deepEqual(result, { text: 'ok', toolCalls: [], modelId: 1 });
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
  assert.deepEqual(result, { text: 'ok', toolCalls: [], modelId: 1 });
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

test('a context-length 400 is recognised from the whole body, in the response or in the stream', async () => {
  // Past the clip the message keeps, so only the full body can tell.
  const padded = JSON.stringify({
    error: { message: `${'x'.repeat(600)} maximum context length is 32768 tokens`, code: 'context_length_exceeded' },
  });
  await withFetch(
    () => new Response(padded, { status: 400 }),
    async () => {
      await assert.rejects(
        retried(provider)([{ role: 'user', text: 'hi' }], []),
        (error: ProviderError) => error.overflow && error.status === 400 && !error.retryable,
      );
    },
  );
  await withFetch(
    () => sse([`data: ${JSON.stringify({ error: { code: 400, message: 'prompt is too long: 210000 tokens' } })}`]),
    async () => {
      await assert.rejects(provider([{ role: 'user', text: 'hi' }], []), (error: ProviderError) => error.overflow);
    },
  );
  await withFetch(
    () => new Response('{"error":"bad request"}', { status: 400 }),
    async () => {
      await assert.rejects(provider([{ role: 'user', text: 'hi' }], []), (error: ProviderError) => !error.overflow);
    },
  );

  assert.ok(isContextOverflow(400, 'the request exceeds the available context size'));
  assert.ok(isContextOverflow(413, 'The input token count (1200000) exceeds the maximum number of tokens allowed'));
  assert.ok(!isContextOverflow(500, 'context_length_exceeded'), 'only a rejection of the request');
  assert.ok(!isContextOverflow(400, 'tools[3].function.parameters is invalid'));
});

test('a model without vision is sent every image as text, and one with it as an image_url part', async () => {
  const shot = { role: 'user' as const, text: 'Screenshot from tool call c1.', image: { mediaType: 'image/png' as const, base64: 'AAA' } };
  const blind = openAiProvider({ baseUrl: 'http://stub/v1', model: 'm', apiKey: 'k', vision: false });
  const { sent: withoutVision } = await withFetch(plainOk, () => blind([shot], []));
  assert.deepEqual((withoutVision as { messages: unknown[] }).messages, [
    { role: 'user', content: `Screenshot from tool call c1.\n${NO_VISION}` },
  ]);
  assert.ok(!JSON.stringify(withoutVision).includes('image_url'));

  const { sent: withVision } = await withFetch(plainOk, () => provider([shot], []));
  assert.match(JSON.stringify(withVision), /"type":"image_url"/, 'absent means it can see');
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

test('finish_reason is read from a streamed reply, past a final usage chunk, and from a plain one', async () => {
  const stream = sse([
    delta({ content: 'half a sent' }),
    `data: ${JSON.stringify({ choices: [{ index: 0, finish_reason: 'length' }] })}`,
    `data: ${JSON.stringify({ choices: [], usage: { prompt_tokens: 9, completion_tokens: 4 } })}`,
    'data: [DONE]',
  ]);
  const { result } = await withFetch(stream, () => provider([{ role: 'user', text: 'hi' }], []));
  assert.equal(result.text, 'half a sent');
  assert.equal(result.finish, 'length');

  const plain = new Response(JSON.stringify({ choices: [{ message: { content: 'ok' }, finish_reason: 'stop' }] }), {
    status: 200,
    headers: { 'content-type': 'application/json' },
  });
  assert.equal((await withFetch(plain, () => provider([{ role: 'user', text: 'hi' }], []))).result.finish, 'stop');
  assert.equal((await withFetch(plainOk, () => provider([{ role: 'user', text: 'hi' }], []))).result.finish, undefined);
});

test('a reply and an error both carry the registry model they came from', async () => {
  assert.equal((await retried(ok)([{ role: 'user', text: 'hi' }], [])).modelId, 1);
  const overflow: Provider = () => Promise.reject(new ProviderError('HTTP 400: context_length_exceeded', false, 400, undefined, true));
  await assert.rejects(retried(overflow)([{ role: 'user', text: 'hi' }], []), (error: unknown) => {
    assert.ok(error instanceof ProviderError);
    assert.equal(error.modelId, 1);
    return true;
  });
});

test('the backup starts its own count of attempts when the owner switches to it', async () => {
  const used: string[] = [];
  const waits: { attempt: number; model: string }[] = [];
  const { provider: calling, control } = withRetries({
    primary: { provider: () => (used.push('main'), busy()), modelId: 1, name: 'Main' },
    backup: { provider: () => (used.push('backup'), busy()), modelId: 2, name: 'Spare' },
    sleep: instant,
    onWait: (state) => {
      if (state === undefined) return;
      waits.push({ attempt: state.attempt, model: state.model });
      if (state.model === 'Main' && state.attempt === MAX_ATTEMPTS) assert.equal(control.useBackup(), true);
    },
  });
  await assert.rejects(calling([{ role: 'user', text: 'hi' }], []), (error: unknown) => {
    assert.ok(error instanceof ProviderError);
    assert.match(error.message, new RegExp(`^after ${MAX_ATTEMPTS} attempts`));
    assert.equal(error.modelId, 2);
    return true;
  });
  assert.equal(used.filter((name) => name === 'main').length, MAX_ATTEMPTS - 1);
  assert.equal(used.filter((name) => name === 'backup').length, MAX_ATTEMPTS, 'a full count, not the one attempt left over');
  assert.deepEqual(
    waits.filter((wait) => wait.model === 'Spare').map((wait) => wait.attempt),
    [2, 3, 4, 5],
  );
});

test('a backup whose key is refused fails the turn at once and is reported against the backup', async () => {
  const used: string[] = [];
  const refused: (number | undefined)[] = [];
  const { provider: calling, control } = withRetries({
    primary: { provider: () => (used.push('main'), busy()), modelId: 1, name: 'Main' },
    backup: {
      provider: () => (used.push('backup'), Promise.reject(new ProviderError('provider returned HTTP 401: bad key', false, 401))),
      modelId: 2,
      name: 'Spare',
    },
    sleep: instant,
    onWait: (state) => {
      if (state !== undefined) control.useBackup();
    },
    onAuthFailure: (call) => refused.push(call.modelId),
  });
  await assert.rejects(calling([{ role: 'user', text: 'hi' }], []), /HTTP 401/);
  assert.deepEqual(used, ['main', 'backup']);
  assert.deepEqual(refused, [2]);
});

type Sent = { messages: Record<string, unknown>[]; tools?: { function: { parameters: unknown } }[] };

test('data lines with nothing in them are keep-alives, not JSON', async () => {
  const stream = sse(['data:', delta({ content: 'still ' }), 'data: ', ': ping', delta({ content: 'here' }), 'data: [DONE]']);
  const { result } = await withFetch(stream, () => provider([{ role: 'user', text: 'hi' }], []));
  assert.equal(result.text, 'still here');
});

test('streamed tool calls without an index are told apart by id, whether or not each chunk repeats it', async () => {
  const stream = sse([
    delta({ tool_calls: [{ id: 'a', function: { name: 'run_command', arguments: '{"comm' } }] }),
    delta({ tool_calls: [{ id: 'a', function: { arguments: 'and":"ls"}' } }] }),
    delta({ tool_calls: [{ id: 'b', function: { name: 'computer', arguments: '' } }] }),
    delta({ tool_calls: [{ function: { arguments: '{"action":"screenshot"}' } }] }),
    delta({ tool_calls: [
      { id: 'c', function: { name: 'remember', arguments: '{}' } },
      { id: 'd', function: { name: 'web_fetch', arguments: '{}' } },
    ] }),
    'data: [DONE]',
  ]);
  const { result } = await withFetch(stream, () => provider([{ role: 'user', text: 'hi' }], []));
  assert.deepEqual(result.toolCalls, [
    { id: 'a', name: 'run_command', arguments: '{"command":"ls"}' },
    { id: 'b', name: 'computer', arguments: '{"action":"screenshot"}' },
    { id: 'c', name: 'remember', arguments: '{}' },
    { id: 'd', name: 'web_fetch', arguments: '{}' },
  ]);
});

test('what an endpoint wants back is collected from a stream: reasoning_content, signatures and reasoning details', async () => {
  const signature = { google: { thought_signature: 'sig==' } };
  const stream = sse([
    delta({ reasoning_content: 'first ' }),
    delta({ reasoning_content: 'then' }),
    delta({ reasoning_details: [{ type: 'reasoning.text', text: 'Thin', index: 0, format: 'x' }] }),
    delta({ reasoning_details: [{ type: 'reasoning.text', text: 'king', index: 0 }] }),
    delta({ reasoning_details: [{ type: 'reasoning.encrypted', data: 'enc', index: 1, format: 'x' }] }),
    delta({ tool_calls: [{ index: 0, id: 'a', extra_content: signature, function: { name: 'computer', arguments: '{}' } }] }),
    delta({ tool_calls: [{ index: 1, id: 'b', function: { name: 'run_command', arguments: '{}' } }] }),
    'data: [DONE]',
  ]);
  const { result } = await withFetch(stream, () => provider([{ role: 'user', text: 'hi' }], []));
  assert.deepEqual(result.echo, {
    source: 'http://stub/v1 m',
    reasoningContent: 'first then',
    reasoningDetails: [
      { type: 'reasoning.text', text: 'Thinking', index: 0, format: 'x' },
      { type: 'reasoning.encrypted', data: 'enc', index: 1, format: 'x' },
    ],
    callExtras: { a: signature },
  });
});

test('a plain JSON reply carries the same echo, and a reply with nothing to echo carries none', async () => {
  const plain = new Response(
    JSON.stringify({
      choices: [{
        message: {
          content: 'ok',
          reasoning_content: 'because',
          reasoning_details: [{ type: 'reasoning.encrypted', data: 'e' }],
          tool_calls: [{ id: 'a', extra_content: { google: { thought_signature: 's' } }, function: { name: 'computer', arguments: '{}' } }],
        },
      }],
    }),
    { status: 200, headers: { 'content-type': 'application/json' } },
  );
  const { result } = await withFetch(plain, () => provider([{ role: 'user', text: 'hi' }], []));
  assert.deepEqual(result.echo, {
    source: 'http://stub/v1 m',
    reasoningContent: 'because',
    reasoningDetails: [{ type: 'reasoning.encrypted', data: 'e' }],
    callExtras: { a: { google: { thought_signature: 's' } } },
  });
  const { result: bare } = await withFetch(plainOk, () => provider([{ role: 'user', text: 'hi' }], []));
  assert.equal(bare.echo, undefined);
});

const echoed: Echo = {
  source: 'http://stub/v1 m',
  reasoningContent: 'because',
  reasoningDetails: [{ type: 'reasoning.encrypted', data: 'e' }],
  callExtras: { a: { google: { thought_signature: 's' } } },
};
const replayed: ProviderMessage[] = [
  { role: 'user', text: 'hi' },
  { role: 'assistant', text: '', toolCalls: [{ id: 'a', name: 'computer', arguments: '{}' }], echo: echoed },
  { role: 'tool', toolCallId: 'a', text: 'done' },
];

test('the echo goes back on the replayed assistant message, to the endpoint and model that produced it only', async () => {
  const same = await withFetch(plainOk, () => provider(replayed, []));
  assert.deepEqual((same.sent as Sent).messages[1], {
    role: 'assistant',
    content: '',
    reasoning_content: 'because',
    reasoning_details: [{ type: 'reasoning.encrypted', data: 'e' }],
    tool_calls: [{ id: 'a', type: 'function', function: { name: 'computer', arguments: '{}' }, extra_content: { google: { thought_signature: 's' } } }],
  });

  const backup = openAiProvider({ baseUrl: 'http://stub/v1', model: 'other', apiKey: 'k' });
  const other = await withFetch(plainOk, () => backup(replayed, []));
  assert.deepEqual((other.sent as Sent).messages[1], {
    role: 'assistant',
    content: '',
    tool_calls: [{ id: 'a', type: 'function', function: { name: 'computer', arguments: '{}' } }],
  });
});

test('on Gemini, a replayed step another model made gets the documented stand-in signature on its first call', async () => {
  const gemini = openAiProvider({ baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai/', model: 'gemini-3.8-flash', apiKey: 'k' });
  const unsigned: ProviderMessage[] = [
    { role: 'user', text: 'hi' },
    { role: 'assistant', text: '', toolCalls: [{ id: 'a', name: 'computer', arguments: '{}' }, { id: 'b', name: 'computer', arguments: '{}' }] },
    { role: 'tool', toolCallId: 'a', text: 'done' },
    { role: 'tool', toolCallId: 'b', text: 'done' },
  ];
  const { sent } = await withFetch(plainOk, () => gemini(unsigned, []));
  const calls = (sent as Sent).messages[1]?.['tool_calls'] as Record<string, unknown>[];
  assert.deepEqual(calls[0]?.['extra_content'], UNSIGNED_CALL);
  assert.equal(calls[1]?.['extra_content'], undefined, 'only the first call of a step carries one');

  const { sent: elsewhere } = await withFetch(plainOk, () => provider(unsigned, []));
  const plainCalls = (elsewhere as Sent).messages[1]?.['tool_calls'] as Record<string, unknown>[];
  assert.equal(plainCalls[0]?.['extra_content'], undefined, 'and no other endpoint gets it');

  const proxied = openAiProvider({ baseUrl: 'http://proxy/v1', model: 'gemini-flash', apiKey: 'k' });
  const { sent: viaProxy } = await withFetch(plainOk, () => proxied(unsigned, []));
  const proxiedCalls = (viaProxy as Sent).messages[1]?.['tool_calls'] as Record<string, unknown>[];
  assert.equal(proxiedCalls[0]?.['extra_content'], undefined, 'not even a proxy in front of a Gemini model');
});

test('consecutive user or system messages become one; tool messages and their order are never touched', () => {
  const image = { type: 'image_url', image_url: { url: 'data:image/png;base64,AAAA' } };
  assert.deepEqual(
    alternate([
      { role: 'system', content: 'rules' },
      { role: 'system', content: 'more rules' },
      { role: 'user', content: 'summary' },
      { role: 'user', content: 'hello' },
      { role: 'assistant', content: '', tool_calls: [{ id: 'a' }, { id: 'b' }] },
      { role: 'tool', tool_call_id: 'a', content: 'one' },
      { role: 'tool', tool_call_id: 'b', content: 'two' },
      { role: 'user', content: [{ type: 'text', text: 'Screenshot' }, image] },
      { role: 'user', content: 'and a note' },
    ]),
    [
      { role: 'system', content: 'rules\n\nmore rules' },
      { role: 'user', content: 'summary\n\nhello' },
      { role: 'assistant', content: '', tool_calls: [{ id: 'a' }, { id: 'b' }] },
      { role: 'tool', tool_call_id: 'a', content: 'one' },
      { role: 'tool', tool_call_id: 'b', content: 'two' },
      { role: 'user', content: [{ type: 'text', text: 'Screenshot' }, image, { type: 'text', text: 'and a note' }] },
    ],
  );
});

test('the request merges consecutive user messages before sending', async () => {
  const { sent } = await withFetch(plainOk, () =>
    provider([{ role: 'system', text: 's' }, { role: 'user', text: 'a' }, { role: 'user', text: 'b' }], []),
  );
  assert.deepEqual((sent as Sent).messages, [{ role: 'system', content: 's' }, { role: 'user', content: 'a\n\nb' }]);
});

test('a schema for Gemini keeps only its OpenAPI subset, without touching the original', () => {
  const original = {
    $schema: 'http://json-schema.org/draft-07/schema#',
    type: 'object',
    additionalProperties: false,
    $defs: { Point: { type: 'object', properties: { x: { type: 'number', format: 'double' } }, required: ['x'] } },
    properties: {
      pattern: { type: 'string', pattern: '^a', maxLength: 10, examples: ['a'] },
      format: { type: ['string', 'null'], format: 'uri' },
      level: { type: 'integer', enum: [1, 2] },
      mode: { const: 'fast' },
      choice: { oneOf: [{ type: 'string' }, { $ref: '#/$defs/Point' }] },
      at: { $ref: '#/$defs/Point', description: 'where' },
      loop: { $ref: '#/$defs/Loop' },
      list: { type: 'array', items: { type: 'string', uniqueItems: true } },
    },
    required: ['pattern', 'gone'],
  };
  const before = structuredClone(original);
  const cleaned = geminiSchema(original);
  assert.deepEqual(original, before);
  assert.deepEqual(cleaned, {
    type: 'object',
    properties: {
      pattern: { type: 'string', pattern: '^a', maxLength: 10 },
      format: { type: 'string', nullable: true },
      level: { type: 'integer' },
      mode: { enum: ['fast'] },
      choice: { anyOf: [{ type: 'string' }, { type: 'object', properties: { x: { type: 'number', format: 'double' } }, required: ['x'] }] },
      at: { type: 'object', properties: { x: { type: 'number', format: 'double' } }, required: ['x'], description: 'where' },
      loop: {},
      list: { type: 'array', items: { type: 'string' } },
    },
    required: ['pattern'],
  });
});

test('a self-referencing schema is cut off rather than inlined forever', () => {
  const tree = { $defs: { Node: { type: 'object', properties: { child: { $ref: '#/$defs/Node' } } } }, $ref: '#/$defs/Node' };
  let node = geminiSchema(tree) as { properties?: { child?: unknown } };
  let depth = 0;
  while (node.properties?.child !== undefined) {
    node = node.properties.child as typeof node;
    depth += 1;
  }
  assert.ok(depth > 0 && depth <= 9, `inlined ${depth} levels`);
});

test('Gemini is recognised by its hosts or a model name, and only then are tool schemas rewritten', async () => {
  assert.equal(isGemini({ baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai/', model: 'x' }), true);
  assert.equal(isGemini({ baseUrl: 'https://us-central1-aiplatform.googleapis.com/v1/projects/p/endpoints/openapi', model: 'x' }), true);
  assert.equal(isGemini({ baseUrl: 'https://openrouter.ai/api/v1', model: 'google/gemini-3.8-pro' }), true);
  assert.equal(isGemini({ baseUrl: 'https://api.openai.com/v1', model: 'gpt-5' }), false);
  assert.equal(isGemini({ baseUrl: 'https://evilgenerativelanguage.googleapis.com.example/v1', model: 'x' }), false);

  const tool = { name: 't', description: 'd', parameters: { type: 'object', additionalProperties: false, properties: {} } };
  const gemini = openAiProvider({ baseUrl: 'http://proxy/v1', model: 'gemini-flash', apiKey: 'k' });
  const { sent } = await withFetch(plainOk, () => gemini([{ role: 'user', text: 'hi' }], [tool]));
  assert.deepEqual((sent as Sent).tools?.[0]?.function.parameters, { type: 'object', properties: {} });
  const { sent: plain } = await withFetch(plainOk, () => provider([{ role: 'user', text: 'hi' }], [tool]));
  assert.deepEqual((plain as Sent).tools?.[0]?.function.parameters, tool.parameters);
});
