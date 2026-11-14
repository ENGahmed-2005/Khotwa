import { randomBytes } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { canonicalJson, hashPassword, newToken, parseStorageKey, PayloadCipher, tokenHash, verifyPassword } from '../src/crypto.js';

describe('authenticated at-rest encryption', () => {
  it('round-trips Arabic data with unique nonces and no plaintext payload', () => {
    const cipher = new PayloadCipher(randomBytes(32));
    const payload = { needs: 'مهارة اصطناعية للاختبار', code: 'ST-AABBCCDD' };
    const a = cipher.encrypt(payload, 'owner:1');
    const b = cipher.encrypt(payload, 'owner:1');
    expect(a).not.toBe(b);
    expect(a).not.toContain(payload.needs);
    expect(a).not.toContain(payload.code);
    expect(cipher.decrypt(a, 'owner:1')).toEqual(payload);
  });
  it('rejects different owner binding, changed ciphertext and wrong key', () => {
    const cipher = new PayloadCipher(randomBytes(32));
    const value = cipher.encrypt({ synthetic: true }, 'owner:1');
    expect(() => cipher.decrypt(value, 'owner:2')).toThrow();
    const parts = value.split('.');
    const data = Buffer.from(parts[3]!, 'base64');
    data[0] = data[0]! ^ 1;
    parts[3] = data.toString('base64');
    expect(() => cipher.decrypt(parts.join('.'), 'owner:1')).toThrow();
    expect(() => new PayloadCipher(randomBytes(32)).decrypt(value, 'owner:1')).toThrow();
  });
  it('rejects malformed keys and ciphertext', () => {
    expect(() => parseStorageKey('not-a-key')).toThrow();
    expect(parseStorageKey(Buffer.alloc(32, 1).toString('base64'))).toEqual(Buffer.alloc(32, 1));
    expect(() => new PayloadCipher(Buffer.alloc(31))).toThrow();
    expect(() => new PayloadCipher(Buffer.alloc(32)).decrypt('plaintext', 'x')).toThrow();
  });
});

describe('credential primitives', () => {
  it('salts passwords independently and verifies only the right password', async () => {
    const password = 'Synthetic-password-1234';
    const a = await hashPassword(password);
    const b = await hashPassword(password);
    expect(a).not.toBe(b);
    expect(a).not.toContain(password);
    expect(await verifyPassword(password, a)).toBe(true);
    expect(await verifyPassword('another-password', a)).toBe(false);
    expect(await verifyPassword(password, 'invalid')).toBe(false);
  });
  it('generates 256-bit opaque tokens and canonical request hashes', () => {
    const a = newToken();
    expect(a).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(newToken()).not.toBe(a);
    expect(tokenHash(a)).not.toBe(a);
    expect(canonicalJson({ b: [1, { z: 2, a: 3 }], a: true })).toBe(canonicalJson({ a: true, b: [1, { a: 3, z: 2 }] }));
  });
});

