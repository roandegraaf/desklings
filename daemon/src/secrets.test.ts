import { mkdtempSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import assert from 'node:assert/strict';
import test from 'node:test';
import { decrypt, encrypt, loadMasterKey } from './secrets.ts';

const keyPath = () => join(mkdtempSync(join(tmpdir(), 'schermes-secrets-')), 'master.key');

test('a value survives an encrypt/decrypt round trip', () => {
  const key = loadMasterKey(keyPath());
  const secret = 'sk-not-a-real-key-0123456789';
  assert.equal(decrypt(key, encrypt(key, secret)), secret);
});

test('the ciphertext does not contain the plaintext', () => {
  const key = loadMasterKey(keyPath());
  assert.doesNotMatch(Buffer.from(encrypt(key, 'hunter2'), 'base64').toString('latin1'), /hunter2/);
});

test('a tampered ciphertext fails the GCM auth tag instead of decrypting', () => {
  const key = loadMasterKey(keyPath());
  const raw = Buffer.from(encrypt(key, 'sk-tamper-me'), 'base64');
  raw.writeUInt8(raw.readUInt8(raw.length - 1) ^ 0xff, raw.length - 1);
  assert.throws(() => decrypt(key, raw.toString('base64')));
});

test('a ciphertext from another master key does not decrypt', () => {
  const blob = encrypt(loadMasterKey(keyPath()), 'sk-other-key');
  assert.throws(() => decrypt(loadMasterKey(keyPath()), blob));
});

test('the master key is generated once, at mode 0600, and reused', () => {
  const path = keyPath();
  const first = loadMasterKey(path);
  assert.equal(first.length, 32);
  assert.equal(statSync(path).mode & 0o777, 0o600);
  assert.deepEqual(loadMasterKey(path), first);
});
