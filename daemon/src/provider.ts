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
  /** The request was longer than the model's context window. Decided from the whole body,
   * before the message clips it. */
  readonly overflow: boolean;
  /** The registry model that refused, set by `withRetries`, which is the only place that knows. */
  modelId: number | undefined;

  constructor(message: string, retryable: boolean, status?: number, retryAfterMs?: number, overflow = false) {
    super(message);
    this.retryable = retryable;
    this.status = status;
    this.retryAfterMs = retryAfterMs;
    this.overflow = overflow;
  }
}

/** How the endpoints we know of word a request past the context window: OpenAI's
 * `context_length_exceeded`, vLLM and OpenRouter's "maximum context length", llama.cpp's
 * "context size", Anthropic's "prompt is too long", Gemini's "input token count" and Groq's
 * "reduce the length". */
const OVERFLOW =
  /context[ _-]?length|context (?:window|size)|maximum context|too many tokens|prompt is too long|input is too long|input token count|reduce the length/i;

export function isContextOverflow(status: number | undefined, body: string): boolean {
  return (status === 400 || status === 413) && OVERFLOW.test(body);
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

/** `expired` is a screenshot pruned past the retention window: no bytes, never sent as a picture. */
export type Image = { mediaType: 'image/png' | 'image/jpeg'; base64: string; expired?: true };

/**
 * What an endpoint handed back with a reply that it wants sent back unchanged when the reply is
 * replayed: DeepSeek's `reasoning_content`, OpenRouter's `reasoning_details` and Gemini's thought
 * signatures, which ride on a tool call's `extra_content`. `source` names the endpoint and model
 * that produced it, and nothing else is ever sent it: a backup or a newly chosen model may refuse
 * fields it does not know, and a signature is only valid for the model that signed it.
 */
export type Echo = {
  source: string;
  reasoningContent?: string;
  reasoningDetails?: unknown[];
  /** By tool call id. */
  callExtras?: Record<string, unknown>;
};

export type ProviderMessage =
  | { role: 'system' | 'user'; text: string; image?: Image }
  | { role: 'assistant'; text: string; toolCalls: readonly ToolCall[]; echo?: Echo }
  | { role: 'tool'; toolCallId: string; text: string };

/** What the endpoint said one call cost, when it said. Streamed endpoints report it in the last
 * chunk and only when asked with `stream_options`. */
export type Usage = { promptTokens: number; completionTokens: number };

export type FinishReason = 'stop' | 'length' | 'tool_calls' | 'content_filter' | (string & {});

export type ChatReply = {
  text: string;
  toolCalls: ToolCall[];
  usage?: Usage;
  finish?: FinishReason;
  echo?: Echo;
  /** The registry model that answered, set by `withRetries`. */
  modelId?: number;
};

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
  /** False sends every image as `NO_VISION` text instead. Absent is true. */
  vision?: boolean;
};

/** What stands in for a picture on a model that cannot see. The tool result before it already
 * said a screenshot was taken, so this says why it is missing and what to use instead. */
export const NO_VISION =
  '[a picture belongs here, but the model you run on cannot see images, so it is left out. ' +
  'Find out what is on screen as text instead: the browser tool returns the page text, and ' +
  'run_command can read files, window titles (wmctrl -l) and the clipboard.]';

/** Gemini's documented stand-in for a call it did not sign itself, such as one made by another
 * model earlier in the turn. Without a signature on the first call of a step, Gemini 3 answers 400. */
export const UNSIGNED_CALL = { google: { thought_signature: 'skip_thought_signature_validator' } };

type WirePart = Record<string, unknown>;
type WireMessage = { role: string; content: string | WirePart[]; [field: string]: unknown };

/** `gemini` covers proxies by model name and only rewrites schemas, which loses hints; `googleHost`
 * gates adding fields to a replayed message, which a proxy might refuse. */
type Dialect = { vision: boolean; source: string; gemini: boolean; googleHost: boolean };

function wire(message: ProviderMessage, dialect: Dialect): WireMessage {
  switch (message.role) {
    case 'assistant': {
      const echo = message.echo?.source === dialect.source ? message.echo : undefined;
      return {
        role: 'assistant',
        content: message.text,
        ...(echo?.reasoningContent === undefined ? {} : { reasoning_content: echo.reasoningContent }),
        ...(echo?.reasoningDetails === undefined ? {} : { reasoning_details: echo.reasoningDetails }),
        ...(message.toolCalls.length === 0
          ? {}
          : {
              tool_calls: message.toolCalls.map((call, position) => {
                const extra = echo?.callExtras?.[call.id] ?? (dialect.googleHost && position === 0 ? UNSIGNED_CALL : undefined);
                return {
                  id: call.id,
                  type: 'function',
                  function: { name: call.name, arguments: call.arguments },
                  ...(extra === undefined ? {} : { extra_content: extra }),
                };
              }),
            }),
      };
    }

    case 'tool':
      return { role: 'tool', tool_call_id: message.toolCallId, content: message.text };

    default:
      if (message.image !== undefined && !dialect.vision) {
        return { role: message.role, content: `${message.text}\n${NO_VISION}` };
      }
      return message.image === undefined || message.image.base64 === ''
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

function parts(content: string | WirePart[]): WirePart[] {
  return typeof content === 'string' ? [{ type: 'text', text: content }] : content;
}

/**
 * Chat templates in the Mistral and Llama style (vLLM, llama.cpp) refuse two messages of the same
 * role in a row, and the transcript has them: a screenshot after a tool result, or the summary
 * before the first message. Consecutive `user` or `system` messages become one, as a string while
 * both are text. `tool` messages are never merged or moved: each answers the call just before it.
 */
export function alternate(messages: readonly WireMessage[]): WireMessage[] {
  const out: WireMessage[] = [];
  for (const message of messages) {
    const last = out.at(-1);
    if (last === undefined || last.role !== message.role || (message.role !== 'user' && message.role !== 'system')) {
      out.push(message);
      continue;
    }
    out[out.length - 1] = {
      role: message.role,
      content:
        typeof last.content === 'string' && typeof message.content === 'string'
          ? `${last.content}\n\n${message.content}`
          : [...parts(last.content), ...parts(message.content)],
    };
  }
  return out;
}

/** The JSON Schema keywords Gemini's OpenAPI-subset `Schema` object knows. Anything else in a tool's
 * parameters makes its OpenAI endpoint answer 400 for the whole request. */
const GEMINI_KEYWORDS = new Set([
  'type', 'format', 'title', 'description', 'nullable', 'enum', 'items', 'properties', 'required',
  'anyOf', 'minItems', 'maxItems', 'minProperties', 'maxProperties', 'minLength', 'maxLength',
  'pattern', 'minimum', 'maximum', 'example', 'default', 'propertyOrdering',
]);
const GEMINI_FORMATS: Record<string, readonly string[]> = {
  string: ['enum', 'date-time'],
  number: ['float', 'double'],
  integer: ['int32', 'int64'],
};
const MAX_REF_DEPTH = 8;

function isGoogleHost(baseUrl: string): boolean {
  let host = '';
  try {
    host = new URL(baseUrl).hostname;
  } catch {
    host = '';
  }
  return /(?:^|[.-])(?:generativelanguage|aiplatform)\.googleapis\.com$/.test(host);
}

/** Whether this endpoint is Gemini's, or a proxy in front of a Gemini model, by host or model name. */
export function isGemini(settings: Pick<ProviderConfig, 'baseUrl' | 'model'>): boolean {
  return isGoogleHost(settings.baseUrl) || /gemini/i.test(settings.model);
}

function record(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
}

/**
 * A copy of a tool's parameters that Gemini accepts. Local `$ref`s are inlined, `oneOf` becomes
 * `anyOf`, a `null` in a type list becomes `nullable`, a `const` becomes a one-value `enum`, and
 * every keyword outside `GEMINI_KEYWORDS` goes. The model only loses hints: what it sends is still
 * checked against the original schema by the tool's own validator.
 */
export function geminiSchema(schema: Record<string, unknown>): Record<string, unknown> {
  const defs = { ...record(schema['definitions']), ...record(schema['$defs']) };
  const resolve = (ref: string): unknown => {
    const found = /^#\/(?:\$defs|definitions)\/(.+)$/.exec(ref);
    return found === null ? undefined : defs[found[1] as string];
  };

  const clean = (raw: unknown, depth: number): Record<string, unknown> => {
    let node = record(raw) ?? {};
    const ref = node['$ref'];
    if (typeof ref === 'string') {
      const target = depth < MAX_REF_DEPTH ? record(resolve(ref)) : undefined;
      node = target === undefined ? {} : { ...target, ...(typeof node['description'] === 'string' ? { description: node['description'] } : {}) };
      depth += 1;
    }
    const out: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(node)) {
      if (!GEMINI_KEYWORDS.has(key)) continue;
      if (key === 'properties') {
        const properties = record(value);
        if (properties === undefined) continue;
        out[key] = Object.fromEntries(Object.entries(properties).map(([name, sub]) => [name, clean(sub, depth)]));
      } else if (key === 'items') {
        if (record(value) !== undefined) out[key] = clean(value, depth);
      } else if (key === 'anyOf') {
        if (Array.isArray(value)) out[key] = value.map((sub) => clean(sub, depth));
      } else if (key === 'enum') {
        if (Array.isArray(value) && value.every((option) => typeof option === 'string')) out[key] = value;
      } else {
        out[key] = value;
      }
    }
    if (Array.isArray(node['oneOf']) && out['anyOf'] === undefined) out['anyOf'] = node['oneOf'].map((sub) => clean(sub, depth));
    if (typeof node['const'] === 'string' && out['enum'] === undefined) out['enum'] = [node['const']];
    if (Array.isArray(node['type'])) {
      const types = node['type'].filter((type): type is string => typeof type === 'string');
      const real = types.filter((type) => type !== 'null');
      if (real.length < types.length) out['nullable'] = true;
      if (real.length === 1) out['type'] = real[0];
      else delete out['type'];
    }
    const type = out['type'];
    if (typeof out['format'] === 'string' && !(typeof type === 'string' && GEMINI_FORMATS[type]?.includes(out['format']))) {
      delete out['format'];
    }
    if (Array.isArray(out['required'])) {
      const kept = record(out['properties']) ?? {};
      const required = out['required'].filter((name) => typeof name === 'string' && name in kept);
      if (required.length === 0) delete out['required'];
      else out['required'] = required;
    }
    return out;
  };

  return clean(schema, 0);
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

function parseToolCalls(raw: unknown, extras: Record<string, unknown>): ToolCall[] {
  if (!Array.isArray(raw)) return [];
  return raw.flatMap((entry, index): ToolCall[] => {
    const fn = field(entry, 'function');
    const name = field(fn, 'name');
    if (typeof name !== 'string') return [];
    const id = field(entry, 'id');
    const args = field(fn, 'arguments');
    const callId = typeof id === 'string' && id !== '' ? id : `call_${index}`;
    const extra = field(entry, 'extra_content');
    if (extra !== undefined && extra !== null) extras[callId] = extra;
    return [{ id: callId, name, arguments: typeof args === 'string' ? args : '{}' }];
  });
}

function echoOf(
  source: string,
  reasoningContent: string,
  reasoningDetails: unknown[],
  callExtras: Record<string, unknown>,
): Echo | undefined {
  const echo: Echo = {
    source,
    ...(reasoningContent === '' ? {} : { reasoningContent }),
    ...(reasoningDetails.length === 0 ? {} : { reasoningDetails }),
    ...(Object.keys(callExtras).length === 0 ? {} : { callExtras }),
  };
  return Object.keys(echo).length === 1 ? undefined : echo;
}

/** One JSON object per `data:` line, ending at `[DONE]` or the end of the body. Comment lines,
 * which OpenRouter sends while it waits on an upstream, and `data:` lines with nothing in them,
 * which some proxies send as a keep-alive, are skipped. */
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
      if (data === '') continue;
      if (data === '[DONE]') return;
      yield JSON.parse(data);
    }
    if (done) return;
  }
}

type PartialCall = { id?: string; name: string; arguments: string; extra?: unknown };
type PartialCalls = { slots: Map<number, PartialCall>; open?: number };

/**
 * Some endpoints leave `index` out of streamed tool calls, and then the array position is 0 in
 * every chunk. Without an index, a chunk whose id differs from the open call's starts a new call,
 * and a chunk with no id or the same id continues the open one.
 */
function mergeToolCallDeltas(calls: PartialCalls, raw: unknown): void {
  if (!Array.isArray(raw)) return;
  for (const entry of raw) {
    const index = field(entry, 'index');
    const rawId = field(entry, 'id');
    const id = typeof rawId === 'string' && rawId !== '' ? rawId : undefined;
    let key: number;
    if (typeof index === 'number') {
      key = index;
    } else {
      const open = calls.open === undefined ? undefined : calls.slots.get(calls.open);
      const fresh = open === undefined || (id !== undefined && open.id !== undefined && id !== open.id);
      key = fresh ? Math.max(-1, ...calls.slots.keys()) + 1 : (calls.open as number);
    }
    const slot = calls.slots.get(key) ?? { name: '', arguments: '' };
    if (id !== undefined) slot.id = id;
    const fn = field(entry, 'function');
    const name = field(fn, 'name');
    if (typeof name === 'string') slot.name += name;
    const args = field(fn, 'arguments');
    if (typeof args === 'string') slot.arguments += args;
    const extra = field(entry, 'extra_content');
    if (extra !== undefined && extra !== null) slot.extra = extra;
    calls.slots.set(key, slot);
    calls.open = key;
  }
}

/** OpenRouter streams `reasoning_details` in pieces; pieces with the same `index` are one detail,
 * whose text-like fields arrive in fragments. The result is what a non-streamed reply carries. */
function mergeReasoningDetails(details: Record<string, unknown>[], raw: unknown): void {
  if (!Array.isArray(raw)) return;
  for (const piece of raw) {
    const part = record(piece);
    if (part === undefined) continue;
    const index = part['index'];
    const same = typeof index === 'number' ? details.find((detail) => detail['index'] === index) : undefined;
    if (same === undefined) {
      details.push({ ...part });
      continue;
    }
    for (const [key, value] of Object.entries(part)) {
      const before = same[key];
      same[key] =
        typeof value === 'string' && typeof before === 'string' && ['text', 'summary', 'data', 'signature'].includes(key)
          ? before + value
          : (before ?? value);
    }
  }
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
  source: string,
  touch: () => void,
  onDelta?: (partial: LiveReply) => void,
): Promise<ChatReply> {
  let text = '';
  let reasoning = '';
  let reasoningContent = '';
  const reasoningDetails: Record<string, unknown>[] = [];
  let usage: Usage | undefined;
  let finish: string | undefined;
  const calls: PartialCalls = { slots: new Map() };
  for await (const chunk of dataLines(body, touch)) {
    usage = parseUsage(field(chunk, 'usage')) ?? usage;
    const failure = field(chunk, 'error');
    if (failure !== undefined) {
      const detail = withoutKey(JSON.stringify(failure), apiKey);
      // OpenRouter has already answered 200 when an upstream times out, so the status it
      // reports inside the stream is the only one there is.
      const code = field(failure, 'code');
      const status = typeof code === 'number' ? code : undefined;
      throw new ProviderError(
        `provider stream failed: ${detail.slice(0, ERROR_BODY_CHARS)}`,
        status !== undefined && retryableStatus(status),
        status,
        undefined,
        isContextOverflow(status, detail),
      );
    }
    const choices = field(chunk, 'choices');
    const choice = Array.isArray(choices) ? choices[0] : undefined;
    const reason = field(choice, 'finish_reason');
    if (typeof reason === 'string') finish = reason;
    const delta = field(choice, 'delta');
    if (delta === undefined) continue;
    const content = field(delta, 'content');
    if (typeof content === 'string') text += content;
    // OpenRouter names it `reasoning`; DeepSeek's own endpoint `reasoning_content`, which is
    // also the one that has to go back.
    const echoed = field(delta, 'reasoning_content');
    if (typeof echoed === 'string') reasoningContent += echoed;
    const thought = field(delta, 'reasoning') ?? echoed;
    if (typeof thought === 'string') reasoning += thought;
    mergeReasoningDetails(reasoningDetails, field(delta, 'reasoning_details'));
    mergeToolCallDeltas(calls, field(delta, 'tool_calls'));
    onDelta?.({ text, reasoning });
  }
  const callExtras: Record<string, unknown> = {};
  const toolCalls = [...calls.slots.entries()]
    .sort(([a], [b]) => a - b)
    .filter(([, call]) => call.name !== '')
    .map(([index, call]) => {
      const id = call.id ?? `call_${index}`;
      if (call.extra !== undefined) callExtras[id] = call.extra;
      return { id, name: call.name, arguments: call.arguments === '' ? '{}' : call.arguments };
    });
  const echo = echoOf(source, reasoningContent, reasoningDetails, callExtras);
  return {
    text,
    toolCalls,
    ...(usage === undefined ? {} : { usage }),
    ...(finish === undefined ? {} : { finish }),
    ...(echo === undefined ? {} : { echo }),
  };
}

/**
 * Chat completions with tool calling and vision, streamed so the reply can be watched while the
 * model is still writing it. An endpoint that answers with plain JSON instead is read as before.
 * The only implementation behind `Provider`: schermes talks to one endpoint, chosen by the
 * settings the owner stored.
 */
export function openAiProvider(settings: ProviderConfig): Provider {
  const base = settings.baseUrl.replace(/\/+$/, '');
  const url = `${base}/chat/completions`;
  const dialect: Dialect = {
    vision: settings.vision !== false,
    source: `${base} ${settings.model}`,
    gemini: isGemini(settings),
    googleHost: isGoogleHost(settings.baseUrl),
  };

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
          messages: alternate(messages.map((message) => wire(message, dialect))),
          stream: true,
          stream_options: { include_usage: true },
          ...(tools.length === 0
            ? {}
            : {
                tools: tools.map((tool) => ({
                  type: 'function',
                  function: dialect.gemini ? { ...tool, parameters: geminiSchema(tool.parameters) } : tool,
                })),
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
          isContextOverflow(status, detail),
        );
      }

      const streamed = response.headers.get('content-type')?.includes('text/event-stream') ?? false;
      if (streamed && response.body !== null) {
        return await readStream(response.body, settings.apiKey, dialect.source, touch, onDelta);
      }

      const body: unknown = await response.json();
      const choices = field(body, 'choices');
      const choice = Array.isArray(choices) ? choices[0] : undefined;
      const message = field(choice, 'message');
      const content = field(message, 'content');
      const usage = parseUsage(field(body, 'usage'));
      const finish = field(choice, 'finish_reason');
      const callExtras: Record<string, unknown> = {};
      const toolCalls = parseToolCalls(field(message, 'tool_calls'), callExtras);
      const reasoningContent = field(message, 'reasoning_content');
      const reasoningDetails = field(message, 'reasoning_details');
      const echo = echoOf(
        dialect.source,
        typeof reasoningContent === 'string' ? reasoningContent : '',
        Array.isArray(reasoningDetails) ? reasoningDetails : [],
        callExtras,
      );
      return {
        text: typeof content === 'string' ? content : '',
        toolCalls,
        ...(usage === undefined ? {} : { usage }),
        ...(typeof finish === 'string' ? { finish } : {}),
        ...(echo === undefined ? {} : { echo }),
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
 * backup model" moves the rest of this turn onto the backup, which starts its own count of
 * attempts. Anything else fails at once. Replies and errors carry the model they came from.
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
          return using.modelId === undefined ? reply : { ...reply, modelId: using.modelId };
        } catch (error) {
          if (signal?.aborted || !(error instanceof ProviderError)) throw error;
          error.modelId = using.modelId;
          if (isAuthFailure(error)) options.onAuthFailure?.(using, error);
          if (!error.retryable) throw error;
          if (attempt >= MAX_ATTEMPTS) {
            const final = new ProviderError(`after ${attempt} attempts, ${error.message}`, true, error.status);
            final.modelId = using.modelId;
            throw final;
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
          if (current !== using) attempt = 0;
        }
      }
    } finally {
      options.onWait?.(undefined);
    }
  };
  return { provider, control };
}
