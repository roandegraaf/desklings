import assert from 'node:assert/strict';
import { Duplex } from 'node:stream';
import test from 'node:test';
import { LoginRefused, checkMailbox, decodeWords } from './imap.ts';
import type { MailCursor, OpenSocket } from './imap.ts';

type Send = (text: string | Buffer) => void;
type Handler = (verb: string, args: string, tag: string, send: Send) => void;

/** A scripted in-memory IMAP server behind the OpenSocket seam. Literals the client sends are
 * folded back into the command as a quoted string, so handlers see one line per command. */
function scripted(handler: Handler, greeting = '* OK ready') {
  const commands: string[] = [];
  const opened: Array<{ host: string; port: number }> = [];
  let destroyed = 0;
  const open: OpenSocket = (host, port) => {
    opened.push({ host, port });
    let buffer = Buffer.alloc(0);
    let pending = '';
    let literal = -1;
    const socket: Duplex = new Duplex({
      read() {},
      write(chunk: Buffer, _encoding, done) {
        buffer = Buffer.concat([buffer, chunk]);
        for (;;) {
          if (literal >= 0) {
            if (buffer.length < literal) break;
            pending += `"${buffer.subarray(0, literal).toString('utf8')}"`;
            buffer = buffer.subarray(literal);
            literal = -1;
            continue;
          }
          const eol = buffer.indexOf('\r\n');
          if (eol < 0) break;
          const line = buffer.subarray(0, eol).toString('utf8');
          buffer = buffer.subarray(eol + 2);
          const size = /\{(\d+)\}$/.exec(line);
          if (size !== null) {
            pending += line.slice(0, -size[0].length);
            literal = Number(size[1]);
            send('+ go on\r\n');
            continue;
          }
          const command = pending + line;
          pending = '';
          commands.push(command);
          const [tag = '', verb = '', ...rest] = command.split(' ');
          handler(verb.toUpperCase(), rest.join(' '), tag, send);
        }
        done();
      },
      destroy(error, done) {
        destroyed += 1;
        done(error);
      },
    });
    const send: Send = (text) => {
      queueMicrotask(() => {
        if (!socket.destroyed) socket.push(text);
      });
    };
    send(`${greeting}\r\n`);
    return socket;
  };
  return { open, commands, opened, destroyed: () => destroyed };
}

type Mail = { uid: number; head: string };

/** A well-behaved mailbox: answers LOGIN, EXAMINE, UID SEARCH and UID FETCH. */
function mailbox(options: { validity: number; mail: Mail[]; uidNext?: boolean; password?: string; loginAnswer?: string }) {
  return scripted((verb, args, tag, send) => {
    const line = (text: string) => send(`${text}\r\n`);
    const max = Math.max(0, ...options.mail.map((m) => m.uid));
    if (verb === 'LOGIN') {
      const ok = options.password === undefined || args.endsWith(` "${options.password}"`);
      line(ok ? `${tag} OK logged in` : `${tag} ${options.loginAnswer ?? 'NO [AUTHENTICATIONFAILED] Invalid credentials'}`);
    } else if (verb === 'EXAMINE') {
      line(`* ${options.mail.length} EXISTS`);
      line(`* OK [UIDVALIDITY ${options.validity}] ok`);
      if (options.uidNext !== false) line(`* OK [UIDNEXT ${max + 1}] ok`);
      line(`${tag} OK [READ-ONLY] examined`);
    } else if (verb === 'UID' && /^SEARCH UID (\d+):\*$/i.test(args)) {
      const from = Number(/(\d+):/.exec(args)?.[1]);
      const hits = options.mail.map((m) => m.uid).filter((uid) => uid >= from);
      line(`* SEARCH ${(hits.length > 0 ? hits : options.mail.length > 0 ? [max] : []).join(' ')}`.trimEnd());
      line(`${tag} OK searched`);
    } else if (verb === 'UID' && /^FETCH /i.test(args)) {
      const wanted = (args.split(' ')[1] ?? '').split(',').map(Number);
      options.mail.forEach((m, index) => {
        if (!wanted.includes(m.uid)) return;
        const head = Buffer.from(m.head, 'utf8');
        send(`* ${index + 1} FETCH (UID ${m.uid} BODY[HEADER.FIELDS (FROM SUBJECT DATE)] {${head.length}}\r\n`);
        send(head);
        line(')');
      });
      line(`${tag} OK fetched`);
    } else {
      line(`${tag} BAD unknown`);
    }
  });
}

const BOX = { host: 'imap.mail.test', port: 993, mailbox: 'INBOX' };
const LOGIN = { username: 'mo@mail.test', password: 'hunter2' };
const OPTIONS = { timeoutMs: 2_000, maxListed: 20 };
const head = (from: string, subject: string, extra = '') => `From: ${from}\r\nSubject: ${subject}\r\nDate: Wed, 30 Sep 2026 07:00:00 +0000\r\n${extra}\r\n`;

test('decodeWords decodes base64 and quoted-printable encoded words in their charsets', () => {
  assert.equal(decodeWords('=?UTF-8?B?SMOpbGxv?='), 'Héllo');
  assert.equal(decodeWords('=?utf-8?q?Caf=C3=A9_au_lait?='), 'Café au lait');
  assert.equal(decodeWords('=?ISO-8859-1?Q?Gr=FC=DFe?='), 'Grüße');
  assert.equal(decodeWords('=?windows-1252?Q?=80uro?='), '€uro');
  assert.equal(decodeWords('Re: =?UTF-8?B?w6k=?= done'), 'Re: é done');
});

test('decodeWords joins adjacent encoded words but keeps the space before plain text', () => {
  assert.equal(decodeWords('=?UTF-8?Q?Hello?= =?UTF-8?Q?_world?='), 'Hello world');
  assert.equal(decodeWords('=?UTF-8?B?QQ==?=\r\n =?UTF-8?B?Qg==?='), 'AB');
  assert.equal(decodeWords('=?UTF-8?Q?A?= B'), 'A B');
});

test('decodeWords leaves plain text and words in an unknown charset alone', () => {
  assert.equal(decodeWords('Just a subject = ? not encoded'), 'Just a subject = ? not encoded');
  assert.equal(decodeWords('=?x-no-such-charset?Q?abc?='), '=?x-no-such-charset?Q?abc?=');
  assert.equal(decodeWords(''), '');
});

test('a first check only sets the baseline from UIDNEXT, read-only, and lists no mail', async () => {
  const server = mailbox({ validity: 7, mail: [{ uid: 3, head: head('a@x.test', 'Old') }, { uid: 9, head: head('b@x.test', 'Older') }] });
  const seen = await checkMailbox(server.open, BOX, LOGIN, undefined, OPTIONS);
  assert.deepEqual(seen, { cursor: { validity: '7', last: 9 }, mail: [], count: 0 });
  assert.deepEqual(server.opened, [{ host: 'imap.mail.test', port: 993 }]);
  assert.deepEqual(server.commands, ['s1 LOGIN "mo@mail.test" "hunter2"', 's2 EXAMINE "INBOX"']);
  assert.ok(!server.commands.some((c) => /\bSELECT\b|\bSTORE\b/i.test(c)), 'never SELECT, never STORE');
  assert.equal(server.destroyed(), 1, 'the socket is closed after the check');
});

test('without UIDNEXT the baseline is the highest UID a search returns, or 0 for an empty box', async () => {
  const full = mailbox({ validity: 7, uidNext: false, mail: [{ uid: 4, head: head('a', 'b') }, { uid: 12, head: head('c', 'd') }] });
  assert.deepEqual((await checkMailbox(full.open, BOX, LOGIN, undefined, OPTIONS)).cursor, { validity: '7', last: 12 });
  assert.equal(full.commands.at(-1), 's3 UID SEARCH UID 1:*');

  const empty = mailbox({ validity: 3, uidNext: false, mail: [] });
  assert.deepEqual((await checkMailbox(empty.open, BOX, LOGIN, undefined, OPTIONS)).cursor, { validity: '3', last: 0 });
});

test('a later check lists only UIDs above the cursor, oldest first, with decoded headers', async () => {
  const server = mailbox({
    validity: 7,
    mail: [
      { uid: 3, head: head('old@x.test', 'Old') },
      { uid: 5, head: head('=?UTF-8?Q?Jos=C3=A9?= <jose@x.test>', '=?UTF-8?B?RmFjdHV1cg==?= 42') },
      { uid: 8, head: head('ann@x.test', 'Second') },
    ],
  });
  const since: MailCursor = { validity: '7', last: 3 };
  const seen = await checkMailbox(server.open, BOX, LOGIN, since, OPTIONS);
  assert.equal(seen.count, 2);
  assert.deepEqual(seen.cursor, { validity: '7', last: 8 });
  assert.deepEqual(
    seen.mail.map((m) => [m.uid, m.from, m.subject, m.date]),
    [
      [5, 'José <jose@x.test>', 'Factuur 42', 'Wed, 30 Sep 2026 07:00:00 +0000'],
      [8, 'ann@x.test', 'Second', 'Wed, 30 Sep 2026 07:00:00 +0000'],
    ],
  );
  assert.ok(server.commands.includes('s3 UID SEARCH UID 4:*'));
  assert.ok(server.commands.some((c) => /^s4 UID FETCH 5,8 \(UID BODY\.PEEK\[HEADER\.FIELDS \(FROM SUBJECT DATE\)\]\)$/.test(c)), 'BODY.PEEK, so nothing is marked seen');
});

test('nothing new keeps the cursor: the `n:*` search answers the highest UID, which is filtered out', async () => {
  const server = mailbox({ validity: 7, mail: [{ uid: 3, head: head('a', 'b') }] });
  const since: MailCursor = { validity: '7', last: 3 };
  const seen = await checkMailbox(server.open, BOX, LOGIN, since, OPTIONS);
  assert.deepEqual(seen, { cursor: since, mail: [], count: 0 });
  assert.ok(!server.commands.some((c) => /FETCH/.test(c)), 'no fetch when nothing is new');
});

test('a changed UIDVALIDITY resets the baseline instead of reporting the whole box as new', async () => {
  const server = mailbox({ validity: 8, mail: [{ uid: 1, head: head('a', 'b') }, { uid: 2, head: head('c', 'd') }] });
  const seen = await checkMailbox(server.open, BOX, LOGIN, { validity: '7', last: 50 }, OPTIONS);
  assert.deepEqual(seen, { cursor: { validity: '8', last: 2 }, mail: [], count: 0 });
  assert.ok(!server.commands.some((c) => /FETCH/.test(c)));
});

test('more new mail than maxListed counts all and lists only the newest', async () => {
  const mail = Array.from({ length: 5 }, (_, n) => ({ uid: 10 + n, head: head(`m${n}@x.test`, `S${n}`) }));
  const server = mailbox({ validity: 1, mail });
  const seen = await checkMailbox(server.open, BOX, LOGIN, { validity: '1', last: 9 }, { ...OPTIONS, maxListed: 2 });
  assert.equal(seen.count, 5);
  assert.deepEqual(seen.mail.map((m) => m.uid), [13, 14]);
  assert.deepEqual(seen.cursor, { validity: '1', last: 14 });
});

test('folded headers are unfolded, control characters blanked, and values cut at 300 characters', async () => {
  const folded = `From: Ann\r\n <ann@x.test>\r\nSubject: one\r\n\ttwo\x07three ${'x'.repeat(400)}\r\nX-Other: ignored\r\n\r\n`;
  const server = mailbox({ validity: 1, mail: [{ uid: 2, head: folded }] });
  const [mail] = (await checkMailbox(server.open, BOX, LOGIN, { validity: '1', last: 1 }, OPTIONS)).mail;
  assert.equal(mail?.from, 'Ann <ann@x.test>');
  assert.equal(mail?.subject.length, 300);
  assert.ok(mail?.subject.startsWith('one two three xxx'));
  assert.equal(mail?.date, '');
});

test('a password outside printable ASCII goes as a literal, and quotes in it are escaped otherwise', async () => {
  const literal = mailbox({ validity: 1, mail: [], password: 'héél' });
  await checkMailbox(literal.open, BOX, { username: 'u', password: 'héél' }, undefined, OPTIONS);
  assert.equal(literal.commands[0], 's1 LOGIN "u" "héél"');

  const quoted = mailbox({ validity: 1, mail: [] });
  await checkMailbox(quoted.open, BOX, { username: 'u', password: 'a"b\\c' }, undefined, OPTIONS);
  assert.equal(quoted.commands[0], 's1 LOGIN "u" "a\\"b\\\\c"');
});

test('a refused login throws LoginRefused; an unavailable server is a plain error', async () => {
  const refused = mailbox({ validity: 1, mail: [], password: 'right' });
  await assert.rejects(checkMailbox(refused.open, BOX, LOGIN, undefined, OPTIONS), (error: unknown) => {
    assert.ok(error instanceof LoginRefused);
    assert.match((error as Error).message, /AUTHENTICATIONFAILED/);
    assert.ok(!(error as Error).message.includes('hunter2'), 'the error never quotes the password');
    return true;
  });

  const busy = mailbox({ validity: 1, mail: [], password: 'right', loginAnswer: 'NO [UNAVAILABLE] try later' });
  await assert.rejects(checkMailbox(busy.open, BOX, LOGIN, undefined, OPTIONS), (error: unknown) => {
    assert.ok(!(error instanceof LoginRefused));
    assert.match((error as Error).message, /^the mail server is unavailable: NO \[UNAVAILABLE\]/);
    return true;
  });
});

test('a bad greeting, a refused EXAMINE or a missing UIDVALIDITY fail the check', async () => {
  const rude = scripted(() => {}, '* BYE go away');
  await assert.rejects(checkMailbox(rude.open, BOX, LOGIN, undefined, OPTIONS), /did not greet: \* BYE go away/);

  const noBox = scripted((verb, _args, tag, send) => {
    send(verb === 'LOGIN' ? `${tag} OK in\r\n` : `${tag} NO [NONEXISTENT] no such mailbox\r\n`);
  });
  await assert.rejects(checkMailbox(noBox.open, { ...BOX, mailbox: 'Archive' }, LOGIN, undefined, OPTIONS), /^Error: could not open Archive: NO \[NONEXISTENT\]/);

  const noValidity = scripted((verb, _args, tag, send) => {
    send(verb === 'LOGIN' ? `${tag} OK in\r\n` : `* 0 EXISTS\r\n${tag} OK examined\r\n`);
  });
  await assert.rejects(checkMailbox(noValidity.open, BOX, LOGIN, undefined, OPTIONS), /sent no UIDVALIDITY/);

  const preauth = scripted((verb, _args, tag, send) => {
    send(verb === 'LOGIN' ? `${tag} OK in\r\n` : `* OK [UIDVALIDITY 4] ok\r\n* OK [UIDNEXT 1] ok\r\n${tag} OK examined\r\n`);
  }, '* PREAUTH already in');
  assert.deepEqual((await checkMailbox(preauth.open, BOX, LOGIN, undefined, OPTIONS)).cursor, { validity: '4', last: 0 });
});

test('a server that stops answering times out, and one that hangs up is an error', async () => {
  const silent = scripted(() => {});
  const started = Date.now();
  await assert.rejects(checkMailbox(silent.open, BOX, LOGIN, undefined, { ...OPTIONS, timeoutMs: 50 }), /did not answer in time/);
  assert.ok(Date.now() - started < 1_000);

  let hangUp: (() => void) | undefined;
  const closing = scripted(() => hangUp?.());
  const open: OpenSocket = (host, port) => {
    const socket = closing.open(host, port);
    hangUp = () => queueMicrotask(() => socket.destroy());
    return socket;
  };
  await assert.rejects(checkMailbox(open, BOX, LOGIN, undefined, OPTIONS), /closed the connection/);
});
