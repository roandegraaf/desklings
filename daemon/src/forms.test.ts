import assert from 'node:assert/strict';
import test from 'node:test';
import { fillForm, readForm } from './browser.ts';
import { filledLine, redactSecrets, hideFromAgent, secureOrigin, shapeForm } from './forms.ts';
import { formPage } from './testpage.ts';

const LOGIN = [
  { id: 't-0', label: 'Email', type: 'email', name: 'email', autocomplete: 'username', required: true },
  { id: 't-1', label: 'Password', type: 'password', name: 'pw', autocomplete: '', required: true },
  { id: 't-2', label: 'Code', type: 'text', name: 'otp', autocomplete: 'one-time-code', required: false },
  { id: 't-3', label: 'Country', type: 'select', name: 'country', autocomplete: '', required: false, options: [{ value: 'nl', label: 'Netherlands' }] },
];

test('secret fields are marked, and keyed for the vault by autocomplete, name or label', () => {
  const shaped = shapeForm('https://bank.example', LOGIN, [{ label: 'CAPTCHA', reason: 'captcha' }]);
  assert.equal(shaped.secure, true);
  assert.deepEqual(
    shaped.fields.map((f) => [f.id, f.secret, f.key]),
    [['t-0', false, 'username'], ['t-1', true, 'pw'], ['t-2', true, 'one-time-code'], ['t-3', false, 'country']],
  );
  assert.deepEqual(shaped.fields[3]?.options, [{ value: 'nl', label: 'Netherlands' }]);
  assert.deepEqual(shaped.unfillable, [{ label: 'CAPTCHA', reason: 'captcha' }]);
});

test('over plain HTTP the secret fields go to the screen; loopback counts as secure', () => {
  const shaped = shapeForm('http://shop.example', LOGIN, []);
  assert.equal(shaped.secure, false);
  assert.deepEqual(shaped.fields.map((f) => f.label), ['Email', 'Country']);
  assert.deepEqual(shaped.unfillable, [
    { label: 'Password', reason: 'insecure' },
    { label: 'Code', reason: 'insecure' },
  ]);
  assert.equal(secureOrigin('http://localhost:3000'), true);
  assert.equal(secureOrigin('http://127.0.0.1'), true);
  assert.equal(secureOrigin('http://10.0.0.2'), false);
});

test('the form is read from the page, with the origin Chromium reports', async () => {
  const page = formPage({ origin: 'https://bank.example', unfillable: [{ label: 'Card', reason: 'cross_origin_frame' }] });
  const form = await readForm(page.connect, 3, 'abcd');
  assert.ok(!('error' in form));
  assert.equal(form.origin, 'https://bank.example');
  assert.equal((form.fields as unknown[]).length, 2);
  assert.deepEqual(form.unfillable, [{ label: 'Card', reason: 'cross_origin_frame' }]);
  const script = String(page.sent.find((s) => s.method === 'Runtime.evaluate' && String(s.params['expression']).includes('const skipped'))?.params['expression']);
  assert.match(script, /\("abcd"\)$/, 'tagged with the token');
  assert.doesNotMatch(script, /(?<!option)\.value\b/, "never reads what a control holds");

  const nothing = await readForm(() => Promise.resolve(undefined), 3, 'abcd');
  assert.deepEqual(nothing, { error: 'your browser is not running; open the page with the browser tool first' });
});

const STEPS = [
  { id: 't-0', label: 'Email', type: 'email', value: 'owner@example.com' },
  { id: 't-1', label: 'Password', type: 'password', value: 'hunter2-secret' },
];

test('a fill types each value into its focused field, and the values only travel in insertText', async () => {
  const page = formPage({});
  assert.deepEqual(await fillForm(page.connect, 3, 'https://bank.example', STEPS), { ok: true });
  assert.deepEqual(page.typed(), ['owner@example.com', 'hunter2-secret']);
  for (const s of page.sent.filter((s) => s.method !== 'Input.insertText')) {
    assert.doesNotMatch(JSON.stringify(s.params), /hunter2/);
  }
});

test('nothing is typed when the page moved to another origin or a field will not take focus', async () => {
  const moved = formPage({});
  moved.origin.current = 'https://evil.example';
  assert.deepEqual(await fillForm(moved.connect, 3, 'https://bank.example', STEPS), {
    error: 'the page is on https://evil.example now, not https://bank.example',
  });
  assert.deepEqual(moved.typed(), []);

  const stolen = formPage({ focus: () => false });
  assert.deepEqual(await fillForm(stolen.connect, 3, 'https://bank.example', STEPS), { error: 'could not put the cursor in Email' });
  assert.deepEqual(stolen.typed(), []);

  let calls = 0;
  const second = formPage({ focus: () => (calls += 1) === 1 });
  assert.deepEqual(await fillForm(second.connect, 3, 'https://bank.example', STEPS), { error: 'could not put the cursor in Password' });
  assert.deepEqual(second.typed(), ['owner@example.com'], 'the password went nowhere');
});

test('the owner line names the fields and hides secret ones; typed secrets are redacted from tool text', () => {
  assert.equal(
    filledLine('https://bank.example', [{ label: 'Email', secret: false }, { label: 'Password', secret: true }]),
    'I filled the form on https://bank.example: Email, Password (hidden). Nothing was submitted; carry on from there.',
  );
  hideFromAgent(7, ['hunter2-secret', 'abc']);
  assert.equal(redactSecrets(7, 'value: hunter2-secret, abc'), 'value: [hidden], abc');
  assert.equal(redactSecrets(8, 'hunter2-secret'), 'hunter2-secret');
});
