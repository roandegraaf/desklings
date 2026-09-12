import { setTimeout as sleep } from 'node:timers/promises';
import type { LiveReply, ToolCall } from '@schermes/shared';
import { log } from './log.ts';

/**
 * Measured between bytes, not over the whole call. A reasoning model streams for minutes on a
 * long transcript, and a total cap killed exactly the turns that were about to answer; a
 * stream that goes silent for this long is dead.
 */
export const IDLE_TIMEOUT_MS = 120_000;
const RETRY_DELAY_MS = 2_000;
const ERROR_BODY_CHARS = 500;

/** A failure the endpoint reported, and whether asking once more can reasonably go differently. */
export class ProviderError extends Error {
  readonly retryable: boolean;

  constructor(message: string, retryable: boolean) {
    super(message);
    this.retryable = retryable;
  }
}

function retryableStatus(status: number): boolean {
  return status === 408 || status === 429 || status >= 500;
}

/** A function tool as an OpenAI-compatible endpoint wants it, minus the `type` wrapper. */
export type ToolDef = {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
};

export type Image = { mediaType: 'image/png'; base64: string };

export type ProviderMessage =
  | { role: 'system' | 'user'; text: string; image?: Image }
  | { role: 'assistant'; text: string; toolCalls: readonly ToolCall[] }
  | { role: 'tool'; toolCallId: string; text: string };

export type ChatReply = { text: string; toolCalls: ToolCall[] };

/** The one seam over the model. A function, because one method is not worth an object. The
 * third argument hears the reply as it streams; a provider that cannot stream never calls it. */
export type Provider = (
  messages: readonly ProviderMessage[],
  tools: readonly ToolDef[],
  onDelta?: (partial: LiveReply) => void,
) => Promise<ChatReply>;

export type ProviderConfig = {
  baseUrl: string;
  model: string;
  apiKey: string;
  /** Merged under every request body: routing, reasoning effort, token caps, whatever the
   * endpoint understands. The fields the daemon owns win over it. */
  extraBody?: Record<string, unknown>;
};

function wire(message: ProviderMessage): Record<string, unknown> {
  switch (message.role) {
    case 'assistant':
      return {
        role: 'assistant',
        content: message.text,
        ...(message.toolCalls.length === 0
          ? {}
          : {
              tool_calls: message.toolCalls.map((call) => ({
                id: call.id,
                type: 'function',
                function: { name: call.name, arguments: call.arguments },
              })),
            }),
      };

    case 'tool':
      return { role: 'tool', tool_call_id: message.toolCallId, content: message.text };

    default:
      return message.image === undefined
        ? { role: message.role, content: message.text }
        : {
            role: message.role,
            content: [
              { type: 'text', text: message.text },
              {
                type: 'image_url',
                image_url: {
                  url: `data:${message.image.mediaType};base64,${message.image.base64}`,
                },
              },
            ],
          };
  }
}

/**
 * An endpoint or a proxy in front of it may echo the request back in an error body. That body
 * ends up in a failure event and in the log, and `redact` only matches field names, so the key
 * is stripped here rather than anywhere downstream.
 */
export function withoutKey(text: string, key: string): string {
  return key === '' ? text : text.replaceAll(key, '[redacted]');
}

function field(value: unknown, name: string): unknown {
  return value !== null && typeof value === 'object' ? (value as Record<string, unknown>)[name] : undefined;
}

function parseToolCalls(raw: unknown): ToolCall[] {
  if (!Array.isArray(raw)) return [];
  return raw.flatMap((entry, index): ToolCall[] => {
    const fn = field(entry, 'function');
    const name = field(fn, 'name');
    if (typeof name !== 'string') return [];
    const id = field(entry, 'id');
    const args = field(fn, 'arguments');
    return [
      {
        id: typeof id === 'string' && id !== '' ? id : `call_${index}`,
        name,
        arguments: typeof args === 'string' ? args : '{}',
      },
    ];
  });
}

/** One JSON object per `data:` line, ending at `[DONE]` or the end of the body. Comment lines,
 * which OpenRouter sends while it waits on an upstream, are skipped. */
async function* dataLines(
  body: ReadableStream<Uint8Array>,
  touch: () => void,
): AsyncGenerator<unknown> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  for (;;) {
    const { value, done } = await reader.read();
    touch();
    buffer += done ? '' : decoder.decode(value, { stream: true });
    let end = buffer.indexOf('\n');
    while (end !== -1) {
      const line = buffer.slice(0, end).trimEnd();
      buffer = buffer.slice(end + 1);
      end = buffer.indexOf('\n');
      if (!line.startsWith('data:')) continue;
      const data = line.slice('data:'.length).trim();
      if (data === '[DONE]') return;
      yield JSON.parse(data);
    }
    if (done) return;
  }
}

type PartialCall = { id?: string; name: string; arguments: string };

function mergeToolCallDeltas(calls: Map<number, PartialCall>, raw: unknown): void {
  if (!Array.isArray(raw)) return;
  raw.forEach((entry, position) => {
    const index = field(entry, 'index');
    const slot = calls.get(typeof index === 'number' ? index : position) ?? {
      name: '',
      arguments: '',
    };
    const id = field(entry, 'id');
    if (typeof id === 'string' && id !== '') slot.id = id;
    const fn = field(entry, 'function');
    const name = field(fn, 'name');
    if (typeof name === 'string') slot.name += name;
    const args = field(fn, 'arguments');
    if (typeof args === 'string') slot.arguments += args;
    calls.set(typeof index === 'number' ? index : position, slot);
  });
}

async function readStream(
  body: ReadableStream<Uint8Array>,
  apiKey: string,
  touch: () => void,
  onDelta?: (partial: LiveReply) => void,
): Promise<ChatReply> {
  let text = '';
  let reasoning = '';
  const calls = new Map<number, PartialCall>();
  for await (const chunk of dataLines(body, touch)) {
    const failure = field(chunk, 'error');
    if (failure !== undefined) {
      const detail = withoutKey(JSON.stringify(failure), apiKey);
      // OpenRouter has already answered 200 when an upstream times out, so the status it
      // reports inside the stream is the only one there is.
      const code = field(failure, 'code');
      throw new ProviderError(
        `provider stream failed: ${detail.slice(0, ERROR_BODY_CHARS)}`,
        typeof code === 'number' && retryableStatus(code),
      );
    }
    const choices = field(chunk, 'choices');
    const delta = field(Array.isArray(choices) ? choices[0] : undefined, 'delta');
    if (delta === undefined) continue;
    const content = field(delta, 'content');
    if (typeof content === 'string') text += content;
    // OpenRouter names it `reasoning`; DeepSeek's own endpoint `reasoning_content`.
    const thought = field(delta, 'reasoning') ?? field(delta, 'reasoning_content');
    if (typeof thought === 'string') reasoning += thought;
    mergeToolCallDeltas(calls, field(delta, 'tool_calls'));
    onDelta?.({ text, reasoning });
  }
  const toolCalls = [...calls.entries()]
    .sort(([a], [b]) => a - b)
    .filter(([, call]) => call.name !== '')
    .map(([index, call]) => ({
      id: call.id ?? `call_${index}`,
      name: call.name,
      arguments: call.arguments === '' ? '{}' : call.arguments,
    }));
  return { text, toolCalls };
}

/**
 * Chat completions with tool calling and vision, streamed so the reply can be watched while the
 * model is still writing it. An endpoint that answers with plain JSON instead is read as before.
 * The only implementation behind `Provider`: schermes talks to one endpoint, chosen by the
 * settings the owner stored.
 */
export function openAiProvider(settings: ProviderConfig): Provider {
  const url = `${settings.baseUrl.replace(/\/+$/, '')}/chat/completions`;

  const request: Provider = async (messages, tools, onDelta) => {
    const controller = new AbortController();
    let timer: NodeJS.Timeout | undefined;
    const touch = () => {
      clearTimeout(timer);
      timer = setTimeout(() => {
        const idle = `no data from the provider for ${IDLE_TIMEOUT_MS / 1000}s`;
        controller.abort(new DOMException(idle, 'TimeoutError'));
      }, IDLE_TIMEOUT_MS);
    };
    touch();

    try {
      const response = await fetch(url, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          authorization: `Bearer ${settings.apiKey}`,
        },
        body: JSON.stringify({
          ...settings.extraBody,
          model: settings.model,
          messages: messages.map(wire),
          stream: true,
          ...(tools.length === 0
            ? {}
            : {
                tools: tools.map((tool) => ({ type: 'function', function: tool })),
                tool_choice: 'auto',
              }),
        }),
        signal: controller.signal,
      });
      touch();

      if (!response.ok) {
        const detail = withoutKey(await response.text(), settings.apiKey);
        const status = response.status;
        throw new ProviderError(
          `provider returned HTTP ${status}: ${detail.slice(0, ERROR_BODY_CHARS)}`,
          retryableStatus(status),
        );
      }

      const streamed = response.headers.get('content-type')?.includes('text/event-stream') ?? false;
      if (streamed && response.body !== null) {
        return await readStream(response.body, settings.apiKey, touch, onDelta);
      }

      const choices = field(await response.json(), 'choices');
      const message = field(Array.isArray(choices) ? choices[0] : undefined, 'message');
      const content = field(message, 'content');
      return {
        text: typeof content === 'string' ? content : '',
        toolCalls: parseToolCalls(field(message, 'tool_calls')),
      };
    } finally {
      clearTimeout(timer);
    }
  };

  // One retry, for the failures that are the endpoint's moment rather than the request: a
  // timeout, a dropped socket, a 429 or a 5xx. A request the endpoint rejected outright is
  // going to be rejected again.
  return async (messages, tools, onDelta) => {
    try {
      return await request(messages, tools, onDelta);
    } catch (error) {
      if (error instanceof ProviderError && !error.retryable) throw error;
      log.info('provider call failed, retrying once', { error });
      await sleep(RETRY_DELAY_MS);
      return request(messages, tools, onDelta);
    }
  };
}
