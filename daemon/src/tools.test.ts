import assert from 'node:assert/strict';
import test from 'node:test';
import { asAgent } from './agents.ts';
import type { AgentTarget } from './agents.ts';
import { systemExec } from './exec.ts';
import type { Exec, ExecOptions, ExecResult } from './exec.ts';
import {
  computerCommand,
  parseComputerAction,
  performComputerAction,
} from './computer.ts';
import { commandArgv, parseCommand, runCommand } from './terminal.ts';

const SCREEN = { width: 1280, height: 800 };
const TARGET: AgentTarget = { user: 'agent-alpha', home: '/home/agent-alpha', display: 3 };

type Call = { file: string; args: readonly string[]; options: ExecOptions };

/** Stands in for the spawn boundary: records the argv and answers with a canned result. */
function fakeExec(result: Partial<ExecResult> = {}) {
  const calls: Call[] = [];
  const exec: Exec = (file, args, options = {}) => {
    calls.push({ file, args, options });
    return Promise.resolve({
      code: 0,
      stdout: Buffer.alloc(0),
      stderr: '',
      truncated: false,
      ...result,
    });
  };
  return { exec, calls };
}

function parsed(body: Record<string, unknown>) {
  const action = parseComputerAction(body, SCREEN);
  assert.ok(!('error' in action), `expected ${JSON.stringify(body)} to parse`);
  return action;
}

function rejected(body: Record<string, unknown>): string {
  const action = parseComputerAction(body, SCREEN);
  assert.ok('error' in action, `expected ${JSON.stringify(body)} to be rejected`);
  return action.error;
}

test('an unknown action is rejected before anything reaches a shell', () => {
  for (const body of [{}, { action: 'reboot' }, { action: 42 }, { action: 'Screenshot' }]) {
    assert.match(rejected(body), /unknown action/);
  }
});

test('coordinates must be integers inside the screen', () => {
  for (const point of [
    { x: -1, y: 0 },
    { x: 0, y: -1 },
    { x: 1280, y: 0 },
    { x: 0, y: 800 },
    { x: 10.5, y: 10 },
    { x: '10', y: 10 },
    { y: 10 },
    {},
  ]) {
    rejected({ action: 'move', ...point });
  }
  assert.deepEqual(parsed({ action: 'move', x: 0, y: 0 }), { action: 'move', x: 0, y: 0 });
  assert.deepEqual(parsed({ action: 'move', x: 1279, y: 799 }), {
    action: 'move',
    x: 1279,
    y: 799,
  });
});

test('the other action fields are validated too', () => {
  rejected({ action: 'click', x: 1, y: 1, button: 4 });
  rejected({ action: 'drag', x: 1, y: 1, toX: 9000, toY: 1 });
  rejected({ action: 'scroll', x: 1, y: 1, direction: 'sideways' });
  rejected({ action: 'scroll', x: 1, y: 1, direction: 'up', amount: 0 });
  rejected({ action: 'type', text: '' });
  rejected({ action: 'type', text: 'x'.repeat(2001) });
  rejected({ action: 'key', keys: 'ctrl+l; rm -rf /' });
  rejected({ action: 'key', keys: '' });
  rejected({ action: 'clipboard_write', text: 12 });

  // Omitted button and amount take a default rather than being rejected.
  assert.deepEqual(parsed({ action: 'click', x: 1, y: 1 }), {
    action: 'click', x: 1, y: 1, button: 1,
  });
  assert.deepEqual(parsed({ action: 'scroll', x: 1, y: 1, direction: 'down' }), {
    action: 'scroll', x: 1, y: 1, direction: 'down', amount: 3,
  });
  assert.deepEqual(parsed({ action: 'key', keys: '  ctrl+shift+t   Return ' }), {
    action: 'key', keys: 'ctrl+shift+t Return',
  });
});

test('every action becomes the argv it should, run as the agent', () => {
  const argv = (body: Record<string, unknown>) => computerCommand(parsed(body)).argv;

  assert.deepEqual(argv({ action: 'move', x: 10, y: 20 }), [
    'xdotool', 'mousemove', '--sync', '10', '20',
  ]);
  assert.deepEqual(argv({ action: 'click', x: 10, y: 20, button: 3 }), [
    'xdotool', 'mousemove', '--sync', '10', '20', 'click', '--clearmodifiers', '3',
  ]);
  assert.deepEqual(argv({ action: 'drag', x: 1, y: 2, toX: 3, toY: 4 }), [
    'xdotool',
    'mousemove', '--sync', '1', '2',
    'mousedown', '--clearmodifiers', '1',
    'mousemove', '--sync', '3', '4',
    'mouseup', '--clearmodifiers', '1',
  ]);
  assert.deepEqual(argv({ action: 'scroll', x: 1, y: 2, direction: 'down', amount: 5 }), [
    'xdotool', 'mousemove', '--sync', '1', '2', 'click', '--clearmodifiers', '--repeat', '5', '5',
  ]);
  assert.deepEqual(argv({ action: 'scroll', x: 1, y: 2, direction: 'up', amount: 1 }).at(-1), '4');
  assert.deepEqual(argv({ action: 'key', keys: 'ctrl+l Return' }), [
    'xdotool', 'key', '--clearmodifiers', 'ctrl+l', 'Return',
  ]);
  assert.deepEqual(argv({ action: 'clipboard_read' }), [
    'xclip', '-selection', 'clipboard', '-o',
  ]);

  // Free text rides in on stdin, so it never needs quoting and never lands in the process list.
  const typed = computerCommand(parsed({ action: 'type', text: '$(id) -- "quoted"' }));
  assert.deepEqual(typed.argv, [
    'xdotool', 'type', '--clearmodifiers', '--delay', '12', '--file', '-',
  ]);
  assert.equal(typed.input, '$(id) -- "quoted"');
  assert.equal(computerCommand(parsed({ action: 'clipboard_write', text: 'hi' })).input, 'hi');
});

test('the sudo prefix carries every variable sudo strips', () => {
  const args = asAgent(TARGET, ['xdotool', 'key', 'Return']);
  assert.deepEqual(args, [
    '-n', '-u', 'agent-alpha',
    'env', '--chdir=/home/agent-alpha',
    'HOME=/home/agent-alpha',
    'USER=agent-alpha',
    'LOGNAME=agent-alpha',
    'DISPLAY=:3',
    'XAUTHORITY=/home/agent-alpha/.Xauthority',
    'xdotool', 'key', 'Return',
  ]);
  // --chdir must precede the assignments or env takes it as the command to run.
  assert.ok(args.indexOf('--chdir=/home/agent-alpha') < args.indexOf('HOME=/home/agent-alpha'));
});

test('a screenshot comes back as base64 and the raw bytes stay out of the result', async () => {
  const png = Buffer.from('\x89PNG\r\n\x1a\nfake', 'binary');
  const { exec, calls } = fakeExec({ stdout: png });

  const result = await performComputerAction(exec, TARGET, { action: 'screenshot' });
  assert.deepEqual(result, {
    action: 'screenshot',
    image: { mediaType: 'image/png', base64: png.toString('base64') },
  });
  assert.equal(calls[0]?.file, 'sudo');
  assert.match(String(calls[0]?.args.at(-1)), /^scrot -o -F "\$HOME\/[^"]+" && cat /);
});

test('a failed action is reported as a failure, but an empty clipboard is not', async () => {
  const broken = fakeExec({ code: 1, stderr: 'Can\'t open display' });
  await assert.rejects(
    performComputerAction(broken.exec, TARGET, { action: 'move', x: 1, y: 1 }),
    /move: Can't open display/,
  );

  const empty = fakeExec({ code: 1, stderr: 'Error: target STRING not available' });
  assert.deepEqual(await performComputerAction(empty.exec, TARGET, { action: 'clipboard_read' }), {
    action: 'clipboard_read',
    text: '',
  });
});

test('a truncated screenshot is refused rather than returned corrupt', async () => {
  const { exec } = fakeExec({ stdout: Buffer.from('half a png'), truncated: true });
  await assert.rejects(
    performComputerAction(exec, TARGET, { action: 'screenshot' }),
    /size limit/,
  );
});

test('a command request is validated and defaulted', () => {
  for (const body of [
    {},
    { command: '   ' },
    { command: 5 },
    { command: 'ls', timeoutMs: 0 },
    { command: 'ls', timeoutMs: 600_001 },
    { command: 'ls', timeoutMs: 1.5 },
    { command: 'ls', background: 'yes' },
    { command: 'x'.repeat(16_385) },
  ]) {
    assert.ok('error' in parseCommand(body), `expected ${JSON.stringify(body)} to be rejected`);
  }

  assert.deepEqual(parseCommand({ command: 'ls' }), {
    command: 'ls',
    timeoutMs: 120_000,
    background: false,
  });
});

test('a foreground command is wrapped in timeout and a background one is detached', () => {
  assert.deepEqual(commandArgv({ command: 'sleep 30', timeoutMs: 4_500, background: false }), [
    'timeout', '--kill-after=5', '5', 'bash', '-c', 'sleep 30',
  ]);

  const background = commandArgv({ command: 'sleep 30 # later', timeoutMs: 1_000, background: true });
  assert.deepEqual(background.slice(0, 4), ['setsid', '--fork', 'bash', '-c']);
  // `exec` first, so the shell drops the daemon's pipes instead of holding them open, and the
  // command comes last so a trailing comment cannot swallow anything.
  assert.equal(background.at(-1), 'exec >/dev/null 2>&1 </dev/null\nsleep 30 # later');
});

test('a non-zero exit is reported, and 124 is reported as a timeout', async () => {
  const failed = fakeExec({ code: 3, stdout: Buffer.from('partial\n'), stderr: 'boom\n' });
  assert.deepEqual(
    await runCommand(failed.exec, TARGET, { command: 'exit 3', timeoutMs: 1_000, background: false }),
    { exitCode: 3, stdout: 'partial\n', stderr: 'boom\n', timedOut: false, background: false },
  );

  const killed = fakeExec({ code: 124 });
  const result = await runCommand(killed.exec, TARGET, {
    command: 'sleep 60',
    timeoutMs: 2_000,
    background: false,
  });
  assert.equal(result.timedOut, true);
  assert.equal(result.exitCode, 124);
  // The backstop must outlast the timeout the command itself enforces.
  assert.ok((killed.calls[0]?.options.timeoutMs ?? 0) > 2_000);
});

test('output past the cap is truncated visibly', async () => {
  const { exec } = fakeExec({ stdout: Buffer.from('first megabyte'), truncated: true });
  const result = await runCommand(exec, TARGET, {
    command: 'cat /dev/urandom',
    timeoutMs: 1_000,
    background: false,
  });
  assert.equal(result.stdout, 'first megabyte\n[output truncated]');
});

test('a background command returns without any output', async () => {
  const { exec } = fakeExec({ stdout: Buffer.from('ignored') });
  assert.deepEqual(
    await runCommand(exec, TARGET, { command: 'sleep 60', timeoutMs: 1_000, background: true }),
    { exitCode: 0, stdout: '', stderr: '', timedOut: false, background: true },
  );
});

test('the spawn boundary feeds stdin, caps output, and does not wait on a detached grandchild', async () => {
  const piped = await systemExec('cat', [], { input: 'from stdin' });
  assert.equal(piped.code, 0);
  assert.equal(piped.stdout.toString(), 'from stdin');
  assert.equal(piped.truncated, false);

  const capped = await systemExec('sh', ['-c', 'head -c 100000 /dev/zero'], { maxBytes: 1024 });
  assert.equal(capped.truncated, true);
  assert.ok(capped.stdout.length <= 1024);

  // The child exits at once but its grandchild keeps the pipe. `close` waits for stdio EOF, so
  // without the linger guard this would resolve ten seconds late.
  const started = Date.now();
  const orphaned = await systemExec('sh', ['-c', 'echo hi; (sleep 10 &); exit 7']);
  assert.equal(orphaned.code, 7);
  assert.equal(orphaned.stdout.toString(), 'hi\n');
  assert.ok(Date.now() - started < 8_000, 'resolved without waiting for the detached child');
});
