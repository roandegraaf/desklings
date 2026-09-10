import { chmodSync, closeSync, openSync, readFileSync, writeSync } from 'node:fs';
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';

const KEY_BYTES = 32;
const IV_BYTES = 12;
const TAG_BYTES = 16;

/** Reads the AES-GCM master key, generating it on first boot. */
export function loadMasterKey(path: string): Buffer {
  try {
    // 'wx' fails if the file exists, so two daemons racing on first boot cannot both generate.
    const fd = openSync(path, 'wx', 0o600);
    try {
      const key = randomBytes(KEY_BYTES);
      writeSync(fd, key);
      chmodSync(path, 0o600);
      return key;
    } finally {
      closeSync(fd);
    }
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'EEXIST') throw err;
  }

  const key = readFileSync(path);
  if (key.length !== KEY_BYTES) {
    throw new Error(`master key ${path} is ${key.length} bytes, expected ${KEY_BYTES}`);
  }
  return key;
}

export function encrypt(key: Buffer, plaintext: string): string {
  const iv = randomBytes(IV_BYTES);
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  const body = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), body]).toString('base64');
}

export function decrypt(key: Buffer, blob: string): string {
  const raw = Buffer.from(blob, 'base64');
  if (raw.length < IV_BYTES + TAG_BYTES) throw new Error('ciphertext is too short to be valid');
  const decipher = createDecipheriv('aes-256-gcm', key, raw.subarray(0, IV_BYTES));
  decipher.setAuthTag(raw.subarray(IV_BYTES, IV_BYTES + TAG_BYTES));
  const body = raw.subarray(IV_BYTES + TAG_BYTES);
  return Buffer.concat([decipher.update(body), decipher.final()]).toString('utf8');
}
