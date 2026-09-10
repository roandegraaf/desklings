const REDACTED = '[redacted]';
const SECRET_KEY = /api[-_]?key|password|secret|token|authorization|cookie|master[-_]?key/i;

// ponytail: redaction is by key name, so a secret pasted into a free-text message still leaks.
// Routes therefore never log request bodies. Add value-based scrubbing if that stops holding.
export function redact(value: unknown, seen = new WeakSet<object>()): unknown {
  if (value instanceof Error) return { name: value.name, message: value.message };
  if (value === null || typeof value !== 'object') return value;
  if (seen.has(value)) return '[circular]';
  seen.add(value);
  if (Array.isArray(value)) return value.map((item) => redact(item, seen));
  return Object.fromEntries(
    Object.entries(value).map(([key, item]) => [
      key,
      SECRET_KEY.test(key) ? REDACTED : redact(item, seen),
    ]),
  );
}

type Level = 'info' | 'warn' | 'error';

export function format(level: Level, msg: string, fields?: Record<string, unknown>): string {
  return JSON.stringify({
    ts: new Date().toISOString(),
    level,
    msg,
    ...(redact(fields ?? {}) as Record<string, unknown>),
  });
}

function write(level: Level, msg: string, fields?: Record<string, unknown>): void {
  const stream = level === 'error' ? process.stderr : process.stdout;
  stream.write(`${format(level, msg, fields)}\n`);
}

export const log = {
  info: (msg: string, fields?: Record<string, unknown>) => write('info', msg, fields),
  warn: (msg: string, fields?: Record<string, unknown>) => write('warn', msg, fields),
  error: (msg: string, fields?: Record<string, unknown>) => write('error', msg, fields),
};
