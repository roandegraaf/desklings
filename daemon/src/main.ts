import { serve } from '@hono/node-server';
import { mkdirSync } from 'node:fs';
import { createApp } from './app.ts';
import { config } from './config.ts';
import { loadMasterKey } from './secrets.ts';
import { log } from './log.ts';
import { openDb } from './db.ts';
import { reconcileDesktops, systemDesktop } from './agents.ts';
import { reconcileAgents } from './loop.ts';
import { systemExec } from './exec.ts';
import { attachVncProxy } from './vnc.ts';
import { startScheduler } from './schedules.ts';

mkdirSync(config.dataDir, { recursive: true });

const db = openDb(config.dbPath, config.migrationsDir);
// Before anything can read them: a daemon that died mid-turn left rows claiming work that no
// process is doing, and transcripts a strict model endpoint would reject.
reconcileAgents(db);
const masterKey = loadMasterKey(config.masterKeyPath);
const { app, runner } = createApp({ db, masterKey, desktop: systemDesktop, exec: systemExec });

const server = serve({ fetch: app.fetch, port: config.port, hostname: config.host }, (info) => {
  log.info('daemon listening', { host: config.host, port: info.port, dataDir: config.dataDir });
  // Desktops outlive the daemon, so this adopts the ones still running and respawns the rest.
  void reconcileDesktops(db, systemDesktop);
});

// The daemon's only clock. Started after the server is listening, so a job that was due while
// the daemon was down fires into a daemon that can already answer for it.
startScheduler(db, runner);

// The owner's window onto an agent's desktop: an upgrade on the one port schermes exposes,
// proxied to Xvnc on loopback. It binds nothing of its own.
attachVncProxy(server, db);

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.on(signal, () => {
    log.info('shutting down', { signal });
    server.close(() => process.exit(0));
  });
}
