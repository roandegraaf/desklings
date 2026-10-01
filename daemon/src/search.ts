import { SEARCH_KINDS } from '@schermes/shared';
import type { SearchAnswer, SearchFilters, SearchKind, SearchResult } from '@schermes/shared';
import { agentTarget, asAgent, isWorker, listAgents } from './agents.ts';
import { participantAgents } from './conversations.ts';
import type { Db } from './db.ts';
import type { Exec } from './exec.ts';
import { log } from './log.ts';
import type { Provider } from './provider.ts';

export const MAX_QUESTION_CHARS = 300;
const HITS_PER_KIND = 20;
const MAX_WORDS = 12;
const MODEL_TIMEOUT_MS = 20_000;
const INDEX_EVERY_MS = 10 * 60_000;
const MAX_FILES = 5_000;
const OCR_PER_PASS = 10;
const OCR_TIMEOUT_MS = 30_000;
const MAX_OCR_CHARS = 20_000;
const DAY_MS = 86_400_000;

export const FILES_SCRIPT =
  `find . -mindepth 1 -maxdepth 6 -name '.*' -prune -o -type f -printf '%T@\\t%P\\n' 2>/dev/null | head -n ${MAX_FILES}`;
const OCR_SCRIPT = 'base64 -d | tesseract stdin stdout 2>/dev/null';

export type IndexedFile = { path: string; modifiedAt: number };

/** An agent's home as the index knows it: every earlier row for that agent is replaced. */
export function indexAgentFiles(db: Db, agentId: number, files: readonly IndexedFile[]): void {
  const sqlite = db.$client;
  const insert = sqlite.prepare('INSERT INTO files_fts (name, path, agent_id, modified_at) VALUES (?, ?, ?, ?)');
  sqlite.transaction(() => {
    sqlite.prepare('DELETE FROM files_fts WHERE agent_id = ?').run(agentId);
    for (const file of files) {
      insert.run(file.path.split('/').at(-1) ?? file.path, file.path, agentId, Math.round(file.modifiedAt));
    }
  })();
}

export function parseFileList(stdout: string): IndexedFile[] {
  return stdout.split('\n').flatMap((line) => {
    const match = /^(\d+(?:\.\d+)?)\t(.+)$/.exec(line);
    return match === null ? [] : [{ path: match[2]!, modifiedAt: Number(match[1]) * 1000 }];
  });
}

async function scanFiles(db: Db, exec: Exec): Promise<void> {
  const agents = listAgents(db).filter((agent) => !isWorker(agent));
  db.$client
    .prepare(`DELETE FROM files_fts WHERE agent_id NOT IN (${agents.map(() => '?').join(',') || 'NULL'})`)
    .run(...agents.map((agent) => agent.id));
  for (const agent of agents) {
    try {
      const result = await exec('sudo', asAgent(await agentTarget(exec, agent), ['bash', '-c', FILES_SCRIPT]), {
        maxBytes: 4 * 1024 * 1024,
      });
      if (result.code !== 0) continue;
      indexAgentFiles(db, agent.id, parseFileList(result.stdout.toString()));
    } catch (error) {
      log.error('search file scan failed', { agent: agent.name, error: (error as Error).message });
    }
  }
}

/** Reads the text in stored pictures, newest first, a few per pass. No tesseract: nothing is
 * marked, so the pictures are read once it is installed. */
async function readScreenshots(db: Db, exec: Exec): Promise<void> {
  if ((await exec('sh', ['-c', 'command -v tesseract'])).code !== 0) return;
  const sqlite = db.$client;
  const next = sqlite.prepare(
    'SELECT id, conversation_id AS conversationId, image FROM messages WHERE image IS NOT NULL ' +
      'AND id NOT IN (SELECT rowid FROM screenshots_fts) ORDER BY id DESC LIMIT 1',
  );
  const mark = sqlite.prepare('INSERT INTO screenshots_fts (rowid, text) VALUES (?, ?)');
  for (let done = 0; done < OCR_PER_PASS; done += 1) {
    const row = next.get() as { id: number; conversationId: number; image: string } | undefined;
    if (row === undefined) return;
    let text = '';
    const agent = participantAgents(db, row.conversationId).find((candidate) => !isWorker(candidate));
    try {
      const image = JSON.parse(row.image) as { base64?: unknown };
      if (agent !== undefined && typeof image.base64 === 'string') {
        const result = await exec('sudo', asAgent(await agentTarget(exec, agent), ['bash', '-c', OCR_SCRIPT]), {
          input: image.base64,
          timeoutMs: OCR_TIMEOUT_MS,
        });
        if (result.code === 0) text = result.stdout.toString().replace(/\s+/g, ' ').trim().slice(0, MAX_OCR_CHARS);
      }
    } catch (error) {
      log.error('screenshot text failed', { message: row.id, error: (error as Error).message });
    }
    // The row may have been rewound away while tesseract ran.
    if (sqlite.prepare('SELECT 1 FROM messages WHERE id = ?').get(row.id) !== undefined) mark.run(row.id, text);
  }
}

export async function indexPass(db: Db, exec: Exec): Promise<void> {
  await scanFiles(db, exec);
  await readScreenshots(db, exec);
}

export function startSearchIndexer(db: Db, exec: Exec): () => void {
  let running = false;
  const pass = async () => {
    if (running) return;
    running = true;
    try {
      await indexPass(db, exec);
    } catch (error) {
      log.error('search index pass failed', { error });
    } finally {
      running = false;
    }
  };
  void pass();
  const timer = setInterval(() => void pass(), INDEX_EVERY_MS);
  timer.unref();
  return () => clearInterval(timer);
}

function localDay(now: number): string {
  const date = new Date(now);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

function dayStart(text: unknown): number | undefined {
  if (typeof text !== 'string') return undefined;
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text);
  if (match === null) return undefined;
  const time = new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3])).getTime();
  return Number.isNaN(time) ? undefined : time;
}

const usable = (word: string) => /[\p{L}\p{N}]/u.test(word);

export function plainFilters(question: string): SearchFilters {
  return { kinds: [...SEARCH_KINDS], words: question.split(/\s+/).filter(usable).slice(0, MAX_WORDS) };
}

/** The model's reply, kept only where it names real agents, kinds and days. */
export function parseFilters(reply: string, agentNames: readonly string[]): SearchFilters | undefined {
  const start = reply.indexOf('{');
  const end = reply.lastIndexOf('}');
  if (start === -1 || end < start) return undefined;
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(reply.slice(start, end + 1)) as Record<string, unknown>;
  } catch {
    return undefined;
  }
  if (typeof parsed !== 'object' || parsed === null) return undefined;
  const kinds = Array.isArray(parsed['kinds'])
    ? SEARCH_KINDS.filter((kind) => (parsed['kinds'] as unknown[]).includes(kind))
    : [];
  const agent = agentNames.find((name) => typeof parsed['agent'] === 'string' && name.toLowerCase() === parsed['agent'].toLowerCase());
  const from = dayStart(parsed['from']);
  const toDay = dayStart(parsed['to']);
  const words = Array.isArray(parsed['words'])
    ? parsed['words'].filter((word): word is string => typeof word === 'string').map((word) => word.trim()).filter(usable)
    : [];
  return {
    kinds: kinds.length === 0 ? [...SEARCH_KINDS] : kinds,
    ...(agent === undefined ? {} : { agent }),
    ...(from === undefined ? {} : { from }),
    ...(toDay === undefined ? {} : { to: toDay + DAY_MS - 1 }),
    words: words.slice(0, MAX_WORDS),
  };
}

const KIND_WORDS: Record<SearchKind, string> = { message: 'messages', file: 'files', screenshot: 'screenshots' };

function dayWords(time: number): string {
  return new Date(time).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
}

export function describeFilters(filters: SearchFilters): string[] {
  const kinds = filters.kinds.map((kind) => KIND_WORDS[kind]);
  const lines = [
    kinds.length === SEARCH_KINDS.length
      ? 'Messages, files and screenshots'
      : `Only ${kinds.length === 1 ? kinds[0] : `${kinds.slice(0, -1).join(', ')} and ${kinds.at(-1)}`}`,
  ];
  if (filters.agent !== undefined) lines.push(`Agent: ${filters.agent}`);
  if (filters.from !== undefined && filters.to !== undefined) {
    lines.push(`From ${dayWords(filters.from)} to ${dayWords(filters.to)}`);
  } else if (filters.from !== undefined) lines.push(`Since ${dayWords(filters.from)}`);
  else if (filters.to !== undefined) lines.push(`Until ${dayWords(filters.to)}`);
  lines.push(filters.words.length === 0 ? 'Any words' : `Words: ${filters.words.join(', ')}`);
  return lines;
}

function matchExpression(words: readonly string[]): string {
  return words.map((word) => `"${word.replace(/"/g, '""')}"*`).join(' OR ');
}

type Clause = { sql: string; params: unknown[] };

function timeClauses(column: string, filters: SearchFilters): Clause[] {
  return [
    ...(filters.from === undefined ? [] : [{ sql: `${column} >= ?`, params: [filters.from] }]),
    ...(filters.to === undefined ? [] : [{ sql: `${column} <= ?`, params: [filters.to] }]),
  ];
}

function where(clauses: readonly Clause[]): Clause {
  return {
    sql: clauses.length === 0 ? '' : `WHERE ${clauses.map((clause) => clause.sql).join(' AND ')}`,
    params: clauses.flatMap((clause) => clause.params),
  };
}

function snippetOf(text: string): string {
  const flat = text.replace(/\s+/g, ' ').trim();
  return flat.length > 240 ? `${flat.slice(0, 239)}…` : flat;
}

type MessageRow = { id: number; conversationId: number; sender: string | null; createdAt: number; snip: string };

function threadHits(db: Db, filters: SearchFilters, agentId: number | undefined, kind: 'message' | 'screenshot'): SearchResult[] {
  const table = kind === 'message' ? 'messages_fts' : 'screenshots_fts';
  const words = filters.words.length > 0;
  const clauses: Clause[] = [
    ...(words ? [{ sql: `${table} MATCH ?`, params: [matchExpression(filters.words)] }] : []),
    ...(kind === 'screenshot' ? [{ sql: `${table}.text != ''`, params: [] }] : []),
    ...timeClauses('m.created_at', filters),
    ...(agentId === undefined
      ? []
      : [{ sql: 'm.conversation_id IN (SELECT conversation_id FROM conversation_participants WHERE agent_id = ?)', params: [agentId] }]),
  ];
  const filter = where(clauses);
  const snip = words ? `snippet(${table}, 0, '', '', '…', 24)` : `substr(${kind === 'message' ? 'm.content' : `${table}.text`}, 1, 400)`;
  const rows = db.$client
    .prepare(
      `SELECT m.id, m.conversation_id AS conversationId, m.sender, m.created_at AS createdAt, ${snip} AS snip ` +
        `FROM ${table} JOIN messages m ON m.id = ${table}.rowid ${filter.sql} ` +
        `ORDER BY ${words ? 'rank' : 'm.id DESC'} LIMIT ${HITS_PER_KIND}`,
    )
    .all(...filter.params) as MessageRow[];
  const participants = new Map<number, string[]>();
  return rows.map((row) => {
    let names = participants.get(row.conversationId);
    if (names === undefined) {
      names = participantAgents(db, row.conversationId).map((agent) => agent.name);
      participants.set(row.conversationId, names);
    }
    return {
      kind,
      ...(row.sender === null ? {} : { agent: row.sender }),
      conversationId: row.conversationId,
      participants: names,
      messageId: row.id,
      at: row.createdAt,
      snippet: snippetOf(row.snip),
    };
  });
}

function fileHits(db: Db, filters: SearchFilters, agentId: number | undefined): SearchResult[] {
  const words = filters.words.length > 0;
  const filter = where([
    ...(words ? [{ sql: 'files_fts MATCH ?', params: [matchExpression(filters.words)] }] : []),
    ...timeClauses('files_fts.modified_at', filters),
    ...(agentId === undefined ? [] : [{ sql: 'files_fts.agent_id = ?', params: [agentId] }]),
  ]);
  const rows = db.$client
    .prepare(
      'SELECT files_fts.path AS path, files_fts.modified_at AS at, agents.name AS agent ' +
        `FROM files_fts JOIN agents ON agents.id = files_fts.agent_id ${filter.sql} ` +
        `ORDER BY ${words ? 'rank' : 'files_fts.modified_at DESC'} LIMIT ${HITS_PER_KIND}`,
    )
    .all(...filter.params) as { path: string; at: number; agent: string }[];
  return rows.map((row) => ({ kind: 'file', agent: row.agent, path: row.path, at: row.at, snippet: row.path }));
}

export function runSearch(db: Db, filters: SearchFilters): SearchResult[] {
  const agentId = filters.agent === undefined ? undefined : listAgents(db).find((agent) => agent.name === filters.agent)?.id;
  const hits = filters.kinds.flatMap((kind) =>
    kind === 'file' ? fileHits(db, filters, agentId) : threadHits(db, filters, agentId, kind),
  );
  return hits.sort((a, b) => b.at - a.at);
}

function filterPrompt(now: number, agentNames: readonly string[]): string {
  return [
    "Turn the owner's search question into filters. Reply with one JSON object and nothing else:",
    '{"kinds": [any of "message", "file", "screenshot"; empty for all], "agent": an agent name or null,',
    '"from": "YYYY-MM-DD" or null, "to": "YYYY-MM-DD" or null, "words": [words the text or file name should contain]}.',
    'Leave the agent name, dates and filler words out of "words"; a file type such as pdf is a word.',
    `Today is ${localDay(now)}. The agents are: ${agentNames.join(', ') || 'none'}.`,
  ].join('\n');
}

/** The model reads the question when there is one; without it, or when the call fails, the same
 * index is searched for the question's own words. Only the question and the agent names go out. */
export async function answerSearch(db: Db, question: string, provider: Provider | undefined, now: number): Promise<SearchAnswer> {
  const agentNames = listAgents(db).map((agent) => agent.name);
  let filters: SearchFilters | undefined;
  if (provider !== undefined) {
    try {
      const reply = await provider(
        [
          { role: 'system', text: filterPrompt(now, agentNames) },
          { role: 'user', text: question },
        ],
        [],
        undefined,
        AbortSignal.timeout(MODEL_TIMEOUT_MS),
      );
      filters = parseFilters(reply.text, agentNames);
      if (filters === undefined) log.info('search model reply was not filters', { reply: reply.text.slice(0, 200) });
    } catch (error) {
      log.info('search model call failed, searching the plain words', { error: (error as Error).message });
    }
  }
  const byModel = filters !== undefined;
  const used = filters ?? plainFilters(question);
  return { understoodAs: describeFilters(used), filters: used, byModel, hits: runSearch(db, used) };
}
