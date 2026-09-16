import { resolve } from 'node:path';
import type { Screen } from './computer.ts';

function port(): number {
  const raw = process.env['SCHERMES_PORT'] ?? '7777';
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 1 || value > 65535) {
    throw new Error(`SCHERMES_PORT must be a port number, got ${JSON.stringify(raw)}`);
  }
  return value;
}

// Screenshots are shrunk to fit this and the model's coordinates scaled back up, so a larger
// display never hands the provider an image it would downscale behind the model's back.
const VIEW = { width: 1280, height: 800 };

function screen(): Screen {
  const raw = process.env['SCHERMES_GEOMETRY'] ?? '1920x1200';
  const match = /^(\d{2,5})x(\d{2,5})$/.exec(raw);
  const width = Number(match?.[1]);
  const height = Number(match?.[2]);
  if (!Number.isInteger(width) || !Number.isInteger(height)) {
    throw new Error(`SCHERMES_GEOMETRY must be WIDTHxHEIGHT, got ${JSON.stringify(raw)}`);
  }
  const shrink = Math.min(1, VIEW.width / width, VIEW.height / height);
  return {
    width: Math.round(width * shrink),
    height: Math.round(height * shrink),
    display: { width, height },
  };
}

// A cap on how much can run at once. One agent loop is a model call plus a tool call; one task
// worker is a loop of its own on top of the agent that spawned it.
function cap(name: string, fallback: number): number {
  const raw = process.env[name] ?? String(fallback);
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 1) {
    throw new Error(`${name} must be a positive whole number, got ${JSON.stringify(raw)}`);
  }
  return value;
}

const dataDir = process.env['SCHERMES_DATA_DIR'] ?? '/var/lib/schermes';

export const config = {
  port: port(),
  maxLoops: cap('SCHERMES_MAX_LOOPS', 8),
  maxWorkers: cap('SCHERMES_MAX_WORKERS', 4),
  // The web port is the one thing schermes exposes; everything else stays on loopback.
  host: '0.0.0.0',
  dataDir,
  screen: screen(),
  dbPath: resolve(dataDir, 'schermes.db'),
  masterKeyPath: resolve(dataDir, 'master.key'),
  apnsKeyFile: process.env['SCHERMES_APNS_KEY_FILE'],
  apnsKeyId: process.env['SCHERMES_APNS_KEY_ID'],
  migrationsDir: resolve(import.meta.dirname, '../migrations'),
  // Resolves to /opt/schermes/infra/desktop on a real host, which is the path the sudoers
  // rule for create-agent-user.sh names literally. The two must keep agreeing.
  desktopScripts: resolve(import.meta.dirname, '../../infra/desktop'),
} as const;
