import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import type { Transport } from '@modelcontextprotocol/sdk/shared/transport.js';
import { asAgent } from './agents.ts';
import type { AgentTarget } from './agents.ts';
import { log } from './log.ts';
import { withoutKey } from './provider.ts';
import type { ToolDef } from './provider.ts';

/** How many servers the owner may configure. A turn connects to every one of them, so this is
 * also how many processes one turn may start. */
export const MAX_MCP_SERVERS = 8;
/** Connecting and listing tools. Spent once per server per turn, in front of the first step. */
export const MCP_CONNECT_TIMEOUT_MS = 20_000;
/** One tool call. Longer than a connect because the work is the server's, not the handshake's. */
export const MCP_CALL_TIMEOUT_MS = 120_000;

/** The namespace every MCP tool is offered under, so nothing a server names can collide with a
 * tool the daemon owns. */
export const MCP_PREFIX = 'mcp__';

/** A server name is lowercase, hyphenated and has no underscore in it, so `mcp__a__b` reads as
 * one server and one tool however either half is written. */
const SERVER_NAME = /^[a-z0-9][a-z0-9-]{0,31}$/;
/** What an OpenAI-compatible endpoint accepts as a function name. A server whose tool does not
 * fit inside it once namespaced is dropped rather than renamed. */
const TOOL_NAME = /^[A-Za-z0-9_-]{1,64}$/;
const ENV_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;

/** A server the daemon starts as the agent's Linux user and talks to over stdin and stdout. */
export type McpStdioServer = {
  name: string;
  command: string;
  args: string[];
  /** Where an owner puts an API key, which is why the whole settings row is encrypted. */
  env: Record<string, string>;
};

/** A server already running somewhere, reached over streamable HTTP. */
export type McpHttpServer = {
  name: string;
  url: string;
  headers: Record<string, string>;
};

export type McpServerSpec = McpStdioServer | McpHttpServer;

export function isHttpServer(spec: McpServerSpec): spec is McpHttpServer {
  return 'url' in spec;
}

/** The values an owner put in this server's env block or headers, so an error on its way to the
 * agent or the log can be stripped of them. */
function secrets(spec: McpServerSpec): string[] {
  return Object.values(isHttpServer(spec) ? spec.headers : spec.env);
}

function safely(spec: McpServerSpec, message: string): string {
  return secrets(spec).reduce((text, value) => withoutKey(text, value), message);
}

function strings(
  value: unknown,
  what: string,
): { values: Record<string, string> } | { error: string } {
  if (value === undefined) return { values: {} };
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    return { error: `${what} must be an object of strings` };
  }
  const values: Record<string, string> = {};
  for (const [key, entry] of Object.entries(value)) {
    if (typeof entry !== 'string') return { error: `${what}.${key} must be a string` };
    values[key] = entry;
  }
  return { values };
}

function parseServer(value: unknown): McpServerSpec | { error: string } {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    return { error: 'every server must be an object' };
  }
  const entry = value as Record<string, unknown>;
  const name = entry['name'];
  if (typeof name !== 'string' || !SERVER_NAME.test(name)) {
    return {
      error: `server name ${JSON.stringify(name)} must be 1-32 lowercase letters, digits or hyphens`,
    };
  }
  const url = entry['url'];
  const command = entry['command'];
  if ((typeof url === 'string') === (typeof command === 'string')) {
    return { error: `${name} must have either a command (stdio) or a url (http), not both` };
  }

  if (typeof url === 'string') {
    let parsed: URL;
    try {
      parsed = new URL(url);
    } catch {
      return { error: `${name}: ${url} is not a URL` };
    }
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
      return { error: `${name}: only http and https MCP servers can be reached` };
    }
    const headers = strings(entry['headers'], `${name}.headers`);
    return 'error' in headers
      ? headers
      : { name, url: parsed.toString(), headers: headers.values };
  }

  if (typeof command !== 'string' || command.trim() === '') {
    return { error: `${name}: command must be a non-empty string` };
  }
  const rawArgs = entry['args'] ?? [];
  if (!Array.isArray(rawArgs) || rawArgs.some((arg) => typeof arg !== 'string')) {
    return { error: `${name}.args must be an array of strings` };
  }
  const env = strings(entry['env'], `${name}.env`);
  if ('error' in env) return env;
  const bad = Object.keys(env.values).find((key) => !ENV_NAME.test(key));
  if (bad !== undefined) return { error: `${name}.env.${bad} is not a variable name` };
  return { name, command: command.trim(), args: rawArgs as string[], env: env.values };
}

/**
 * The owner's server list as the daemon understands it. Shared by the route that writes it and
 * the reader that loads it, so what may be stored and what may be run cannot drift apart.
 */
export function parseMcpServers(value: unknown): { servers: McpServerSpec[] } | { error: string } {
  if (!Array.isArray(value)) return { error: 'servers must be an array' };
  if (value.length > MAX_MCP_SERVERS) {
    return { error: `at most ${MAX_MCP_SERVERS} MCP servers can be configured` };
  }
  const servers: McpServerSpec[] = [];
  for (const entry of value) {
    const spec = parseServer(entry);
    if ('error' in spec) return spec;
    if (servers.some((other) => other.name === spec.name)) {
      return { error: `two servers are both named ${spec.name}` };
    }
    servers.push(spec);
  }
  return { servers };
}

/**
 * The argv that starts a stdio server **as the agent's Linux user**. The daemon's own user owns
 * the sudoers rules and the master key, and an MCP server is somebody else's code, so it never
 * runs as `schermes`. The env block rides in as operands to the `env` that `asAgent` already
 * builds, which is the only way through: the sudoers rules grant no `SETENV`, so `sudo` strips
 * the environment it was handed.
 */
export function stdioArgv(spec: McpStdioServer, target: AgentTarget): string[] {
  return asAgent(target, [
    ...Object.entries(spec.env).map(([key, value]) => `${key}=${value}`),
    spec.command,
    ...spec.args,
  ]);
}

/** How a server becomes a connection. A parameter so a test can link the client to a server in
 * this process rather than spawning one. */
export type MakeTransport = (spec: McpServerSpec, target: AgentTarget) => Transport;

/** The SDK's own transports declare `sessionId` as `string | undefined` where its `Transport`
 * interface makes the property optional, which `exactOptionalPropertyTypes` reads as two
 * different types. The cast is that gap and nothing else. */
const systemTransport: MakeTransport = (spec, target) =>
  (isHttpServer(spec)
    ? new StreamableHTTPClientTransport(new URL(spec.url), {
        requestInit: { headers: spec.headers },
      })
    : new StdioClientTransport({ command: 'sudo', args: stdioArgv(spec, target) })) as Transport;

/** Why one server contributed no tools. The owner's test route reports it; a turn only logs it. */
export type McpFailure = { server: string; error: string };

/**
 * Every configured server's tools for the length of one turn. Opened once in front of the first
 * step so the list the model is offered is identical across the steps of that turn — the rule
 * memory, the skills index and the schedules already follow — and closed when the turn ends.
 */
export type McpSession = {
  readonly tools: readonly ToolDef[];
  readonly failures: readonly McpFailure[];
  call(
    name: string,
    args: Record<string, unknown>,
    limit: number,
  ): Promise<{ text: string } | { error: string }>;
  close(): Promise<void>;
};

function content(result: unknown, limit: number): string {
  const parts = (result as { content?: unknown }).content;
  if (!Array.isArray(parts)) return '';
  const text = parts
    .map((part: unknown) => {
      const kind = (part as { type?: unknown }).type;
      if (kind === 'text') return String((part as { text?: unknown }).text ?? '');
      return `[${typeof kind === 'string' ? kind : 'unknown'} content, which is not shown here]`;
    })
    .join('\n')
    .trim();
  return text.length <= limit ? text : `${text.slice(0, limit)}\n[output truncated]`;
}

/**
 * Connects to each server in turn and namespaces what it offers. A server that is down, slow or
 * misconfigured costs the agent **that server's tools and nothing else**: the turn runs, the
 * rest of the list is offered, and the reason is a failure row rather than a thrown error.
 *
 * ponytail: every configured server is connected, whether or not the agent calls one, because
 * `tools/list` is how the tool list is built. A turn therefore costs one spawn per stdio server.
 * If that hurts, the upgrade is caching a server's tool list and connecting on the first call.
 */
export async function openMcp(
  specs: readonly McpServerSpec[],
  target: AgentTarget,
  makeTransport: MakeTransport = systemTransport,
): Promise<McpSession> {
  const open: Client[] = [];
  const routes = new Map<string, { client: Client; tool: string; spec: McpServerSpec }>();
  const tools: ToolDef[] = [];
  const failures: McpFailure[] = [];

  for (const spec of specs) {
    const client = new Client({ name: 'schermes', version: '0.1' });
    let listed: Awaited<ReturnType<Client['listTools']>>;
    try {
      await client.connect(makeTransport(spec, target), { timeout: MCP_CONNECT_TIMEOUT_MS });
      listed = await client.listTools(undefined, { timeout: MCP_CONNECT_TIMEOUT_MS });
    } catch (error) {
      // The transport is the client's now, so closing the client is what stops a child process
      // that spawned but never finished the handshake.
      await client.close().catch(() => {});
      const why = safely(spec, error instanceof Error ? error.message : String(error));
      failures.push({ server: spec.name, error: why });
      log.error('MCP server unreachable, its tools are not offered', { server: spec.name, error: why });
      continue;
    }
    open.push(client);

    for (const tool of [...listed.tools].sort((a, b) => a.name.localeCompare(b.name))) {
      const name = `${MCP_PREFIX}${spec.name}__${tool.name}`;
      if (!TOOL_NAME.test(name) || routes.has(name)) {
        log.info('MCP tool not offered', { server: spec.name, tool: tool.name });
        continue;
      }
      routes.set(name, { client, tool: tool.name, spec });
      tools.push({
        name,
        description: tool.description ?? `${tool.name}, from the ${spec.name} MCP server`,
        parameters:
          tool.inputSchema === null || typeof tool.inputSchema !== 'object'
            ? { type: 'object' }
            : (tool.inputSchema as Record<string, unknown>),
      });
    }
  }

  return {
    tools,
    failures,
    async call(name, args, limit) {
      const route = routes.get(name);
      if (route === undefined) return { error: `no tool named ${name}` };
      let result: unknown;
      try {
        result = await route.client.callTool({ name: route.tool, arguments: args }, undefined, {
          timeout: MCP_CALL_TIMEOUT_MS,
        });
      } catch (error) {
        const why = safely(route.spec, error instanceof Error ? error.message : String(error));
        return { error: `${name} failed: ${why}` };
      }
      const text = content(result, limit);
      return (result as { isError?: unknown }).isError === true
        ? { error: `${name} reported a failure: ${text}` }
        : { text };
    },
    async close() {
      // Every one of them, whatever any single close does: a stdio client left open is a child
      // process that outlives the turn that started it.
      await Promise.all(
        open.map((client) =>
          client.close().catch((error: unknown) => log.error('MCP client would not close', { error })),
        ),
      );
    },
  };
}
