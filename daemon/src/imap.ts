import { connect } from 'node:tls';
import type { Duplex } from 'node:stream';

/** How a check reaches the server. TLS with the default certificate checks; tests swap in a plain socket. */
export type OpenSocket = (host: string, port: number) => Duplex;
export const openTls: OpenSocket = (host, port) => connect({ host, port, servername: host });

/** The server said no to the login itself, as opposed to being down or busy. */
export class LoginRefused extends Error {}

export type Mailbox = { host: string; port: number; mailbox: string };
export type Login = { username: string; password: string };
/** Where a mailbox's check left off: its UIDVALIDITY and the highest UID already seen. */
export type MailCursor = { validity: string; last: number };
export type MailHeader = { uid: number; from: string; subject: string; date: string };

const MAX_BUFFERED = 4 * 1024 * 1024;
const MAX_HEADER_CHARS = 300;

class Reader {
  private buffer = Buffer.alloc(0);
  private wake: (() => void) | undefined;
  private failure: Error | undefined;

  constructor(socket: Duplex) {
    socket.on('data', (chunk: Buffer) => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      if (this.buffer.length > MAX_BUFFERED) socket.destroy(new Error('the mail server sent too much'));
      this.wake?.();
    });
    const end = (error?: Error) => {
      this.failure ??= error ?? new Error('the mail server closed the connection');
      this.wake?.();
    };
    socket.on('error', end);
    socket.on('close', () => end());
  }

  /** One response, with any `{n}` literals in it read whole: n counts bytes, not characters. */
  async next(): Promise<string> {
    let at = 0;
    for (;;) {
      const eol = this.buffer.indexOf('\r\n', at);
      if (eol >= 0) {
        const literal = /\{(\d+)\}$/.exec(this.buffer.subarray(at, eol).toString('latin1'));
        if (literal === null) {
          const line = this.buffer.subarray(0, eol).toString('utf8');
          this.buffer = this.buffer.subarray(eol + 2);
          return line;
        }
        const end = eol + 2 + Number(literal[1]);
        if (this.buffer.length >= end) {
          at = end;
          continue;
        }
      }
      if (this.failure !== undefined) throw this.failure;
      await new Promise<void>((resolve) => (this.wake = resolve));
      this.wake = undefined;
    }
  }
}

type Part = string | { literal: string };
type Reply = { untagged: string[]; ok: boolean; text: string };

/** An IMAP string: quoted when plain printable ASCII, else a literal. */
function astring(value: string): Part {
  return /^[\x20-\x7e]*$/.test(value) ? `"${value.replace(/[\\"]/g, '\\$&')}"` : { literal: value };
}

class Session {
  private tags = 0;
  private readonly socket: Duplex;
  private readonly reader: Reader;

  constructor(socket: Duplex, reader: Reader) {
    this.socket = socket;
    this.reader = reader;
  }

  async run(...parts: Part[]): Promise<Reply> {
    const tag = `s${++this.tags}`;
    const untagged: string[] = [];
    const settle = async (): Promise<Reply> => {
      for (;;) {
        const line = await this.reader.next();
        if (line.startsWith(`${tag} `)) {
          const text = line.slice(tag.length + 1);
          return { untagged, ok: /^OK\b/i.test(text), text };
        }
        if (line.startsWith('+')) return { untagged, ok: true, text: '+' };
        untagged.push(line);
      }
    };
    let pending = `${tag} `;
    for (const part of parts) {
      if (typeof part === 'string') {
        pending += part;
        continue;
      }
      const bytes = Buffer.from(part.literal, 'utf8');
      this.socket.write(`${pending}{${bytes.length}}\r\n`);
      const go = await settle();
      if (go.text !== '+') return go;
      this.socket.write(bytes);
      pending = '';
    }
    this.socket.write(`${pending}\r\n`);
    const reply = await settle();
    if (reply.text === '+') throw new Error('the mail server asked for more than was sent');
    return reply;
  }
}

function code(lines: readonly string[], name: string): string | undefined {
  for (const line of lines) {
    const found = new RegExp(`\\[${name} (\\d+)\\]`, 'i').exec(line);
    if (found !== null) return found[1];
  }
  return undefined;
}

function searched(lines: readonly string[], after: number): number[] {
  return lines
    .filter((line) => /^\* SEARCH\b/i.test(line))
    .flatMap((line) => line.slice('* SEARCH'.length).trim().split(/\s+/))
    .map(Number)
    .filter((uid) => Number.isSafeInteger(uid) && uid > after)
    .sort((a, b) => a - b);
}

/** RFC 2047 encoded words, which is how most subjects and names outside ASCII arrive. */
export function decodeWords(value: string): string {
  return value.replace(/=\?([^?]+)\?([bq])\?([^?]*)\?=(\s+(?==\?))?/gi, (whole, charset: string, kind: string, text: string) => {
    const bytes =
      kind.toLowerCase() === 'b'
        ? Buffer.from(text, 'base64')
        : Buffer.from(text.replace(/_/g, ' ').replace(/=([0-9a-f]{2})/gi, (_, hex: string) => String.fromCharCode(parseInt(hex, 16))), 'latin1');
    try {
      return new TextDecoder(charset).decode(bytes);
    } catch {
      return whole;
    }
  });
}

function header(fetched: string): MailHeader | undefined {
  const uid = /\bUID (\d+)/i.exec(fetched);
  const start = fetched.indexOf('}\r\n');
  if (uid === null || start < 0) return undefined;
  const found: Record<string, string> = {};
  for (const line of fetched.slice(start + 3).replace(/\r\n[ \t]+/g, ' ').split('\r\n')) {
    const field = /^(from|subject|date):\s*(.*)$/i.exec(line);
    if (field === null) continue;
    const value = decodeWords(field[2] ?? '').replace(/[\x00-\x1f\x7f]/g, ' ').trim();
    found[(field[1] ?? '').toLowerCase()] = value.slice(0, MAX_HEADER_CHARS);
  }
  return { uid: Number(uid[1]), from: found['from'] ?? '', subject: found['subject'] ?? '', date: found['date'] ?? '' };
}

/**
 * One look at a mailbox, read-only: LOGIN, EXAMINE (never SELECT), then UID SEARCH and a
 * `BODY.PEEK` of three header fields, so no message is ever marked seen. Without a cursor, or
 * when UIDVALIDITY changed, it only sets the baseline. Errors never quote a sent command: the
 * LOGIN line holds the password.
 */
export async function checkMailbox(
  open: OpenSocket,
  box: Mailbox,
  login: Login,
  since: MailCursor | undefined,
  options: { timeoutMs: number; maxListed: number },
): Promise<{ cursor: MailCursor; mail: MailHeader[]; count: number }> {
  const socket = open(box.host, box.port);
  const timer = setTimeout(() => socket.destroy(new Error('the mail server did not answer in time')), options.timeoutMs);
  try {
    const reader = new Reader(socket);
    const greeting = await reader.next();
    if (!/^\* (OK|PREAUTH)\b/i.test(greeting)) throw new Error(`the mail server did not greet: ${greeting.slice(0, 200)}`);
    const session = new Session(socket, reader);
    const loggedIn = await session.run('LOGIN ', astring(login.username), ' ', astring(login.password));
    if (!loggedIn.ok) {
      const text = loggedIn.text.slice(0, 200);
      throw /\[(UNAVAILABLE|INUSE|LIMIT|SERVERBUG)\]/i.test(text) ? new Error(`the mail server is unavailable: ${text}`) : new LoginRefused(text);
    }
    const examined = await session.run('EXAMINE ', astring(box.mailbox));
    if (!examined.ok) throw new Error(`could not open ${box.mailbox}: ${examined.text.slice(0, 200)}`);
    const validity = code(examined.untagged, 'UIDVALIDITY');
    if (validity === undefined) throw new Error('the mail server sent no UIDVALIDITY');

    const search = async (after: number) => {
      const reply = await session.run(`UID SEARCH UID ${after + 1}:*`);
      if (!reply.ok) throw new Error(`UID SEARCH failed: ${reply.text.slice(0, 200)}`);
      // `n:*` always includes the highest UID, even when n is past it.
      return searched(reply.untagged, after);
    };
    if (since === undefined || since.validity !== validity) {
      const next = Number(code(examined.untagged, 'UIDNEXT'));
      const last = Number.isSafeInteger(next) && next > 0 ? next - 1 : ((await search(0)).at(-1) ?? 0);
      return { cursor: { validity, last }, mail: [], count: 0 };
    }
    const uids = await search(since.last);
    if (uids.length === 0) return { cursor: since, mail: [], count: 0 };
    const listed = uids.slice(-options.maxListed);
    const fetched = await session.run(`UID FETCH ${listed.join(',')} (UID BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])`);
    if (!fetched.ok) throw new Error(`UID FETCH failed: ${fetched.text.slice(0, 200)}`);
    const mail = fetched.untagged
      .filter((line) => /^\* \d+ FETCH\b/i.test(line))
      .flatMap((line) => header(line) ?? [])
      .sort((a, b) => a.uid - b.uid);
    return { cursor: { validity, last: uids.at(-1) ?? since.last }, mail, count: uids.length };
  } finally {
    clearTimeout(timer);
    socket.destroy();
  }
}
