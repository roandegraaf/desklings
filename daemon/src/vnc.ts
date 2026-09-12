import { connect } from 'node:net';
import { parse } from 'hono/utils/cookie';
import { WebSocketServer } from 'ws';
import type { IncomingMessage } from 'node:http';
import type { Socket } from 'node:net';
import type { Duplex } from 'node:stream';
import type { RawData, WebSocket } from 'ws';
import { SESSION_COOKIE, sessionValid } from './auth.ts';
import { desktopAgent } from './agents.ts';
import { log } from './log.ts';
import type { Db } from './db.ts';

// Xvnc binds 127.0.0.1:(5900 + display) and lets in anyone who can reach it, which is why the
// session guard is here and why the proxy is the only way in from off the machine.
const VNC_PORT_BASE = 5900;

const VNC_PATH = /^\/api\/agents\/([a-z0-9-]+)\/vnc$/;

/** Swapped for a stand-in in tests; production always dials the agent's own Xvnc on loopback. */
export type Dial = (display: number) => Socket;

const dialVnc: Dial = (display) => connect(VNC_PORT_BASE + display, '127.0.0.1');

/** The upgrade half of the server `serve()` returns, which is a union this does not care about. */
type Upgradable = {
  on(
    event: 'upgrade',
    listener: (request: IncomingMessage, socket: Duplex, head: Buffer) => void,
  ): unknown;
};

function refuse(socket: Duplex, status: number, reason: string): void {
  socket.end(`HTTP/1.1 ${status} ${reason}\r\nconnection: close\r\n\r\n`);
}

function bytes(data: RawData): Buffer {
  if (Array.isArray(data)) return Buffer.concat(data);
  return Buffer.isBuffer(data) ? data : Buffer.from(data as ArrayBuffer);
}

/**
 * Bytes in both directions and nothing else.
 *
 * ponytail: no backpressure and no RFB parsing. A slow viewer buffers in this process, and a
 * viewer that sends pointer and key events while it does not hold control is stopped by its own
 * client rather than by us — filtering RFB message types 4 and 5 would need a real parser.
 */
function pipe(ws: WebSocket, vnc: Socket, agent: string): void {
  const stop = () => {
    vnc.destroy();
    ws.close();
  };

  vnc.on('data', (chunk: Buffer) => ws.send(chunk));
  vnc.on('close', stop);
  vnc.on('error', (error) => {
    log.error('vnc connection failed', { agent, error });
    stop();
  });

  ws.on('message', (data: RawData) => vnc.write(bytes(data)));
  ws.on('close', stop);
  ws.on('error', (error) => {
    log.error('vnc viewer failed', { agent, error });
    stop();
  });
}

/**
 * The owner's window onto one agent's desktop, on the web port every other route is on and
 * behind the same session guard. `noServer` means this binds nothing of its own.
 */
export function attachVncProxy(server: Upgradable, db: Db, dial: Dial = dialVnc): void {
  const sockets = new WebSocketServer({ noServer: true });

  server.on('upgrade', (request, socket, head) => {
    // An upgrade socket with no error handler takes the process down on a reset.
    socket.on('error', (error) => log.error('vnc upgrade failed', { error }));

    const name = VNC_PATH.exec(request.url ?? '')?.[1];
    if (name === undefined) return refuse(socket, 404, 'Not Found');

    const session = parse(request.headers.cookie ?? '')[SESSION_COOKIE];
    if (session === undefined || !sessionValid(db, session)) {
      return refuse(socket, 401, 'Unauthorized');
    }

    const agent = desktopAgent(db, name);
    if (agent === undefined) return refuse(socket, 404, 'Not Found');

    sockets.handleUpgrade(request, socket, head, (ws) => {
      log.info('vnc viewer connected', { agent: agent.name, display: agent.display });
      pipe(ws, dial(agent.display), agent.name);
    });
  });
}
