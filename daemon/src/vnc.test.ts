import assert from 'node:assert/strict';
import test from 'node:test';
import { createServer } from 'node:http';
import { createServer as createTcpServer, connect } from 'node:net';
import { resolve } from 'node:path';
import type { AddressInfo } from 'node:net';
import type { Agent } from '@schermes/shared';
import { openDb } from './db.ts';
import { insertAgent, insertWorker } from './agents.ts';
import { conversationFor } from './conversations.ts';
import { sessions } from './schema.ts';
import { attachVncProxy } from './vnc.ts';

const MIGRATIONS = resolve(import.meta.dirname, '../migrations');
const SESSION = 'schermes_session=a-live-session';
const BANNER = 'RFB 003.008\n';

const tick = () => new Promise((done) => setTimeout(done, 5));

async function until(read: () => string, pattern: RegExp): Promise<string> {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const seen = read();
    if (pattern.test(seen)) return seen;
    await tick();
  }
  throw new Error(`never saw ${pattern.source}, got ${JSON.stringify(read())}`);
}

/** One masked binary frame, which is the only shape a browser sends. Payloads stay under 126
 * bytes so the length fits the short form. */
function clientFrame(payload: string): Buffer {
  const body = Buffer.from(payload);
  const mask = Buffer.from([0x37, 0xfa, 0x21, 0x3d]);
  const masked = body.map((byte, index) => byte ^ (mask[index % 4] as number));
  return Buffer.concat([Buffer.from([0x82, 0x80 | body.length]), mask, masked]);
}

/** The daemon's web server with the proxy on it, and a stand-in for one agent's Xvnc. */
async function harness() {
  const db = openDb(':memory:', MIGRATIONS);
  const alpha = insertAgent(db, 'alpha') as Agent;
  insertWorker(db, alpha, 'alpha-w1', conversationFor(db, alpha.id));
  db.insert(sessions)
    .values({ id: 'a-live-session', createdAt: Date.now(), expiresAt: Date.now() + 60_000 })
    .run();

  const received: Buffer[] = [];
  const xvnc = createTcpServer((socket) => {
    socket.write(BANNER);
    socket.on('data', (chunk: Buffer) => received.push(chunk));
  });
  await new Promise<void>((done) => {
    xvnc.listen(0, '127.0.0.1', () => done());
  });
  const vncPort = (xvnc.address() as AddressInfo).port;

  const dialled: number[] = [];
  const web = createServer();
  attachVncProxy(web, db, (display) => {
    dialled.push(display);
    return connect(vncPort, '127.0.0.1');
  });
  await new Promise<void>((done) => {
    web.listen(0, '127.0.0.1', () => done());
  });

  const open = new Set<ReturnType<typeof connect>>();

  return {
    alpha,
    dialled,
    received,
    async upgrade(path: string, cookie?: string) {
      const socket = connect((web.address() as AddressInfo).port, '127.0.0.1');
      open.add(socket);
      const chunks: Buffer[] = [];
      socket.on('data', (chunk: Buffer) => chunks.push(chunk));
      socket.on('error', () => {});
      await new Promise((done) => socket.once('connect', done));
      socket.write(
        [
          `GET ${path} HTTP/1.1`,
          'Host: 127.0.0.1',
          'Upgrade: websocket',
          'Connection: Upgrade',
          'Sec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==',
          'Sec-WebSocket-Version: 13',
          ...(cookie === undefined ? [] : [`Cookie: ${cookie}`]),
          '',
          '',
        ].join('\r\n'),
      );
      return { socket, read: () => Buffer.concat(chunks).toString('latin1') };
    },
    close() {
      for (const socket of open) socket.destroy();
      web.close();
      xvnc.close();
    },
  };
}

test('the vnc proxy answers only the owner, and only for a desktop that exists', async () => {
  const h = await harness();
  try {
    const anonymous = await h.upgrade('/api/agents/alpha/vnc');
    assert.match(await until(anonymous.read, /^HTTP\/1\.1 \d{3} /), /^HTTP\/1\.1 401 /);

    const stale = await h.upgrade('/api/agents/alpha/vnc', 'schermes_session=expired-long-ago');
    assert.match(await until(stale.read, /^HTTP\/1\.1 \d{3} /), /^HTTP\/1\.1 401 /);

    const nobody = await h.upgrade('/api/agents/nobody/vnc', SESSION);
    assert.match(await until(nobody.read, /^HTTP\/1\.1 \d{3} /), /^HTTP\/1\.1 404 /);

    // A task worker shares its parent's desktop and its display is a placeholder, so there is
    // nothing behind 5900 + that number to connect to.
    const worker = await h.upgrade('/api/agents/alpha-w1/vnc', SESSION);
    assert.match(await until(worker.read, /^HTTP\/1\.1 \d{3} /), /^HTTP\/1\.1 404 /);

    const elsewhere = await h.upgrade('/api/agents/alpha/messages', SESSION);
    assert.match(await until(elsewhere.read, /^HTTP\/1\.1 \d{3} /), /^HTTP\/1\.1 404 /);

    assert.deepEqual(h.dialled, [], 'no refused upgrade reached an Xvnc');
  } finally {
    h.close();
  }
});

test('an owner with a session gets the desktop bytes, in both directions', async () => {
  const h = await harness();
  try {
    const viewer = await h.upgrade('/api/agents/alpha/vnc', SESSION);
    await until(viewer.read, /^HTTP\/1\.1 101 /);
    // The server never masks, so the handshake bytes are the banner Xvnc sent, verbatim.
    await until(viewer.read, /RFB 003\.008/);
    assert.deepEqual(h.dialled, [h.alpha.display], "the proxy dialled the agent's own display");

    viewer.socket.write(clientFrame(BANNER));
    await until(() => Buffer.concat(h.received).toString(), /RFB 003\.008/);
    assert.equal(Buffer.concat(h.received).toString(), BANNER, 'unmasked on the way through');
  } finally {
    h.close();
  }
});
