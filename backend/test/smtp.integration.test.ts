import { randomBytes, randomUUID } from 'node:crypto';
import { createServer, type Socket } from 'node:net';
import { PrismaClient } from '@prisma/client';
import type { FastifyInstance } from 'fastify';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { tokenHash } from '../src/crypto.js';
import { resetDeliveryFromEnvironment, smtpOptionsFromEnvironment } from '../src/mail/reset-delivery.js';

const runId = `test-smtp-${randomUUID()}`;
const password = 'Synthetic-SMTP-password-1234';
let prisma: PrismaClient;

/** A loopback SMTP receiver for actual transport tests; no message goes to the internet. */
async function receiver(settings: { rejectRecipient?: boolean; rejectGreeting?: boolean } = {}) {
  const messages: string[] = [];
  const commands: string[] = [];
  const sockets = new Set<Socket>();
  const server = createServer(socket => {
    sockets.add(socket);
    socket.on('error', () => {});
    socket.on('close', () => sockets.delete(socket));
    socket.setEncoding('utf8');
    socket.write(settings.rejectGreeting ? '421 Synthetic test service unavailable\r\n' : '220 loopback.synthetic ESMTP\r\n');
    let input = '';
    let data: string[] | undefined;
    let recipientAccepted = false;
    socket.on('data', (chunk: string) => {
      input += chunk;
      let index: number;
      while ((index = input.indexOf('\r\n')) !== -1) {
        const line = input.slice(0, index);
        input = input.slice(index + 2);
        if (data) {
          if (line === '.') { messages.push(data.join('\r\n')); data = undefined; socket.write('250 Message accepted by synthetic receiver\r\n'); }
          else data.push(line.startsWith('..') ? line.slice(1) : line);
          continue;
        }
        commands.push(line);
        if (/^(?:EHLO|HELO) /i.test(line)) socket.write('250-loopback.synthetic\r\n250 PIPELINING\r\n');
        else if (/^MAIL FROM:/i.test(line)) { recipientAccepted = false; socket.write('250 Sender accepted\r\n'); }
        else if (/^RCPT TO:/i.test(line)) { recipientAccepted = !settings.rejectRecipient; socket.write(recipientAccepted ? '250 Recipient accepted\r\n' : '550 Synthetic recipient rejected\r\n'); }
        else if (/^DATA$/i.test(line)) {
          if (recipientAccepted) { data = []; socket.write('354 End data with dot\r\n'); }
          else socket.write('503 A valid recipient is required\r\n');
        }
        else if (/^QUIT$/i.test(line)) socket.end('221 Bye\r\n');
        else if (/^(?:RSET|NOOP)$/i.test(line)) socket.write('250 OK\r\n');
        else socket.write('500 Command unavailable in loopback test receiver\r\n');
      }
    });
  });
  await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('Missing loopback receiver address');
  return { port: address.port, messages, commands, async close() {
    for (const socket of sockets) socket.destroy();
    await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
  } };
}

function environment(port: number): NodeJS.ProcessEnv {
  return { NODE_ENV: 'test', SMTP_ENABLED: 'true', SMTP_HOST: '127.0.0.1', SMTP_PORT: String(port),
    SMTP_TLS_MODE: 'plain-loopback', SMTP_ALLOW_INSECURE_LOOPBACK: 'true', SMTP_FROM: 'khotwa@example.test' };
}
function decodedText(message: string): string {
  const separator = message.indexOf('\r\n\r\n');
  const headers = message.slice(0, separator);
  const body = message.slice(separator + 4);
  if (/Content-Transfer-Encoding:\s*base64/iu.test(headers)) return Buffer.from(body.replace(/\s/gu, ''), 'base64').toString('utf8');
  if (/Content-Transfer-Encoding:\s*quoted-printable/iu.test(headers)) {
    const decoded = body.replace(/=\r?\n/gu, '').replace(/=([a-f0-9]{2})/giu, (_, hex: string) => String.fromCharCode(Number.parseInt(hex, 16)));
    return Buffer.from(decoded, 'latin1').toString('utf8');
  }
  return body;
}
async function register(app: FastifyInstance) {
  const email = `${runId}-${randomUUID()}@example.test`;
  const response = await app.inject({ method: 'POST', url: '/v1/auth/register', payload: { email, password } });
  expect(response.statusCode).toBe(201);
  return { email, ...response.json<{ token: string; user: { id: string } }>() };
}
beforeAll(async () => {
  const url = process.env.TEST_DATABASE_URL;
  if (!url) throw new Error('TEST_DATABASE_URL is required for SMTP account tests');
  prisma = new PrismaClient({ datasources: { db: { url } }, log: [] });
  await prisma.$connect();
});
afterAll(async () => {
  if (prisma) {
    await prisma.user.deleteMany({ where: { email: { startsWith: runId } } });
    await prisma.$disconnect();
  }
});

describe('server-only SMTP configuration', () => {
  it('is disabled by default and requires explicit loopback-only plaintext development', () => {
    expect(resetDeliveryFromEnvironment({ SMTP_HOST: 'smtp.example.test' })).toBeUndefined();
    const base = environment(2525);
    expect(() => smtpOptionsFromEnvironment({ ...base, SMTP_ALLOW_INSECURE_LOOPBACK: 'false' })).toThrow();
    expect(() => smtpOptionsFromEnvironment({ ...base, NODE_ENV: 'production' })).toThrow();
    expect(() => smtpOptionsFromEnvironment({ ...base, SMTP_HOST: 'smtp.example.test' })).toThrow();
    expect(() => smtpOptionsFromEnvironment({ ...base, SMTP_FROM: 'bad@example.test\r\nBcc: other@example.test' })).toThrow();
  });
  it('requires remote authentication and TLS with certificate verification', () => {
    const base = { SMTP_ENABLED: 'true', SMTP_HOST: 'smtp.example.test', SMTP_FROM: 'khotwa@example.test', SMTP_USER: 'synthetic-user', SMTP_PASSWORD: 'synthetic-password' };
    const starttls = smtpOptionsFromEnvironment(base)!;
    expect(starttls.options).toMatchObject({ secure: false, requireTLS: true, ignoreTLS: false, logger: false, debug: false,
      disableFileAccess: true, disableUrlAccess: true, tls: { minVersion: 'TLSv1.2', rejectUnauthorized: true, servername: 'smtp.example.test' } });
    expect(smtpOptionsFromEnvironment({ ...base, SMTP_TLS_MODE: 'implicit' })!.options).toMatchObject({ secure: true, port: 465 });
    expect(() => smtpOptionsFromEnvironment({ ...base, SMTP_PASSWORD: undefined })).toThrow();
    expect(() => smtpOptionsFromEnvironment({ ...base, SMTP_HOST: '192.0.2.1' })).toThrow();
  });
});

describe('actual loopback SMTP password recovery', () => {
  it('receives an actual message, completes reset once, and revokes existing sessions', async () => {
    const smtp = await receiver();
    const app = await buildApp({ prisma, storageKey: randomBytes(32), authRateLimit: 1000, resetDelivery: resetDeliveryFromEnvironment(environment(smtp.port)) });
    try {
      const owner = await register(app);
      const request = await app.inject({ method: 'POST', url: '/v1/auth/password-reset/request', payload: { email: owner.email } });
      expect(request.statusCode).toBe(202);
      expect(smtp.messages).toHaveLength(1);
      const message = smtp.messages[0]!;
      expect(smtp.commands).toContain(`RCPT TO:<${owner.email}>`);
      const token = /(?:\r?\n)([A-Za-z0-9_-]{43})(?:\r?\n|$)/u.exec(decodedText(message))?.[1];
      expect(token).toBeDefined();
      expect(request.body).not.toContain(token);
      const row = await prisma.passwordReset.findFirstOrThrow({ where: { userId: owner.user.id } });
      expect(row.tokenHash).toBe(tokenHash(token!));
      expect(row.tokenHash).not.toBe(token);
      const updated = 'Changed-Synthetic-SMTP-password';
      const confirmation = { token, password: updated };
      expect((await app.inject({ method: 'POST', url: '/v1/auth/password-reset/confirm', payload: confirmation })).statusCode).toBe(204);
      expect((await app.inject({ method: 'POST', url: '/v1/auth/password-reset/confirm', payload: confirmation })).statusCode).toBe(400);
      expect((await app.inject({ url: '/v1/auth/me', headers: { authorization: `Bearer ${owner.token}` } })).statusCode).toBe(401);
      expect((await app.inject({ method: 'POST', url: '/v1/auth/login', payload: { email: owner.email, password: updated } })).statusCode).toBe(200);
      const unknown = await app.inject({ method: 'POST', url: '/v1/auth/password-reset/request', payload: { email: `${runId}-unknown@example.test` } });
      expect(unknown.body).toBe(request.body);
      expect(smtp.messages).toHaveLength(1);
    } finally { await app.close(); await smtp.close(); }
  });
  it('fails closed if STARTTLS is unavailable and never sends credentials or reset content', async () => {
    const smtp = await receiver();
    const delivery = resetDeliveryFromEnvironment({ ...environment(smtp.port), SMTP_TLS_MODE: 'starttls', SMTP_TLS_SERVERNAME: 'smtp.example.test',
      SMTP_USER: 'synthetic-user', SMTP_PASSWORD: 'synthetic-password' })!;
    try {
      await expect(delivery.verifyAvailability!()).rejects.toThrow();
      expect(smtp.commands.some(line => /^AUTH|^MAIL|^RCPT/i.test(line))).toBe(false);
      expect(smtp.messages).toHaveLength(0);
    } finally { await smtp.close(); }
  });
  it('reports availability failures consistently before looking up known or unknown accounts', async () => {
    const smtp = await receiver({ rejectGreeting: true });
    const app = await buildApp({ prisma, storageKey: randomBytes(32), authRateLimit: 1000, resetDelivery: resetDeliveryFromEnvironment(environment(smtp.port)) });
    try {
      const owner = await register(app);
      const known = await app.inject({ method: 'POST', url: '/v1/auth/password-reset/request', payload: { email: owner.email } });
      const unknown = await app.inject({ method: 'POST', url: '/v1/auth/password-reset/request', payload: { email: `${runId}-unknown@example.test` } });
      expect(known.statusCode).toBe(503);
      expect(unknown.body).toBe(known.body);
      expect(known.json().error.code).toBe('RESET_DELIVERY_UNAVAILABLE');
      expect(await prisma.passwordReset.count({ where: { userId: owner.user.id } })).toBe(0);
      expect(smtp.messages).toHaveLength(0);
    } finally { await app.close(); await smtp.close(); }
  });
  it('revokes an undelivered token and audits recipient rejection without revealing account membership', async () => {
    const smtp = await receiver({ rejectRecipient: true });
    const app = await buildApp({ prisma, storageKey: randomBytes(32), authRateLimit: 1000, resetDelivery: resetDeliveryFromEnvironment(environment(smtp.port)) });
    try {
      const owner = await register(app);
      const known = await app.inject({ method: 'POST', url: '/v1/auth/password-reset/request', payload: { email: owner.email } });
      const unknown = await app.inject({ method: 'POST', url: '/v1/auth/password-reset/request', payload: { email: `${runId}-unknown@example.test` } });
      expect(known.statusCode).toBe(202);
      expect(unknown.body).toBe(known.body);
      expect(await prisma.passwordReset.count({ where: { userId: owner.user.id } })).toBe(0);
      expect(await prisma.auditEvent.count({ where: { ownerId: owner.user.id, action: 'account.reset_delivery_failed' } })).toBe(1);
      expect(smtp.messages).toHaveLength(0);
    } finally { await app.close(); await smtp.close(); }
  });
});
