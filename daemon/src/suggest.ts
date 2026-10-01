import { BLOUB_COLORS, BLOUB_SHAPES } from '@schermes/shared';
import type { AgentSuggestion } from '@schermes/shared';
import { MAX_LABEL_CHARS, cleanLabel, listAgents } from './agents.ts';
import type { Db } from './db.ts';
import { log } from './log.ts';
import type { Provider } from './provider.ts';
import { DEFAULT_LEVELS, parseLevels } from './rules.ts';
import { parseSchedule } from './schedules.ts';

export const MAX_DESCRIPTION_CHARS = 2_000;
const MODEL_TIMEOUT_MS = 20_000;
/** Room for a worker's `-w<n>` after a derived name, as the app leaves it. */
const MAX_DERIVED_NAME = 27;

function slugged(label: string): string {
  const folded = label.normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase();
  const slug = folded
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+/, '')
    .slice(0, MAX_DERIVED_NAME)
    .replace(/-+$/, '');
  return slug === '' ? 'agent' : slug;
}

/** The label's slug, or the first free number after it: the app's `agentName(for:taken:)`. */
export function freeName(label: string, taken: ReadonlySet<string>): string {
  const stem = slugged(label);
  if (!taken.has(stem)) return stem;
  for (let number = 2; number <= 1000; number += 1) {
    const suffix = `-${number}`;
    const name = `${stem.slice(0, MAX_DERIVED_NAME - suffix.length).replace(/-+$/, '')}${suffix}`;
    if (!taken.has(name)) return name;
  }
  return stem;
}

function clip(text: string): string {
  const line = text.replace(/\s+/g, ' ').trim();
  return [...line].length <= MAX_LABEL_CHARS ? line : `${[...line].slice(0, MAX_LABEL_CHARS - 1).join('')}…`;
}

function suggestPrompt(): string {
  return [
    'The owner describes a new AI agent they want. Suggest how to set it up. Reply with one JSON object and nothing else:',
    '{"label": a short first name for it, one or two words, "tagline": what it is for in two to four words,',
    `"look": {"shape": one of ${BLOUB_SHAPES.join(', ')}, "color": one of ${BLOUB_COLORS.join(', ')}},`,
    '"levels": {category: level} only where it should differ from the default,',
    '"routine": {"cron": a five-field cron expression, "prompt": what it does then, as an instruction to itself} or null}.',
    `Categories and their defaults: ${Object.entries(DEFAULT_LEVELS)
      .filter(([category]) => category !== 'passwords_security')
      .map(([category, level]) => `${category}=${level}`)
      .join(', ')}.`,
    'Levels: on_its_own, if_pre_approved, ask_first, hand_to_you. Loosen only what the description clearly needs,',
    'and tighten what it warns about. Suggest a routine only when the work is clearly recurring.',
  ].join('\n');
}

function readReply(reply: string): Record<string, unknown> | undefined {
  const start = reply.indexOf('{');
  const end = reply.lastIndexOf('}');
  if (start === -1 || end < start) return undefined;
  try {
    const parsed = JSON.parse(reply.slice(start, end + 1)) as unknown;
    return parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}

function lookOf(raw: unknown): string | undefined {
  const look = raw as Record<string, unknown> | null | undefined;
  const shape = look?.['shape'];
  const color = look?.['color'];
  return (BLOUB_SHAPES as readonly unknown[]).includes(shape) && (BLOUB_COLORS as readonly unknown[]).includes(color)
    ? `${String(shape)}:${String(color)}`
    : undefined;
}

/** Whatever of the model's reply holds up; a field that does not falls back on its own. */
function fromReply(reply: Record<string, unknown>, description: string, taken: ReadonlySet<string>): AgentSuggestion | undefined {
  const label = typeof reply['label'] === 'string' ? cleanLabel(reply['label']) : undefined;
  if (label === undefined) return undefined;
  const tagline = typeof reply['tagline'] === 'string' ? cleanLabel(reply['tagline']) : undefined;
  const levels = parseLevels(reply['levels'] ?? {}, true);
  const routine =
    reply['routine'] !== null && typeof reply['routine'] === 'object' ? parseSchedule(reply['routine'] as Record<string, unknown>) : undefined;
  const look = lookOf(reply['look']);
  return {
    name: freeName(label, taken),
    label,
    tagline: tagline ?? clip(description),
    ...(look === undefined ? {} : { look }),
    levels: { ...DEFAULT_LEVELS, ...('error' in levels ? {} : levels) },
    ...(routine === undefined || 'error' in routine ? {} : { routine }),
    byModel: true,
  };
}

/** The default model's suggestion for a new agent, or a plain one when there is no model or its
 * reply is unusable. Only the description goes out. */
export async function suggestAgent(db: Db, description: string, provider: Provider | undefined): Promise<AgentSuggestion> {
  const taken = new Set(listAgents(db).map((agent) => agent.name));
  if (provider !== undefined) {
    try {
      const reply = await provider(
        [
          { role: 'system', text: suggestPrompt() },
          { role: 'user', text: description },
        ],
        [],
        undefined,
        AbortSignal.timeout(MODEL_TIMEOUT_MS),
      );
      const parsed = readReply(reply.text);
      const suggestion = parsed === undefined ? undefined : fromReply(parsed, description, taken);
      if (suggestion !== undefined) return suggestion;
      log.info('agent suggestion reply was unusable', { reply: reply.text.slice(0, 200) });
    } catch (error) {
      log.info('agent suggestion model call failed, suggesting plainly', { error: (error as Error).message });
    }
  }
  return { name: freeName('Helper', taken), label: 'Helper', tagline: clip(description), levels: { ...DEFAULT_LEVELS }, byModel: false };
}
