import { serve } from '@hono/node-server';
import { mkdirSync } from 'node:fs';
import { createApp } from './app.ts';
import { config } from './config.ts';
import { loadMasterKey } from './secrets.ts';
import { seedPushKey } from './settings.ts';
import { log } from './log.ts';
import { openDb } from './db.ts';
import { reconcileDesktops, systemDesktop } from './agents.ts';
import { reconcileAgents, startSweeper } from './loop.ts';
import { migrateModelProviders, migrateProviderSettings } from './models.ts';
import { systemExec } from './exec.ts';
import { attachVncProxy } from './vnc.ts';
import { startScheduler } from './schedules.ts';
import { closeInterruptedPasses, startIdleScheduler } from './idle.ts';
import { startTriggerScheduler } from './triggers.ts';
import { startSearchIndexer } from './search.ts';
import { startSnapshotPruner } from './snapshots.ts';
import { startImageMover, startImagePruner } from './images.ts';

mkdirSync(config.dataDir, { recursive: true });

const db = openDb(config.dbPath, config.migrationsDir);
migrateProviderSettings(db);
// Before anything can read them: a daemon that died mid-turn left rows claiming work that no
// process is doing, and transcripts a strict model endpoint would reject.
reconcileAgents(db);
closeInterruptedPasses(db);
const masterKey = loadMasterKey(config.masterKeyPath);
migrateModelProviders(db, masterKey);
if (config.apnsKeyFile !== undefined && seedPushKey(db, masterKey, config.apnsKeyFile, config.apnsKeyId)) {
  log.info('push key loaded', { file: config.apnsKeyFile });
}
const { app, runner, recorder, setupToken } = createApp({ db, masterKey, desktop: systemDesktop, exec: systemExec });

const server = serve({ fetch: app.fetch, port: config.port, hostname: config.host }, (info) => {
  log.info('daemon listening', { host: config.host, port: info.port, dataDir: config.dataDir });
  // Under `code`, not `token`: the log redacts any field whose name says token.
  if (setupToken !== undefined) log.info('first-run setup token', { code: setupToken });
  // Desktops outlive the daemon, so this adopts the ones still running and respawns the rest.
  void reconcileDesktops(db, systemDesktop);
});

// The daemon's only clock. Started after the server is listening, so a job that was due while
// the daemon was down fires into a daemon that can already answer for it. The sweep goes first:
// what a restart left queued or unread is older than anything a schedule fires now.
startSweeper(runner);
startScheduler(db, runner);
startIdleScheduler(db, systemExec, runner);
startTriggerScheduler(db, systemExec, runner, { masterKey });
startSearchIndexer(db, systemExec);
startSnapshotPruner(db, systemExec);
startImageMover(db);
startImagePruner(db);

// The owner's window onto an agent's desktop: an upgrade on the one port schermes exposes,
// proxied to Xvnc on loopback. It binds nothing of its own.
attachVncProxy(server, db, undefined, (display) => recorder.tap(display));

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.on(signal, () => {
    log.info('shutting down', { signal });
    server.close(() => process.exit(0));
  });
}
