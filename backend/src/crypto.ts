import { createCipheriv, createDecipheriv, createHash, randomBytes, scrypt, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';

const derive = promisify(scrypt);

export function parseStorageKey(value: string): Buffer {
  const key = Buffer.from(value, 'base64');
  if (key.length !== 32 || key.toString('base64') !== value) throw new Error('STORAGE_KEY must contain 32 random bytes encoded as base64');
  return key;
}

/** AAD binds ciphertext to its owner and entity, so copying rows cannot change ownership. */
export class PayloadCipher {
  private readonly key: Buffer;
  constructor(key: Buffer) {
    if (key.length !== 32) throw new Error('A 256-bit storage key is required');
    this.key = Buffer.from(key);
  }

  encrypt(value: unknown, context: string): string {
    const nonce = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', this.key, nonce);
    cipher.setAAD(Buffer.from(context, 'utf8'));
    const encrypted = Buffer.concat([cipher.update(JSON.stringify(value), 'utf8'), cipher.final()]);
    return ['v1', nonce.toString('base64'), cipher.getAuthTag().toString('base64'), encrypted.toString('base64')].join('.');
  }

  decrypt<T>(value: string, context: string): T {
    const [version, nonce, tag, data, extra] = value.split('.');
    if (version !== 'v1' || !nonce || !tag || !data || extra !== undefined) throw new Error('Invalid encrypted payload');
    const decipher = createDecipheriv('aes-256-gcm', this.key, Buffer.from(nonce, 'base64'));
    decipher.setAAD(Buffer.from(context, 'utf8'));
    decipher.setAuthTag(Buffer.from(tag, 'base64'));
    return JSON.parse(Buffer.concat([decipher.update(Buffer.from(data, 'base64')), decipher.final()]).toString('utf8')) as T;
  }
}

export async function hashPassword(password: string): Promise<string> {
  const salt = randomBytes(16);
  const key = await derive(password, salt, 64) as Buffer;
  return `scrypt$${salt.toString('base64')}$${key.toString('base64')}`;
}

export async function verifyPassword(password: string, encoded: string): Promise<boolean> {
  const [scheme, salt, expected] = encoded.split('$');
  if (scheme !== 'scrypt' || !salt || !expected) return false;
  const key = await derive(password, Buffer.from(salt, 'base64'), 64) as Buffer;
  const comparison = Buffer.from(expected, 'base64');
  return key.length === comparison.length && timingSafeEqual(key, comparison);
}

export function tokenHash(token: string): string { return createHash('sha256').update(token).digest('hex'); }
export function newToken(): string { return randomBytes(32).toString('base64url'); }

export function canonicalJson(value: unknown): string {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  const object = value as Record<string, unknown>;
  return `{${Object.keys(object).sort().map(key => `${JSON.stringify(key)}:${canonicalJson(object[key])}`).join(',')}}`;
}

