import { eq } from 'drizzle-orm';
import { APPROVAL_CATEGORIES, RULE_LEVELS } from '@schermes/shared';
import type { Agent, AgentRules, Approval, ApprovalCategory, RuleLevel } from '@schermes/shared';
import { findAgentById } from './agents.ts';
import { CATEGORY_WORDS, MAX_TARGET_CHARS } from './approvals.ts';
import { agents } from './schema.ts';
import type { Db } from './db.ts';

const MAX_PRE_APPROVED = 100;
const MAX_GRANTS = 20;

export const DEFAULT_LEVELS: Record<ApprovalCategory, RuleLevel> = {
  browse: 'on_its_own',
  run_commands: 'on_its_own',
  write_files: 'on_its_own',
  delete_files: 'ask_first',
  send_messages: 'if_pre_approved',
  spend_money: 'ask_first',
  install_software: 'ask_first',
  share_outside: 'ask_first',
  passwords_security: 'hand_to_you',
};

type Guarded = 'delete_files' | 'install_software';
type Grant = { category: Guarded; target: string };
type Found = { category: Guarded; target: string; targets: string[] };

function column(db: Db, agent: Agent, key: 'rules' | 'grants'): unknown {
  const row = db.select({ value: agents[key] }).from(agents).where(eq(agents.id, agent.id)).get();
  return row?.value == null ? undefined : JSON.parse(row.value);
}

export function readRules(db: Db, agent: Agent): AgentRules {
  const stored = (column(db, agent, 'rules') ?? {}) as { levels?: Levels; preApproved?: unknown };
  const levels: AgentRules['levels'] = { ...DEFAULT_LEVELS, ...stored.levels, passwords_security: 'hand_to_you' };
  return { levels, preApproved: perCategory(stored.preApproved, levels) };
}

/** Rules stored before the lists were per category had one list, read by every If pre-approved
 * category. It goes to those, or to sending messages when none is, so nothing gains a pass. */
function perCategory(stored: unknown, levels: AgentRules['levels']): AgentRules['preApproved'] {
  if (!Array.isArray(stored)) return (stored ?? {}) as AgentRules['preApproved'];
  if (stored.length === 0) return {};
  const reading = APPROVAL_CATEGORIES.filter((category) => levels[category] === 'if_pre_approved');
  const to = reading.length === 0 ? (['send_messages'] as const) : reading;
  return Object.fromEntries(to.map((category) => [category, [...(stored as string[])]]));
}

function writeRules(db: Db, agent: Agent, rules: AgentRules): void {
  db.update(agents).set({ rules: JSON.stringify(rules) }).where(eq(agents.id, agent.id)).run();
}

type Levels = Partial<Record<ApprovalCategory, RuleLevel>>;

/** Levels by category, or why they are refused. `lenient` drops a bad entry instead, for a model's
 * suggestion; passwords are never anything but hand_to_you either way. */
export function parseLevels(raw: unknown, lenient = false): Levels | { error: string } {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    return lenient ? {} : { error: 'levels must be an object of category to level' };
  }
  const out: Levels = {};
  for (const [category, level] of Object.entries(raw)) {
    let error: string | undefined;
    if (!(APPROVAL_CATEGORIES as readonly string[]).includes(category)) error = `unknown category ${category}`;
    else if (typeof level !== 'string' || !(RULE_LEVELS as readonly string[]).includes(level)) {
      error = `a level must be one of ${RULE_LEVELS.join(', ')}`;
    } else if (category === 'passwords_security' && level !== 'hand_to_you') {
      error = 'passwords_security is always hand_to_you';
    }
    if (error === undefined) out[category as ApprovalCategory] = level as RuleLevel;
    else if (!lenient) return { error };
  }
  return out;
}

/** The owner's edit laid over what is stored, or why it is refused. */
export function updateRules(
  db: Db,
  agent: Agent,
  body: Record<string, unknown>,
): AgentRules | { error: string } {
  const current = readRules(db, agent);
  if (body['levels'] !== undefined) {
    const levels = parseLevels(body['levels']);
    if ('error' in levels) return levels;
    Object.assign(current.levels, levels);
  }
  const lists = body['preApproved'];
  if (lists !== undefined) {
    if (lists === null || typeof lists !== 'object' || Array.isArray(lists)) {
      return { error: 'preApproved must be an object of category to list' };
    }
    for (const [category, list] of Object.entries(lists)) {
      if (!(APPROVAL_CATEGORIES as readonly string[]).includes(category) || category === 'passwords_security') {
        return { error: `${category} has no pre-approved list` };
      }
      if (!Array.isArray(list) || list.length > MAX_PRE_APPROVED) {
        return { error: `a pre-approved list has at most ${MAX_PRE_APPROVED} entries` };
      }
      const entries: string[] = [];
      for (const entry of list) {
        if (typeof entry !== 'string' || entry.trim() === '' || /\s/.test(entry.trim()) || entry.length > MAX_TARGET_CHARS) {
          return { error: `each pre-approved entry is one domain or recipient, at most ${MAX_TARGET_CHARS} characters` };
        }
        entries.push(entry.trim().toLowerCase());
      }
      if (entries.length === 0) delete current.preApproved[category as ApprovalCategory];
      else current.preApproved[category as ApprovalCategory] = [...new Set(entries)];
    }
  }
  writeRules(db, agent, current);
  return current;
}

/** What "Always allow" puts on the list: the site, or for a message the recipient. Never a path
 * or a package: those are the model's own words, and a standing pass on them is a blank check. */
export function alwaysAllowable(approval: Approval): string | undefined {
  if (approval.kind !== 'action') return undefined;
  if (['passwords_security', 'delete_files', 'install_software'].includes(approval.category)) return undefined;
  if (approval.origin !== undefined) return approval.origin.toLowerCase();
  return ['send_messages', 'share_outside'].includes(approval.category) && approval.target !== ''
    ? approval.target.toLowerCase()
    : undefined;
}

/** Adds the entry to that category's list, and moves an Ask first category to If pre-approved: otherwise the list would
 * never be read for the very thing the owner just said always to allow. */
export function alwaysAllow(db: Db, agent: Agent, category: ApprovalCategory, entry: string): void {
  const rules = readRules(db, agent);
  const list = rules.preApproved[category] ?? [];
  if (!list.includes(entry)) rules.preApproved[category] = [...list, entry];
  if (rules.levels[category] === 'ask_first') rules.levels[category] = 'if_pre_approved';
  writeRules(db, agent, rules);
}

export function grantOnce(db: Db, agent: Agent, approval: Approval): void {
  if (approval.kind !== 'action') return;
  if (approval.category !== 'delete_files' && approval.category !== 'install_software') return;
  const grants = [...((column(db, agent, 'grants') ?? []) as Grant[]), { category: approval.category, target: approval.target }];
  db.update(agents)
    .set({ grants: JSON.stringify(grants.slice(-MAX_GRANTS)) })
    .where(eq(agents.id, agent.id))
    .run();
}

const LEVEL_WORDS: Record<RuleLevel, string> = {
  on_its_own: 'Go ahead on your own',
  if_pre_approved:
    'Go ahead when the domain or recipient is on the pre-approved list for that kind of action; for anything else, ask first with request_approval',
  ask_first: 'Ask first with request_approval, and do it only once the answer says approved',
  hand_to_you: 'Never do these yourself: tell the owner what is needed, and they do it',
};

export function rulesPrompt(rules: AgentRules): string {
  const lines = RULE_LEVELS.flatMap((level) => {
    const covered = APPROVAL_CATEGORIES.filter((category) => rules.levels[category] === level);
    return covered.length === 0
      ? []
      : [`- ${LEVEL_WORDS[level]}: ${covered.map((category) => CATEGORY_WORDS[category]).join('; ')}.`];
  });
  const list = APPROVAL_CATEGORIES.filter((category) => rules.levels[category] === 'if_pre_approved').map((category) => {
    const entries = rules.preApproved[category] ?? [];
    return `Pre-approved to ${CATEGORY_WORDS[category]}: ${entries.length === 0 ? 'nothing yet' : entries.join(', ')}.`;
  });
  return [
    'The owner\'s rules for what you do without them:',
    ...lines,
    ...list,
    'A delete or an install through run_command that these rules do not allow is refused.',
  ].join('\n');
}

const SEPARATORS = /;|&&|\|\||\||&|\n|\(|\)|`|\$\(/;
/** Words that run the next one, with the flags of theirs that take a value. */
const PREFIXES: Record<string, readonly string[]> = {
  sudo: ['-u', '-g', '-C', '-D', '-h', '-p', '-r', '-t', '-U'],
  doas: ['-u', '-C'],
  env: ['-u', '-C', '-S'],
  xargs: ['-I', '-L', '-P', '-n', '-d', '-a', '-E', '-s'],
  nice: ['-n'],
  stdbuf: [],
  nohup: [],
  time: [],
  command: [],
  exec: [],
  // Shell keywords open a segment that goes on with the command itself.
  do: [],
  then: [],
  else: [],
  elif: [],
  if: [],
  while: [],
  until: [],
  '{': [],
  '!': [],
};
const DELETERS = new Set(['rm', 'rmdir', 'unlink', 'shred', 'trash', 'trash-put']);
const INSTALLERS: Record<string, readonly string[]> = {
  apt: ['install', 'reinstall'],
  'apt-get': ['install', 'reinstall'],
  aptitude: ['install', 'reinstall'],
  dnf: ['install', 'reinstall'],
  yum: ['install', 'reinstall'],
  zypper: ['install', 'in'],
  apk: ['add'],
  snap: ['install'],
  flatpak: ['install'],
  brew: ['install', 'reinstall'],
  pip: ['install'],
  pip3: ['install'],
  pipx: ['install'],
  gem: ['install'],
  cargo: ['install'],
  go: ['install'],
};
const GLOBAL_INSTALLERS: Record<string, readonly string[]> = {
  npm: ['i', 'install', 'add'],
  pnpm: ['i', 'install', 'add'],
  bun: ['i', 'install', 'add'],
};

function words(segment: string): string[] {
  const out: string[] = [];
  let redirected = false;
  for (const raw of segment.trim().split(/\s+/)) {
    const word = raw.replace(/^['"]|['"]$/g, '');
    if (redirected) redirected = false;
    else if (/^\d*[<>]/.test(word)) redirected = /^\d*[<>]+$/.test(word);
    else if (word !== '') out.push(word);
  }
  return out;
}

const plain = (args: readonly string[]) => args.filter((arg) => !arg.startsWith('-'));

/** The segment's words from the command itself on, past assignments and prefixes like sudo. */
function commandWords(segment: string): string[] {
  let rest = words(segment);
  while (rest.length > 0) {
    const head = rest[0] ?? '';
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(head)) rest = rest.slice(1);
    else if (Object.hasOwn(PREFIXES, head)) {
      rest = rest.slice(1);
      while ((rest[0] ?? '').startsWith('-')) rest = rest.slice(PREFIXES[head]?.includes(rest[0] ?? '') ? 2 : 1);
    } else break;
  }
  return rest;
}

/** The program each segment of a shell command runs, without its path. */
export function commandNames(command: string): string[] {
  return command.split(SEPARATORS).flatMap((segment) => commandWords(segment)[0]?.split('/').at(-1) || []);
}

function classifySegment(segment: string): Found | undefined {
  const rest = commandWords(segment);
  const command = (rest[0] ?? '').split('/').at(-1) ?? '';
  let args = rest.slice(1);
  if ((command === 'python' || command === 'python3') && args[0] === '-m' && args[1] === 'pip') {
    return classifySegment(['pip', ...args.slice(2)].join(' '));
  }
  if (command === 'uv' && (args[0] === 'pip' || args[0] === 'tool')) args = args.slice(1);

  const found = (category: Guarded, targets: string[]): Found => ({
    category,
    targets,
    target: targets.join(' ').slice(0, MAX_TARGET_CHARS),
  });
  if (DELETERS.has(command)) return found('delete_files', plain(args));
  if (command === 'find' && args.some((arg) => arg === '-delete' || ['-exec', '-execdir', '-ok'].includes(arg))) {
    const execs = args.findIndex((arg) => ['-exec', '-execdir', '-ok'].includes(arg));
    const deleting = args.includes('-delete') || DELETERS.has(args[execs + 1]?.split('/').at(-1) ?? '');
    if (deleting) return found('delete_files', args.slice(0, args.findIndex((arg) => arg.startsWith('-'))));
  }
  if (command === 'dpkg' && args.some((arg) => arg === '-i' || arg === '--install')) {
    return found('install_software', plain(args));
  }
  const sub = plain(args)[0] ?? '';
  const subAt = args.indexOf(sub);
  if ((Object.hasOwn(INSTALLERS, command) && INSTALLERS[command]?.includes(sub)) || (command === 'uv' && sub === 'install')) {
    return found('install_software', plain(args.slice(subAt + 1)));
  }
  const global = args.includes('-g') || args.includes('--global');
  if (Object.hasOwn(GLOBAL_INSTALLERS, command) && GLOBAL_INSTALLERS[command]?.includes(sub) && global) {
    return found('install_software', plain(args.slice(subAt + 1)));
  }
  if (command === 'yarn' && sub === 'global' && args[subAt + 1] === 'add') {
    return found('install_software', plain(args.slice(subAt + 2)));
  }
  return undefined;
}

/**
 * The deletes and installs in a shell command, read off the words in command position.
 * ponytail: a heuristic for an agent that means well, not a sandbox. `bash -c "…"`, `eval`, a
 * script that deletes, and anything done through the computer tool or an MCP server get past it;
 * those stay rules in the prompt.
 */
export function classifyCommand(command: string): Found[] {
  return command.split(SEPARATORS).flatMap((segment) => classifySegment(segment) ?? []);
}

/**
 * Why this command may not run, or undefined. A task worker runs as the agent that spawned it,
 * so it runs under that agent's rules. The grants a command needs are used up only when every
 * delete and install in it is allowed, so a refusal never costs an approval.
 */
export function guardCommand(db: Db, agent: Agent, command: string): string | undefined {
  const owner = agent.parentId === undefined ? agent : findAgentById(db, agent.parentId);
  if (owner === undefined) return undefined;
  const rules = readRules(db, owner);
  const grants = (column(db, owner, 'grants') ?? []) as Grant[];
  const left = [...grants];
  for (const found of classifyCommand(command)) {
    const level = rules.levels[found.category];
    if (level === 'on_its_own') continue;
    if (
      level === 'if_pre_approved' &&
      found.targets.length > 0 &&
      found.targets.every((target) => (rules.preApproved[found.category] ?? []).includes(target.toLowerCase()))
    ) {
      continue;
    }
    const granted = left.findIndex((grant) => grant.category === found.category && grant.target === found.target);
    if (level !== 'hand_to_you' && granted !== -1) {
      left.splice(granted, 1);
      continue;
    }
    return refusal(agent, owner, found, level);
  }
  if (left.length !== grants.length) {
    db.update(agents).set({ grants: JSON.stringify(left) }).where(eq(agents.id, owner.id)).run();
  }
  return undefined;
}

function refusal(agent: Agent, owner: Agent, found: Found, level: RuleLevel): string {
  const what = `${CATEGORY_WORDS[found.category]}${found.target === '' ? '' : ` (${found.target})`}`;
  if (level === 'hand_to_you') {
    return `the owner's rules leave it to them to ${what}. Nothing was run. Tell the owner what is needed; they do it themselves.`;
  }
  if (agent.id !== owner.id) {
    return (
      `${owner.name}'s rules say to ask the owner before you ${what}. Nothing was run. Say so in ` +
      `your result, with the command, so ${owner.name} can ask.`
    );
  }
  return (
    `your rules say to ask the owner before you ${what}. Nothing was run. Ask with ` +
    `request_approval, category ${found.category}, target "${found.target}"; once the answer says ` +
    'approved, run the same command again.'
  );
}
