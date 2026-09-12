import { randomUUID } from 'node:crypto';
import { asAgent } from './agents.ts';
import type { AgentTarget } from './agents.ts';
import type { Exec } from './exec.ts';
import type { ToolDef } from './provider.ts';

/**
 * How much of `~/memory/MEMORY.md` reaches the prompt. The head is kept, so the oldest lines
 * are the ones that survive.
 *
 * ponytail: once the file passes this, a newly remembered line never reaches the prompt again.
 * The upgrade path is the nightly summarisation the overview leaves open — a cron job that
 * rewrites MEMORY.md — not a bigger number here.
 */
export const MAX_MEMORY_CHARS = 8_000;
/** How much of a `SKILL.md` is read to find its frontmatter. The body is never loaded. */
const MAX_FRONTMATTER_CHARS = 1_000;
const MAX_REMEMBER_CHARS = 1_000;

/** Skills every agent on the machine can read, created by `infra/install.sh`. */
export const SHARED_SKILLS = '/srv/schermes/shared/skills';

/**
 * arg0 of each script. `bash -c` gives the first operand to `$0`, so without a placeholder the
 * arguments below would shift and `set -u` would fail the read on every turn. It doubles as the
 * handle a reader — or a test — has on which of the two ran.
 */
export const HOME_LOAD = 'schermes-home';
export const HOME_APPEND = 'schermes-remember';

/**
 * One pass over the agent's home, as the agent. Sections are announced by a marker the caller
 * generates per call, so nothing a file contains can forge one. Memory is read first because it
 * is the thing most likely to be there.
 */
const LOAD_SCRIPT = `set -u
mark=$1
printf '\\n%s memory\\n' "$mark"
[ -f "$HOME/memory/MEMORY.md" ] && head -c ${MAX_MEMORY_CHARS} "$HOME/memory/MEMORY.md"
for skill in "$HOME"/skills/*/SKILL.md ${SHARED_SKILLS}/*/SKILL.md; do
  [ -f "$skill" ] || continue
  printf '\\n%s skill %s\\n' "$mark" "$skill"
  head -c ${MAX_FRONTMATTER_CHARS} "$skill"
done
exit 0
`;

const APPEND_SCRIPT = `set -eu
mkdir -p "$1"
cat >> "$1/$2"
`;

export type Skill = { name: string; description: string; path: string };
export type Home = { memory: string; skills: Skill[] };

function frontmatter(head: string, key: string): string | undefined {
  const block = /^---\r?\n([\s\S]*?)\r?\n---/.exec(head)?.[1];
  if (block === undefined) return undefined;
  const found = new RegExp(`^${key}:[ \\t]*(.+)$`, 'm').exec(block)?.[1]?.trim();
  return found === undefined || found === '' ? undefined : found.replace(/^["']|["']$/g, '');
}

export function parseHome(raw: string, mark: string): Home {
  const home: Home = { memory: '', skills: [] };
  for (const section of raw.split(`\n${mark} `).slice(1)) {
    const cut = section.indexOf('\n');
    const header = cut === -1 ? section : section.slice(0, cut);
    const body = cut === -1 ? '' : section.slice(cut + 1);
    if (header === 'memory') {
      home.memory = body.trim();
      continue;
    }
    if (!header.startsWith('skill ')) continue;
    const path = header.slice('skill '.length);
    home.skills.push({
      name: frontmatter(body, 'name') ?? path.split('/').at(-2) ?? path,
      description: frontmatter(body, 'description') ?? '',
      path,
    });
  }
  return home;
}

export async function loadHome(exec: Exec, target: AgentTarget): Promise<Home> {
  const mark = randomUUID();
  const argv = asAgent(target, ['bash', '-c', LOAD_SCRIPT, HOME_LOAD, mark]);
  const result = await exec('sudo', argv);
  return parseHome(result.stdout.toString(), mark);
}

/** The prompt tail. Empty when the agent has neither, so a fresh agent is told nothing. */
export function homePrompt(home: Home): string {
  const lines = [
    'Your memory, the file ~/memory/MEMORY.md. You are shown it at the start of every turn, in ' +
      'every conversation, and the remember tool is how you add to it:',
    home.memory === '' ? '(empty)' : `\n${home.memory}`,
    '',
    home.skills.length === 0
      ? 'You have no skills yet. A skill is a folder ~/skills/<name>/SKILL.md whose frontmatter ' +
        'gives a name and a description; write one when you work out how to do something you ' +
        'will be asked for again.'
      : 'Skills you have. Only the name and description are here: read the file with run_command ' +
        'before you follow one.',
  ];
  for (const skill of home.skills) {
    lines.push(
      skill.description === ''
        ? `- ${skill.name} — ${skill.path}`
        : `- ${skill.name}: ${skill.description} — ${skill.path}`,
    );
  }
  return lines.join('\n');
}

export type RememberRequest = { text: string; scope: 'lasting' | 'today' };

export function parseRemember(
  body: Record<string, unknown>,
): RememberRequest | { error: string } {
  const text = body['text'];
  if (typeof text !== 'string' || text.trim() === '') {
    return { error: 'text must be a non-empty string' };
  }
  if (text.length > MAX_REMEMBER_CHARS) {
    return { error: `text must be at most ${MAX_REMEMBER_CHARS} characters` };
  }
  const scope = body['scope'];
  if (scope !== 'lasting' && scope !== 'today') {
    return { error: "scope must be 'lasting' or 'today'" };
  }
  // One entry is one line: a multi-line note would make MEMORY.md unreadable as a list.
  return { text: text.trim().replace(/\s+/g, ' '), scope };
}

/** Built from the constants `parseRemember` enforces, so the two cannot disagree. */
export function rememberToolDef(): ToolDef {
  return {
    name: 'remember',
    description:
      'Write one line into your memory, which is files in your home directory that outlive ' +
      "this conversation and this machine's uptime. Use it the moment you learn something " +
      'worth carrying: you will not get another chance.',
    parameters: {
      type: 'object',
      properties: {
        text: {
          type: 'string',
          maxLength: MAX_REMEMBER_CHARS,
          description: 'one line, written so it still makes sense months from now',
        },
        scope: {
          type: 'string',
          enum: ['lasting', 'today'],
          description:
            'lasting appends to ~/memory/MEMORY.md, which you are shown at the start of every ' +
            'turn in every conversation: who the owner is, how they want things done, what you ' +
            "decided. today appends to today's ~/memory/<date>.md note, which you are not " +
            'shown: what happened, to be found later with grep or rg in run_command.',
        },
      },
      required: ['text', 'scope'],
      additionalProperties: false,
    },
  };
}

export async function remember(
  exec: Exec,
  target: AgentTarget,
  request: RememberRequest,
): Promise<{ path: string } | { error: string }> {
  const dir = `${target.home}/memory`;
  const file =
    request.scope === 'lasting' ? 'MEMORY.md' : `${new Date().toISOString().slice(0, 10)}.md`;
  // The line goes in on stdin. Nothing the model wrote is ever an argument, let alone a path.
  const argv = asAgent(target, ['bash', '-c', APPEND_SCRIPT, HOME_APPEND, dir, file]);
  const result = await exec('sudo', argv, { input: `- ${request.text}\n` });
  return result.code === 0
    ? { path: `${dir}/${file}` }
    : { error: `could not write ${dir}/${file}: ${result.stderr.trim()}` };
}
