import { Cron } from 'croner';

export type WallClock = { year: number; month: number; day: number; hour: number; minute: number };

export function daemonTimezone(): string {
  return Intl.DateTimeFormat().resolvedOptions().timeZone;
}

/**
 * Both checks, because the two disagree at the edges: a schedule whose zone croner rejects has
 * no next run, and the tick drops a row with no next run.
 */
export function validTimezone(name: string): boolean {
  if (name.trim() === '' || name.length > 64) return false;
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: name });
    return new Cron('0 0 * * *', { timezone: name }).nextRun() !== null;
  } catch {
    return false;
  }
}

const HALF_DAY_MS = 12 * 3_600_000;

const formatters = new Map<string, Intl.DateTimeFormat>();

function formatter(timezone: string): Intl.DateTimeFormat {
  let found = formatters.get(timezone);
  if (found === undefined) {
    found = new Intl.DateTimeFormat('en-US', {
      timeZone: timezone,
      hourCycle: 'h23',
      year: 'numeric',
      month: 'numeric',
      day: 'numeric',
      hour: 'numeric',
      minute: 'numeric',
      second: 'numeric',
    });
    formatters.set(timezone, found);
  }
  return found;
}

export function wallClock(at: number, timezone: string): WallClock & { second: number } {
  const parts = Object.fromEntries(
    formatter(timezone)
      .formatToParts(new Date(at))
      .filter((part) => part.type !== 'literal')
      .map((part) => [part.type, Number(part.value)]),
  ) as Record<string, number>;
  return {
    year: parts['year'] ?? 0,
    month: parts['month'] ?? 1,
    day: parts['day'] ?? 1,
    hour: parts['hour'] ?? 0,
    minute: parts['minute'] ?? 0,
    second: parts['second'] ?? 0,
  };
}

function offsetAt(at: number, timezone: string): number {
  const local = wallClock(at, timezone);
  const asUtc = Date.UTC(local.year, local.month - 1, local.day, local.hour, local.minute, local.second);
  return asUtc - Math.floor(at / 1000) * 1000;
}

/**
 * The instant a wall-clock time names in `timezone`. Fields may overflow (hour 30 is 06:00 the
 * next day). A time skipped by a spring-forward gap lands just after the gap; one repeated by a
 * fall-back lands on its first occurrence.
 */
export function zonedTime(clock: WallClock, timezone: string): number {
  const naive = Date.UTC(clock.year, clock.month - 1, clock.day, clock.hour, clock.minute);
  const before = naive - offsetAt(naive - HALF_DAY_MS, timezone);
  const after = naive - offsetAt(naive + HALF_DAY_MS, timezone);
  const named = (at: number) => {
    const local = wallClock(at, timezone);
    return Date.UTC(local.year, local.month - 1, local.day, local.hour, local.minute) === naive;
  };
  const matching = [before, after].filter(named);
  return matching.length === 0 ? before : Math.min(...matching);
}

export function startOfDay(at: number, timezone: string): number {
  const { year, month, day } = wallClock(at, timezone);
  return zonedTime({ year, month, day, hour: 0, minute: 0 }, timezone);
}
