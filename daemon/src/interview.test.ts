import assert from 'node:assert/strict';
import test from 'node:test';
import {
  KICKOFF,
  MAX_PROFILE_CHARS,
  MAX_QUESTIONS,
  askOwnerToolDef,
  describedKickoff,
  parseAskOwner,
  parseProfile,
  profilePrompt,
  setNameToolDef,
  setProfileToolDef,
} from './interview.ts';

function refuse(body: Record<string, unknown>): string {
  const parsed = parseAskOwner(body);
  assert.ok('error' in parsed, `expected ${JSON.stringify(body)} to be refused`);
  return parsed.error;
}

type Schema = Record<string, unknown>;
const props = (schema: Schema): Record<string, Schema> => schema['properties'] as Record<string, Schema>;

test('the plain kickoff asks for an open description first, then the profile', () => {
  assert.match(KICKOFF, /^I just created you\./);
  assert.match(KICKOFF, /ask_owner and no options/);
  assert.match(KICKOFF, /set_profile/);
});

test('a described kickoff quotes every line of the description and only names a tagline when given', () => {
  const plain = describedKickoff('  Sorts my inbox.\nFiles receipts.\n', undefined);
  assert.match(plain, /^I just created you\. This is what I want you for:\n> Sorts my inbox\.\n> Files receipts\.\n\n/);
  assert.match(plain, /Do not ask what I already told you/);
  assert.ok(plain.endsWith('write your profile with set_profile.'));

  const tagged = describedKickoff('Sorts my inbox.', 'Inbox keeper');
  assert.ok(tagged.endsWith('set_profile, starting with this line on its own: Inbox keeper'));
});

test('the profile prompt interviews without a profile and quotes the profile with one', () => {
  const none = profilePrompt(undefined);
  assert.match(none, /no profile yet/);
  assert.match(none, /ask_owner/);
  assert.match(none, /set_profile/);

  assert.equal(profilePrompt('# Inbox keeper\nI sort mail.'), 'Who you are, as agreed with the owner. Act on it in every turn:\n# Inbox keeper\nI sort mail.');
});

test('questions are bounded field by field, and oversized optional parts are refused or dropped', () => {
  assert.match(refuse({ questions: 'one' }), /1 to 4 questions/);
  assert.match(refuse({ questions: [null] }), /each question must be an object/);
  assert.match(refuse({ questions: ['plain text'] }), /each question must be an object/);
  assert.match(refuse({ questions: [{ question: 'x'.repeat(401) }] }), /1-400/);
  assert.match(refuse({ questions: [{ question: 'x', options: Array(7).fill({ label: 'a' }) }] }), /at most 6/);
  assert.match(refuse({ questions: [{ question: 'x', options: [null] }] }), /label of 1-80/);
  assert.match(refuse({ questions: [{ question: 'x', options: [{ label: 'x'.repeat(81) }] }] }), /label of 1-80/);

  assert.deepEqual(
    parseAskOwner({
      questions: [
        {
          question: 'Tone?',
          header: 'x'.repeat(25),
          options: [{ label: 'Formal', description: 'x'.repeat(201) }, { label: ' Casual ', description: '  relaxed\n and short ' }],
          multiple: 'yes',
        },
      ],
    }),
    [{ question: 'Tone?', options: [{ label: 'Formal' }, { label: 'Casual', description: 'relaxed and short' }] }],
    'a too-long header or description is dropped, and only true sets multiple',
  );
  assert.deepEqual(parseAskOwner({ questions: [{ question: 'Pick', options: [] }] }), [{ question: 'Pick', options: [] }]);
  assert.equal((parseAskOwner({ questions: Array(MAX_QUESTIONS).fill({ question: 'q' }) }) as unknown[]).length, MAX_QUESTIONS);
});

test('a profile at the limit is accepted and its surrounding blank lines go', () => {
  assert.match(String((parseProfile({ profile: 7 }) as { error: string }).error), /non-empty/);
  assert.match(String((parseProfile({ profile: ' \n ' }) as { error: string }).error), /non-empty/);
  assert.equal(parseProfile({ profile: 'x'.repeat(MAX_PROFILE_CHARS) }), 'x'.repeat(MAX_PROFILE_CHARS));
});

test('the interview tool definitions carry the limits their parsers enforce', () => {
  const ask = askOwnerToolDef();
  assert.equal(ask.name, 'ask_owner');
  assert.match(ask.description, new RegExp(`at most ${MAX_QUESTIONS} at a time`));
  const questions = props(ask.parameters)['questions'] as Schema;
  assert.equal(questions['minItems'], 1);
  assert.equal(questions['maxItems'], MAX_QUESTIONS);
  const item = questions['items'] as Schema;
  assert.deepEqual(item['required'], ['question']);
  assert.equal(props(item)['question']?.['maxLength'], 400);
  assert.equal(props(item)['header']?.['maxLength'], 24);
  const options = props(item)['options'] as Schema;
  assert.equal(options['maxItems'], 6);
  const option = options['items'] as Schema;
  assert.equal(props(option)['label']?.['maxLength'], 80);
  assert.equal(props(option)['description']?.['maxLength'], 200);

  const profile = setProfileToolDef();
  assert.equal(profile.name, 'set_profile');
  assert.equal(props(profile.parameters)['profile']?.['maxLength'], MAX_PROFILE_CHARS);

  const name = setNameToolDef();
  assert.equal(name.name, 'set_name');
  const pattern = new RegExp(String(props(name.parameters)['name']?.['pattern']));
  assert.ok(pattern.test('alpha-2'));
  assert.ok(pattern.test('a'.repeat(31)));
  assert.ok(!pattern.test('a'.repeat(32)));
  assert.ok(!pattern.test('-alpha'));
  assert.ok(!pattern.test('Alpha'));
});
