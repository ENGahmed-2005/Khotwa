import { randomBytes, randomUUID } from 'node:crypto';
import { PrismaClient } from '@prisma/client';
import type { FastifyInstance } from 'fastify';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { buildApp } from '../src/app.js';
import { canonicalJson, PayloadCipher, tokenHash } from '../src/crypto.js';
import { AI_OPERATION_LEASE_MS } from '../src/ai/routes.js';
import type { GenerationInput } from '../src/planning/domain.js';
import type { Envelope, SyncResult } from '../src/records.js';
import { assessmentFixture, fixtureTime, operationFixture, studentFixture } from './fixtures.js';
import { aiContent, aiInput } from './ai.fixtures.js';

const runId = `test-ai-${randomUUID()}`;
const password = 'Synthetic-password-12345';
const storageKey = randomBytes(32);
const cipher = new PayloadCipher(storageKey);
const startTime = '2026-11-06T10:00:00Z';
const generate = vi.fn<(payload: GenerationInput) => Promise<unknown>>();
let prisma: PrismaClient;
let app: FastifyInstance;
let now: Date;
interface Account { token: string; user: { id: string; email: string; role: string } }
interface Preview { payload: GenerationInput; hash: string; previewToken: string; expiresAt: string }
const headers = (account: Account) => ({ authorization: `Bearer ${account.token}` });
async function register(): Promise<Account> {
  const response = await app.inject({ method: 'POST', url: '/v1/auth/register', payload: { email: `${runId}-${randomUUID()}@example.test`, password } });
  expect(response.statusCode).toBe(201);
  return response.json<Account>();
}
async function source(account: Account, approved = true) {
  const student = studentFixture();
  const assessment = assessmentFixture(student.id, { status: approved ? 'approved' : 'draft', approvedAt: approved ? fixtureTime : null,
    strengths: 'SYNTHETIC-PRIVATE-STRENGTHS', needs: 'SYNTHETIC-PRIVATE-NEEDS' });
  assessment.results['1a']!.response = 'SYNTHETIC-PRIVATE-RAW-ANSWER';
  assessment.results['1a']!.observation = 'SYNTHETIC-PRIVATE-OBSERVATION';
  for (const operation of [operationFixture('student', student), operationFixture('assessment', assessment)]) {
    const response = await app.inject({ method: 'POST', url: '/v1/sync/push', headers: headers(account), payload: { operations: [operation] } });
    expect(response.json<{ results: SyncResult[] }>().results[0]?.status).toBe('applied');
  }
  return { student, assessment };
}
type Source = Awaited<ReturnType<typeof source>>;
const previewInput = (data: Source) => ({ ...structuredClone(aiInput), studentId: data.student.id, assessmentId: data.assessment.id, syntheticDataConfirmed: true });
async function preview(account: Account, data: Source): Promise<Preview> {
  const response = await app.inject({ method: 'POST', url: '/v1/ai/preview', headers: headers(account), payload: previewInput(data) });
  expect(response.statusCode).toBe(200);
  return response.json<Preview>();
}
const generationInput = (value: Preview) => ({ previewToken: value.previewToken, confirmedHash: value.hash, confirmed: true, syntheticDataConfirmed: true, operationId: randomUUID() });
async function draft(account: Account, data: Source) {
  const input = generationInput(await preview(account, data));
  const response = await app.inject({ method: 'POST', url: '/v1/ai/generate', headers: headers(account), payload: input });
  expect(response.statusCode).toBe(201);
  return { input, record: response.json<{ record: Envelope }>().record };
}

beforeAll(async () => {
  const url = process.env.TEST_DATABASE_URL;
  if (!url) throw new Error('TEST_DATABASE_URL is required; AI database integration tests are never skipped or mocked.');
  prisma = new PrismaClient({ datasources: { db: { url } }, log: [] });
  await prisma.$connect();
});

describe('explicit cancellation and bounded durable generation leases', () => {
  it('requires authenticated owning specialists for status and cancellation', async () => {
    const operationId = randomUUID();
    for (const route of [{ method: 'GET' as const, url: `/v1/ai/operations/${operationId}` },
      { method: 'POST' as const, url: `/v1/ai/operations/${operationId}/cancel`, payload: { confirmed: true } }]) {
      expect((await app.inject(route)).statusCode).toBe(401);
    }
    const owner = await register();
    const other = await register();
    const data = await source(owner);
    const generated = await draft(owner, data);
    for (const route of [{ method: 'GET' as const, url: `/v1/ai/operations/${generated.input.operationId}` },
      { method: 'POST' as const, url: `/v1/ai/operations/${generated.input.operationId}/cancel`, payload: { confirmed: true } }]) {
      expect((await app.inject({ ...route, headers: headers(other) })).statusCode).toBe(404);
      await prisma.user.update({ where: { id: other.user.id }, data: { role: 'viewer' } });
      expect((await app.inject({ ...route, headers: headers(other) })).statusCode).toBe(403);
      await prisma.user.update({ where: { id: other.user.id }, data: { role: 'specialist' } });
    }
  });

  it('cancels through another server instance and prevents a late result from creating a plan', async () => {
    const owner = await register();
    const data = await source(owner);
    const input = generationInput(await preview(owner, data));
    let release!: () => void;
    const barrier = new Promise<void>(resolve => { release = resolve; });
    generate.mockImplementationOnce(async () => { await barrier; return aiContent(); });
    const first = app.inject({ method: 'POST', url: '/v1/ai/generate', headers: headers(owner), payload: input }).then(value => value);
    await vi.waitFor(() => expect(generate).toHaveBeenCalledTimes(1));
    const replica = await buildApp({ prisma, storageKey, clock: () => now });
    try {
      const status = await replica.inject({ url: `/v1/ai/operations/${input.operationId}`, headers: headers(owner) });
      expect(status.json()).toMatchObject({ state: 'pending', canCancel: true, startedAt: now.toISOString(), leaseExpiresAt: new Date(now.getTime() + AI_OPERATION_LEASE_MS).toISOString() });
      const cancel = (confirmed: boolean) => replica.inject({ method: 'POST', url: `/v1/ai/operations/${input.operationId}/cancel`, headers: headers(owner), payload: { confirmed } });
      expect((await cancel(false)).statusCode).toBe(400);
      const cancelled = await cancel(true);
      expect(cancelled.statusCode).toBe(200);
      expect((await cancel(true)).json()).toEqual(cancelled.json());
      release();
      const response = await first;
      expect(response.statusCode).toBe(409);
      expect(response.json().error.code).toBe('AI_OPERATION_CANCELLED');
      expect(await prisma.record.count({ where: { ownerId: owner.user.id, kind: 'plan' } })).toBe(0);
      expect((await app.inject({ method: 'POST', url: '/v1/ai/generate', headers: headers(owner), payload: input })).json().error.code).toBe('AI_OPERATION_CANCELLED');
      expect(generate).toHaveBeenCalledTimes(1);
      expect((await draft(owner, data)).record.data.status).toBe('draft');
      expect(generate).toHaveBeenCalledTimes(2);
      expect((await replica.inject({ url: `/v1/ai/operations/${input.operationId}`, headers: headers(owner) })).json().state).toBe('cancelled');
    } finally { release(); await first; await replica.close(); }
  });

  it('does not turn cancellation into failure when a provider rejects later', async () => {
    const owner = await register();
    const data = await source(owner);
    const input = generationInput(await preview(owner, data));
    let release!: () => void;
    const barrier = new Promise<void>(resolve => { release = resolve; });
    generate.mockImplementationOnce(async () => { await barrier; throw new Error('SYNTHETIC-LATE-PROVIDER-SECRET'); });
    const first = app.inject({ method: 'POST', url: '/v1/ai/generate', headers: headers(owner), payload: input }).then(value => value);
    await vi.waitFor(() => expect(generate).toHaveBeenCalledTimes(1));
    try {
      expect((await app.inject({ method: 'POST', url: `/v1/ai/operations/${input.operationId}/cancel`, headers: headers(owner), payload: { confirmed: true } })).statusCode).toBe(200);
    } finally { release(); }
    const response = await first;
    expect(response.statusCode).toBe(409);
    expect(response.body).not.toContain('SYNTHETIC-LATE-PROVIDER-SECRET');
    expect((await app.inject({ url: `/v1/ai/operations/${input.operationId}`, headers: headers(owner) })).json().state).toBe('cancelled');
  });

  it('expires legacy pending receipts after a crash without silently calling the provider again', async () => {
    const owner = await register();
    const data = await source(owner);
    const input = generationInput(await preview(owner, data));
    await prisma.syncOperation.create({ data: { ownerId: owner.user.id, operationId: input.operationId,
      requestHash: tokenHash(canonicalJson({ namespace: 'ai-generate', ...input })),
      createdAt: new Date(now.getTime() - AI_OPERATION_LEASE_MS - 1),
      encryptedResult: cipher.encrypt({ namespace: 'ai-generate', state: 'pending' }, `operation:${owner.user.id}:${input.operationId}`) } });
    const status = await app.inject({ url: `/v1/ai/operations/${input.operationId}`, headers: headers(owner) });
    expect(status.json()).toMatchObject({ state: 'expired', canCancel: true });
    const replay = await app.inject({ method: 'POST', url: '/v1/ai/generate', headers: headers(owner), payload: input });
    expect(replay.statusCode).toBe(409);
    expect(replay.json().error.code).toBe('AI_OPERATION_EXPIRED');
    expect(generate).not.toHaveBeenCalled();
    expect((await app.inject({ method: 'POST', url: `/v1/ai/operations/${input.operationId}/cancel`, headers: headers(owner), payload: { confirmed: true } })).statusCode).toBe(200);
    expect((await draft(owner, data)).record.data.status).toBe('draft');
    expect(generate).toHaveBeenCalledTimes(1);
  });

  it('discards an expired in-flight result while a fresh explicitly confirmed operation succeeds', async () => {
    const owner = await register();
    const data = await source(owner);
    const input = generationInput(await preview(owner, data));
    let release!: () => void;
    const barrier = new Promise<void>(resolve => { release = resolve; });
    generate.mockImplementationOnce(async () => { await barrier; return aiContent(); });
    const first = app.inject({ method: 'POST', url: '/v1/ai/generate', headers: headers(owner), payload: input }).then(value => value);
    await vi.waitFor(() => expect(generate).toHaveBeenCalledTimes(1));
    try {
      now = new Date(now.getTime() + AI_OPERATION_LEASE_MS + 1);
      const fresh = await draft(owner, data);
      expect(fresh.input.operationId).not.toBe(input.operationId);
      release();
      const late = await first;
      expect(late.statusCode).toBe(409);
      expect(late.json().error.code).toBe('AI_OPERATION_EXPIRED');
      expect(await prisma.record.count({ where: { ownerId: owner.user.id, kind: 'plan' } })).toBe(1);
      expect((await app.inject({ url: `/v1/ai/operations/${input.operationId}`, headers: headers(owner) })).json().state).toBe('expired');
      expect(generate).toHaveBeenCalledTimes(2);
    } finally { release(); await first; }
  });

  it('refuses to cancel a committed result and keeps its existing draft intact', async () => {
    const owner = await register();
    const data = await source(owner);
    const generated = await draft(owner, data);
    const result = await app.inject({ method: 'POST', url: `/v1/ai/operations/${generated.input.operationId}/cancel`, headers: headers(owner), payload: { confirmed: true } });
    expect(result.statusCode).toBe(409);
    expect(result.json().error.code).toBe('AI_OPERATION_FINISHED');
    const status = await app.inject({ url: `/v1/ai/operations/${generated.input.operationId}`, headers: headers(owner) });
    expect(status.json()).toMatchObject({ state: 'completed', recordId: generated.record.id, canCancel: false });
    expect((await app.inject({ url: `/v1/records/${generated.record.id}`, headers: headers(owner) })).json().record).toEqual(generated.record);
    expect(generate).toHaveBeenCalledTimes(1);
  });
});
beforeEach(async () => {
  now = new Date(startTime);
  generate.mockReset().mockImplementation(async () => aiContent());
  app = await buildApp({ prisma, storageKey, clock: () => now, authRateLimit: 10000, globalRateLimit: 10000,
    ai: { enabled: true, syntheticOnly: true, model: 'synthetic-test-provider', provider: { generate } } });
  await app.ready();
});
afterEach(async () => { if (app) await app.close(); });
afterAll(async () => {
  if (prisma) {
    await prisma.user.deleteMany({ where: { email: { startsWith: runId } } });
    await prisma.$disconnect();
  }
});

describe('AI owner boundaries and consent on real PostgreSQL', () => {
  it('requires an authenticated specialist at every AI and approval endpoint', async () => {
    const routes = [
      { method: 'GET' as const, url: `/v1/ai/skills?assessmentId=${randomUUID()}` },
      { method: 'POST' as const, url: '/v1/ai/preview' },
      { method: 'POST' as const, url: '/v1/ai/generate' },
      { method: 'POST' as const, url: `/v1/plans/${randomUUID()}/approve` },
    ];
    for (const route of routes) expect((await app.inject(route)).statusCode).toBe(401);
    const account = await register();
    await prisma.user.update({ where: { id: account.user.id }, data: { role: 'viewer' } });
    for (const route of routes) expect((await app.inject({ ...route, headers: headers(account) })).statusCode).toBe(403);
    expect(generate).not.toHaveBeenCalled();
  });
  it('does not enable processing merely because routes exist or a server key is configured', async () => {
    const account = await register();
    const disabled = await buildApp({ prisma, storageKey });
    const wrongPolicy = await buildApp({ prisma, storageKey, ai: { enabled: true, syntheticOnly: false, model: 'synthetic', provider: { generate } } });
    try {
      expect((await disabled.inject({ method: 'POST', url: '/v1/ai/preview', headers: headers(account), payload: {} })).statusCode).toBe(503);
      expect((await wrongPolicy.inject({ method: 'POST', url: '/v1/ai/preview', headers: headers(account), payload: {} })).statusCode).toBe(403);
      expect(generate).not.toHaveBeenCalled();
    } finally { await disabled.close(); await wrongPolicy.close(); }
  });
  it('denies cross-owner skills, preview, signed token and plan approval', async () => {
    const owner = await register();
    const other = await register();
    const data = await source(owner);
    expect((await app.inject({ url: `/v1/ai/skills?assessmentId=${data.assessment.id}`, headers: headers(other) })).statusCode).toBe(404);
    expect((await app.inject({ method: 'POST', url: '/v1/ai/preview', headers: headers(other), payload: previewInput(data) })).statusCode).toBe(404);
    const token = await preview(owner, data);
    expect((await app.inject({ method: 'POST', url: '/v1/ai/generate', headers: headers(other), payload: generationInput(token) })).statusCode).toBe(400);
    const generated = await draft(owner, data);
    expect((await app.inject({ method: 'POST', url: `/v1/plans/${generated.record.id}/approve`, headers: headers(other), payload: { revision: 1, confirmed: true } })).statusCode).toBe(404);
    expect((await app.inject({ url: `/v1/records/${generated.record.id}`, headers: headers(other) })).statusCode).toBe(404);
    expect((await app.inject({ url: '/v1/records?kind=plan', headers: headers(other) })).json()).toEqual({ records: [] });
    expect(generate).toHaveBeenCalledTimes(1);
  });
  it('requires a complete approved assessment and rejects unreviewed or unknown skill input', async () => {
    const account = await register();
    const incomplete = await source(account, false);
    expect((await app.inject({ url: `/v1/ai/skills?assessmentId=${incomplete.assessment.id}`, headers: headers(account) })).statusCode).toBe(409);
    expect((await app.inject({ method: 'POST', url: '/v1/ai/preview', headers: headers(account), payload: previewInput(incomplete) })).statusCode).toBe(409);
    const data = await source(account);
    for (const patch of [
      { syntheticDataConfirmed: false }, { rawText: 'SYNTHETIC-PRIVATE-TEXT' },
      { skills: [{ ...aiInput.skills[0], skillId: 'medical.diagnosis' }] },
      { skills: [{ ...aiInput.skills[0], evidence: 'approvedAlternativeAssessment' }] },
      { skills: [aiInput.skills[0], aiInput.skills[0]] },
      { skills: [{ ...aiInput.skills[0], level: 'mastered' }] },
      { availableTools: ['cards', 'cards'] },
    ]) {
      expect((await app.inject({ method: 'POST', url: '/v1/ai/preview', headers: headers(account), payload: { ...previewInput(data), ...patch } })).statusCode).toBe(400);
    }
    expect(generate).not.toHaveBeenCalled();
  });
  it('shows only a controlled preview and sends nothing before exact confirmation', async () => {
    const account = await register();
    const data = await source(account);
    const skills = await app.inject({ url: `/v1/ai/skills?assessmentId=${data.assessment.id}`, headers: headers(account) });
    expect(skills.statusCode).toBe(200);
    expect(skills.body).not.toContain('SYNTHETIC-PRIVATE');
    const value = await preview(account, data);
    expect(value.payload).toEqual(aiInput);
    expect(value.expiresAt).toBe('2026-11-06T10:10:00.000Z');
    for (const patch of [{ confirmed: false }, { syntheticDataConfirmed: false }, { confirmedHash: 'a'.repeat(64) }, { rawText: 'SYNTHETIC-PRIVATE-TEXT' }]) {
      expect((await app.inject({ method: 'POST', url: '/v1/ai/generate', headers: headers(account), payload: { ...generationInput(value), ...patch } })).statusCode).toBe(400);
    }
    const valid = generationInput(value);
    expect((await app.inject({ method: 'POST', url: '/v1/ai/generate', headers: headers(account), payload: valid })).statusCode).toBe(201);
    expect(generate).toHaveBeenCalledWith(aiInput, expect.any(AbortSignal));
    expect(JSON.stringify(generate.mock.calls)).not.toContain('SYNTHETIC-PRIVATE');
    expect(JSON.stringify(generate.mock.calls)).not.toContain(data.student.code);
    expect(JSON.stringify(generate.mock.calls)).not.toContain(data.student.id);
    expect(JSON.stringify(generate.mock.calls)).not.toContain(account.user.email);
  });
});

describe('durable generation and explicit approval', () => {
  it('stores encrypted draft with source/audit and explicit approval history', async () => {
    const account = await register();
    const data = await source(account);
    const { record } = await draft(account, data);
    expect(record).toMatchObject({ kind: 'plan', parentId: data.student.id, revision: 1,
      data: { status: 'draft', suggested: true, source: 'ai', approvedAt: null, approvedBy: null,
        generation: { model: 'synthetic-test-provider', assessmentId: data.assessment.id, assessmentRevision: 1 } } });
    const row = await prisma.record.findUniqueOrThrow({ where: { ownerId_id: { ownerId: account.user.id, id: record.id } } });
    expect(row.encryptedPayload).not.toContain(aiContent().baseline);
    expect(cipher.decrypt(row.encryptedPayload, `record:${account.user.id}:${record.id}`)).toEqual(record.data);
    const approvalUrl = `/v1/plans/${record.id}/approve`;
    for (const payload of [{ revision: 1 }, { revision: 1, confirmed: false }, { revision: 1, confirmed: true, approvedBy: 'model' }]) {
      expect((await app.inject({ method: 'POST', url: approvalUrl, headers: headers(account), payload })).statusCode).toBe(400);
    }
    expect((await app.inject({ method: 'POST', url: approvalUrl, headers: headers(account), payload: { revision: 8, confirmed: true } })).statusCode).toBe(409);
    const approved = await app.inject({ method: 'POST', url: approvalUrl, headers: headers(account), payload: { revision: 1, confirmed: true } });
    expect(approved.statusCode).toBe(200);
    expect(approved.json<{ record: Envelope }>().record).toMatchObject({ revision: 2, data: { version: 2, status: 'approved', suggested: false, approvedBy: account.user.id,
      history: [{ status: 'draft', version: 1, source: 'ai', approvedBy: null }] } });
    expect((await app.inject({ method: 'POST', url: approvalUrl, headers: headers(account), payload: { revision: 2, confirmed: true } })).statusCode).toBe(409);
    const audits = await prisma.auditEvent.findMany({ where: { ownerId: account.user.id } });
    expect(audits.map(audit => audit.action)).toEqual(expect.arrayContaining(['ai.generation_requested', 'ai.draft_created', 'plan.approved']));
    expect(JSON.stringify(audits)).not.toContain(aiContent().baseline);
    expect(JSON.stringify(audits)).not.toContain('SYNTHETIC-PRIVATE');
  });
  it('replays the same operation after a lost acknowledgement, even when the preview expired', async () => {
    const account = await register();
    const data = await source(account);
    const { input, record } = await draft(account, data);
    now = new Date(now.getTime() + 11 * 60000);
    const replay = await app.inject({ method: 'POST', url: '/v1/ai/generate', headers: headers(account), payload: input });
    expect(replay.statusCode).toBe(200);
    expect(replay.json<{ record: Envelope }>().record).toEqual(record);
    expect(generate).toHaveBeenCalledTimes(1);
    expect(await prisma.record.count({ where: { ownerId: account.user.id, kind: 'plan' } })).toBe(1);
    const reused = { ...input, confirmedHash: 'a'.repeat(64) };
    expect((await app.inject({ method: 'POST', url: '/v1/ai/generate', headers: headers(account), payload: reused })).statusCode).toBe(400);
    // Reusing a receipt with a fresh signed preview is also rejected.
    const fresh = generationInput(await preview(account, data));
    expect((await app.inject({ method: 'POST', url: '/v1/ai/generate', headers: headers(account), payload: { ...fresh, operationId: input.operationId } })).statusCode).toBe(409);
    const receipt = await prisma.syncOperation.findUniqueOrThrow({ where: { ownerId_operationId: { ownerId: account.user.id, operationId: input.operationId } } });
    expect(receipt.encryptedResult).not.toContain(aiContent().baseline);
  });
  it('reserves one durable claim when identical generation requests arrive together', async () => {
    const account = await register();
    const data = await source(account);
    const input = generationInput(await preview(account, data));
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    let started!: () => void;
    const entered = new Promise<void>(resolve => { started = resolve; });
    generate.mockImplementationOnce(async () => { started(); await gate; return aiContent(); });
    const first = app.inject({ method: 'POST', url: '/v1/ai/generate', headers: headers(account), payload: input }).then(response => response);
    await entered;
    try {
      const duplicate = await app.inject({ method: 'POST', url: '/v1/ai/generate', headers: headers(account), payload: input });
      expect(duplicate.statusCode).toBe(409);
      expect(duplicate.json().error.code).toBe('AI_IN_PROGRESS');
    } finally { release(); }
    expect((await first).statusCode).toBe(201);
    expect(generate).toHaveBeenCalledTimes(1);
  });
  it('rejects expired first send and changed student source before calling the provider', async () => {
    const account = await register();
    const data = await source(account);
    const value = await preview(account, data);
    now = new Date(now.getTime() + 10 * 60000);
    const expired = await app.inject({ method: 'POST', url: '/v1/ai/generate', headers: headers(account), payload: generationInput(value) });
    expect(expired.statusCode).toBe(409);
    expect(expired.json().error.code).toBe('PREVIEW_EXPIRED');
    const current = await preview(account, data);
    const changed = { ...data.student, ageMonths: 3 };
    const operation = operationFixture('student', changed, { baseRevision: 1 });
    expect((await app.inject({ method: 'POST', url: '/v1/sync/push', headers: headers(account), payload: { operations: [operation] } })).json().results[0].status).toBe('applied');
    const response = await app.inject({ method: 'POST', url: '/v1/ai/generate', headers: headers(account), payload: generationInput(current) });
    expect(response.statusCode).toBe(409);
    expect(response.json().error.code).toBe('SOURCE_CHANGED');
    expect(generate).not.toHaveBeenCalled();
  });
  it('rechecks source after the external call so deletion cannot create an orphan plan', async () => {
    const account = await register();
    const data = await source(account);
    generate.mockImplementationOnce(async () => {
      const deletion = operationFixture('student', {}, { entityId: data.student.id, action: 'delete', baseRevision: 1 });
      const response = await app.inject({ method: 'POST', url: '/v1/sync/push', headers: headers(account), payload: { operations: [deletion] } });
      expect(response.json().results[0].status).toBe('applied');
      return aiContent();
    });
    const response = await app.inject({ method: 'POST', url: '/v1/ai/generate', headers: headers(account), payload: generationInput(await preview(account, data)) });
    expect(response.statusCode).toBe(404);
    expect(await prisma.record.count({ where: { ownerId: account.user.id, kind: 'plan' } })).toBe(0);
  });
  it('revokes deleted plans for approval and replay without another provider call', async () => {
    const account = await register();
    const data = await source(account);
    const { record, input } = await draft(account, data);
    const operation = operationFixture('plan', {}, { entityId: record.id, parentId: data.student.id, action: 'delete', baseRevision: 1 });
    const deletion = await app.inject({ method: 'POST', url: '/v1/sync/push', headers: headers(account), payload: { operations: [operation] } });
    expect(deletion.json().results[0].status).toBe('applied');
    expect((await app.inject({ method: 'POST', url: '/v1/ai/generate', headers: headers(account), payload: input })).statusCode).toBe(404);
    expect((await app.inject({ method: 'POST', url: `/v1/plans/${record.id}/approve`, headers: headers(account), payload: { revision: 2, confirmed: true } })).statusCode).toBe(404);
    expect(generate).toHaveBeenCalledTimes(1);
  });
  it('keeps provider failures safe and durable, with no fabricated fallback or automatic resend', async () => {
    const account = await register();
    const data = await source(account);
    generate.mockRejectedValueOnce(new Error('SYNTHETIC-PROVIDER-SECRET'));
    const input = generationInput(await preview(account, data));
    const failed = await app.inject({ method: 'POST', url: '/v1/ai/generate', headers: headers(account), payload: input });
    expect(failed.statusCode).toBe(502);
    expect(failed.body).not.toContain('SYNTHETIC-PROVIDER-SECRET');
    const replay = await app.inject({ method: 'POST', url: '/v1/ai/generate', headers: headers(account), payload: input });
    expect(replay.statusCode).toBe(502);
    expect(replay.json().error.code).toBe('AI_PREVIOUS_FAILED');
    expect(generate).toHaveBeenCalledTimes(1);
    expect(await prisma.record.count({ where: { ownerId: account.user.id, kind: 'plan' } })).toBe(0);
    // A new reviewed/confirmed operation is an explicit retry.
    expect((await draft(account, data)).record.data.status).toBe('draft');
    expect(generate).toHaveBeenCalledTimes(2);
  });
  it.each(['diagnosis', 'inventedBaseline', 'tool', 'skill', 'schedule', 'date', 'approval'])('rejects unsafe %s output before persistence', async mode => {
    const account = await register();
    const data = await source(account);
    const bad = aiContent();
    if (mode === 'diagnosis') bad.recommendations = ['تشخيص'];
    if (mode === 'inventedBaseline') bad.baseline = 'حقق دقة 90%';
    if (mode === 'tool') bad.tools = ['الحاسوب'];
    if (mode === 'skill') bad.goals[0]!.skillId = 'reading.unapproved';
    if (mode === 'schedule') bad.durationWeeks = 8;
    if (mode === 'date') bad.nextFollowUp = '2026-11-01';
    const content = mode === 'approval' ? { ...bad, status: 'approved' } : bad;
    generate.mockResolvedValueOnce(content);
    const failed = await app.inject({ method: 'POST', url: '/v1/ai/generate', headers: headers(account), payload: generationInput(await preview(account, data)) });
    expect(failed.statusCode).toBe(502);
    expect(failed.json().error.code).toBe('AI_OUTPUT_INVALID');
    expect(await prisma.record.count({ where: { ownerId: account.user.id, kind: 'plan' } })).toBe(0);
  });
});
