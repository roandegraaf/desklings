import { serve } from '@hono/node-server';
import { mkdirSync } from 'node:fs';
import { createApp } from './app.ts';
import { config } from './config.ts';
import { loadMasterKey } from './secrets.ts';
import { log } from './log.ts';
import { openDb } from './db.ts';

mkdirSync(config.dataDir, { recursive: true });

const db = openDb(config.dbPath, config.migrationsDir);
const masterKey = loadMasterKey(config.masterKeyPath);
const app = createApp({ db, masterKey });

const server = serve({ fetch: app.fetch, port: config.port, hostname: config.host }, (info) => {
  log.info('daemon listening', { host: config.host, port: info.port, dataDir: config.dataDir });
});

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.on(signal, () => {
    log.info('shutting down', { signal });
    server.close(() => process.exit(0));
  });
}
