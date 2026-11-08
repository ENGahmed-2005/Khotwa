import { randomBytes, randomUUID } from 'node:crypto';
import { PrismaClient } from '@prisma/client';
import type { FastifyInstance } from 'fastify';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { buildApp } from '../src/app.js';
import { PayloadCipher } from '../src/crypto.js';
import type { InitialAssessment } from '../src/intake/schema.js';
import { attendance, sessionAccuracy, type GenerationInput } from '../src/planning/domain.js';
import type { Envelope, SyncResult } from '../src/records.js';
import type { Operation } from '../src/schemas.js';
import { aiContent } from './ai.fixtures.js';
import { assessmentFixture, fixtureTime, operationFixture, studentFixture } from './fixtures.js';

const runId = `test-mvp-${randomUUID()}`;
const password = 'Synthetic-only-password-12345';
const storageKey = randomBytes(32);
const cipher = new PayloadCipher(storageKey);
const today = '2026-11-08';
const clock = () => new Date(`${today}T10:00:00Z`);
const generate = vi.fn<(payload: GenerationInput) => Promise<unknown>>(async () => aiContent());
let prisma: PrismaClient;
let app: FastifyInstance;
interface Account { token: string; user: { id: string; role: string } }
const auth = (account: Account) => ({ authorization: `Bearer ${account.token}` });
async function account(): Promise<Account> {
  const response = await app.inject({ method: 'POST', url: '/v1/auth/register', payload: { email: `${runId}-${randomUUID()}@example.test`, password } });
  expect(response.statusCode).toBe(201);
  return response.json<Account>();
}
async function push(owner: Account, operations: Operation[]) {
  const response = await app.inject({ method: 'POST', url: '/v1/sync/push', headers: auth(owner), payload: { operations } });
  expect(response.statusCode).toBe(200);
  return response.json<{ results: SyncResult[] }>().results;
}
async function student(owner: Account) {
  const data = studentFixture({ ageYears: 14, gender: 'female', referralReason: 'دعم التمييز الصوتي',
    classroomObservation: 'SYNTHETIC-PRIVATE-CLASSROOM', familyNotes: 'SYNTHETIC-PRIVATE-FAMILY',
    teacherNotes: 'SYNTHETIC-PRIVATE-TEACHER', proposedDurationWeeks: 8, sessionsPerWeek: 2, sessionMinutes: 30 });
  expect((await push(owner, [operationFixture('student', data)]))[0]?.status).toBe('applied');
  return data;
}
function initial(studentId: string, override: Partial<InitialAssessment> = {}): InitialAssessment {
  return { id: randomUUID(), studentId, createdAt: fixtureTime, assessedOn: '2026-11-01', status: 'approved',
    method: 'directObservation', academicAssessmentId: null, alternativeReason: 'تقييم تربوي بديل مناسب للعمر',
    domains: [{ id: 'reading', label: 'القراءة', currentPerformance: 'SYNTHETIC-PRIVATE-BASELINE',
      strengths: 'SYNTHETIC-PRIVATE-STRENGTH', needs: 'SYNTHETIC-PRIVATE-NEED',
      skills: [{ id: 'reading.sound_deletion', label: 'SYNTHETIC-PRIVATE-LABEL', level: 'developing', evidence: 'SYNTHETIC-PRIVATE-EVIDENCE' }] }],
    previousStrategies: [{ name: 'العرض المتدرج', result: 'SYNTHETIC-PRIVATE-STRATEGY' }], privacyReviewed: true, approvedAt: fixtureTime, ...override };
}
async function source(owner: Account, approved = true) {
  const child = await student(owner);
  const assessment = initial(child.id, approved ? {} : { status: 'draft', approvedAt: null });
  expect((await push(owner, [operationFixture('initialAssessment', assessment)]))[0]?.status).toBe('applied');
  return { child, assessment };
}
const previewBody = (data: Awaited<ReturnType<typeof source>>) => ({ studentId: data.child.id, assessmentId: data.assessment.id,
  skills: [{ skillId: 'reading.sound_deletion', level: 'developing', evidence: 'approvedAlternativeAssessment' }],
  durationWeeks: 6, sessionsPerWeek: 2, availableTools: ['cards'], syntheticDataConfirmed: true });
async function draft(owner: Account, data: Awaited<ReturnType<typeof source>>) {
  const preview = await app.inject({ method: 'POST', url: '/v1/ai/preview', headers: auth(owner), payload: previewBody(data) });
  expect(preview.statusCode).toBe(200);
  const value = preview.json<{ previewToken: string; hash: string }>();
  const generated = await app.inject({ method: 'POST', url: '/v1/ai/generate', headers: auth(owner),
    payload: { previewToken: value.previewToken, confirmedHash: value.hash, confirmed: true, syntheticDataConfirmed: true, operationId: randomUUID() } });
  expect(generated.statusCode).toBe(201);
  return generated.json<{ record: Envelope }>().record;
}
async function approvedPlan(owner: Account) {
  const data = await source(owner);
  const plan = await draft(owner, data);
  const approved = await app.inject({ method: 'POST', url: `/v1/plans/${plan.id}/approve`, headers: auth(owner), payload: { revision: plan.revision, confirmed: true } });
  expect(approved.statusCode).toBe(200);
  return { ...data, plan: approved.json<{ record: Envelope }>().record };
}
function session(data: Awaited<ReturnType<typeof approvedPlan>>, override: Record<string, unknown> = {}) {
  const content = data.plan.data.content as ReturnType<typeof aiContent>;
  return { id: randomUUID(), studentId: data.child.id, planVersionId: data.plan.id, goalId: content.goals[0]!.id,
    occurredOn: '2026-11-07', status: 'completed', total: 5, correct: 4, support: 'verbal', engagement: 'تفاعل موثق باختيار المختصة',
    durationMinutes: 30, createdAt: fixtureTime, activityId: null, notes: 'ملاحظة تربوية اصطناعية', privacyReviewed: true, ...override };
}
beforeAll(async () => {
  const url = process.env.TEST_DATABASE_URL;
  if (!url) throw new Error('TEST_DATABASE_URL is required for real PostgreSQL MVP tests');
  prisma = new PrismaClient({ datasources: { db: { url } }, log: [] });
  await prisma.$connect();
});
beforeEach(async () => {
  app = await buildApp({ prisma, storageKey, clock, authRateLimit: 10000, globalRateLimit: 10000,
    ai: { enabled: true, syntheticOnly: true, model: 'injected-deterministic-test-provider', provider: { generate } } });
  await app.ready();
});
afterEach(async () => { if (app) await app.close(); });
afterAll(async () => {
  if (prisma) {
    await prisma.user.deleteMany({ where: { email: { startsWith: runId } } });
    await prisma.$disconnect();
  }
});

describe('documented educational intake on real PostgreSQL', () => {
  it('requires authentication for the educational catalog and exposes seven educational domains', async () => {
    expect((await app.inject('/v1/assessment-catalog')).statusCode).toBe(401);
    const owner = await account();
    const response = await app.inject({ url: '/v1/assessment-catalog', headers: auth(owner) });
    expect(response.statusCode).toBe(200);
    expect(response.json().domains).toHaveLength(7);
    expect(response.body).toContain('life.independence');
    expect(response.body).not.toMatch(/diagnosis|medical/);
  });
  it('retains optional student intake only inside owner-bound encryption', async () => {
    const owner = await account();
    const child = await student(owner);
    const row = await prisma.record.findUniqueOrThrow({ where: { ownerId_id: { ownerId: owner.user.id, id: child.id } } });
    expect(row.encryptedPayload).not.toContain('SYNTHETIC-PRIVATE');
    expect(cipher.decrypt(row.encryptedPayload, `record:${owner.user.id}:${child.id}`)).toEqual(child);
    for (const patch of [{ gender: 'unapproved-value' }, { sessionMinutes: 0 }, { medical_diagnosis: 'forbidden' }, { familyNotes: 'contact@example.test' }]) {
      const next = { ...child, ...patch };
      expect((await push(owner, [operationFixture('student', next, { baseRevision: 1 })]))[0]?.status).toBe('rejected');
    }
  });
  it('saves partial alternative assessment drafts and resumes them without forcing an age card', async () => {
    const owner = await account();
    const child = await student(owner);
    const data = initial(child.id, { status: 'draft', approvedAt: null, domains: [], alternativeReason: '' });
    const result = (await push(owner, [operationFixture('initialAssessment', data)]))[0]!;
    expect(result.status).toBe('applied');
    const restored = await app.inject({ url: `/v1/records/${data.id}`, headers: auth(owner) });
    expect(restored.json().record.data).toEqual(data);
    expect((await push(owner, [operationFixture('initialAssessment', { ...initial(child.id), id: data.id }, { baseRevision: 1 })]))[0]?.status).toBe('applied');
  });
  it('refuses approval without baseline, strengths, needs, evidence, or documented alternative', async () => {
    const owner = await account();
    const child = await student(owner);
    for (const patch of [{ alternativeReason: '' }, { domains: [] }, { privacyReviewed: false }, { approvedAt: null }]) {
      expect((await push(owner, [operationFixture('initialAssessment', { ...initial(child.id), ...patch })]))[0]?.status).toBe('rejected');
    }
    for (const field of ['currentPerformance', 'strengths', 'needs']) {
      const data = initial(child.id);
      (data.domains[0] as unknown as Record<string, unknown>)[field] = '';
      expect((await push(owner, [operationFixture('initialAssessment', data)]))[0]?.status).toBe('rejected');
    }
    const emptyEvidence = initial(child.id);
    emptyEvidence.domains[0]!.skills[0]!.evidence = '';
    expect((await push(owner, [operationFixture('initialAssessment', emptyEvidence)]))[0]?.status).toBe('rejected');
  });
  it('prevents future assessment dates and retains approved history unchanged', async () => {
    const owner = await account();
    const data = await source(owner);
    const changed = structuredClone(data.assessment);
    changed.domains[0]!.needs = 'محاولة تعديل النسخة المعتمدة';
    expect((await push(owner, [operationFixture('initialAssessment', changed, { baseRevision: 1 })]))[0]?.error?.code).toBe('ASSESSMENT_IMMUTABLE');
    expect((await push(owner, [operationFixture('initialAssessment', initial(data.child.id, { assessedOn: '2026-11-09' }))]))[0]?.error?.code).toBe('FUTURE_ASSESSMENT');
    const repeated = initial(data.child.id);
    expect((await push(owner, [operationFixture('initialAssessment', repeated)]))[0]?.status).toBe('applied');
    expect((await app.inject({ url: '/v1/records?kind=initialAssessment', headers: auth(owner) })).json().records).toHaveLength(2);
  });
  it('rejects identifying and medical fields before retaining a sync receipt', async () => {
    const owner = await account();
    const child = await student(owner);
    const operation = operationFixture('initialAssessment', { ...initial(child.id), real_name: 'FORBIDDEN-SYNTHETIC-IDENTITY' });
    expect((await push(owner, [operation]))[0]?.status).toBe('rejected');
    const receipt = await prisma.syncOperation.findUniqueOrThrow({ where: { ownerId_operationId: { ownerId: owner.user.id, operationId: operation.operationId } } });
    const decoded = cipher.decrypt(receipt.encryptedResult, `operation:${owner.user.id}:${operation.operationId}`);
    expect(JSON.stringify(decoded)).not.toContain('FORBIDDEN-SYNTHETIC');
    expect(await prisma.record.count({ where: { ownerId: owner.user.id, id: operation.entityId } })).toBe(0);
  });
  it('isolates every alternative assessment read, update, delete, and AI preview by owner', async () => {
    const owner = await account();
    const other = await account();
    const data = await source(owner);
    expect((await app.inject({ url: `/v1/records/${data.assessment.id}`, headers: auth(other) })).statusCode).toBe(404);
    expect((await app.inject({ url: '/v1/records?kind=initialAssessment', headers: auth(other) })).json().records).toEqual([]);
    for (const action of ['upsert', 'delete'] as const) {
      const operation = operationFixture('initialAssessment', action === 'delete' ? {} : data.assessment,
        { entityId: data.assessment.id, parentId: data.child.id, baseRevision: 1, action });
      expect((await push(other, [operation]))[0]?.status).toBe('rejected');
    }
    expect((await app.inject({ method: 'POST', url: '/v1/ai/preview', headers: auth(other), payload: previewBody(data) })).statusCode).toBe(404);
  });
  it('requires a real approved owned academic reference when that method is claimed', async () => {
    const owner = await account();
    const child = studentFixture();
    expect((await push(owner, [operationFixture('student', child)]))[0]?.status).toBe('applied');
    const academic = assessmentFixture(child.id, { status: 'approved', approvedAt: fixtureTime, strengths: 'مشاركة في التقييم', needs: 'متابعة الوعي الصوتي' });
    expect((await push(owner, [operationFixture('assessment', academic)]))[0]?.status).toBe('applied');
    expect((await push(owner, [operationFixture('initialAssessment', initial(child.id, { method: 'academicCards', alternativeReason: '', academicAssessmentId: randomUUID() }))]))[0]?.status).toBe('rejected');
    const good = initial(child.id, { method: 'academicCards', alternativeReason: '', academicAssessmentId: academic.id });
    expect((await push(owner, [operationFixture('initialAssessment', good)]))[0]?.status).toBe('applied');
    const invented = initial(child.id, { method: 'academicCards', academicAssessmentId: academic.id });
    invented.domains[0]!.skills[0]!.id = 'life.hygiene';
    expect((await push(owner, [operationFixture('initialAssessment', invented)]))[0]?.error?.code).toBe('INVALID_SKILLS');
  });
});

describe('reviewed alternative AI source, never raw intake', () => {
  it('requires approval and matches the exact reviewed skill level', async () => {
    const owner = await account();
    const incomplete = await source(owner, false);
    expect((await app.inject({ method: 'POST', url: '/v1/ai/preview', headers: auth(owner), payload: previewBody(incomplete) })).statusCode).toBe(409);
    const data = await source(owner);
    const skills = await app.inject({ url: `/v1/ai/skills?assessmentId=${data.assessment.id}`, headers: auth(owner) });
    expect(skills.json().skills).toEqual([{ skillId: 'reading.sound_deletion', label: 'حذف الصوت الأول', level: 'developing', evidence: 'approvedAlternativeAssessment' }]);
    expect(skills.body).not.toContain('SYNTHETIC-PRIVATE');
    for (const level of ['mastered', 'needsSupport']) {
      const input = previewBody(data);
      input.skills[0]!.level = level;
      expect((await app.inject({ method: 'POST', url: '/v1/ai/preview', headers: auth(owner), payload: input })).statusCode).toBe(400);
    }
  });
  it('sends controlled identifiers and reviewed levels only after explicit confirmation', async () => {
    const owner = await account();
    const data = await source(owner);
    const generated = await draft(owner, data);
    expect(generated.data.status).toBe('draft');
    const payload = generate.mock.calls.at(-1)![0];
    expect(payload.skills[0]?.evidence).toBe('approvedAlternativeAssessment');
    const outbound = JSON.stringify(payload);
    for (const privateValue of ['SYNTHETIC-PRIVATE', data.child.code, data.child.id, data.assessment.id, 'female', 'classroomObservation']) expect(outbound).not.toContain(privateValue);
  });
});

describe('durable session sync tied to approved immutable plan versions', () => {
  it('accepts a two-session batch with a past date and replays operations exactly once', async () => {
    const owner = await account();
    const data = await approvedPlan(owner);
    const one = session(data);
    const two = session(data, { occurredOn: '2026-11-02', total: 10, correct: 6 });
    const operations = [operationFixture('session', one), operationFixture('session', two)];
    const first = await push(owner, operations);
    expect(first.map(result => result.status)).toEqual(['applied', 'applied']);
    expect(await push(owner, operations)).toEqual(first);
    expect(await push(owner, operations)).toEqual(first);
    const stored = await app.inject({ url: '/v1/records?kind=session', headers: auth(owner) });
    expect(stored.json().records).toHaveLength(2);
    expect(sessionAccuracy(first[0]!.record!.data as unknown as Parameters<typeof sessionAccuracy>[0])).toBe(80);
    const row = await prisma.record.findUniqueOrThrow({ where: { ownerId_id: { ownerId: owner.user.id, id: one.id } } });
    expect(row.encryptedPayload).not.toContain(one.notes);
  });
  it('rejects invalid trials, future performance, draft plans and unrelated goals', async () => {
    const owner = await account();
    const data = await approvedPlan(owner);
    for (const patch of [{ correct: 6 }, { total: 0 }, { occurredOn: '2026-11-09' }, { goalId: randomUUID() }, { privacyReviewed: false }, { medical_diagnosis: 'forbidden' }]) {
      expect((await push(owner, [operationFixture('session', session(data, patch))]))[0]?.status).toBe('rejected');
    }
    const pending = await draft(owner, data);
    expect((await push(owner, [operationFixture('session', session(data, { planVersionId: pending.id }))]))[0]?.error?.code).toBe('INVALID_SESSION');
  });
  it('represents absence/cancellation without invented scores and keeps attendance descriptive', async () => {
    const owner = await account();
    const data = await approvedPlan(owner);
    const completed = session(data);
    const absent = session(data, { status: 'absent', total: null, correct: null, support: null, engagement: null, durationMinutes: null });
    const cancelled = { ...absent, id: randomUUID(), status: 'cancelled' };
    const result = await push(owner, [completed, absent, cancelled].map(value => operationFixture('session', value)));
    expect(result.every(value => value.status === 'applied')).toBe(true);
    const values = result.map(value => value.record!.data as unknown as Parameters<typeof sessionAccuracy>[0]);
    expect(values.map(sessionAccuracy)).toEqual([80, null, null]);
    expect(attendance(values)).toEqual({ completed: 1, scheduled: 2, percent: 50 });
    expect((await push(owner, [operationFixture('session', { ...absent, id: randomUUID(), correct: 0 })]))[0]?.status).toBe('rejected');
  });
  it('refuses cross-owner and cross-student session relationships', async () => {
    const owner = await account();
    const other = await account();
    const data = await approvedPlan(owner);
    const value = session(data);
    expect((await push(other, [operationFixture('session', value)]))[0]?.status).toBe('rejected');
    const unrelated = await student(owner);
    expect((await push(owner, [operationFixture('session', { ...value, id: randomUUID(), studentId: unrelated.id })]))[0]?.status).toBe('rejected');
    expect((await push(owner, [operationFixture('session', value)]))[0]?.status).toBe('applied');
    expect((await app.inject({ url: `/v1/records/${value.id}`, headers: auth(other) })).statusCode).toBe(404);
    expect((await app.inject({ url: '/v1/records?kind=session', headers: auth(other) })).json().records).toEqual([]);
  });
  it('validates optional activities against the same owner, student, approved plan and goal', async () => {
    const owner = await account();
    const data = await approvedPlan(owner);
    const activityId = randomUUID();
    const value = session(data, { activityId });
    expect((await push(owner, [operationFixture('session', value)]))[0]?.status).toBe('rejected');
    const payload = { id: activityId, studentId: data.child.id, planId: data.plan.id, goalId: value.goalId, status: 'draft', suggested: true };
    await prisma.record.create({ data: { id: activityId, ownerId: owner.user.id, kind: 'activity', parentId: data.child.id,
      encryptedPayload: cipher.encrypt(payload, `record:${owner.user.id}:${activityId}`) } });
    expect((await push(owner, [operationFixture('session', { ...value, id: randomUUID() })]))[0]?.status).toBe('applied');
    await prisma.record.update({ where: { ownerId_id: { ownerId: owner.user.id, id: activityId } }, data: {
      encryptedPayload: cipher.encrypt({ ...payload, goalId: randomUUID() }, `record:${owner.user.id}:${activityId}`) } });
    expect((await push(owner, [operationFixture('session', { ...value, id: randomUUID() })]))[0]?.error?.code).toBe('INVALID_RELATION');
  });
});

describe('specialist revisions preserve plan history and source provenance', () => {
  it('creates a new reviewable draft without changing an approved plan or its sessions', async () => {
    const owner = await account();
    const data = await approvedPlan(owner);
    const content = structuredClone(data.plan.data.content as ReturnType<typeof aiContent>);
    content.goals[0]!.behavior = 'يحدد الصوت الأول ثم يحذفه';
    const input = { revision: data.plan.revision, operationId: randomUUID(), confirmed: true, content,
      templateOptions: { showStrategies: false, showRecommendations: true, showSessionSchedule: false } };
    const response = await app.inject({ method: 'POST', url: `/v1/plans/${data.plan.id}/versions`, headers: auth(owner), payload: input });
    expect(response.statusCode).toBe(201);
    const revised = response.json<{ record: Envelope }>().record;
    expect(revised.id).not.toBe(data.plan.id);
    expect(revised.data).toMatchObject({ status: 'draft', previousVersionId: data.plan.id, suggested: true, templateOptions: input.templateOptions });
    expect(revised.data.provenance).toMatchObject({ [`goals.${content.goals[0]!.id}.behavior`]: 'specialist', generalGoal: 'ai' });
    const original = await app.inject({ url: `/v1/records/${data.plan.id}`, headers: auth(owner) });
    expect(original.json().record).toEqual(data.plan);
    expect((await push(owner, [operationFixture('session', session(data))]))[0]?.status).toBe('applied');
    const history = await app.inject({ url: `/v1/plans/${revised.id}/history`, headers: auth(owner) });
    expect(history.statusCode).toBe(200);
    expect(history.json().history.at(-1).status).toBe('approved');
    expect(history.json().current.id).toBe(revised.id);
    const approved = await app.inject({ method: 'POST', url: `/v1/plans/${revised.id}/approve`, headers: auth(owner), payload: { revision: 1, confirmed: true } });
    expect(approved.statusCode).toBe(200);
    expect(approved.json().record.data.suggested).toBe(false);
    expect(approved.json().record.data.templateOptions).toEqual(input.templateOptions);
  });
  it('returns the same new version on retry and refuses reused IDs or stale revisions', async () => {
    const owner = await account();
    const data = await approvedPlan(owner);
    const input = { revision: data.plan.revision, operationId: randomUUID(), confirmed: true, content: data.plan.data.content };
    const send = (payload: Record<string, unknown>) => app.inject({ method: 'POST', url: `/v1/plans/${data.plan.id}/versions`, headers: auth(owner), payload });
    const one = await send(input);
    const two = await send(input);
    expect(one.statusCode).toBe(201);
    expect(two.json()).toEqual(one.json());
    expect((await send({ ...input, templateOptions: { showStrategies: false } })).statusCode).toBe(409);
    expect((await send({ ...input, operationId: randomUUID(), revision: 1 })).statusCode).toBe(409);
    expect((await app.inject({ url: '/v1/records?kind=plan', headers: auth(owner) })).json().records).toHaveLength(2);
  });
  it('guards every version/history route against other owners, viewers and missing authentication', async () => {
    const owner = await account();
    const other = await account();
    const data = await approvedPlan(owner);
    const input = { revision: data.plan.revision, operationId: randomUUID(), confirmed: true, content: data.plan.data.content };
    for (const headers of [undefined, auth(other)]) {
      const expected = headers ? 404 : 401;
      expect((await app.inject({ method: 'POST', url: `/v1/plans/${data.plan.id}/versions`, headers, payload: input })).statusCode).toBe(expected);
      expect((await app.inject({ url: `/v1/plans/${data.plan.id}/history`, headers })).statusCode).toBe(expected);
    }
    await prisma.user.update({ where: { id: other.user.id }, data: { role: 'viewer' } });
    expect((await app.inject({ method: 'POST', url: '/v1/sync/push', headers: auth(other), payload: { operations: [operationFixture('student', studentFixture())] } })).statusCode).toBe(403);
    expect((await app.inject({ method: 'POST', url: `/v1/plans/${data.plan.id}/versions`, headers: auth(other), payload: input })).statusCode).toBe(403);
    expect((await app.inject({ url: `/v1/plans/${data.plan.id}/history`, headers: auth(other) })).statusCode).toBe(403);
  });
  it('rejects clinical language, injected approval, unknown skills and invalid goal structure', async () => {
    const owner = await account();
    const data = await approvedPlan(owner);
    const content = data.plan.data.content as ReturnType<typeof aiContent>;
    for (const changed of [{ ...content, recommendations: ['تشخيص طبي'] }, { ...content, goals: [] }, { ...content, status: 'approved' },
      { ...content, goals: [{ ...content.goals[0], skillId: 'unapproved.skill' }] }]) {
      const response = await app.inject({ method: 'POST', url: `/v1/plans/${data.plan.id}/versions`, headers: auth(owner),
        payload: { revision: data.plan.revision, operationId: randomUUID(), confirmed: true, content: changed } });
      expect(response.statusCode).toBe(400);
    }
    expect((await app.inject({ url: '/v1/records?kind=plan', headers: auth(owner) })).json().records).toHaveLength(1);
  });
});
