import { resolve } from 'node:path';

function port(): number {
  const raw = process.env['SCHERMES_PORT'] ?? '7777';
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 1 || value > 65535) {
    throw new Error(`SCHERMES_PORT must be a port number, got ${JSON.stringify(raw)}`);
  }
  return value;
}

const dataDir = process.env['SCHERMES_DATA_DIR'] ?? '/var/lib/schermes';

export const config = {
  port: port(),
  // The web port is the one thing schermes exposes; everything else stays on loopback.
  host: '0.0.0.0',
  dataDir,
  dbPath: resolve(dataDir, 'schermes.db'),
  masterKeyPath: resolve(dataDir, 'master.key'),
  migrationsDir: resolve(import.meta.dirname, '../migrations'),
} as const;
