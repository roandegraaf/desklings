import type { CommandRequest, CommandResult } from '@schermes/shared';
import { asAgent } from './agents.ts';
import type { AgentTarget } from './agents.ts';
import type { Exec } from './exec.ts';
import type { ToolDef } from './provider.ts';

const DEFAULT_TIMEOUT_MS = 120_000;
const MIN_TIMEOUT_MS = 1_000;
const MAX_TIMEOUT_MS = 600_000;
const MAX_COMMAND_CHARS = 16_384;
const KILL_AFTER_S = 5;
const TIMEOUT_EXIT = 124;

// `timeout` inside the sudo does the killing. This only stops a wedged `sudo` from leaving a
// promise the agent loop would wait on forever.
const BACKSTOP_MS = 10_000;

export type ResolvedCommand = Required<CommandRequest>;

export function parseCommand(body: Record<string, unknown>): ResolvedCommand | { error: string } {
  const command = body['command'];
  if (typeof command !== 'string' || command.trim() === '') {
    return { error: 'command must be a non-empty string' };
  }
  if (command.length > MAX_COMMAND_CHARS) {
    return { error: `command must be at most ${MAX_COMMAND_CHARS} characters` };
  }

  const timeoutMs = body['timeoutMs'] ?? DEFAULT_TIMEOUT_MS;
  if (
    typeof timeoutMs !== 'number' ||
    !Number.isInteger(timeoutMs) ||
    timeoutMs < MIN_TIMEOUT_MS ||
    timeoutMs > MAX_TIMEOUT_MS
  ) {
    return { error: `timeoutMs must be an integer between ${MIN_TIMEOUT_MS} and ${MAX_TIMEOUT_MS}` };
  }

  const background = body['background'] ?? false;
  if (typeof background !== 'boolean') return { error: 'background must be a boolean' };

  return { command, timeoutMs, background };
}

/** Built from the constants `parseCommand` enforces, so the two cannot disagree. */
export function commandToolDef(): ToolDef {
  return {
    name: 'run_command',
    description:
      'Run a shell command as your own Linux user, from your home directory. Returns stdout, ' +
      'stderr and the exit code. Use it to read and write files, install packages with sudo ' +
      'apt-get, and launch desktop applications (with background true, so they keep running).',
    parameters: {
      type: 'object',
      properties: {
        command: { type: 'string', maxLength: MAX_COMMAND_CHARS },
        timeoutMs: {
          type: 'integer',
          minimum: MIN_TIMEOUT_MS,
          maximum: MAX_TIMEOUT_MS,
          description: `how long to wait before killing it, ${DEFAULT_TIMEOUT_MS} by default`,
        },
        background: {
          type: 'boolean',
          description: 'detach the command and return at once, discarding its output',
        },
      },
      required: ['command'],
      additionalProperties: false,
    },
  };
}

export function commandArgv(request: ResolvedCommand): string[] {
  if (request.background) {
    // `exec` replaces the shell's own descriptors, not just the ones the command inherits.
    // Redirecting the command alone leaves bash holding the daemon's stdout pipe for as long
    // as the detached job runs, and the request never completes.
    return ['setsid', '--fork', 'bash', '-c', `exec >/dev/null 2>&1 </dev/null\n${request.command}`];
  }
  // GNU timeout runs the command in its own process group and signals the whole group, so a
  // command that spawned children does not leave them behind. 124 is its "I killed it" code.
  return [
    'timeout',
    `--kill-after=${KILL_AFTER_S}`,
    String(Math.ceil(request.timeoutMs / 1000)),
    'bash',
    '-c',
    request.command,
  ];
}

export async function runCommand(
  exec: Exec,
  target: AgentTarget,
  request: ResolvedCommand,
): Promise<CommandResult> {
  const result = await exec('sudo', asAgent(target, commandArgv(request)), {
    timeoutMs: request.timeoutMs + BACKSTOP_MS,
  });

  if (request.background) {
    return {
      exitCode: result.code,
      stdout: '',
      stderr: result.stderr,
      timedOut: false,
      background: true,
    };
  }

  const stdout = result.truncated
    ? `${result.stdout.toString()}\n[output truncated]`
    : result.stdout.toString();

  return {
    exitCode: result.code,
    stdout,
    stderr: result.stderr,
    // ponytail: a command that exits 124 by itself reads as a timeout. Telling them apart needs
    // a wrapper that reports the signal instead; not worth it until something trips over it.
    timedOut: result.code === TIMEOUT_EXIT,
    background: false,
  };
}
