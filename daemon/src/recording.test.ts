import assert from 'node:assert/strict';
import test from 'node:test';
import type { AgentTarget } from './agents.ts';
import type { Focused } from './browser.ts';
import type { Image } from './provider.ts';
import { createRecorder, MAX_SHOTS, MAX_STEPS, rfbInput, secrecy, shownLine, SHOWN_PREFIX } from './recording.ts';
import type { InputEvent, RecorderDeps } from './recording.ts';

const TARGET: AgentTarget = { user: 'agent-alpha', home: '/home/agent-alpha', display: 7 };
const SCREEN = { width: 1280, height: 800, display: { width: 2560, height: 1600 } };
const HANDSHAKE = Buffer.from('RFB 003.008\n\x01\x01', 'latin1');

const pointer = (mask: number, x: number, y: number) => Buffer.from([5, mask, x >> 8, x & 255, y >> 8, y & 255]);
const key = (keysym: number, down: boolean) => {
  const message = Buffer.alloc(8);
  message[0] = 4;
  message[1] = down ? 1 : 0;
  message.writeUInt32BE(keysym, 4);
  return message;
};
const tap = (keysym: number) => Buffer.concat([key(keysym, true), key(keysym, false)]);
const typed = (text: string) => Buffer.concat([...text].map((char) => tap(char.codePointAt(0) as number)));
const click = (x: number, y: number) => Buffer.concat([pointer(1, x, y), pointer(0, x, y)]);
const settle = () => new Promise((done) => setTimeout(done, 5));

function harness(focused: (display: number) => Promise<Focused> = () => Promise.resolve('elsewhere')) {
  let clock = 1_000;
  let shotNo = 0;
  const deps: RecorderDeps = {
    screen: SCREEN,
    focused,
    now: () => clock,
    shotDelayMs: 1,
    screenshot: () => Promise.resolve<Image>({ mediaType: 'image/png', base64: `shot${(shotNo += 1)}` }),
  };
  const recorder = createRecorder(deps);
  recorder.start(TARGET);
  const feed = recorder.tap(TARGET.display);
  feed(HANDSHAKE);
  return {
    recorder,
    feed,
    advance(ms: number) {
      clock += ms;
    },
  };
}

test('the RFB client stream is read past the handshake, split or joined, and pointer and key events come out', () => {
  const events: InputEvent[] = [];
  const read = rfbInput((event) => events.push(event));
  const stream = Buffer.concat([
    HANDSHAKE,
    Buffer.from([0, 0, 0, 0, ...new Array(16).fill(0)]),
    Buffer.from([2, 0, 0, 2, 0, 0, 0, 7, 0, 0, 0, 0]),
    Buffer.from([3, 1, 0, 0, 0, 0, 5, 0, 3, 32]),
    pointer(1, 300, 20),
    key(0x61, true),
    Buffer.from([6, 0, 0, 0, 0, 0, 0, 3, 120, 121, 122]),
  ]);
  for (let at = 0; at < stream.length; at += 3) read(stream.subarray(at, at + 3));
  assert.deepEqual(events, [
    { kind: 'pointer', mask: 1, x: 300, y: 20 },
    { kind: 'key', down: true, keysym: 0x61 },
  ]);

  read(Buffer.from([99, 0, 0]));
  read(pointer(0, 1, 1));
  assert.equal(events.length, 2, 'an unknown message stops the socket being read at all');
});

test('clicks, a double click, a drag, scrolls, typing with a backspace and chords become steps in model coordinates', async () => {
  const { recorder, feed, advance } = harness();
  await settle();
  feed(click(200, 100));
  advance(1_000);
  feed(click(800, 400));
  advance(100);
  feed(click(802, 401));
  advance(1_000);
  feed(Buffer.concat([pointer(1, 0, 0), pointer(1, 100, 100), pointer(0, 400, 200)]));
  feed(Buffer.concat([pointer(8, 10, 10), pointer(0, 10, 10), pointer(8, 10, 10), pointer(0, 10, 10)]));
  feed(typed('Helo'));
  feed(tap(0xff08));
  feed(typed('lo W'));
  feed(Buffer.concat([key(0xffeb, true), tap(0x63), key(0xffeb, false)]));
  feed(Buffer.concat([key(0xffe1, true), tap(0xff09), key(0xffe1, false)]));
  feed(tap(0xff0d));
  await settle();

  const recording = await recorder.stop(TARGET.display);
  assert.ok(recording !== undefined);
  assert.deepEqual(
    recording.steps.map(({ at: _at, shot: _shot, ...step }) => step),
    [
      { kind: 'click', x: 100, y: 50, button: 'left' },
      { kind: 'click', x: 400, y: 200, button: 'left', double: true },
      { kind: 'drag', x: 0, y: 0, toX: 200, toY: 100, button: 'left' },
      { kind: 'scroll', x: 5, y: 5, direction: 'up', amount: 2 },
      { kind: 'type', text: 'Hello W' },
      { kind: 'key', keys: 'super+c' },
      { kind: 'key', keys: 'shift+Tab' },
      { kind: 'key', keys: 'Return' },
    ],
  );
  assert.equal(recording.shots[0]?.base64, 'shot1', 'the first shot is the screen at the start');
  assert.equal(recording.steps[0]?.shot, 2);
  assert.equal(recorder.state(TARGET.display), undefined, 'stopping ends it');
});

test('input on another display, or with no recording running, is not recorded', async () => {
  const { recorder, feed } = harness();
  const other = recorder.tap(8);
  other(HANDSHAKE);
  other(click(10, 10));
  feed(click(20, 20));
  const recording = await recorder.stop(TARGET.display);
  assert.equal(recording?.steps.length, 1);
  feed(click(30, 30));
  assert.equal(await recorder.stop(TARGET.display), undefined);
});

test('steps and shots are capped and the recording says it was cut short', async () => {
  const { recorder, feed, advance } = harness();
  for (let n = 0; n < MAX_STEPS + 20; n += 1) {
    advance(600);
    feed(click(n * 20, 10));
    await settle();
  }
  const state = recorder.state(TARGET.display);
  assert.deepEqual([state?.steps, state?.truncated], [MAX_STEPS, true]);
  const recording = await recorder.stop(TARGET.display);
  assert.equal(recording?.steps.length, MAX_STEPS);
  assert.equal(recording?.shots.length, MAX_SHOTS);
  assert.equal(recording?.truncated, true);
});

test('a recording past its time limit takes no more steps', async () => {
  const { recorder, feed, advance } = harness();
  feed(click(10, 10));
  advance(31 * 60_000);
  feed(click(20, 20));
  const recording = await recorder.stop(TARGET.display);
  assert.deepEqual([recording?.steps.length, recording?.truncated], [1, true]);
});

test('what the browser says has focus decides whether typing is secret', () => {
  assert.deepEqual(secrecy('elsewhere'), { secret: false, masked: false });
  assert.deepEqual(secrecy({ type: 'email', autocomplete: 'username' }), { secret: false, masked: false });
  assert.deepEqual(secrecy({ type: 'password', autocomplete: '' }), { secret: true, masked: true });
  assert.deepEqual(secrecy({ type: 'text', autocomplete: 'one-time-code' }), { secret: true, masked: false });
  assert.deepEqual(secrecy({ type: 'text', autocomplete: 'cc-number' }), { secret: true, masked: false });
  assert.deepEqual(secrecy({ frame: true }), { secret: true, masked: false }, 'a frame it cannot see into is a secret');
  assert.deepEqual(secrecy({ error: 'the browser does not answer' }), { secret: true, masked: false }, 'fails closed');
});

test('a password is never kept, and screenshots go on because the field is masked on screen', async () => {
  let field: Focused = { type: 'email', autocomplete: 'username' };
  const { recorder, feed, advance } = harness(() => Promise.resolve(field));
  feed(click(10, 10));
  feed(typed('me@example.com'));
  await settle();
  feed(tap(0xff09));
  field = { type: 'password', autocomplete: 'current-password' };
  feed(typed('hunter2-secret'));
  await settle();
  advance(1_000);
  feed(tap(0xff0d));
  await settle();
  const recording = await recorder.stop(TARGET.display);
  assert.ok(recording !== undefined);
  assert.ok(!JSON.stringify(recording).includes('hunter2'), 'no trace of the password');
  assert.deepEqual(
    recording.steps.filter((step) => step.kind === 'type').map(({ at: _at, shot: _shot, ...step }) => step),
    [{ kind: 'type', text: 'me@example.com' }, { kind: 'type', text: '', secret: true }],
  );
  assert.ok((recording.steps.at(-1)?.shot ?? 0) > 0, 'Return after a masked password still gets its shot');
});

test('a visible secret (Secret on, or a one-time code) stops all screenshots from then on', async () => {
  for (const how of ['owner', 'otp'] as const) {
    let field: Focused = 'elsewhere';
    const { recorder, feed, advance } = harness(() => Promise.resolve(field));
    feed(click(10, 10));
    await settle();
    const before = recorder.state(TARGET.display)?.shots ?? 0;
    assert.ok(before >= 2);
    if (how === 'owner') recorder.setSecret(TARGET.display, true);
    else field = { type: 'text', autocomplete: 'one-time-code' };
    feed(typed('492817'));
    await settle();
    recorder.setSecret(TARGET.display, false);
    field = 'elsewhere';
    advance(1_000);
    feed(click(50, 50));
    feed(tap(0xff0d));
    await settle();
    const recording = await recorder.stop(TARGET.display);
    assert.ok(recording !== undefined);
    assert.ok(!JSON.stringify(recording).includes('492817'), how);
    assert.equal(recording.shots.length, before, `${how}: no shot after the secret`);
    assert.equal(recording.steps.at(-1)?.shot, undefined);
  }
});

test('a focus check that fails or is slow keeps the typing secret and holds back the shot', async () => {
  let answer: (focused: Focused) => void = () => {};
  const { recorder, feed } = harness(() => new Promise((done) => (answer = done)));
  feed(typed('s3cr3t'));
  feed(click(40, 40));
  await settle();
  const shots = recorder.state(TARGET.display)?.shots;
  const stopping = recorder.stop(TARGET.display);
  answer({ error: 'the page did not answer' });
  const recording = await stopping;
  assert.ok(!JSON.stringify(recording).includes('s3cr3t'));
  assert.equal(recording?.shots.length, shots);
  assert.equal(recording?.steps[0]?.kind === 'type' && recording.steps[0].secret, true);
});

test('the hand-off line lists the steps, the saved place, the skill frontmatter and the routine offer', () => {
  const line = shownLine(
    {
      startedAt: 0,
      endedAt: 42_000,
      truncated: false,
      shots: [{ mediaType: 'image/png', base64: 'a' }, { mediaType: 'image/png', base64: 'b' }],
      steps: [
        { kind: 'click', at: 1, x: 10, y: 20, button: 'left', shot: 2 },
        { kind: 'type', at: 2, text: '', secret: true },
        { kind: 'key', at: 3, keys: 'Return' },
      ],
    },
    '/home/agent-alpha/recordings/20260930-120000',
    'sheet',
  );
  assert.ok(line.startsWith(`${SHOWN_PREFIX}: 3 steps in 42 s.`));
  assert.match(line, /^1\. Click at \(10, 20\)\. \(shot 2\)$/m);
  assert.match(line, /^2\. Type something secret\. It was not recorded/m);
  assert.match(line, /^3\. Press Return\.$/m);
  assert.match(line, /saved in \/home\/agent-alpha\/recordings\/20260930-120000\//);
  assert.match(line, /~\/skills\/<short-name>\/SKILL\.md/);
  assert.match(line, /^---\nname: <short-name>\ndescription: .+\n---$/m);
  assert.match(line, /ask_owner/);
  assert.match(line, /schedule_task/);
});
