import assert from 'node:assert/strict';
import test from 'node:test';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import type { Transport } from '@modelcontextprotocol/sdk/shared/transport.js';
import { MAX_MCP_SERVERS, openMcp, parseMcpServers, stdioArgv } from './mcp.ts';
import type { MakeTransport, McpServerSpec, McpStdioServer } from './mcp.ts';
import type { AgentTarget } from './agents.ts';

const TARGET: AgentTarget = { user: 'agent-alpha', home: '/home/agent-alpha', display: 1 };
const LIMIT = 200;

function only(value: unknown): McpServerSpec[] {
  const parsed = parseMcpServers(value);
  assert.ok(!('error' in parsed), `expected a valid list, got ${JSON.stringify(parsed)}`);
  return parsed.servers;
}

function refused(value: unknown): string {
  const parsed = parseMcpServers(value);
  assert.ok('error' in parsed, `expected a refusal for ${JSON.stringify(value)}`);
  return parsed.error;
}

type StubTool = { name: string; description?: string };

/** One MCP server running in this process, reached over a linked in-memory transport pair: the
 * real protocol, the real client, no child process. */
async function stubServer(
  tools: readonly StubTool[],
  answer: (name: string, args: Record<string, unknown>) => Record<string, unknown>,
): Promise<Transport> {
  const [clientSide, serverSide] = InMemoryTransport.createLinkedPair();
  const server = new Server({ name: 'stub', version: '0' }, { capabilities: { tools: {} } });
  server.setRequestHandler(ListToolsRequestSchema, () => ({
    tools: tools.map((tool) => ({
      name: tool.name,
      ...(tool.description === undefined ? {} : { description: tool.description }),
      inputSchema: { type: 'object' as const, properties: { path: { type: 'string' } } },
    })),
  }));
  server.setRequestHandler(CallToolRequestSchema, (request) =>
    answer(request.params.name, request.params.arguments ?? {}),
  );
  await server.connect(serverSide);
  return clientSide;
}

/** A transport that never comes up, which is what a server that is down looks like from here. */
function deadTransport(why: string): Transport {
  return {
    start: () => Promise.reject(new Error(why)),
    send: () => Promise.resolve(),
    close: () => Promise.resolve(),
  };
}

function byName(pairs: Record<string, Transport>): MakeTransport {
  return (spec) => {
    const transport = pairs[spec.name];
    if (transport === undefined) throw new Error(`no stub transport for ${spec.name}`);
    return transport;
  };
}

const STDIO = { name: 'files', command: 'npx', args: ['-y', 'server-filesystem'], env: {} };
const HTTP = { name: 'docs', url: 'https://example.com/mcp', headers: {} };

test('a stdio and an http server both parse into what the daemon runs', () => {
  const servers = only([
    { name: 'files', command: 'npx', args: ['-y', 'pkg'], env: { TOKEN: 'x' } },
    { name: 'docs', url: 'https://example.com/mcp', headers: { authorization: 'Bearer y' } },
  ]);
  assert.deepEqual(servers[0], { name: 'files', command: 'npx', args: ['-y', 'pkg'], env: { TOKEN: 'x' } });
  assert.deepEqual(servers[1], {
    name: 'docs',
    url: 'https://example.com/mcp',
    headers: { authorization: 'Bearer y' },
  });
});

test('args and env are optional and default to nothing', () => {
  assert.deepEqual(only([{ name: 'files', command: 'mcp-server' }])[0], {
    name: 'files',
    command: 'mcp-server',
    args: [],
    env: {},
  });
});

test('a server list the daemon cannot run is refused rather than silently dropped', () => {
  assert.match(refused({}), /must be an array/);
  assert.match(refused([{ name: 'Files', command: 'x' }]), /lowercase letters/);
  // No underscore in a name, so `mcp__<server>__<tool>` reads one way whatever either half is.
  assert.match(refused([{ name: 'my_files', command: 'x' }]), /lowercase letters/);
  assert.match(refused([{ name: 'files' }]), /either a command .* or a url/);
  assert.match(refused([{ name: 'files', command: 'x', url: 'https://a.example' }]), /not both/);
  assert.match(refused([{ name: 'docs', url: 'ftp://a.example' }]), /only http and https/);
  assert.match(refused([{ name: 'docs', url: 'not a url' }]), /is not a URL/);
  assert.match(refused([{ name: 'files', command: 'x', args: [1] }]), /array of strings/);
  assert.match(refused([{ name: 'files', command: 'x', env: { A: 2 } }]), /must be a string/);
  assert.match(refused([{ name: 'files', command: 'x', env: { '--chdir': 'y' } }]), /not a variable name/);
  assert.match(refused([STDIO, { ...STDIO, command: 'other' }]), /both named files/);
  assert.match(
    refused(Array.from({ length: MAX_MCP_SERVERS + 1 }, (_, i) => ({ name: `s${i}`, command: 'x' }))),
    /at most 8 MCP servers/,
  );
});

test('a stdio server runs as the agent Linux user, with its env block in front of the command', () => {
  const spec: McpStdioServer = {
    name: 'files',
    command: 'npx',
    args: ['-y', 'pkg'],
    env: { TOKEN: 'secret' },
  };
  const argv = stdioArgv(spec, TARGET);

  assert.deepEqual(argv.slice(0, 5), [
    '-n',
    '-u',
    'agent-alpha',
    'env',
    '--chdir=/home/agent-alpha',
  ]);
  // The env block is an operand of the `env` asAgent already builds, because the sudoers rules
  // grant no SETENV: what sudo was handed is stripped before the command ever sees it.
  assert.deepEqual(argv.slice(-4), ['TOKEN=secret', 'npx', '-y', 'pkg']);
  assert.ok(!argv.includes('sudo'), 'sudo is the file spawned, not an argument');
});

test('a configured server is offered namespaced tools and a call round-trips', async () => {
  const transport = await stubServer(
    [{ name: 'read', description: 'Read a file' }, { name: 'append' }],
    (name, args) => ({ content: [{ type: 'text', text: `${name} ${JSON.stringify(args)}` }] }),
  );
  const session = await openMcp([STDIO], TARGET, byName({ files: transport }));

  assert.deepEqual(
    session.tools.map((tool) => tool.name),
    ['mcp__files__append', 'mcp__files__read'],
    'namespaced, and sorted so the list is the same every turn',
  );
  assert.equal(session.tools[1]?.description, 'Read a file');
  assert.match(String(session.tools[0]?.description), /append, from the files MCP server/);
  assert.deepEqual(session.tools[1]?.parameters, {
    type: 'object',
    properties: { path: { type: 'string' } },
  });

  const result = await session.call('mcp__files__read', { path: '/etc/hostname' }, LIMIT);
  assert.deepEqual(result, { text: 'read {"path":"/etc/hostname"}' });
  await session.close();
});

test('an unreachable server costs its own tools and nothing else', async () => {
  const up = await stubServer([{ name: 'read' }], () => ({ content: [{ type: 'text', text: 'ok' }] }));
  const session = await openMcp(
    [{ ...HTTP, name: 'down' } as McpServerSpec, STDIO],
    TARGET,
    byName({ down: deadTransport('connection refused'), files: up }),
  );

  assert.deepEqual(session.tools.map((tool) => tool.name), ['mcp__files__read']);
  assert.deepEqual(session.failures.map((failure) => failure.server), ['down']);
  assert.match(String(session.failures[0]?.error), /connection refused/);
  assert.deepEqual(await session.call('mcp__files__read', {}, LIMIT), { text: 'ok' });
  await session.close();
});

test('a header an owner stored never reaches the failure it is echoed in', async () => {
  const spec: McpServerSpec = {
    name: 'docs',
    url: 'https://example.com/mcp',
    headers: { authorization: 'Bearer s3cr3t' },
  };
  const session = await openMcp(
    [spec],
    TARGET,
    byName({ docs: deadTransport('rejected: Bearer s3cr3t') }),
  );

  assert.deepEqual(session.tools, []);
  assert.match(String(session.failures[0]?.error), /rejected: \[redacted\]/);
  assert.ok(!String(session.failures[0]?.error).includes('s3cr3t'));
  await session.close();
});

test('a tool the server reports as failing is an error the agent can read', async () => {
  const transport = await stubServer([{ name: 'read' }], () => ({
    content: [{ type: 'text', text: 'no such file' }],
    isError: true,
  }));
  const session = await openMcp([STDIO], TARGET, byName({ files: transport }));

  const result = await session.call('mcp__files__read', { path: '/nope' }, LIMIT);
  assert.deepEqual(result, { error: 'mcp__files__read reported a failure: no such file' });
  await session.close();
});

test('a long answer is clipped and a non-text part is named rather than shown', async () => {
  const transport = await stubServer([{ name: 'read' }, { name: 'shot' }], (name) =>
    name === 'shot'
      ? { content: [{ type: 'image', data: 'AAAA', mimeType: 'image/png' }] }
      : { content: [{ type: 'text', text: 'x'.repeat(LIMIT * 2) }] },
  );
  const session = await openMcp([STDIO], TARGET, byName({ files: transport }));

  const long = await session.call('mcp__files__read', {}, LIMIT);
  assert.ok('text' in long);
  assert.equal(long.text.length, LIMIT + '\n[output truncated]'.length);

  const shot = await session.call('mcp__files__shot', {}, LIMIT);
  assert.deepEqual(shot, { text: '[image content, which is not shown here]' });
  await session.close();
});

test('a tool nothing is routed to is refused rather than sent somewhere', async () => {
  const transport = await stubServer([{ name: 'read' }], () => ({ content: [] }));
  const session = await openMcp([STDIO], TARGET, byName({ files: transport }));

  assert.deepEqual(await session.call('mcp__files__write', {}, LIMIT), {
    error: 'no tool named mcp__files__write',
  });
  await session.close();
});

test('closing the session closes every client it opened', async () => {
  const closed: string[] = [];
  const watch = (name: string, transport: Transport): Transport => {
    const inner = transport.close.bind(transport);
    transport.close = () => {
      closed.push(name);
      return inner();
    };
    return transport;
  };
  const one = await stubServer([{ name: 'read' }], () => ({ content: [] }));
  const two = await stubServer([{ name: 'find' }], () => ({ content: [] }));
  const session = await openMcp(
    [STDIO, HTTP as McpServerSpec],
    TARGET,
    byName({ files: watch('files', one), docs: watch('docs', two) }),
  );

  await session.close();
  assert.deepEqual([...new Set(closed)].sort(), ['docs', 'files']);
});
