// Opt-in only: one real plan call and one real activity call against the local API.
// Run from backend after starting the API and installing Python's pypdf:
// KHOTWA_ALLOW_LIVE_MVP_SMOKE=synthetic-only KHOTWA_SMOKE_PYTHON=python node --import tsx test/live-mvp.smoke.ts
// This verifies API approval mechanisms; it is not an institution's educational review or native-device acceptance.
import { createHash, randomUUID } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { strFromU8, unzipSync } from 'fflate';
import { planContentSchema, sessionAccuracy, type InterventionSession } from '../src/planning/domain.js';
import { canonicalJson } from '../src/crypto.js';
import type { Envelope, SyncResult } from '../src/records.js';
import { assessmentFixture, operationFixture, studentFixture } from './fixtures.js';

if (process.env.KHOTWA_ALLOW_LIVE_MVP_SMOKE !== 'synthetic-only') throw new Error('Explicit synthetic-only opt-in is required');
const base = 'http://127.0.0.1:3000';
const python = process.env.KHOTWA_SMOKE_PYTHON ?? 'python';
const runId = `${new Date().toISOString().replace(/[:.]/gu, '-')}-${randomUUID().slice(0, 8)}`;
const directory = join(fileURLToPath(new URL('../../.artifacts/live-mvp/', import.meta.url)), runId);
const password = `Synthetic-${randomUUID()}`;
const privateMarker = 'SYNTHETIC-PRIVATE-NEVER-EXPORT';
let token: string | undefined;
let ownerId: string | undefined;
interface Step { step: string; http: number; code?: string }
interface Artifact { file: string; mime: string; bytes: number; sha256: string; serial: string; pages?: number }
const summary = {
  startedAt: new Date().toISOString(), syntheticOnly: true, base,
  liveGenerationLimits: { plan: 1, activity: 1 },
  humanEducationalReview: false, nativeOfflineLifecycleVerified: false,
  state: 'IN_PROGRESS', steps: [] as Step[], artifacts: [] as Artifact[],
  checks: {} as Record<string, boolean | number[]>,
  cleanup: { deleted: false, revokedToken: false }, failure: null as string | null,
};
class SmokeFailure extends Error {}
function check(condition: unknown, name: string): asserts condition {
  if (!condition) throw new SmokeFailure(name);
}
function safeCode(body: unknown): string | undefined {
  if (!body || typeof body !== 'object' || !('error' in body)) return undefined;
  const error = body.error;
  if (!error || typeof error !== 'object' || !('code' in error)) return undefined;
  return typeof error.code === 'string' && /^[A-Z_]{1,80}$/u.test(error.code) ? error.code : undefined;
}
function logStep(step: Step) { summary.steps.push(step); console.info(JSON.stringify(step)); }
async function request(step: string, method: string, path: string, data?: unknown): Promise<Response> {
  const response = await fetch(`${base}${path}`, {
    method, headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    ...(data === undefined ? {} : { body: JSON.stringify(data) }), redirect: 'error', signal: AbortSignal.timeout(120000),
  });
  if (response.ok) logStep({ step, http: response.status });
  return response;
}
async function json<T>(step: string, method: string, path: string, data?: unknown, expected = 200): Promise<T> {
  const response = await request(step, method, path, data);
  const body: unknown = response.status === 204 ? {} : await response.json();
  if (!response.ok) logStep({ step, http: response.status, ...(safeCode(body) ? { code: safeCode(body) } : {}) });
  check(response.status === expected, `${step}: HTTP_${response.status}${safeCode(body) ? `_${safeCode(body)}` : ''}`);
  return body as T;
}
interface Preview { hash: string; previewToken: string; payload: Record<string, unknown> }
const confirm = (preview: Preview) => ({ previewToken: preview.previewToken, confirmedHash: preview.hash,
  operationId: randomUUID(), confirmed: true, syntheticDataConfirmed: true });
const same = (left: unknown, right: unknown) => canonicalJson(left) === canonicalJson(right);

function verifyPdf(path: string, code: string, serial: string): number {
  const script = `import sys,json\nfrom pypdf import PdfReader\npages=[p.extract_text() or '' for p in PdfReader(sys.argv[1]).pages]\nassert pages and all(sys.argv[2] in p and sys.argv[3] in p for p in pages), 'PDF_IDENTIFIERS'\nassert all(sys.argv[4] not in p for p in pages), 'PDF_PRIVATE_MARKER'\nprint(json.dumps({'pages':len(pages)}))`;
  const result = spawnSync(python, ['-c', script, path, code, serial, privateMarker], { encoding: 'utf8', timeout: 30000, windowsHide: true });
  check(result.status === 0, 'PDF_TEXT_AND_IDENTIFIERS_VERIFICATION_FAILED');
  const metadata = JSON.parse(result.stdout) as { pages: number };
  check(Number.isSafeInteger(metadata.pages) && metadata.pages > 0, 'PDF_PAGE_COUNT_INVALID');
  return metadata.pages;
}
async function exportFile(step: string, path: string, selection: unknown, format: 'pdf' | 'docx', code: string) {
  const response = await request(step, 'POST', path, selection);
  if (response.status !== 200) {
    const body: unknown = await response.json();
    logStep({ step, http: response.status, ...(safeCode(body) ? { code: safeCode(body) } : {}) });
    throw new SmokeFailure(`${step}: HTTP_${response.status}${safeCode(body) ? `_${safeCode(body)}` : ''}`);
  }
  const mime = response.headers.get('content-type')?.split(';')[0] ?? '';
  check(mime === (format === 'pdf' ? 'application/pdf' : 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'), `${step}: MIME_INVALID`);
  const serial = response.headers.get('x-khotwa-report-serial') ?? '';
  check(/^KH-(?:RPT|ACT)-[A-F0-9-]{36}$/u.test(serial), `${step}: SERIAL_MISSING`);
  const disposition = response.headers.get('content-disposition') ?? '';
  check(disposition.includes(serial) && disposition.includes(code), `${step}: FILENAME_IDENTIFIERS_MISSING`);
  const bytes = Buffer.from(await response.arrayBuffer());
  check(bytes.length > 500 && bytes.length < 30 * 1024 * 1024, `${step}: SIZE_INVALID`);
  check(format === 'pdf' ? bytes.subarray(0, 5).toString('ascii') === '%PDF-' : bytes.readUInt32LE(0) === 0x04034b50, `${step}: SIGNATURE_INVALID`);
  const file = `${step}-${serial}-${code}.${format}`;
  const output = join(directory, file);
  await writeFile(output, bytes);
  let pages: number | undefined;
  if (format === 'pdf') pages = verifyPdf(output, code, serial);
  else {
    const archive = unzipSync(bytes);
    check(archive['[Content_Types].xml'] && archive['word/document.xml'], 'WORD_PACKAGE_INVALID');
    const xml = Object.entries(archive).filter(([name]) => /^word\/.*\.xml$/u.test(name)).map(([, data]) => strFromU8(data)).join('');
    const headers = Object.entries(archive).filter(([name]) => /^word\/header\d+\.xml$/u.test(name)).map(([, data]) => strFromU8(data)).join('');
    check(headers.includes(code) && headers.includes(serial), 'WORD_HEADER_IDENTIFIERS_MISSING');
    check(xml.includes('w:bidi') && !xml.includes(privateMarker), 'WORD_RTL_OR_PRIVACY_INVALID');
    check(/(?:PAGE|NUMPAGES)/u.test(headers), 'WORD_PAGE_FIELDS_MISSING');
  }
  summary.artifacts.push({ file, mime, bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex'), serial, ...(pages ? { pages } : {}) });
  return serial;
}

await mkdir(directory, { recursive: true });
try {
  const prerequisite = spawnSync(python, ['-c', 'import pypdf'], { encoding: 'utf8', timeout: 30000, windowsHide: true });
  check(prerequisite.status === 0, 'PYTHON_PYPDF_PREREQUISITE_MISSING');
  await json('health', 'GET', '/health');
  const account = await json<{ token: string; user: { id: string } }>('register', 'POST', '/v1/auth/register', {
    email: `live-mvp-synthetic-${randomUUID()}@example.test`, password,
  }, 201);
  token = account.token;
  ownerId = account.user.id;
  check(typeof token === 'string' && token.length > 20 && typeof ownerId === 'string', 'SYNTHETIC_ACCOUNT_INVALID');
  const now = new Date().toISOString();
  const today = now.slice(0, 10);
  const yesterday = new Date(Date.parse(`${today}T00:00:00Z`) - 86400000).toISOString().slice(0, 10);
  const student = studentFixture({ createdAt: now, consentDate: now });
  const assessment = assessmentFixture(student.id, { createdAt: now, status: 'approved', approvedAt: now,
    strengths: 'مشاركة تعليمية اصطناعية في التقييم', needs: 'احتياج اصطناعي لتطوير الوعي الصوتي' });
  assessment.results['1a']!.response = privateMarker;
  assessment.results['1a']!.observation = privateMarker;
  const source = await json<{ results: SyncResult[] }>('source-sync', 'POST', '/v1/sync/push', {
    operations: [operationFixture('student', student), operationFixture('assessment', assessment)],
  });
  check(source.results.length === 2 && source.results.every(result => result.status === 'applied'), 'SOURCE_SYNC_FAILED');
  const preview = await json<Preview>('plan-preview', 'POST', '/v1/ai/preview', {
    studentId: student.id, assessmentId: assessment.id,
    skills: [{ skillId: 'reading.sound_deletion', level: 'developing', evidence: 'approvedAcademicAssessment' }],
    durationWeeks: 6, sessionsPerWeek: 2, availableTools: ['cards'], syntheticDataConfirmed: true,
  });
  check(!JSON.stringify(preview.payload).includes(privateMarker) && !JSON.stringify(preview.payload).includes(student.code), 'PLAN_PREVIEW_PRIVACY_FAILED');
  const generated = await json<{ record: Envelope }>('plan-generate', 'POST', '/v1/ai/generate', confirm(preview), 201);
  check(generated.record.data.status === 'draft' && generated.record.data.suggested === true && generated.record.data.approvedAt === null, 'PLAN_NOT_REVIEWABLE_DRAFT');
  const content = planContentSchema.parse(generated.record.data.content);
  check(content.goals.length > 0, 'PLAN_GOAL_MISSING');
  const edited = structuredClone(content);
  edited.goals[0]!.condition = 'عند سماع كلمة قصيرة من المختصة، مع تعليمات واضحة ومتدرجة.';
  const revised = await json<{ record: Envelope }>('plan-edit-version', 'POST', `/v1/plans/${generated.record.id}/versions`, {
    revision: generated.record.revision, operationId: randomUUID(), confirmed: true, content: edited,
  }, 201);
  check(revised.record.id !== generated.record.id && revised.record.data.status === 'draft', 'PLAN_VERSION_NOT_SEPARATE_DRAFT');
  const original = await json<{ record: Envelope }>('original-plan-history', 'GET', `/v1/records/${generated.record.id}`);
  check(original.record.data.status === 'draft' && same(original.record.data.content, content), 'ORIGINAL_PLAN_OVERWRITTEN');
  const approved = await json<{ record: Envelope }>('plan-explicit-approve', 'POST', `/v1/plans/${revised.record.id}/approve`, { revision: revised.record.revision, confirmed: true });
  check(approved.record.data.status === 'approved' && approved.record.data.approvedBy === ownerId, 'PLAN_APPROVAL_MECHANISM_FAILED');
  const goal = planContentSchema.parse(approved.record.data.content).goals[0]!;
  const profile = await json<{ revision: number; tools: { id: string; label: string }[] }>('tools-read', 'GET', '/v1/activities/tools');
  await json('tools-explicit-save', 'PUT', '/v1/activities/tools', { revision: profile.revision, tools: profile.tools, privacyReviewed: true });
  const activityPreview = await json<Preview>('activity-preview', 'POST', '/v1/activities/preview', {
    studentId: student.id, planId: approved.record.id, goalId: goal.id, domain: 'reading', grade: student.grade,
    difficulty: 'practice', type: 'cards', toolIds: profile.tools.map(tool => tool.id), minutes: 15, mode: 'individual',
    privacyReviewed: true, syntheticDataConfirmed: true,
  });
  check(!JSON.stringify(activityPreview.payload).includes(student.id) && !JSON.stringify(activityPreview.payload).includes(student.code) && !JSON.stringify(activityPreview.payload).includes(privateMarker), 'ACTIVITY_PREVIEW_PRIVACY_FAILED');
  const activityDraft = await json<{ record: Envelope }>('activity-generate', 'POST', '/v1/activities/generate', confirm(activityPreview), 201);
  check(activityDraft.record.data.status === 'draft' && activityDraft.record.data.suggested === true && activityDraft.record.data.approvedAt === null, 'ACTIVITY_NOT_REVIEWABLE_DRAFT');
  const activity = await json<{ record: Envelope }>('activity-explicit-approve', 'POST', `/v1/activities/${activityDraft.record.id}/approve`, { revision: activityDraft.record.revision, confirmed: true });
  check(activity.record.data.status === 'approved' && activity.record.data.approvedBy === ownerId, 'ACTIVITY_APPROVAL_MECHANISM_FAILED');
  const sessions = [
    { occurredOn: today, total: 5, correct: 4 }, { occurredOn: yesterday, total: 10, correct: 6 },
  ].map(performance => ({ id: randomUUID(), studentId: student.id, planVersionId: approved.record.id, goalId: goal.id,
    ...performance, status: 'completed' as const, support: 'independent' as const, engagement: 'مشاركة موثقة لسيناريو اصطناعي',
    durationMinutes: 15, activityId: activity.record.id, notes: privateMarker, privacyReviewed: true as const, createdAt: now }));
  const operations = sessions.map(session => operationFixture('session', session));
  const pushed = await json<{ results: SyncResult[] }>('two-session-sync', 'POST', '/v1/sync/push', { operations });
  check(pushed.results.length === 2 && pushed.results.every(result => result.status === 'applied'), 'SESSION_SYNC_FAILED');
  const replay = await json<{ results: SyncResult[] }>('session-operation-replay', 'POST', '/v1/sync/push', { operations });
  check(same(replay, pushed), 'SESSION_IDEMPOTENT_REPLAY_FAILED');
  const pulled = await json<{ records: Envelope[]; fullSnapshot: boolean }>('durable-pull', 'GET', '/v1/sync/pull');
  const restored = sessions.map(session => pulled.records.find(record => record.id === session.id));
  check(pulled.fullSnapshot && pulled.records.filter(record => record.kind === 'session').length === 2 && restored.every(Boolean), 'DURABLE_PULL_LOST_OR_DUPLICATED_SESSIONS');
  check(restored.every((record, index) => same(record!.data, sessions[index])), 'DURABLE_SESSION_DATA_CHANGED');
  const percentages = restored.map(record => sessionAccuracy(record!.data as unknown as InterventionSession));
  check(same(percentages, [80, 60]), 'SESSION_PERCENTAGES_INCORRECT');
  summary.checks.sessionPercentages = percentages as number[];
  summary.checks.explicitApprovalMechanisms = true;
  summary.checks.versionHistoryPreserved = true;
  summary.checks.idempotentSessionsAndDurablePull = true;
  const report = { studentId: student.id, planId: approved.record.id, type: 'progress', periodStart: yesterday, periodEnd: today, includeGrade: false };
  await exportFile('progress-pdf', '/v1/reports/export', { ...report, format: 'pdf' }, 'pdf', student.code);
  await exportFile('progress-word', '/v1/reports/export', { ...report, format: 'docx' }, 'docx', student.code);
  await exportFile('activity-pdf', `/v1/activities/${activity.record.id}/export`, {}, 'pdf', student.code);
  const exports = await json<{ exports: { serial: string; studentCode: string }[] }>('export-history', 'GET', '/v1/reports/exports');
  check(exports.exports.length === 3 && summary.artifacts.every(file => exports.exports.some(log => log.serial === file.serial && log.studentCode === student.code)), 'EXPORT_HISTORY_IDENTIFIERS_MISMATCH');
  check(new Set(summary.artifacts.map(file => file.serial)).size === 3, 'EXPORT_SERIALS_NOT_UNIQUE');
  summary.checks.exportsHaveVerifiedIdentifiers = true;
  summary.checks.privateRawInputsExcluded = true;
  summary.state = 'PASS';
} catch (error) {
  summary.state = 'FAIL';
  summary.failure = error instanceof SmokeFailure ? error.message.slice(0, 160) : 'TRANSPORT_OR_FILE_VERIFICATION_FAILURE';
  process.exitCode = 2;
} finally {
  if (token) {
    try {
      await json('delete-synthetic-account', 'DELETE', '/v1/auth/account', { password, confirmed: true }, 204);
      summary.cleanup.deleted = true;
      await json('revoked-token-check', 'GET', '/v1/records', undefined, 401);
      summary.cleanup.revokedToken = true;
    } catch {
      summary.state = 'FAIL'; summary.failure = 'SYNTHETIC_CLEANUP_OR_REVOCATION_UNVERIFIED'; process.exitCode = 3;
    }
  }
  await writeFile(join(directory, 'SUMMARY.json'), JSON.stringify({ ...summary, finishedAt: new Date().toISOString() }, null, 2));
  console.info(JSON.stringify({ state: summary.state, steps: summary.steps.length, artifacts: summary.artifacts.length,
    cleanup: summary.cleanup, failure: summary.failure, directory }));
}
