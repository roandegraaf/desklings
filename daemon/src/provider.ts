import { setTimeout as sleep } from 'node:timers/promises';
import type { LiveReply, RetryState, ToolCall } from '@schermes/shared';
import { log } from './log.ts';

/**
 * Measured between bytes, not over the whole call. A reasoning model streams for minutes on a
 * long transcript, and a total cap killed exactly the turns that were about to answer; a
 * stream that goes silent for this long is dead.
 */
export const IDLE_TIMEOUT_MS = 120_000;
export const MAX_ATTEMPTS = 5;
export const RETRY_BASE_MS = 2_000;
const MAX_WAIT_MS = 120_000;
const ERROR_BODY_CHARS = 500;

/** A failure the endpoint reported, and whether asking once more can reasonably go differently. */
export class ProviderError extends Error {
  readonly retryable: boolean;
  readonly status: number | undefined;
  readonly retryAfterMs: number | undefined;

  constructor(message: string, retryable: boolean, status?: number, retryAfterMs?: number) {
    super(message);
    this.retryable = retryable;
    this.status = status;
    this.retryAfterMs = retryAfterMs;
  }
}

/** A key the endpoint refused. Asking again with the same key cannot go differently. */
export function isAuthFailure(error: unknown): boolean {
  return error instanceof ProviderError && (error.status === 401 || error.status === 403);
}

/** Seconds or an HTTP date, as RFC 9110 allows; anything else is no hint. */
export function parseRetryAfter(value: string | null, now = Date.now()): number | undefined {
  if (value === null || value.trim() === '') return undefined;
  const seconds = Number(value);
  if (Number.isFinite(seconds)) return Math.max(0, seconds * 1000);
  const at = Date.parse(value);
  return Number.isNaN(at) ? undefined : Math.max(0, at - now);
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

export type Image = { mediaType: 'image/png' | 'image/jpeg'; base64: string };

export type ProviderMessage =
  | { role: 'system' | 'user'; text: string; image?: Image }
  | { role: 'assistant'; text: string; toolCalls: readonly ToolCall[] }
  | { role: 'tool'; toolCallId: string; text: string };

/** What the endpoint said one call cost, when it said. Streamed endpoints report it in the last
 * chunk and only when asked with `stream_options`. */
export type Usage = { promptTokens: number; completionTokens: number };

export type ChatReply = { text: string; toolCalls: ToolCall[]; usage?: Usage };

/** The one seam over the model. A function, because one method is not worth an object. The
 * third argument hears the reply as it streams; a provider that cannot stream never calls it.
 * The fourth ends the call early: the owner stopping a turn must not wait out the model. */
export type Provider = (
  messages: readonly ProviderMessage[],
  tools: readonly ToolDef[],
  onDelta?: (partial: LiveReply) => void,
  signal?: AbortSignal,
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

function parseUsage(raw: unknown): Usage | undefined {
  const prompt = field(raw, 'prompt_tokens');
  const completion = field(raw, 'completion_tokens');
  if (typeof prompt !== 'number' || typeof completion !== 'number') return undefined;
  return { promptTokens: prompt, completionTokens: completion };
}

async function readStream(
  body: ReadableStream<Uint8Array>,
  apiKey: string,
  touch: () => void,
  onDelta?: (partial: LiveReply) => void,
): Promise<ChatReply> {
  let text = '';
  let reasoning = '';
  let usage: Usage | undefined;
  const calls = new Map<number, PartialCall>();
  for await (const chunk of dataLines(body, touch)) {
    usage = parseUsage(field(chunk, 'usage')) ?? usage;
    const failure = field(chunk, 'error');
    if (failure !== undefined) {
      const detail = withoutKey(JSON.stringify(failure), apiKey);
      // OpenRouter has already answered 200 when an upstream times out, so the status it
      // reports inside the stream is the only one there is.
      const code = field(failure, 'code');
      throw new ProviderError(
        `provider stream failed: ${detail.slice(0, ERROR_BODY_CHARS)}`,
        typeof code === 'number' && retryableStatus(code),
        typeof code === 'number' ? code : undefined,
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
  return { text, toolCalls, ...(usage === undefined ? {} : { usage }) };
}

/**
 * Chat completions with tool calling and vision, streamed so the reply can be watched while the
 * model is still writing it. An endpoint that answers with plain JSON instead is read as before.
 * The only implementation behind `Provider`: schermes talks to one endpoint, chosen by the
 * settings the owner stored.
 */
export function openAiProvider(settings: ProviderConfig): Provider {
  const url = `${settings.baseUrl.replace(/\/+$/, '')}/chat/completions`;

  return async (messages, tools, onDelta, signal) => {
    const controller = new AbortController();
    const stop = () => controller.abort(signal?.reason);
    if (signal?.aborted) stop();
    signal?.addEventListener('abort', stop, { once: true });
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
          stream_options: { include_usage: true },
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
          status,
          parseRetryAfter(response.headers.get('retry-after')),
        );
      }

      const streamed = response.headers.get('content-type')?.includes('text/event-stream') ?? false;
      if (streamed && response.body !== null) {
        return await readStream(response.body, settings.apiKey, touch, onDelta);
      }

      const body: unknown = await response.json();
      const choices = field(body, 'choices');
      const message = field(Array.isArray(choices) ? choices[0] : undefined, 'message');
      const content = field(message, 'content');
      const usage = parseUsage(field(body, 'usage'));
      return {
        text: typeof content === 'string' ? content : '',
        toolCalls: parseToolCalls(field(message, 'tool_calls')),
        ...(usage === undefined ? {} : { usage }),
      };
    } catch (error) {
      // A timeout or a dropped socket is the endpoint's moment, not the request; a call the
      // owner stopped is neither and goes out as it came in.
      if (error instanceof ProviderError || signal?.aborted) throw error;
      throw new ProviderError(error instanceof Error ? error.message : String(error), true);
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener('abort', stop);
    }
  };
}

/** One model a turn can call: the provider, and which registry entry it came from. */
export type ModelCall = { provider: Provider; modelId: number | undefined; name: string };

/** The owner's two levers over a call that is waiting: only while it waits do they do anything. */
export type RetryControl = { now(): boolean; useBackup(): boolean };

export type RetryOptions = {
  primary: ModelCall;
  /** Offered while waiting, never switched to on its own and never for a refused key. */
  backup?: ModelCall | undefined;
  /** The wait being shown, or undefined once there is none. */
  onWait?: (state: RetryState | undefined) => void;
  onAuthFailure?: (call: ModelCall, error: ProviderError) => void;
  onSuccess?: (call: ModelCall) => void;
  baseMs?: number;
  sleep?: (ms: number, signal: AbortSignal) => Promise<void>;
};

/**
 * Up to `MAX_ATTEMPTS` calls for the failures that are the endpoint's moment rather than the
 * request: a timeout, a dropped socket, a 429 or a 5xx. The wait doubles from `baseMs` unless the
 * endpoint said how long with `Retry-After`. A stop cuts the wait; so does "Retry now", and "Use
 * backup model" moves the rest of this turn onto the backup. Anything else fails at once.
 */
export function withRetries(options: RetryOptions): { provider: Provider; control: RetryControl } {
  const { primary, backup, baseMs = RETRY_BASE_MS } = options;
  const pause = options.sleep ?? ((ms, signal) => sleep(ms, undefined, { signal }));
  let current = primary;
  let wake: AbortController | undefined;
  const control: RetryControl = {
    now: () => {
      if (wake === undefined) return false;
      wake.abort();
      return true;
    },
    useBackup: () => {
      if (wake === undefined || backup === undefined || current === backup) return false;
      current = backup;
      wake.abort();
      return true;
    },
  };

  const provider: Provider = async (messages, tools, onDelta, signal) => {
    try {
      for (let attempt = 1; ; attempt += 1) {
        const using = current;
        try {
          const reply = await using.provider(messages, tools, onDelta, signal);
          options.onSuccess?.(using);
          return reply;
        } catch (error) {
          if (signal?.aborted || !(error instanceof ProviderError)) throw error;
          if (isAuthFailure(error)) options.onAuthFailure?.(using, error);
          if (!error.retryable) throw error;
          if (attempt >= MAX_ATTEMPTS) {
            throw new ProviderError(`after ${attempt} attempts, ${error.message}`, true, error.status);
          }
          const wait = Math.min(error.retryAfterMs ?? baseMs * 2 ** (attempt - 1), MAX_WAIT_MS);
          wake = new AbortController();
          options.onWait?.({
            attempt: attempt + 1,
            of: MAX_ATTEMPTS,
            retryAt: Date.now() + wait,
            error: error.message,
            model: using.name,
            ...(backup === undefined || current === backup ? {} : { backup: backup.name }),
          });
          log.info('provider call failed, retrying', { attempt, wait, error });
          try {
            await pause(wait, signal === undefined ? wake.signal : AbortSignal.any([signal, wake.signal]));
          } catch (stopped) {
            if (signal?.aborted) throw signal.reason ?? stopped;
          } finally {
            wake = undefined;
          }
        }
      }
    } finally {
      options.onWait?.(undefined);
    }
  };
  return { provider, control };
}
