import type { ToolDef } from './provider.ts';

export const MAX_PROFILE_CHARS = 4_000;
export const MAX_QUESTIONS = 4;
const MAX_OPTIONS = 6;
const MAX_QUESTION_CHARS = 400;
const MAX_HEADER_CHARS = 24;
const MAX_LABEL_CHARS = 80;
const MAX_DESCRIPTION_CHARS = 200;

export type Option = { label: string; description?: string };
export type Question = { question: string; header?: string; options?: Option[]; multiple?: boolean };

/** What the owner's thread opens with the moment an agent is created. Written as the owner's,
 * like a fired routine, so the agent wakes on it and answers the person who made it. */
export const KICKOFF =
  'I just created you. Introduce yourself in a line, then find out from me what you should be ' +
  'and do. Start by asking me, with ask_owner and no options, to describe in a few sentences ' +
  'what I want you for; then ask a few focused questions that follow from what I said, and ' +
  'when you know enough write your profile with set_profile.';

/** The system-prompt half: who the agent is, or what to do about not knowing yet. */
export function profilePrompt(profile: string | undefined): string {
  if (profile === undefined) {
    return (
      'You have no profile yet, so nobody has told you what you are for. Before any other work, ' +
      'interview the owner with ask_owner. First one open question with no options: what they ' +
      'want you for, in their own words. Then, from what they said, a few focused questions ' +
      'with options where that helps: how they want it done, what to deliver and how, and ' +
      'what to leave alone. Do not ask what their answer already told you. Then write it down ' +
      'with set_profile, in your own words and in Markdown, so every later turn starts from it.'
    );
  }
  return `Who you are, as agreed with the owner. Act on it in every turn:\n${profile}`;
}

function oneLine(value: unknown, max: number): string | undefined {
  if (typeof value !== 'string') return undefined;
  const text = value.trim().replace(/\s+/g, ' ');
  return text === '' || text.length > max ? undefined : text;
}

export function parseAskOwner(body: Record<string, unknown>): Question[] | { error: string } {
  const raw = body['questions'];
  if (!Array.isArray(raw) || raw.length === 0 || raw.length > MAX_QUESTIONS) {
    return { error: `questions must be a list of 1 to ${MAX_QUESTIONS} questions` };
  }
  const questions: Question[] = [];
  for (const item of raw) {
    if (item === null || typeof item !== 'object') return { error: 'each question must be an object' };
    const entry = item as Record<string, unknown>;
    const question = oneLine(entry['question'], MAX_QUESTION_CHARS);
    if (question === undefined) {
      return { error: `question must be 1-${MAX_QUESTION_CHARS} characters` };
    }
    const parsed: Question = { question };
    const header = oneLine(entry['header'], MAX_HEADER_CHARS);
    if (header !== undefined) parsed.header = header;
    if (entry['multiple'] === true) parsed.multiple = true;
    if (entry['options'] !== undefined) {
      const options = entry['options'];
      if (!Array.isArray(options) || options.length > MAX_OPTIONS) {
        return { error: `options must be a list of at most ${MAX_OPTIONS}` };
      }
      parsed.options = [];
      for (const option of options) {
        const label = oneLine((option as Record<string, unknown> | null)?.['label'], MAX_LABEL_CHARS);
        if (label === undefined) return { error: `each option needs a label of 1-${MAX_LABEL_CHARS} characters` };
        const description = oneLine((option as Record<string, unknown>)['description'], MAX_DESCRIPTION_CHARS);
        parsed.options.push(description === undefined ? { label } : { label, description });
      }
    }
    questions.push(parsed);
  }
  return questions;
}

export function askOwnerToolDef(): ToolDef {
  return {
    name: 'ask_owner',
    description:
      'Put questions to the owner as a form they answer in one go: each question with a few ' +
      'options to pick from, or free text when there is nothing to offer. The owner can always ' +
      'type an answer of their own instead of an option. Calling this ends your turn: the ' +
      'answers arrive as the next message from the owner. Use it when what to do depends on ' +
      "what they want, not to confirm what they already said; and ask at most " +
      `${MAX_QUESTIONS} at a time.`,
    parameters: {
      type: 'object',
      properties: {
        questions: {
          type: 'array',
          minItems: 1,
          maxItems: MAX_QUESTIONS,
          items: {
            type: 'object',
            properties: {
              question: { type: 'string', maxLength: MAX_QUESTION_CHARS, description: 'the whole question' },
              header: {
                type: 'string',
                maxLength: MAX_HEADER_CHARS,
                description: 'a two-word label for the question, such as Purpose or Tone',
              },
              options: {
                type: 'array',
                maxItems: MAX_OPTIONS,
                items: {
                  type: 'object',
                  properties: {
                    label: { type: 'string', maxLength: MAX_LABEL_CHARS },
                    description: {
                      type: 'string',
                      maxLength: MAX_DESCRIPTION_CHARS,
                      description: 'what picking this means, when the label alone does not say',
                    },
                  },
                  required: ['label'],
                  additionalProperties: false,
                },
                description: 'choices to offer; leave out for a free-text answer',
              },
              multiple: { type: 'boolean', description: 'true when several options may be picked at once' },
            },
            required: ['question'],
            additionalProperties: false,
          },
        },
      },
      required: ['questions'],
      additionalProperties: false,
    },
  };
}

export function parseProfile(body: Record<string, unknown>): string | { error: string } {
  const profile = body['profile'];
  if (typeof profile !== 'string' || profile.trim() === '') {
    return { error: 'profile must be a non-empty string' };
  }
  if (profile.length > MAX_PROFILE_CHARS) {
    return { error: `profile must be at most ${MAX_PROFILE_CHARS} characters` };
  }
  return profile.trim();
}

export function setNameToolDef(): ToolDef {
  return {
    name: 'set_name',
    description:
      'Change the name you run and are addressed by: lowercase letters, digits and dashes, up ' +
      'to 31 characters, not one another agent has. It takes effect when this turn ends: your ' +
      'Linux user and home move with it, your desktop restarts, and your history stays yours. ' +
      'Until then you are still your current name.',
    parameters: {
      type: 'object',
      properties: {
        name: { type: 'string', pattern: '^[a-z0-9][a-z0-9-]{0,30}$' },
      },
      required: ['name'],
      additionalProperties: false,
    },
  };
}

export function setProfileToolDef(): ToolDef {
  return {
    name: 'set_profile',
    description:
      'Write who you are: what you are for, who you work for, how they want it done, what you ' +
      'stay out of. Markdown, in your own words, replacing what was there. It is in your system ' +
      'prompt from your next turn on and the owner reads and edits it too, so write it for both ' +
      'of you. Call it after interviewing the owner with ask_owner, and again whenever what they ' +
      'want from you changes.',
    parameters: {
      type: 'object',
      properties: {
        profile: { type: 'string', maxLength: MAX_PROFILE_CHARS },
      },
      required: ['profile'],
      additionalProperties: false,
    },
  };
}
