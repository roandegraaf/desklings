import type { Agent, CantUndo, FileChanges, Message } from '@schermes/shared';
import { agentTarget, asAgent, isWorker, listAgents } from './agents.ts';
import { APPROVED, GO_AHEAD } from './approvals.ts';
import { SYSTEM_SENDER } from './conversations.ts';
import type { Db } from './db.ts';
import type { Exec } from './exec.ts';
import { FILLED } from './forms.ts';
import { MAIL_SENDERS } from './idle.ts';
import { log } from './log.ts';
import { classifyCommand, commandNames } from './rules.ts';
import { TRIGGER_SENDER } from './triggers.ts';

export const SNAPSHOTS = 'schermes-snapshots';
export const KEEP_SNAPSHOTS_MS = 7 * 24 * 60 * 60 * 1_000;
const PRUNE_EVERY_MS = 60 * 60 * 1_000;
const SNAPSHOT_TIMEOUT_MS = 5 * 60 * 1_000;
const MAX_LISTED = 5_000;
const MAX_MANIFEST_BYTES = 64 * 1024 * 1024;

/**
 * One script, four modes, run as the agent in its home. A snapshot is `<mark>-<epoch ms>` in
 * ~/.schermes-snapshots: a NUL-separated manifest (`size mtime path`) and a tar of exactly those
 * files. The mark is the newest message id when the turn started. An unchanged home hard-links the
 * previous tar, which is safe because an archive is never written again.
 */
// ponytail: a full tar per changed turn; a home of many gigabytes wants rsync --link-dest instead.
const SCRIPT = `set -u
d="$HOME/.schermes-snapshots"
cd "$HOME" || exit 1
manifest() {
  find . -mindepth 1 \\( -name '.*' -o -name node_modules \\) -prune -o ! -type d -printf '%s %T@ %P\\0'
}
case $1 in
list)
  [ -d "$d" ] || exit 0
  ls -- "$d" | grep -E '^[0-9]+-[0-9]+\\.list$' || true
  ;;
snapshot)
  mkdir -p "$d" || exit 1
  manifest > "$d/.new.list" || exit 1
  prev=$(ls -- "$d" | grep -E '^[0-9]+-[0-9]+\\.list$' | sort -n | tail -n 1)
  if [ -n "$prev" ] && [ -f "$d/\${prev%.list}.tgz" ] && cmp -s "$d/.new.list" "$d/$prev"; then
    ln -f "$d/\${prev%.list}.tgz" "$d/.new.tgz" || exit 1
  else
    sed -z 's/^[^ ]* [^ ]* //' "$d/.new.list" \\
      | tar -czf "$d/.new.tgz" --null --no-recursion --verbatim-files-from --ignore-failed-read --warning=no-file-changed -T -
    [ $? -le 1 ] || exit 1
  fi
  mv -f "$d/.new.tgz" "$d/$2.tgz" && mv -f "$d/.new.list" "$d/$2.list"
  ;;
prune)
  [ -d "$d" ] || exit 0
  for f in "$d"/*.list; do
    [ -e "$f" ] || continue
    t=\${f##*-}; t=\${t%.list}
    case $t in ''|*[!0-9]*) continue;; esac
    [ "$t" -lt "$2" ] && rm -f -- "$f" "\${f%.list}.tgz"
  done
  exit 0
  ;;
diff)
  [ -f "$d/$2.list" ] || exit 3
  cat -- "$d/$2.list"
  printf '\\0'
  manifest
  ;;
restore)
  [ -f "$d/$2.tgz" ] || exit 3
  tar -xzf "$d/$2.tgz" || exit 1
  xargs -0 -r rm -f --
  ;;
esac
`;

type Snapshot = { name: string; mark: number; takenAt: number };
type Entry = { size: number; mtime: number };

async function run(exec: Exec, agent: Agent, args: string[], options: { input?: string; signal?: AbortSignal } = {}) {
  const argv = ['bash', '-c', SCRIPT, SNAPSHOTS, ...args];
  return exec('sudo', asAgent(await agentTarget(exec, agent), argv), { timeoutMs: SNAPSHOT_TIMEOUT_MS, maxBytes: MAX_MANIFEST_BYTES, ...options });
}

/** Before a turn. A failure is logged and the turn goes on without one. */
export async function snapshotWorkspace(exec: Exec, agent: Agent, mark: number, now: number, signal?: AbortSignal): Promise<void> {
  try {
    const result = await run(exec, agent, ['snapshot', `${mark}-${now}`], signal === undefined ? {} : { signal });
    if (result.code !== 0) log.error('workspace snapshot failed', { agent: agent.name, stderr: result.stderr });
  } catch (error) {
    log.error('workspace snapshot failed', { agent: agent.name, error });
  }
}

export async function pruneSnapshots(db: Db, exec: Exec, now: number): Promise<void> {
  for (const agent of listAgents(db).filter((a) => !isWorker(a))) {
    try {
      await run(exec, agent, ['prune', String(now - KEEP_SNAPSHOTS_MS)]);
    } catch (error) {
      log.error('snapshot prune failed', { agent: agent.name, error });
    }
  }
}

export function startSnapshotPruner(db: Db, exec: Exec): () => void {
  const timer = setInterval(() => void pruneSnapshots(db, exec, Date.now()), PRUNE_EVERY_MS);
  timer.unref();
  return () => clearInterval(timer);
}

export function parseSnapshotNames(stdout: string): Snapshot[] {
  return stdout.split('\n').flatMap((line) => {
    const match = /^(\d+)-(\d+)\.list$/.exec(line.trim());
    return match === null ? [] : [{ name: `${match[1]}-${match[2]}`, mark: Number(match[1]), takenAt: Number(match[2]) }];
  });
}

/**
 * The files as they were before any turn that wrote a row at or after `from`: the first turn that
 * started with that row not yet written. A turn cut in the middle keeps what it did before the cut.
 */
export function pickSnapshot(snapshots: readonly Snapshot[], from: number, now: number): Snapshot | undefined {
  return snapshots
    .filter((s) => s.mark >= from - 1 && s.takenAt >= now - KEEP_SNAPSHOTS_MS)
    .sort((a, b) => a.mark - b.mark || a.takenAt - b.takenAt)[0];
}

function safePath(path: string): boolean {
  return path !== '' && !path.startsWith('/') && !path.split('/').includes('..');
}

function parseRecords(records: readonly string[]): Map<string, Entry> {
  const entries = new Map<string, Entry>();
  for (const record of records) {
    const match = /^(\d+) (\d+)(?:\.\d+)? (.+)$/s.exec(record);
    if (match === null || !safePath(match[3] as string)) continue;
    entries.set(match[3] as string, { size: Number(match[1]), mtime: Number(match[2]) });
  }
  return entries;
}

/** The `diff` output: the snapshot's manifest, an empty record, the home's manifest now. Mtimes
 * compare in whole seconds, because tar puts files back with whole-second times. */
export function diffManifests(stdout: string): Omit<FileChanges, 'agent' | 'takenAt'> {
  const records = stdout.split('\0');
  const cut = records.indexOf('');
  const then = parseRecords(records.slice(0, cut === -1 ? records.length : cut));
  const now = parseRecords(cut === -1 ? [] : records.slice(cut + 1));
  const sorted = (paths: Iterable<string>) => [...paths].sort().slice(0, MAX_LISTED);
  return {
    added: sorted([...now.keys()].filter((path) => !then.has(path))),
    changed: sorted(
      [...now].filter(([path, entry]) => {
        const old = then.get(path);
        return old !== undefined && (old.size !== entry.size || old.mtime !== entry.mtime);
      }).map(([path]) => path),
    ),
    removed: sorted([...then.keys()].filter((path) => !now.has(path))),
  };
}

/** Undefined when there is no usable snapshot from before `from`. */
export async function fileChanges(exec: Exec, agent: Agent, from: number, now: number): Promise<{ changes: FileChanges; name: string } | undefined> {
  const listed = await run(exec, agent, ['list']);
  if (listed.code !== 0) throw new Error(`listing snapshots failed: ${listed.stderr}`);
  const snapshot = pickSnapshot(parseSnapshotNames(listed.stdout.toString()), from, now);
  if (snapshot === undefined) return undefined;
  const diff = await run(exec, agent, ['diff', snapshot.name]);
  if (diff.code === 3) return undefined;
  if (diff.code !== 0 || diff.truncated) throw new Error(`reading snapshot ${snapshot.name} failed: ${diff.stderr}`);
  return { changes: { agent: agent.name, takenAt: snapshot.takenAt, ...diffManifests(diff.stdout.toString()) }, name: snapshot.name };
}

/** Extracts the snapshot over the home and removes what was added since. The diff is taken here,
 * not trusted from a preview, so what goes is what differs now. */
export async function restoreFiles(exec: Exec, agent: Agent, from: number, now: number): Promise<FileChanges | undefined> {
  const found = await fileChanges(exec, agent, from, now);
  if (found === undefined) return undefined;
  const added = found.changes.added.map((path) => `${path}\0`).join('');
  const result = await run(exec, agent, ['restore', found.name], { input: added });
  if (result.code !== 0) throw new Error(`restoring ${agent.name}'s files failed: ${result.stderr}`);
  return found.changes;
}

export function restoredLine(changes: FileChanges): string {
  const counts = [
    [changes.changed.length, 'changed file', 'put back'],
    [changes.removed.length, 'deleted file', 'brought back'],
    [changes.added.length, 'new file', 'removed'],
  ] as const;
  const done = counts.filter(([n]) => n > 0).map(([n, what, how]) => `${n} ${what}${n === 1 ? '' : 's'} ${how}`);
  return (
    `The owner put ${changes.agent}'s files back to how they were at this point in the thread` +
    (done.length === 0 ? '; nothing had changed.' : `: ${done.join(', ')}.`)
  );
}

function clip(text: string, max = 160): string {
  const line = text.replace(/\s+/g, ' ').trim();
  return line.length > max ? `${line.slice(0, max - 1)}…` : line;
}

/** What restoring files leaves done, read from the rows a rewind deletes. `all` is the whole
 * thread, for the results of calls. */
export function cantUndo(rewound: readonly Message[], all: readonly Message[]): CantUndo[] {
  const results = new Map(all.filter((m) => m.role === 'tool').map((m) => [m.toolCallId ?? '', m.content]));
  return rewound.flatMap((m): CantUndo[] => {
    if (m.role === 'assistant') {
      return (m.toolCalls ?? []).flatMap((call): CantUndo[] => {
        const result = results.get(call.id);
        if (result === undefined || result.startsWith('error:')) return [];
        let args: Record<string, unknown> = {};
        try {
          args = JSON.parse(call.arguments) as Record<string, unknown>;
        } catch {
          return [];
        }
        const who = m.sender ?? 'The agent';
        if (call.name === 'send_message') {
          return [{ messageId: m.id, kind: 'message', text: `${who} sent a message to ${String(args['to'])}.` }];
        }
        if (call.name !== 'run_command' || typeof args['command'] !== 'string') return [];
        const command = args['command'];
        const mailer = commandNames(command).find((name) => MAIL_SENDERS.has(name));
        const installs = classifyCommand(command).filter((found) => found.category === 'install_software');
        return [
          ...(mailer === undefined ? [] : [{ messageId: m.id, kind: 'mail' as const, text: `${who} sent mail: ${clip(command)}` }]),
          ...installs.map((found) => ({
            messageId: m.id,
            kind: 'install' as const,
            text: `${who} installed software${found.target === '' ? '' : ` (${found.target})`}.`,
          })),
        ];
      });
    }
    if (m.role !== 'user') return [];
    if ((m.sender === undefined || m.sender === SYSTEM_SENDER) && m.content.startsWith(APPROVED)) {
      const end = m.content.indexOf(GO_AHEAD);
      const what = m.content.slice(APPROVED.length, end === -1 ? undefined : end);
      return [{ messageId: m.id, kind: 'approval', text: `You approved: ${clip(what)}.` }];
    }
    if (m.sender === undefined && m.content.startsWith(FILLED)) {
      return [{ messageId: m.id, kind: 'form', text: `You filled a form on ${clip(m.content.slice(FILLED.length).split(': ')[0] ?? '')}.` }];
    }
    if (m.sender === TRIGGER_SENDER && /^Trigger \d+ fired:/.test(m.content)) {
      return [{ messageId: m.id, kind: 'trigger', text: clip(m.content.split('. ')[0] ?? m.content) }];
    }
    return [];
  });
}
