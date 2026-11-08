import { randomBytes, randomUUID } from 'node:crypto';
import { PrismaClient } from '@prisma/client';
import { afterAll, afterEach, beforeAll, beforeEach, expect, it, vi } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../src/app.js';
import { defaultTools, type ActivityPayload } from '../src/activities/domain.js';
import { createDraft, approvePlan } from '../src/planning/domain.js';
import { aiContent } from './ai.fixtures.js';
import { studentFixture, operationFixture } from './fixtures.js';
import type { Envelope, SyncResult } from '../src/records.js';

const run = `test-activities-${randomUUID()}`;
const key = randomBytes(32);
const generate = vi.fn<(payload: ActivityPayload) => Promise<unknown>>();
const activity = () => ({ title: 'بطاقات تجريبية', steps: ['اعرض البطاقات'], examples: ['اختر الحرف المطلوب'], feedback: 'قدم نموذجًا ثم شجع المحاولة',
  measurement: 'سجل عدد الإجابات الصحيحة من المحاولات المنفذة', preparation: ['أعد البطاقات'], tools: ['cards'], minutes: 20, lowCostAlternatives: [], teacherNotes: '' });
let prisma: PrismaClient;
let app: FastifyInstance;
let now: Date;
interface Account { token: string; user: { id: string } }
const headers = (account: Account) => ({ authorization: `Bearer ${account.token}` });
beforeAll(async () => {
  if (!process.env.TEST_DATABASE_URL) throw new Error('TEST_DATABASE_URL is required; no skipped database integration tests');
  prisma = new PrismaClient({ datasources: { db: { url: process.env.TEST_DATABASE_URL } }, log: [] });
  await prisma.$connect();
});
beforeEach(async () => {
  now = new Date('2026-11-08T10:00:00Z');
  generate.mockReset().mockImplementation(async () => activity());
  app = await buildApp({ prisma, storageKey: key, clock: () => now, authRateLimit: 10000, globalRateLimit: 10000,
    activities: { enabled: true, syntheticOnly: true, model: 'injected-test-provider', provider: { generate } } });
});
afterEach(async () => {
  await app.close();
  await prisma.user.deleteMany({ where: { email: { startsWith: run } } });
});
afterAll(async () => { await prisma?.$disconnect(); });
async function register(): Promise<Account> {
  const response = await app.inject({ method: 'POST', url: '/v1/auth/register', payload: { email: `${run}-${randomUUID()}@example.test`, password: 'Synthetic-password-123456' } });
  expect(response.statusCode).toBe(201);
  return response.json<Account>();
}
async function setup(account: Account, approved = true) {
  const student = studentFixture();
  const response = await app.inject({ method: 'POST', url: '/v1/sync/push', headers: headers(account), payload: { operations: [operationFixture('student', student)] } });
  expect(response.json<{ results: SyncResult[] }>().results[0]!.status).toBe('applied');
  const draft = createDraft(aiContent(), student.id, 'ai', now);
  const plan = approved ? approvePlan(draft, account.user.id, true, now) : draft;
  // Seeding a real encrypted approved plan isolates this module from provider tests.
  const { PayloadCipher } = await import('../src/crypto.js');
  const cipher = new PayloadCipher(key);
  await prisma.record.create({ data: { id: plan.id, ownerId: account.user.id, parentId: student.id, kind: 'plan',
    encryptedPayload: cipher.encrypt({ ...plan, history: [] }, `record:${account.user.id}:${plan.id}`) } });
  const tools = await app.inject({ method: 'PUT', url: '/v1/activities/tools', headers: headers(account), payload: { revision: 0, tools: defaultTools, privacyReviewed: true } });
  expect(tools.statusCode).toBe(200);
  const input = { studentId: student.id, planId: plan.id, goalId: plan.content.goals[0]!.id, domain: 'reading', grade: student.grade,
    difficulty: 'practice', type: 'cards', toolIds: ['cards'], minutes: 20, mode: 'individual', privacyReviewed: true, syntheticDataConfirmed: true };
  return { student, plan, input };
}
async function preview(account: Account, input: Record<string, unknown>) {
  const response = await app.inject({ method: 'POST', url: '/v1/activities/preview', headers: headers(account), payload: input });
  expect(response.statusCode).toBe(200);
  const value = response.json<{ payload: ActivityPayload; hash: string; previewToken: string }>();
  return { value, request: { previewToken: value.previewToken, confirmedHash: value.hash, operationId: randomUUID(), confirmed: true, syntheticDataConfirmed: true } };
}
it('persists tool profile per owner and checks stale settings revisions', async () => {
  const first = await register(), second = await register();
  await setup(first);
  const other = await app.inject({ method: 'GET', url: '/v1/activities/tools', headers: headers(second) });
  expect(other.json()).toMatchObject({ configured: false, revision: 0 });
  const stale = await app.inject({ method: 'PUT', url: '/v1/activities/tools', headers: headers(first), payload: { revision: 0, tools: defaultTools, privacyReviewed: true } });
  expect(stale.statusCode).toBe(409);
});
it('excludes IDs and raw assessment data from exact reviewed payload and saves a suggested draft', async () => {
  const account = await register();
  const source = await setup(account);
  const { value, request } = await preview(account, source.input);
  expect(JSON.stringify(value.payload)).not.toMatch(/studentId|ownerId|planId|goalId|ST-|response|observation/);
  const response = await app.inject({ method: 'POST', url: '/v1/activities/generate', headers: headers(account), payload: request });
  expect(response.statusCode).toBe(201);
  const record = response.json<{ record: Envelope }>().record;
  expect(record.data).toMatchObject({ status: 'draft', suggested: true, approvedBy: null, planId: source.plan.id });
  expect(record.data.toolSnapshot).toEqual(value.payload.availableTools);
  const stored = await prisma.record.findUniqueOrThrow({ where: { ownerId_id: { ownerId: account.user.id, id: record.id } } });
  expect(stored.encryptedPayload).not.toContain('بطاقات');
  expect(generate).toHaveBeenCalledExactlyOnceWith(value.payload);
});
it('rejects another owner source and stolen preview token without calling provider', async () => {
  const account = await register(), other = await register();
  const source = await setup(account);
  const stolenSource = await app.inject({ method: 'POST', url: '/v1/activities/preview', headers: headers(other), payload: source.input });
  expect(stolenSource.statusCode).toBe(404);
  const { request } = await preview(account, source.input);
  const stolenToken = await app.inject({ method: 'POST', url: '/v1/activities/generate', headers: headers(other), payload: request });
  expect(stolenToken.statusCode).toBe(400);
  expect(generate).not.toHaveBeenCalled();
});
it('blocks activities for an unapproved plan', async () => {
  const account = await register();
  const source = await setup(account, false);
  const response = await app.inject({ method: 'POST', url: '/v1/activities/preview', headers: headers(account), payload: source.input });
  expect(response.statusCode).toBe(409);
  expect(generate).not.toHaveBeenCalled();
});
it('requires exact confirmation, expires new previews and never approves from model output', async () => {
  const account = await register(), source = await setup(account);
  const { request } = await preview(account, source.input);
  const denied = await app.inject({ method: 'POST', url: '/v1/activities/generate', headers: headers(account), payload: { ...request, confirmed: false } });
  expect(denied.statusCode).toBe(400);
  const wrongHash = await app.inject({ method: 'POST', url: '/v1/activities/generate', headers: headers(account), payload: { ...request, confirmedHash: '0'.repeat(64) } });
  expect(wrongHash.statusCode).toBe(400);
  now = new Date(now.getTime() + 11 * 60000);
  const expired = await app.inject({ method: 'POST', url: '/v1/activities/generate', headers: headers(account), payload: request });
  expect(expired.statusCode).toBe(409);
  expect(generate).not.toHaveBeenCalled();
});
it('recovers a committed operation after preview expiry without a second provider call', async () => {
  const account = await register(), source = await setup(account);
  const { request } = await preview(account, source.input);
  const first = await app.inject({ method: 'POST', url: '/v1/activities/generate', headers: headers(account), payload: request });
  expect(first.statusCode).toBe(201);
  now = new Date(now.getTime() + 11 * 60000);
  const second = await app.inject({ method: 'POST', url: '/v1/activities/generate', headers: headers(account), payload: request });
  expect(second.statusCode).toBe(200);
  expect(second.json()).toEqual(first.json());
  expect(generate).toHaveBeenCalledTimes(1);
  const changed = await app.inject({ method: 'POST', url: '/v1/activities/generate', headers: headers(account), payload: { ...request, confirmedHash: '1'.repeat(64) } });
  expect(changed.statusCode).toBe(400);
});
it('provider failure and unsafe output save no fallback and failed retries do not repeat calls', async () => {
  const account = await register(), source = await setup(account);
  const { request } = await preview(account, source.input);
  generate.mockRejectedValueOnce(new Error('synthetic upstream failure'));
  const failed = await app.inject({ method: 'POST', url: '/v1/activities/generate', headers: headers(account), payload: request });
  expect(failed.statusCode).toBe(502);
  const retry = await app.inject({ method: 'POST', url: '/v1/activities/generate', headers: headers(account), payload: request });
  expect(retry.json()).toMatchObject({ error: { code: 'AI_PREVIOUS_FAILED' } });
  expect(generate).toHaveBeenCalledTimes(1);
  generate.mockResolvedValueOnce({ ...activity(), feedback: 'طالب كسول' });
  const next = (await preview(account, source.input)).request;
  const unsafe = await app.inject({ method: 'POST', url: '/v1/activities/generate', headers: headers(account), payload: next });
  expect(unsafe.json()).toMatchObject({ error: { code: 'AI_OUTPUT_INVALID' } });
  expect(await prisma.record.count({ where: { ownerId: account.user.id, kind: 'activity' } })).toBe(0);
});
it('rejects changed tools after preview and preserves source review', async () => {
  const account = await register(), source = await setup(account);
  const { request } = await preview(account, source.input);
  const changed = await app.inject({ method: 'PUT', url: '/v1/activities/tools', headers: headers(account), payload: { revision: 1, tools: defaultTools.slice(0, 1), privacyReviewed: true } });
  expect(changed.statusCode).toBe(200);
  const response = await app.inject({ method: 'POST', url: '/v1/activities/generate', headers: headers(account), payload: request });
  expect(response.json()).toMatchObject({ error: { code: 'SOURCE_CHANGED' } });
  expect(generate).not.toHaveBeenCalled();
});
it('only owning specialist can explicitly approve the reviewed activity revision', async () => {
  const account = await register(), other = await register(), source = await setup(account);
  const { request } = await preview(account, source.input);
  const generated = await app.inject({ method: 'POST', url: '/v1/activities/generate', headers: headers(account), payload: request });
  const record = generated.json<{ record: Envelope }>().record;
  const endpoint = `/v1/activities/${record.id}/approve`;
  const denied = await app.inject({ method: 'POST', url: endpoint, headers: headers(other), payload: { revision: record.revision, confirmed: true } });
  expect(denied.statusCode).toBe(404);
  const explicit = await app.inject({ method: 'POST', url: endpoint, headers: headers(account), payload: { revision: record.revision, confirmed: false } });
  expect(explicit.statusCode).toBe(400);
  const approved = await app.inject({ method: 'POST', url: endpoint, headers: headers(account), payload: { revision: record.revision, confirmed: true } });
  expect(approved.json<{ record: Envelope }>().record.data).toMatchObject({ status: 'approved', suggested: false, approvedBy: account.user.id });
  const repeat = await app.inject({ method: 'POST', url: endpoint, headers: headers(account), payload: { revision: record.revision, confirmed: true } });
  expect(repeat.statusCode).toBe(409);
});

it('explicit cancellation preserves its receipt and prevents a late provider result from creating an activity', async () => {
  const account = await register(), other = await register(), source = await setup(account);
  const { request } = await preview(account, source.input);
  let release!: () => void, started!: () => void;
  const began = new Promise<void>(resolve => { started = resolve; });
  const hold = new Promise<void>(resolve => { release = resolve; });
  generate.mockImplementationOnce(async () => { started(); await hold; return activity(); });
  const pending = app.inject({ method: 'POST', url: '/v1/activities/generate', headers: headers(account), payload: request });
  // Begin Fastify's thenable injection before awaiting the provider barrier.
  const response = pending.then(result => result);
  await began;
  try {
    const path = `/v1/activities/operations/${request.operationId}`;
    expect((await app.inject({ method: 'GET', url: path, headers: headers(other) })).statusCode).toBe(404);
    expect((await app.inject({ method: 'POST', url: `${path}/cancel`, headers: headers(account), payload: { confirmed: false } })).statusCode).toBe(400);
    const cancelled = await app.inject({ method: 'POST', url: `${path}/cancel`, headers: headers(account), payload: { confirmed: true } });
    expect(cancelled.json()).toMatchObject({ state: 'cancelled' });
    expect((await app.inject({ method: 'POST', url: `${path}/cancel`, headers: headers(account), payload: { confirmed: true } })).statusCode).toBe(200);
  } finally { release(); }
  expect((await response).json()).toMatchObject({ error: { code: 'AI_OPERATION_CANCELLED' } });
  expect(await prisma.record.count({ where: { ownerId: account.user.id, kind: 'activity' } })).toBe(0);
  const replay = await app.inject({ method: 'POST', url: '/v1/activities/generate', headers: headers(account), payload: request });
  expect(replay.json()).toMatchObject({ error: { code: 'AI_OPERATION_CANCELLED' } });
  expect(generate).toHaveBeenCalledTimes(1);
});
it('expired activity leases remain recoverable by explicit cancellation without accepting late content', async () => {
  const account = await register(), source = await setup(account);
  const { request } = await preview(account, source.input);
  let release!: () => void, started!: () => void;
  const began = new Promise<void>(resolve => { started = resolve; });
  const hold = new Promise<void>(resolve => { release = resolve; });
  generate.mockImplementationOnce(async () => { started(); await hold; return activity(); });
  const pending = app.inject({ method: 'POST', url: '/v1/activities/generate', headers: headers(account), payload: request }).then(value => value);
  await began;
  now = new Date(now.getTime() + 11 * 60000);
  release();
  expect((await pending).json()).toMatchObject({ error: { code: 'AI_OPERATION_EXPIRED' } });
  const path = `/v1/activities/operations/${request.operationId}`;
  expect((await app.inject({ method: 'GET', url: path, headers: headers(account) })).json()).toMatchObject({ state: 'expired', canCancel: true });
  expect((await app.inject({ method: 'POST', url: `${path}/cancel`, headers: headers(account), payload: { confirmed: true } })).statusCode).toBe(200);
  const next = await preview(account, source.input);
  const generated = await app.inject({ method: 'POST', url: '/v1/activities/generate', headers: headers(account), payload: next.request });
  expect(generated.statusCode).toBe(201);
  expect(await prisma.record.count({ where: { ownerId: account.user.id, kind: 'activity' } })).toBe(1);
});
