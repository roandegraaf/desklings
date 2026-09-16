import { spawn } from 'node:child_process';

export type ExecResult = {
  code: number;
  stdout: Buffer;
  stderr: string;
  truncated: boolean;
};

export type ExecOptions = {
  input?: string;
  timeoutMs?: number;
  maxBytes?: number;
  /** Ends the command early with SIGTERM. `sudo` relays it, and GNU `timeout` passes it on to
   * the whole process group, so the owner stopping a turn stops the command it was running. */
  signal?: AbortSignal;
};

export type Exec = (
  file: string,
  args: readonly string[],
  options?: ExecOptions,
) => Promise<ExecResult>;

const DEFAULT_MAX_BYTES = 1024 * 1024;
const STDERR_MAX_BYTES = 64 * 1024;
// A detached grandchild can keep the pipes open after the command itself exited. Waiting for
// EOF would hang the request forever, so the streams get this long and are then dropped.
const LINGER_MS = 2_000;

/**
 * The one place the daemon reaches a shell. Everything above it takes this as a parameter, so
 * tests never spawn anything.
 */
export const systemExec: Exec = (file, args, options = {}) =>
  new Promise((resolve, reject) => {
    const maxBytes = options.maxBytes ?? DEFAULT_MAX_BYTES;
    const child = spawn(file, [...args]);
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    let size = 0;
    let errSize = 0;
    let truncated = false;
    let timer: NodeJS.Timeout | undefined;

    child.stdout.on('data', (chunk: Buffer) => {
      if (truncated || size + chunk.length > maxBytes) {
        truncated = true;
        return;
      }
      size += chunk.length;
      stdout.push(chunk);
    });

    child.stderr.on('data', (chunk: Buffer) => {
      if (errSize >= STDERR_MAX_BYTES) return;
      errSize += chunk.length;
      stderr.push(chunk);
    });

    child.on('error', reject);

    let linger: NodeJS.Timeout | undefined;
    child.on('exit', () => {
      linger = setTimeout(() => {
        child.stdout.destroy();
        child.stderr.destroy();
      }, LINGER_MS);
    });

    child.on('close', (code) => {
      clearTimeout(timer);
      clearTimeout(linger);
      resolve({
        code: code ?? 128,
        stdout: Buffer.concat(stdout),
        stderr: Buffer.concat(stderr).toString(),
        truncated,
      });
    });

    if (options.timeoutMs !== undefined) {
      timer = setTimeout(() => child.kill('SIGKILL'), options.timeoutMs);
    }
    const stop = () => child.kill('SIGTERM');
    if (options.signal?.aborted) stop();
    options.signal?.addEventListener('abort', stop, { once: true });
    child.on('close', () => options.signal?.removeEventListener('abort', stop));

    // A tool that never reads stdin makes this EPIPE, which is not an error here.
    child.stdin.on('error', () => {});
    child.stdin.end(options.input ?? '');
  });
