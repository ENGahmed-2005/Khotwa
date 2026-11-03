import { randomBytes, randomUUID } from 'node:crypto';
import { PrismaClient } from '@prisma/client';
import type { FastifyInstance } from 'fastify';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { PayloadCipher, tokenHash } from '../src/crypto.js';
import type { Envelope, SyncResult } from '../src/records.js';
import type { Operation } from '../src/schemas.js';
import { assessmentFixture, fixtureTime, operationFixture, studentFixture } from './fixtures.js';

const runId = `test-${randomUUID()}`;
const password = 'Synthetic-password-12345';
const storageKey = randomBytes(32);
const delivered: { email: string; token: string; expiresAt: Date }[] = [];
let prisma: PrismaClient;
let app: FastifyInstance;
interface Account { token: string; expiresAt: string; user: { id: string; email: string; role: string } }
const headers = (account: Account) => ({ authorization: `Bearer ${account.token}` });
async function register(): Promise<Account> {
  const response = await app.inject({ method: 'POST', url: '/v1/auth/register', payload: { email: `${runId}-${randomUUID()}@example.test`, password } });
  expect(response.statusCode).toBe(201);
  return response.json<Account>();
}
async function push(account: Account, operations: Operation[]): Promise<SyncResult[]> {
  const response = await app.inject({ method: 'POST', url: '/v1/sync/push', headers: headers(account), payload: { operations } });
  expect(response.statusCode).toBe(200);
  return response.json<{ results: SyncResult[] }>().results;
}
async function createStudent(account: Account) {
  const data = studentFixture();
  const operation = operationFixture('student', data);
  const results = await push(account, [operation]);
  expect(results[0]?.status).toBe('applied');
  return { data, operation, record: results[0]!.record! };
}

beforeAll(async () => {
  // Deliberately fail instead of skipping: a green test:ci requires real PostgreSQL.
  const url = process.env.TEST_DATABASE_URL;
  if (!url) throw new Error('TEST_DATABASE_URL is required for PostgreSQL integration tests. No database tests were skipped or mocked.');
  prisma = new PrismaClient({ datasources: { db: { url } }, log: [] });
  await prisma.$connect();
  app = await buildApp({ prisma, storageKey, authRateLimit: 10000, globalRateLimit: 10000,
    resetDelivery: { async sendPasswordReset(message) { delivered.push(message); } },
  });
  await app.ready();
});
afterAll(async () => {
  if (app) await app.close();
  if (prisma) {
    // Remove only synthetic users created by this test run, never truncate a database.
    await prisma.user.deleteMany({ where: { email: { startsWith: runId } } });
    await prisma.$disconnect();
  }
});

describe('real PostgreSQL account lifecycle', () => {
  it('reports actual readiness and returns safe request errors', async () => {
    expect((await app.inject('/health')).json()).toEqual({ status: 'ok', database: 'ready' });
    const response = await app.inject({ method: 'POST', url: '/v1/auth/register', payload: { email: 'bad', password, admin: true } });
    expect(response.statusCode).toBe(400);
    expect(response.json()).toEqual({ error: { code: 'INVALID_INPUT', message: 'راجع الحقول المطلوبة وصياغتها.' } });
    expect(response.body).not.toContain(password);
  });
  it('stores password and opaque session hashes, never the bearer token', async () => {
    const account = await register();
    const user = await prisma.user.findUniqueOrThrow({ where: { id: account.user.id } });
    const session = await prisma.authSession.findFirstOrThrow({ where: { userId: user.id } });
    expect(user.passwordHash).toMatch(/^scrypt\$/);
    expect(user.passwordHash).not.toContain(password);
    expect(session.tokenHash).toBe(tokenHash(account.token));
    expect(session.tokenHash).not.toBe(account.token);
    expect((await app.inject({ url: '/v1/auth/me', headers: headers(account) })).json()).toEqual({ user: account.user });
  });
  it('logs in, denies wrong credentials, revokes logout and expires sessions', async () => {
    const account = await register();
    const wrong = await app.inject({ method: 'POST', url: '/v1/auth/login', payload: { email: account.user.email, password: 'Wrong-password-123' } });
    expect(wrong.statusCode).toBe(401);
    const login = await app.inject({ method: 'POST', url: '/v1/auth/login', payload: { email: account.user.email, password } });
    expect(login.statusCode).toBe(200);
    const second = login.json<Account>();
    expect((await app.inject({ method: 'POST', url: '/v1/auth/logout', headers: headers(second) })).statusCode).toBe(204);
    expect((await app.inject({ url: '/v1/auth/me', headers: headers(second) })).statusCode).toBe(401);
    await prisma.authSession.updateMany({ where: { userId: account.user.id }, data: { expiresAt: new Date(0) } });
    expect((await app.inject({ url: '/v1/auth/me', headers: headers(account) })).statusCode).toBe(401);
  });
  it('returns generic reset requests, consumes tokens once and revokes all sessions', async () => {
    const account = await register();
    const known = await app.inject({ method: 'POST', url: '/v1/auth/password-reset/request', payload: { email: account.user.email } });
    const unknown = await app.inject({ method: 'POST', url: '/v1/auth/password-reset/request', payload: { email: `${runId}-missing@example.test` } });
    expect(known.statusCode).toBe(202);
    expect(known.body).toBe(unknown.body);
    const delivery = delivered.find(value => value.email === account.user.email)!;
    expect(delivery).toBeDefined();
    expect(known.body).not.toContain(delivery.token);
    const row = await prisma.passwordReset.findFirstOrThrow({ where: { userId: account.user.id } });
    expect(row.tokenHash).toBe(tokenHash(delivery.token));
    const newPassword = 'Changed-synthetic-password';
    const confirm = () => app.inject({ method: 'POST', url: '/v1/auth/password-reset/confirm', payload: { token: delivery.token, password: newPassword } });
    expect((await confirm()).statusCode).toBe(204);
    expect((await confirm()).statusCode).toBe(400);
    expect((await app.inject({ url: '/v1/auth/me', headers: headers(account) })).statusCode).toBe(401);
    expect((await app.inject({ method: 'POST', url: '/v1/auth/login', payload: { email: account.user.email, password } })).statusCode).toBe(401);
    expect((await app.inject({ method: 'POST', url: '/v1/auth/login', payload: { email: account.user.email, password: newPassword } })).statusCode).toBe(200);
  });
  it('rejects expired reset tokens and permits only one concurrent consume', async () => {
    const account = await register();
    await app.inject({ method: 'POST', url: '/v1/auth/password-reset/request', payload: { email: account.user.email } });
    const token = delivered.find(value => value.email === account.user.email)!.token;
    await prisma.passwordReset.updateMany({ where: { userId: account.user.id }, data: { expiresAt: new Date(0) } });
    expect((await app.inject({ method: 'POST', url: '/v1/auth/password-reset/confirm', payload: { token, password } })).statusCode).toBe(400);
    await app.inject({ method: 'POST', url: '/v1/auth/password-reset/request', payload: { email: account.user.email } });
    const latest = delivered.filter(value => value.email === account.user.email).at(-1)!;
    const responses = await Promise.all([1, 2].map(() => app.inject({ method: 'POST', url: '/v1/auth/password-reset/confirm', payload: { token: latest.token, password } })));
    expect(responses.map(response => response.statusCode).sort()).toEqual([204, 400]);
  });
  it('requires explicit password-confirmed deletion and cascades all user state', async () => {
    const account = await register();
    await createStudent(account);
    const denied = await app.inject({ method: 'DELETE', url: '/v1/auth/account', headers: headers(account), payload: { password, confirmed: false } });
    expect(denied.statusCode).toBe(400);
    const deleted = await app.inject({ method: 'DELETE', url: '/v1/auth/account', headers: headers(account), payload: { password, confirmed: true } });
    expect(deleted.statusCode).toBe(204);
    expect(await prisma.user.count({ where: { id: account.user.id } })).toBe(0);
    expect(await prisma.record.count({ where: { ownerId: account.user.id } })).toBe(0);
    expect(await prisma.syncOperation.count({ where: { ownerId: account.user.id } })).toBe(0);
    expect(await prisma.auditEvent.count({ where: { ownerId: account.user.id } })).toBe(0);
    expect((await app.inject({ url: '/v1/auth/me', headers: headers(account) })).statusCode).toBe(401);
  });
  it('reports unconfigured reset delivery rather than pretending mail was sent', async () => {
    const isolated = await buildApp({ prisma, storageKey });
    const response = await isolated.inject({ method: 'POST', url: '/v1/auth/password-reset/request', payload: { email: `${runId}-none@example.test` } });
    expect(response.statusCode).toBe(503);
    expect(response.json().error.code).toBe('RESET_DELIVERY_UNAVAILABLE');
    await isolated.close();
  });
  it('limits repeated authentication attempts', async () => {
    const isolated = await buildApp({ prisma, storageKey, authRateLimit: 2 });
    const send = () => isolated.inject({ method: 'POST', url: '/v1/auth/login', payload: { email: `${runId}-none@example.test`, password } });
    expect((await send()).statusCode).toBe(401);
    expect((await send()).statusCode).toBe(401);
    const throttled = await send();
    expect(throttled.statusCode).toBe(429);
    expect(throttled.json().error.code).toBe('RATE_LIMITED');
    await isolated.close();
  });
});

describe('owner isolation and encrypted durable synchronization', () => {
  it('requires authentication on all record and synchronization endpoints', async () => {
    for (const request of [{ method: 'GET', url: '/v1/records' }, { method: 'GET', url: `/v1/records/${randomUUID()}` }, { method: 'GET', url: '/v1/sync/pull' }, { method: 'POST', url: '/v1/sync/push', payload: { operations: [] } }] as const) {
      expect((await app.inject(request)).statusCode).toBe(401);
    }
  });
  it('persists encrypted student payloads and returns data only to their owner', async () => {
    const account = await register();
    const other = await register();
    const { data } = await createStudent(account);
    const row = await prisma.record.findUniqueOrThrow({ where: { ownerId_id: { ownerId: account.user.id, id: data.id } } });
    expect(row.encryptedPayload).not.toContain(data.code);
    expect(row.encryptedPayload).not.toContain(data.grade);
    const owned = await app.inject({ url: `/v1/records/${data.id}`, headers: headers(account) });
    expect(owned.json().record.data).toEqual(data);
    expect(owned.headers['cache-control']).toBe('no-store');
    expect((await app.inject({ url: `/v1/records/${data.id}`, headers: headers(other) })).statusCode).toBe(404);
    expect((await app.inject({ url: '/v1/records?kind=student', headers: headers(other) })).json().records).toEqual([]);
    expect((await app.inject({ url: '/v1/sync/pull', headers: headers(other) })).json()).toEqual({ records: [], fullSnapshot: true });
    const attempted = await push(other, [operationFixture('student', data, { baseRevision: 1 })]);
    expect(attempted[0]?.status).toBe('rejected');
    expect(attempted[0]?.record).toBeUndefined();
  });
  it('rejects identity, health and unexpected fields without storing them', async () => {
    const account = await register();
    for (const field of ['real_name', 'birth_date', 'medical_diagnosis', 'photo', 'ownerId']) {
      const data = { ...studentFixture(), [field]: 'synthetic forbidden input' };
      expect((await push(account, [operationFixture('student', data)]))[0]?.status).toBe('rejected');
    }
    expect(await prisma.record.count({ where: { ownerId: account.user.id } })).toBe(0);
    const receipts = await prisma.syncOperation.findMany({ where: { ownerId: account.user.id } });
    for (const receipt of receipts) {
      const plain = new PayloadCipher(storageKey).decrypt(receipt.encryptedResult, `operation:${account.user.id}:${receipt.operationId}`);
      expect(JSON.stringify(plain)).not.toContain('synthetic forbidden input');
      expect(JSON.stringify(plain)).not.toContain('real_name');
    }
  });
  it('rejects mismatched identifiers, duplicate anonymous codes and unavailable kinds', async () => {
    const account = await register();
    const { data } = await createStudent(account);
    expect((await push(account, [operationFixture('student', studentFixture({ code: data.code }))]))[0]?.error?.code).toBe('DUPLICATE_CODE');
    expect((await push(account, [operationFixture('student', studentFixture(), { entityId: randomUUID() })]))[0]?.error?.code).toBe('INVALID_RELATION');
    expect((await push(account, [operationFixture('plan', { id: randomUUID(), studentId: data.id }, { parentId: data.id })]))[0]?.error?.code).toBe('KIND_NOT_AVAILABLE');
  });
  it('replays an identical operation exactly and rejects reused IDs with changed content', async () => {
    const account = await register();
    const { operation, record } = await createStudent(account);
    expect((await push(account, [operation]))[0]?.record).toEqual(record);
    expect((await push(account, [{ ...operation, data: { ...operation.data, ageMonths: 3 } }]))[0]?.error?.code).toBe('OPERATION_REUSED');
    expect(await prisma.record.count({ where: { ownerId: account.user.id } })).toBe(1);
    expect(await prisma.syncOperation.count({ where: { ownerId: account.user.id } })).toBe(1);
  });
  it('handles concurrent duplicate submission once and competing revisions without overwrite', async () => {
    const account = await register();
    const data = studentFixture();
    const operation = operationFixture('student', data);
    const duplicates = await Promise.all([push(account, [operation]), push(account, [operation]), push(account, [operation])]);
    expect(duplicates.map(result => result[0]?.status)).toEqual(['applied', 'applied', 'applied']);
    expect(await prisma.syncOperation.count({ where: { ownerId: account.user.id } })).toBe(1);
    const a = operationFixture('student', { ...data, ageMonths: 4 }, { baseRevision: 1 });
    const b = operationFixture('student', { ...data, ageMonths: 5 }, { baseRevision: 1 });
    const raced = (await Promise.all([push(account, [a]), push(account, [b])])).flat();
    expect(raced.map(result => result.status).sort()).toEqual(['applied', 'conflict']);
    const conflict = raced.find(result => result.status === 'conflict')!;
    expect(conflict.record?.revision).toBe(2);
    const receipt = await prisma.syncOperation.findUniqueOrThrow({ where: { ownerId_operationId: { ownerId: account.user.id, operationId: conflict.operationId } } });
    const retained = new PayloadCipher(storageKey).decrypt<{ operation: Operation }>(receipt.encryptedResult, `operation:${account.user.id}:${conflict.operationId}`);
    expect(retained.operation).toEqual(conflict.operationId === a.operationId ? a : b);
    expect((await push(account, [retained.operation]))[0]).toEqual(conflict);
  });
  it('cascades tombstones and prevents delayed operations from resurrecting descendants', async () => {
    const account = await register();
    const { data } = await createStudent(account);
    const assessment = assessmentFixture(data.id);
    expect((await push(account, [operationFixture('assessment', assessment)]))[0]?.status).toBe('applied');
    const deletion = operationFixture('student', {}, { entityId: data.id, baseRevision: 1, action: 'delete' });
    expect((await push(account, [deletion]))[0]?.record?.deletedAt).toBeTruthy();
    const rows = (await app.inject({ url: '/v1/sync/pull', headers: headers(account) })).json<{ records: Envelope[] }>().records;
    expect(rows).toHaveLength(2);
    expect(rows.every(row => row.deletedAt !== null && row.revision === 2)).toBe(true);
    expect((await app.inject({ url: '/v1/records', headers: headers(account) })).json().records).toEqual([]);
    expect((await push(account, [operationFixture('assessment', assessment, { baseRevision: 1 })]))[0]?.status).toBe('conflict');
    expect((await push(account, [operationFixture('assessment', assessment, { baseRevision: 2 })]))[0]?.error?.code).toBe('RECORD_DELETED');
    expect((await push(account, [operationFixture('assessment', assessmentFixture(data.id))]))[0]?.error?.code).toBe('NOT_FOUND');
  });
});

describe('academic assessment API and human approval', () => {
  it('accepts ordered parent/assessment creation and preserves exact item judgments', async () => {
    const account = await register();
    const student = studentFixture();
    const assessment = assessmentFixture(student.id);
    assessment.results['1a'] = { ...assessment.results['1a']!, execution: 'unable', judgment: null };
    const results = await push(account, [operationFixture('student', student), operationFixture('assessment', assessment)]);
    expect(results.map(result => result.status)).toEqual(['applied', 'applied']);
    expect(results[1]?.record?.data).toEqual(assessment);
  });
  it('denies cross-owner parent references and enforces documented age overrides', async () => {
    const account = await register();
    const other = await register();
    const { data } = await createStudent(account);
    expect((await push(other, [operationFixture('assessment', assessmentFixture(data.id))]))[0]?.error?.code).toBe('NOT_FOUND');
    const olderCard = assessmentFixture(data.id, { ageGroup: '9-12' });
    expect((await push(account, [operationFixture('assessment', olderCard)]))[0]?.error?.code).toBe('AGE_OVERRIDE_REQUIRED');
    expect((await push(account, [operationFixture('assessment', { ...olderCard, ageOverrideReason: 'مراجعة تربوية تجريبية' })]))[0]?.status).toBe('applied');
    const outside = studentFixture({ ageYears: 14 });
    await push(account, [operationFixture('student', outside)]);
    expect((await push(account, [operationFixture('assessment', assessmentFixture(outside.id, { ageOverrideReason: 'لا يتجاوز العمر المسموح' }))]))[0]?.error?.code).toBe('MANUAL_ASSESSMENT_REQUIRED');
  });
  it('validates approval, stamps reviewer audit and makes approved assessments immutable', async () => {
    const account = await register();
    const { data } = await createStudent(account);
    const assessment = assessmentFixture(data.id);
    await push(account, [operationFixture('assessment', assessment)]);
    const approved = { ...assessment, status: 'approved' as const, approvedAt: fixtureTime, strengths: 'تمييز الأصوات', needs: 'دعم القراءة' };
    expect((await push(account, [operationFixture('assessment', { ...approved, needs: '' }, { baseRevision: 1 })]))[0]?.error?.code).toBe('INVALID_INPUT');
    expect((await push(account, [operationFixture('assessment', approved, { baseRevision: 1 })]))[0]?.status).toBe('applied');
    const audit = await prisma.auditEvent.findFirstOrThrow({ where: { ownerId: account.user.id, entityId: assessment.id, action: 'assessment.approved' } });
    expect(audit.createdAt).toBeInstanceOf(Date);
    expect((await push(account, [operationFixture('assessment', { ...approved, needs: 'تعديل' }, { baseRevision: 2 })]))[0]?.error?.code).toBe('ASSESSMENT_IMMUTABLE');
    const other = await register();
    expect((await app.inject({ url: `/v1/records/${assessment.id}`, headers: headers(other) })).statusCode).toBe(404);
  });
  it('freezes template and group once created and does not expose decrypted corruption', async () => {
    const account = await register();
    const { data } = await createStudent(account);
    const assessment = assessmentFixture(data.id);
    await push(account, [operationFixture('assessment', assessment)]);
    const swapped = assessmentFixture(data.id, { id: assessment.id, ageGroup: '9-12', ageOverrideReason: 'مبرر' });
    expect((await push(account, [operationFixture('assessment', swapped, { baseRevision: 1 })]))[0]?.error?.code).toBe('TEMPLATE_IMMUTABLE');
    await prisma.record.update({ where: { ownerId_id: { ownerId: account.user.id, id: assessment.id } }, data: { encryptedPayload: 'corrupted' } });
    const response = await app.inject({ url: `/v1/records/${assessment.id}`, headers: headers(account) });
    expect(response.statusCode).toBe(503);
    expect(response.body).not.toContain('corrupted');
    expect(response.body).not.toContain('stack');
  });
});
