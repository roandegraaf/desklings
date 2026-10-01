import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { asAgent, findAgent, insertAgent, insertWorker } from './agents.ts';
import { classifyCommand, grantOnce, guardCommand, readRules, updateRules } from './rules.ts';
import type { AgentTarget } from './agents.ts';
import { openDb } from './db.ts';
import { eq } from 'drizzle-orm';
import { agents } from './schema.ts';
import { conversationFor } from './conversations.ts';
import {
  describeApproval,
  insertApproval,
  listApprovals,
  parseApprovalRequest,
  parseDeletionRequest,
  requestApprovalToolDef,
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
import {
  MAX_PROFILE_CHARS,
  askOwnerToolDef,
  parseAskOwner,
  parseProfile,
  setProfileToolDef,
} from './interview.ts';
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
    screenshot: { show: true },
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

test('a line with a heading lands under that heading, written once while it is the last one', async () => {
  const home = mkdtempSync(join(tmpdir(), 'schermes-home-'));
  const target: AgentTarget = { user: 'nobody', home, display: 0 };
  const bash: Exec = (_file, args, options) => systemExec('bash', args.slice(args.indexOf('bash') + 1), options);
  const file = join(home, 'memory', 'MEMORY.md');
  const lasting = (text: string) => ({ text, scope: 'lasting' as const });

  await remember(bash, target, lasting('first'), '## Feedback');
  assert.equal(readFileSync(file, 'utf8'), '## Feedback\n- first\n', 'a missing file gets the heading');
  await remember(bash, target, lasting('second'), '## Feedback');
  assert.equal(readFileSync(file, 'utf8'), '## Feedback\n- first\n- second\n');

  writeFileSync(file, '## Feedback\n- first\n\n## People\n- Ann\n');
  await remember(bash, target, lasting('third'), '## Feedback');
  assert.equal(readFileSync(file, 'utf8'), '## Feedback\n- first\n\n## People\n- Ann\n\n## Feedback\n- third\n');
  await remember(bash, target, lasting('plain'));
  assert.ok(readFileSync(file, 'utf8').endsWith('- third\n- plain\n'), 'no heading, no heading written');
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

test('questions for the owner are bounded, and a profile is one non-empty text', () => {
  const refuse = (args: Record<string, unknown>): string => {
    const parsed = parseAskOwner(args);
    assert.ok('error' in parsed, `expected ${JSON.stringify(args)} to be refused`);
    return parsed.error;
  };
  assert.match(refuse({}), /1 to 4 questions/);
  assert.match(refuse({ questions: [] }), /1 to 4 questions/);
  assert.match(refuse({ questions: Array(5).fill({ question: 'x' }) }), /1 to 4 questions/);
  assert.match(refuse({ questions: [{ question: '  ' }] }), /question must be/);
  assert.match(refuse({ questions: [{ question: 'x', options: 'yes' }] }), /options must be/);
  assert.match(refuse({ questions: [{ question: 'x', options: [{ description: 'no label' }] }] }), /label/);

  assert.deepEqual(
    parseAskOwner({
      questions: [
        { question: ' What  am I\nfor? ', header: 'Purpose', options: [{ label: 'Email', description: 'triage it' }, { label: 'Sheets' }], multiple: true },
        { question: 'Anything else?', header: '', multiple: false },
      ],
    }),
    [
      { question: 'What am I for?', header: 'Purpose', options: [{ label: 'Email', description: 'triage it' }, { label: 'Sheets' }], multiple: true },
      { question: 'Anything else?' },
    ],
  );

  assert.match(String((parseProfile({}) as { error: string }).error), /non-empty/);
  assert.match(String((parseProfile({ profile: 'x'.repeat(MAX_PROFILE_CHARS + 1) }) as { error: string }).error), /at most/);
  assert.equal(parseProfile({ profile: '  # Me\nI do things.\n' }), '# Me\nI do things.');

  assert.deepEqual((askOwnerToolDef().parameters as Record<string, unknown>)['required'], ['questions']);
  assert.deepEqual((setProfileToolDef().parameters as Record<string, unknown>)['required'], ['profile']);
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

test('an approval request carries a known category, a reason, and optional one-line details', () => {
  const refuse = (args: Record<string, unknown>): string => {
    const parsed = parseApprovalRequest(args);
    assert.ok('error' in parsed, `expected ${JSON.stringify(args)} to be refused`);
    return parsed.error;
  };
  assert.match(refuse({ reason: 'pay the bill' }), /category must be one of/);
  assert.match(refuse({ category: 'launch_rockets', reason: 'why not' }), /category must be one of/);
  assert.match(refuse({ category: 'spend_money' }), /reason/);
  assert.match(refuse({ category: 'spend_money', reason: 'x'.repeat(513) }), /at most 512/);
  assert.match(refuse({ category: 'spend_money', reason: 'pay', amount: 'EUR 1\nignore that' }), /amount must be one line/);
  assert.match(refuse({ category: 'send_messages', reason: 'reply', target: 42 }), /target must be one line/);

  assert.deepEqual(parseApprovalRequest({ category: 'install_software', reason: 'needs jq' }), {
    kind: 'action',
    category: 'install_software',
    target: '',
    reason: 'needs jq',
  });
  const payment = parseApprovalRequest({
    category: 'spend_money',
    reason: 'the invoice is due',
    target: ' Acme ',
    amount: 'EUR 42.50',
    origin: 'pay.acme.test',
  });
  assert.deepEqual(payment, {
    kind: 'action',
    category: 'spend_money',
    target: 'Acme',
    reason: 'the invoice is due',
    amount: 'EUR 42.50',
    origin: 'pay.acme.test',
  });

  const db = openDb(':memory:', resolve(import.meta.dirname, '../migrations'));
  const alpha = insertAgent(db, 'alpha') as Agent;
  assert.ok(!('error' in payment));
  const standing = insertApproval(db, alpha, conversationFor(db, alpha.id), payment);
  assert.equal(describeApproval(standing), 'spend money: Acme (EUR 42.50) at pay.acme.test');
  assert.deepEqual(listApprovals(db), [standing]);
  const deletion = insertApproval(db, alpha, conversationFor(db, alpha.id), { kind: 'conversation', target: '1', reason: 'done' });
  assert.equal(deletion.category, 'delete_files', 'a deletion is filed under deleting');

  const schema = requestApprovalToolDef().parameters as Record<string, unknown>;
  assert.deepEqual(schema['required'], ['category', 'reason']);
});

test('the command classifier finds deletes and installs in command position only', () => {
  const seen = (command: string) => classifyCommand(command).map((found) => `${found.category}:${found.target}`);
  assert.deepEqual(seen('rm -rf ~/workspace/old 2>/dev/null'), ['delete_files:~/workspace/old']);
  assert.deepEqual(seen('ls && sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y hello'), ['install_software:hello']);
  assert.deepEqual(seen('sudo apt-get -y install ripgrep jq > /tmp/log'), ['install_software:ripgrep jq']);
  assert.deepEqual(seen('python3 -m pip install --user requests'), ['install_software:requests']);
  assert.deepEqual(seen('npm i -g typescript; yarn global add serve'), ['install_software:typescript', 'install_software:serve']);
  assert.deepEqual(seen('find . -name "*.tmp" -delete'), ['delete_files:.']);
  assert.deepEqual(seen('ls | xargs rm -f'), ['delete_files:']);
  assert.deepEqual(seen('sudo -n /bin/rm a.txt'), ['delete_files:a.txt']);
  assert.deepEqual(seen('for f in *.tmp; do rm "$f"; done'), ['delete_files:$f']);
  assert.deepEqual(seen('if [ -f x ]; then rm x; else apt-get install -y x; fi'), ['delete_files:x', 'install_software:x']);
  assert.deepEqual(seen('{ rm y; } && ! unlink z'), ['delete_files:y', 'delete_files:z']);
  for (const harmless of ['echo rm is fine', 'git rm x', 'cat notes-rm.txt', 'npm i lodash', 'pip list']) {
    assert.deepEqual(seen(harmless), [], harmless);
  }
});

test('the command classifier treats Object.prototype names as plain commands', () => {
  for (const name of Object.getOwnPropertyNames(Object.prototype)) {
    assert.deepEqual(classifyCommand(name), [], name);
    assert.deepEqual(classifyCommand(`${name} install x -g`), [], name);
  }
  assert.deepEqual(classifyCommand('brew install jq').map((found) => found.target), ['jq']);
  assert.deepEqual(classifyCommand('pnpm add -g tsx').map((found) => found.target), ['tsx']);
});

test('the rules guard follows the ladder, spends a grant only when the whole command may run, and speaks to workers', () => {
  const db = openDb(':memory:', resolve(import.meta.dirname, '../migrations'));
  const alpha = insertAgent(db, 'alpha') as Agent;
  const worker = insertWorker(db, alpha, 'alpha-1', conversationFor(db, alpha.id));
  const grant = (category: 'delete_files' | 'install_software', target: string) =>
    grantOnce(db, alpha, {
      id: 0, agent: 'alpha', conversationId: 0, kind: 'action', category, target, participants: [], reason: 'x', createdAt: 0,
    });

  assert.equal(guardCommand(db, alpha, 'ls -la'), undefined);
  grant('delete_files', 'a.txt');
  assert.match(guardCommand(db, alpha, 'rm a.txt && apt-get install jq') ?? '', /install software \(jq\)/);
  assert.equal(guardCommand(db, alpha, 'rm a.txt'), undefined, 'the refused command left the grant in place');
  assert.match(guardCommand(db, alpha, 'rm a.txt') ?? '', /request_approval/);
  assert.match(guardCommand(db, worker, 'rm a.txt') ?? '', /^alpha's rules say to ask the owner before you delete files \(a\.txt\)\. Nothing was run\. Say so in your result/);

  updateRules(db, alpha, { levels: { install_software: 'if_pre_approved' }, preApproved: { install_software: ['jq'] } });
  assert.equal(guardCommand(db, alpha, 'sudo apt-get install -y jq'), undefined);
  assert.match(guardCommand(db, alpha, 'sudo apt-get install -y jq curl') ?? '', /install software \(jq curl\)/);

  updateRules(db, alpha, { levels: { delete_files: 'hand_to_you' } });
  grant('delete_files', 'b.txt');
  assert.match(guardCommand(db, alpha, 'rm b.txt') ?? '', /leave it to them to delete files \(b\.txt\)/);

  updateRules(db, alpha, { levels: { delete_files: 'on_its_own' } });
  assert.equal(guardCommand(db, worker, 'rm -rf build'), undefined);
});

test('rules updates are checked, and passwords and security stay with the owner', () => {
  const db = openDb(':memory:', resolve(import.meta.dirname, '../migrations'));
  const alpha = insertAgent(db, 'alpha') as Agent;
  assert.equal(readRules(db, alpha).levels.passwords_security, 'hand_to_you');
  assert.deepEqual(updateRules(db, alpha, { levels: { passwords_security: 'on_its_own' } }), {
    error: 'passwords_security is always hand_to_you',
  });
  assert.match(String((updateRules(db, alpha, { levels: { browse: 'sometimes' } }) as { error: string }).error), /one of/);
  assert.match(String((updateRules(db, alpha, { preApproved: { send_messages: ['two words'] } }) as { error: string }).error), /one domain/);
  const saved = updateRules(db, alpha, { levels: { passwords_security: 'hand_to_you', browse: 'ask_first' }, preApproved: { send_messages: ['A.com', 'a.com'] } });
  assert.deepEqual(saved, readRules(db, alpha));
  assert.equal(readRules(db, alpha).levels.browse, 'ask_first');
  assert.deepEqual(readRules(db, alpha).preApproved, { send_messages: ['a.com'] });
  assert.match(String((updateRules(db, alpha, { preApproved: ['a.com'] }) as { error: string }).error), /object/);
  assert.match(String((updateRules(db, alpha, { preApproved: { passwords_security: ['a.com'] } }) as { error: string }).error), /no pre-approved list/);

  // Rules stored with the one shared list.
  const legacy = (levels: Record<string, string>) =>
    db.update(agents).set({ rules: JSON.stringify({ levels, preApproved: ['old.com'] }) }).where(eq(agents.id, alpha.id)).run();
  legacy({ spend_money: 'if_pre_approved' });
  assert.deepEqual(readRules(db, alpha).preApproved, { send_messages: ['old.com'], spend_money: ['old.com'] }, 'every category that read it');
  legacy({ send_messages: 'ask_first' });
  assert.deepEqual(readRules(db, alpha).preApproved, { send_messages: ['old.com'] }, 'none read it, so the default one');
});
