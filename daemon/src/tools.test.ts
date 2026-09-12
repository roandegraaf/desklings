import assert from 'node:assert/strict';
import test from 'node:test';
import { resolve } from 'node:path';
import { asAgent, findAgent, insertAgent } from './agents.ts';
import type { AgentTarget } from './agents.ts';
import { openDb } from './db.ts';
import { conversationFor } from './conversations.ts';
import {
  describeApproval,
  insertApproval,
  listApprovals,
  parseDeletionRequest,
  requestDeletionToolDef,
} from './approvals.ts';
import { systemExec } from './exec.ts';
import type { Exec, ExecOptions, ExecResult } from './exec.ts';
import {
  computerCommand,
  computerToolDef,
  parseComputerAction,
  performComputerAction,
} from './computer.ts';
import { commandArgv, commandToolDef, parseCommand, runCommand } from './terminal.ts';
import { HOME_APPEND, parseRemember, remember, rememberToolDef } from './home.ts';
import { nextRun, parseSchedule, parseScheduleId, scheduleTaskToolDef } from './schedules.ts';
import { COMPUTER_ACTIONS } from '@schermes/shared';
import type { Agent } from '@schermes/shared';

const SCREEN = { width: 1280, height: 800, display: { width: 1280, height: 800 } };
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
  const argv = (body: Record<string, unknown>) => computerCommand(parsed(body), SCREEN).argv;

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
  const typed = computerCommand(parsed({ action: 'type', text: '$(id) -- "quoted"' }), SCREEN);
  assert.deepEqual(typed.argv, [
    'xdotool', 'type', '--clearmodifiers', '--delay', '12', '--file', '-',
  ]);
  assert.equal(typed.input, '$(id) -- "quoted"');
  assert.equal(computerCommand(parsed({ action: 'clipboard_write', text: 'hi' }), SCREEN).input, 'hi');
});

test('a display larger than the view is shrunk for the model and its clicks mapped back', () => {
  const large = { ...SCREEN, display: { width: 1920, height: 1200 } };
  const argv = (body: Record<string, unknown>) => computerCommand(parsed(body), large).argv;

  assert.deepEqual(argv({ action: 'move', x: 640, y: 400 }), [
    'xdotool', 'mousemove', '--sync', '960', '600',
  ]);
  assert.deepEqual(argv({ action: 'move', x: 1279, y: 799 }).slice(-2), ['1919', '1199']);
  assert.deepEqual(argv({ action: 'drag', x: 0, y: 0, toX: 2, toY: 2 }).slice(10, 12), ['3', '3']);
  assert.match(String(argv({ action: 'screenshot' }).at(-1)), / -resize 1280x800! /);
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

  const result = await performComputerAction(exec, TARGET, { action: 'screenshot' }, SCREEN);
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
    performComputerAction(broken.exec, TARGET, { action: 'move', x: 1, y: 1 }, SCREEN),
    /move: Can't open display/,
  );

  const empty = fakeExec({ code: 1, stderr: 'Error: target STRING not available' });
  assert.deepEqual(await performComputerAction(empty.exec, TARGET, { action: 'clipboard_read' }, SCREEN), {
    action: 'clipboard_read',
    text: '',
  });
});

test('a truncated screenshot is refused rather than returned corrupt', async () => {
  const { exec } = fakeExec({ stdout: Buffer.from('half a png'), truncated: true });
  await assert.rejects(
    performComputerAction(exec, TARGET, { action: 'screenshot' }, SCREEN),
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

// The tool schema is what the model is told it may send; the parser is what the daemon will
// accept. These are built from the same constants, and this is the check that they stayed that
// way — a schema that promises more than the parser allows turns into a refused tool call.
function schema(def: { parameters: Record<string, unknown> }): Record<string, Record<string, unknown>> {
  return def.parameters['properties'] as Record<string, Record<string, unknown>>;
}

test('every action the computer tool advertises is an action the parser accepts', () => {
  const props = schema(computerToolDef(SCREEN));
  const sample: Record<string, Record<string, unknown>> = {
    screenshot: {},
    move: { x: 1, y: 1 },
    click: { x: 1, y: 1 },
    drag: { x: 1, y: 1, toX: 2, toY: 2 },
    scroll: { x: 1, y: 1, direction: 'down' },
    type: { text: 'hi' },
    key: { keys: 'Return' },
    clipboard_read: {},
    clipboard_write: { text: 'hi' },
  };

  const advertised = props['action']?.['enum'] as string[];
  assert.deepEqual([...advertised].sort(), [...COMPUTER_ACTIONS].sort());
  for (const action of advertised) {
    parsed({ action, ...sample[action] });
  }
});

test('the computer schema bounds are the bounds the parser enforces', () => {
  const props = schema(computerToolDef(SCREEN));

  for (const [axis, limit] of [['x', SCREEN.width], ['y', SCREEN.height]] as const) {
    assert.equal(props[axis]?.['maximum'], limit - 1);
    assert.equal(props[axis]?.['minimum'], 0);
  }
  parsed({ action: 'move', x: Number(props['x']?.['maximum']), y: Number(props['y']?.['maximum']) });
  rejected({ action: 'move', x: Number(props['x']?.['maximum']) + 1, y: 0 });

  for (const button of props['button']?.['enum'] as number[]) parsed({ action: 'click', x: 1, y: 1, button });
  rejected({ action: 'click', x: 1, y: 1, button: (props['button']?.['enum'] as number[]).length + 1 });

  for (const direction of props['direction']?.['enum'] as string[]) {
    parsed({ action: 'scroll', x: 1, y: 1, direction });
  }

  const [min, max] = [props['amount']?.['minimum'], props['amount']?.['maximum']];
  parsed({ action: 'scroll', x: 1, y: 1, direction: 'up', amount: Number(min) });
  parsed({ action: 'scroll', x: 1, y: 1, direction: 'up', amount: Number(max) });
  rejected({ action: 'scroll', x: 1, y: 1, direction: 'up', amount: Number(max) + 1 });
  rejected({ action: 'scroll', x: 1, y: 1, direction: 'up', amount: Number(min) - 1 });
});

test('the run_command schema bounds are the bounds the parser enforces', () => {
  const props = schema(commandToolDef());
  const timeout = props['timeoutMs'] as Record<string, number>;

  assert.ok('error' in parseCommand({ command: 'ls', timeoutMs: timeout['minimum']! - 1 }));
  assert.ok('error' in parseCommand({ command: 'ls', timeoutMs: timeout['maximum']! + 1 }));
  assert.ok(!('error' in parseCommand({ command: 'ls', timeoutMs: timeout['minimum']! })));
  assert.ok(!('error' in parseCommand({ command: 'ls', timeoutMs: timeout['maximum']! })));

  const longest = Number(props['command']?.['maxLength']);
  assert.ok(!('error' in parseCommand({ command: 'x'.repeat(longest) })));
  assert.ok('error' in parseCommand({ command: 'x'.repeat(longest + 1) }));
});

test('a remembered line is validated and flattened to one line', () => {
  const props = schema(rememberToolDef());
  const longest = Number(props['text']?.['maxLength']);

  assert.ok('error' in parseRemember({ text: '   ', scope: 'lasting' }));
  assert.ok('error' in parseRemember({ text: 'x', scope: 'somewhere' }));
  assert.ok('error' in parseRemember({ text: 'x' }), 'the model has to choose which file');
  assert.ok('error' in parseRemember({ text: 'x'.repeat(longest + 1), scope: 'today' }));
  assert.ok(!('error' in parseRemember({ text: 'x'.repeat(longest), scope: 'today' })));

  for (const scope of props['scope']?.['enum'] as string[]) {
    assert.ok(!('error' in parseRemember({ text: 'a fact', scope })));
  }

  const flattened = parseRemember({ text: '  two\n\nlines  ', scope: 'lasting' });
  assert.deepEqual(flattened, { text: 'two lines', scope: 'lasting' });
});

test('a remembered line reaches the file on stdin, never as an argument', async () => {
  const { exec, calls } = fakeExec();
  const written = await remember(exec, TARGET, { text: 'rm -rf / $(whoami)', scope: 'lasting' });

  assert.deepEqual(written, { path: '/home/agent-alpha/memory/MEMORY.md' });
  const call = calls[0];
  assert.equal(call?.file, 'sudo');
  assert.equal(call?.options.input, '- rm -rf / $(whoami)\n');
  assert.deepEqual(call?.args.slice(-3), [HOME_APPEND, '/home/agent-alpha/memory', 'MEMORY.md']);
  assert.ok(
    !call?.args.some((arg) => arg.includes('whoami')),
    'nothing the model wrote is in the argv',
  );
});

test('a failed append is reported rather than silently lost', async () => {
  const { exec } = fakeExec({ code: 1, stderr: 'Read-only file system' });
  const written = await remember(exec, TARGET, { text: 'a fact', scope: 'today' });

  assert.ok('error' in written);
  assert.match(written.error, /Read-only file system/);
});

test('a schedule is validated against the same bounds the tool advertises', () => {
  const props = schema(scheduleTaskToolDef());
  const longestCron = Number(props['cron']?.['maxLength']);
  const longestPrompt = Number(props['prompt']?.['maxLength']);
  const job = { cron: '0 9 * * 1-5', prompt: 'read the overnight logs' };

  assert.deepEqual(parseSchedule(job), job);
  assert.ok(!('error' in parseSchedule({ ...job, cron: '*/30 * * * * *' })), 'six fields too');
  assert.ok('error' in parseSchedule({ ...job, cron: '  ' }));
  assert.ok('error' in parseSchedule({ ...job, prompt: '  ' }));
  assert.ok('error' in parseSchedule({ ...job, cron: 'every weekday at nine' }), 'no prose');
  // Syntactically fine and never due: a row for it would sit permanently past its next run.
  assert.ok('error' in parseSchedule({ ...job, cron: '0 0 30 2 *' }), 'february the 30th');
  assert.ok('error' in parseSchedule({ ...job, cron: 'x'.repeat(longestCron + 1) }));
  assert.ok('error' in parseSchedule({ ...job, prompt: 'x'.repeat(longestPrompt + 1) }));
  assert.ok(!('error' in parseSchedule({ ...job, prompt: 'x'.repeat(longestPrompt) })));

  // An id never reaches a query as anything but a whole number.
  assert.deepEqual(parseScheduleId({ id: '3' }), { error: 'id must be a schedule id' });
  assert.ok(typeof parseScheduleId({ id: 1.5 }) === 'object');
  assert.equal(parseScheduleId({ id: 3 }), 3);
});

test('a cron expression is resolved against a given moment, never the wall clock', () => {
  const noon = Date.UTC(2026, 0, 1, 12, 0, 0);
  // Strictly after the moment it is handed, which is what stops a fired row firing again, and
  // no further away than the expression's own period.
  const hourly = nextRun('0 * * * *', noon) as number;
  assert.ok(hourly > noon && hourly <= noon + 3_600_000);
  const often = nextRun('*/5 * * * * *', noon) as number;
  assert.ok(often > noon && often <= noon + 5_000);
  assert.equal(nextRun('nonsense', noon), undefined);
  assert.equal(nextRun('0 0 30 2 *', noon), undefined);
});

test('a deletion request is checked before it can stand, and names an agent that exists', () => {
  const db = openDb(':memory:', resolve(import.meta.dirname, '../migrations'));
  const alpha = insertAgent(db, 'alpha') as Agent;
  insertAgent(db, 'bravo');

  const refuse = (args: Record<string, unknown>): string => {
    const parsed = parseDeletionRequest(db, alpha, args);
    assert.ok('error' in parsed, `expected ${JSON.stringify(args)} to be refused`);
    return parsed.error;
  };
  assert.match(refuse({ what: 'agent', agent: 'bravo' }), /reason/);
  assert.match(refuse({ what: 'agent', agent: 'bravo', reason: '  ' }), /reason/);
  assert.match(refuse({ what: 'everything', reason: 'tidying up' }), /'agent' or 'conversation'/);
  assert.match(refuse({ what: 'agent', reason: 'tidying up' }), /agent must be/);
  assert.match(refuse({ what: 'agent', agent: '../etc', reason: 'tidying up' }), /agent must be/);
  assert.match(refuse({ what: 'agent', agent: 'nobody', reason: 'tidying up' }), /no agent named/);

  assert.deepEqual(parseDeletionRequest(db, alpha, { what: 'agent', agent: 'bravo', reason: 'done' }), {
    kind: 'agent',
    target: 'bravo',
    reason: 'done',
  });
  // A thread carries no target from the model: the one it is in is the only one it can name.
  assert.deepEqual(parseDeletionRequest(db, alpha, { what: 'conversation', reason: 'finished' }), {
    kind: 'conversation',
    target: '',
    reason: 'finished',
  });

  // Its own name is allowed, and reads as itself on the owner's screen.
  const itself = parseDeletionRequest(db, alpha, { what: 'agent', agent: 'alpha', reason: 'done' });
  assert.ok(!('error' in itself));
  const standing = insertApproval(db, alpha, conversationFor(db, alpha.id), itself);
  assert.equal(describeApproval(standing), 'delete itself (alpha)');
  assert.equal(findAgent(db, 'alpha')?.name, 'alpha', 'asking deletes nothing');
  assert.equal(listApprovals(db).length, 1);

  const schema = requestDeletionToolDef().parameters as Record<string, unknown>;
  assert.deepEqual(schema['required'], ['what', 'reason']);
});
