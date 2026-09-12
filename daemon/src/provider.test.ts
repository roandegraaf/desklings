import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { LiveReply } from '@schermes/shared';
import { openAiProvider } from './provider.ts';

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
    () => routed([{ role: 'user', text: 'hi' }], []),
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
    () => provider([{ role: 'user', text: 'hi' }], []),
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
