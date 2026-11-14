// Opt-in smoke against the local running API and its actual configured provider.
// Never part of the deterministic CI suite; never creates real student data.
import { randomUUID } from 'node:crypto';
import { assessmentFixture, fixtureTime, operationFixture, studentFixture } from './fixtures.js';

if (process.env.KHOTWA_ALLOW_LIVE_AI_SMOKE !== 'synthetic-only') throw new Error('Explicit synthetic-only opt-in is required');
const base = 'http://127.0.0.1:3000';
const password = `Synthetic-${randomUUID()}`;
let token: string | undefined;
async function request(method: string, path: string, data?: unknown) {
  const response = await fetch(`${base}${path}`, {
    method, headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    ...(data ? { body: JSON.stringify(data) } : {}), signal: AbortSignal.timeout(90000), redirect: 'error',
  });
  const body = response.status === 204 ? {} : await response.json() as Record<string, unknown>;
  return { status: response.status, body };
}
try {
  const registered = await request('POST', '/v1/auth/register', { email: `live-synthetic-${randomUUID()}@example.test`, password });
  if (registered.status !== 201) throw new Error('Synthetic registration failed');
  token = registered.body.token as string;
  const student = studentFixture();
  const assessment = assessmentFixture(student.id, { status: 'approved', approvedAt: fixtureTime, strengths: 'نقاط قوة اصطناعية لا تخص طفلًا', needs: 'احتياج اصطناعي لا يخص طفلًا' });
  for (const operation of [operationFixture('student', student), operationFixture('assessment', assessment)]) {
    const saved = await request('POST', '/v1/sync/push', { operations: [operation] });
    const results = saved.body.results as { status: string }[];
    if (saved.status !== 200 || results[0]?.status !== 'applied') throw new Error('Synthetic source synchronization failed');
  }
  const preview = await request('POST', '/v1/ai/preview', {
    studentId: student.id, assessmentId: assessment.id,
    skills: [{ skillId: 'reading.sound_deletion', level: 'developing', evidence: 'approvedAcademicAssessment' }],
    durationWeeks: 6, sessionsPerWeek: 2, availableTools: ['cards'], syntheticDataConfirmed: true,
  });
  if (preview.status !== 200) throw new Error('Synthetic preview failed');
  const generated = await request('POST', '/v1/ai/generate', {
    previewToken: preview.body.previewToken, confirmedHash: preview.body.hash,
    confirmed: true, syntheticDataConfirmed: true, operationId: randomUUID(),
  });
  const record = generated.body.record as { data?: { status?: string } } | undefined;
  const error = generated.body.error as { code?: string } | undefined;
  const listed = await request('GET', '/v1/records?kind=plan');
  const plans = listed.body.records as unknown[];
  if (generated.status === 201 && record?.data?.status !== 'draft') throw new Error('Provider result was not a draft');
  if (generated.status !== 201 && plans.length !== 0) throw new Error('A failed generation persisted a fallback plan');
  console.info(JSON.stringify({ previewHttp: preview.status, generationHttp: generated.status, code: error?.code ?? null, planStatus: record?.data?.status ?? null, plansPersisted: plans.length, syntheticOnly: true }));
  if (generated.status !== 201) process.exitCode = 2;
} finally {
  if (token) {
    const deleted = await request('DELETE', '/v1/auth/account', { password, confirmed: true });
    if (deleted.status !== 204) { console.info('Synthetic cleanup could not be verified'); process.exitCode = 3; }
    else console.info('Synthetic smoke account and its records deleted');
  }
}
