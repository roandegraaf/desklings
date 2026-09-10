import assert from 'node:assert/strict';
import test from 'node:test';
import { format, redact } from './log.ts';

const SECRET = 'sk-live-shouldnevershowup';

test('secret-looking keys are redacted at any depth', () => {
  const line = format('info', 'settings updated', {
    provider: { baseUrl: 'https://api.example.com', apiKey: SECRET },
    nested: [{ password: 'hunter2' }, { master_key: SECRET }],
    session: { Cookie: `schermes_session=${SECRET}` },
  });
  assert.doesNotMatch(line, /shouldnevershowup/);
  assert.doesNotMatch(line, /hunter2/);
  assert.match(line, /https:\/\/api\.example\.com/);
});

test('ordinary fields survive redaction', () => {
  const line = format('info', 'daemon listening', { host: '0.0.0.0', port: 7777 });
  assert.match(line, /"port":7777/);
  assert.equal(JSON.parse(line).msg, 'daemon listening');
});

test('errors keep their message and cycles do not hang', () => {
  const cyclic: Record<string, unknown> = { name: 'loop' };
  cyclic['self'] = cyclic;
  const line = format('error', 'boom', { err: new Error('it broke'), cyclic });
  assert.match(line, /it broke/);
  assert.match(line, /\[circular\]/);
});
