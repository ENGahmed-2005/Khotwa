import { randomBytes, randomUUID } from 'node:crypto';
import { PrismaClient } from '@prisma/client';
import type { FastifyInstance } from 'fastify';
import { chromium } from 'playwright-core';
import { strFromU8, unzipSync } from 'fflate';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { PayloadCipher } from '../src/crypto.js';
import type { Envelope } from '../src/records.js';
import { reportFixtures, approvedActivity } from './reports.fixtures.js';

const storageKey = randomBytes(32), cipher = new PayloadCipher(storageKey);
const runId = `report-test-${randomUUID()}`;
let app: FastifyInstance, prisma: PrismaClient;
interface Account { token: string; user: { id: string } }
const headers = (account: Account) => ({ authorization: `Bearer ${account.token}` });
async function account(): Promise<Account> {
  const response = await app.inject({ method: 'POST', url: '/v1/auth/register', payload: { email: `${runId}-${randomUUID()}@example.test`, password: 'Synthetic-password-123456' } });
  expect(response.statusCode).toBe(201); return response.json<Account>();
}
async function save(ownerId: string, record: Envelope) {
  await prisma.record.create({ data: { id: record.id, ownerId, kind: record.kind, parentId: record.parentId,
    encryptedPayload: cipher.encrypt(record.data, `record:${ownerId}:${record.id}`) } });
}
async function fixture(owner: Account) {
  const data = reportFixtures();
  for (const record of [data.studentRecord, data.planRecord, ...data.sessionRecords]) await save(owner.user.id, record);
  return { ...data, request: { studentId: data.student.id, planId: data.plan.id, type: 'progress', periodStart: '2026-11-01', periodEnd: '2026-11-30', format: 'pdf' } };
}
beforeAll(async () => {
  const url = process.env.TEST_DATABASE_URL;
  if (!url) throw new Error('Reports integration requires a real isolated PostgreSQL TEST_DATABASE_URL');
  prisma = new PrismaClient({ datasources: { db: { url } }, log: [] });
  await prisma.$connect();
  app = await buildApp({ prisma, storageKey, authRateLimit: 10000, globalRateLimit: 10000 });
  await app.ready();
});
afterAll(async () => {
  if (app) await app.close();
  if (prisma) { await prisma.user.deleteMany({ where: { email: { startsWith: runId } } }); await prisma.$disconnect(); }
});

describe('real PostgreSQL report authorization and persistence', () => {
  it('authenticates every report and activity export endpoint', async () => {
    for (const [method, url, payload] of [['GET', '/v1/reports/settings', undefined], ['GET', '/v1/reports/exports', undefined], ['PUT', '/v1/reports/settings', {}], ['POST', '/v1/reports/export', {}], ['POST', '/v1/reports/batch', {}], ['POST', `/v1/activities/${randomUUID()}/export`, {}]] as const) {
      expect((await app.inject({ method, url, payload })).statusCode).toBe(401);
    }
  });
  it('denies a different account and mixed-owner student/plan pairing without an export log', async () => {
    const a = await account(), b = await account(); const data = await fixture(a), other = await fixture(b);
    const response = await app.inject({ method: 'POST', url: '/v1/reports/export', headers: headers(b), payload: data.request });
    expect(response.statusCode).toBe(404);
    const mixed = await app.inject({ method: 'POST', url: '/v1/reports/export', headers: headers(a), payload: { ...data.request, planId: other.plan.id } });
    expect(mixed.statusCode).toBe(404);
    expect(await prisma.record.count({ where: { ownerId: b.user.id, kind: 'reportExport' } })).toBe(0);
  });
  it('does not export draft plans or deleted sources', async () => {
    const owner = await account(), data = await fixture(owner);
    await prisma.record.update({ where: { ownerId_id: { ownerId: owner.user.id, id: data.plan.id } }, data: { encryptedPayload: cipher.encrypt({ ...data.plan, status: 'draft' }, `record:${owner.user.id}:${data.plan.id}`) } });
    expect((await app.inject({ method: 'POST', url: '/v1/reports/export', headers: headers(owner), payload: data.request })).statusCode).toBe(409);
    await prisma.record.update({ where: { ownerId_id: { ownerId: owner.user.id, id: data.student.id } }, data: { deletedAt: new Date() } });
    expect((await app.inject({ method: 'POST', url: '/v1/reports/export', headers: headers(owner), payload: data.request })).statusCode).toBe(404);
  });
  it('exports actual binary PDF and DOCX, recording unique encrypted serials and payload-free audit events', async () => {
    const owner = await account(), data = await fixture(owner);
    const pdf = await app.inject({ method: 'POST', url: '/v1/reports/export', headers: headers(owner), payload: data.request });
    expect(pdf.statusCode).toBe(200); expect(pdf.headers['content-type']).toContain('application/pdf');
    expect(pdf.rawPayload.subarray(0, 5).toString()).toBe('%PDF-');
    const docx = await app.inject({ method: 'POST', url: '/v1/reports/export', headers: headers(owner), payload: { ...data.request, format: 'docx', includeGrade: true } });
    expect(docx.statusCode).toBe(200);
    const xml = strFromU8(unzipSync(docx.rawPayload)['word/document.xml']!);
    expect(xml).toContain(data.student.grade); expect(xml).not.toContain('NEVER_EXPORT');
    expect(pdf.headers['x-khotwa-report-serial']).not.toBe(docx.headers['x-khotwa-report-serial']);
    const exports = (await app.inject({ url: '/v1/reports/exports', headers: headers(owner) })).json<{ exports: { serial: string; studentCode: string }[] }>().exports;
    expect(exports).toHaveLength(2); expect(exports.every(log => log.studentCode === data.student.code)).toBe(true);
    const rows = await prisma.record.findMany({ where: { ownerId: owner.user.id, kind: 'reportExport' } });
    expect(rows.every(row => !row.encryptedPayload.includes(data.student.code))).toBe(true);
    expect((await prisma.auditEvent.findMany({ where: { ownerId: owner.user.id, action: 'report.exported' } })).length).toBe(2);
    const foreign = await account();
    expect((await app.inject({ url: '/v1/reports/exports', headers: headers(foreign) })).json()).toEqual({ exports: [] });
    expect((await app.inject({ url: `/v1/records/${rows[0]!.id}`, headers: headers(foreign) })).statusCode).toBe(404);
  }, 60000);
  it('creates independent files and a code/serial matching list in batch export', async () => {
    const owner = await account(), first = await fixture(owner), second = await fixture(owner);
    const reports = [first, second].map(({ request }) => Object.fromEntries(Object.entries(request).filter(([key]) => key !== 'format')));
    const response = await app.inject({ method: 'POST', url: '/v1/reports/batch', headers: headers(owner), payload: { reports, format: 'docx' } });
    expect(response.statusCode).toBe(200);
    const entries = unzipSync(response.rawPayload);
    const matching = JSON.parse(strFromU8(entries['MATCHING.json']!)) as { studentCode: string; serial: string; filename: string }[];
    expect(matching).toHaveLength(2); expect(new Set(matching.map(row => row.serial)).size).toBe(2);
    for (const [index, source] of [first, second].entries()) {
      const row = matching.find(row => row.studentCode === source.student.code)!;
      const xml = strFromU8(unzipSync(entries[row.filename]!)['word/document.xml']!);
      expect(xml).toContain(source.student.code);
      expect(xml).not.toContain([first, second][1 - index]!.student.code);
    }
    expect(strFromU8(entries['MATCHING.csv']!)).toContain('report_serial');
  }, 60000);
  it('fails an unauthorized batch atomically and rejects hidden student-name input', async () => {
    const owner = await account(), foreign = await account(), a = await fixture(owner), b = await fixture(foreign);
    const reports = [a, b].map(({ request }) => Object.fromEntries(Object.entries(request).filter(([key]) => key !== 'format')));
    const response = await app.inject({ method: 'POST', url: '/v1/reports/batch', headers: headers(owner), payload: { reports, format: 'pdf' } });
    expect(response.statusCode).toBe(404);
    expect(await prisma.record.count({ where: { ownerId: owner.user.id, kind: 'reportExport' } })).toBe(0);
    expect((await app.inject({ method: 'POST', url: '/v1/reports/export', headers: headers(owner), payload: { ...a.request, studentName: 'SYNTHETIC_FORBIDDEN_INPUT' } })).statusCode).toBe(400);
  });
  it('persists only the owner institution header and normalized logo with revision conflicts', async () => {
    const owner = await account(), other = await account();
    expect((await app.inject({ url: '/v1/reports/settings', headers: headers(owner) })).json()).toEqual({ settings: { institutionTitle: '', logo: null, privacyReviewed: true }, revision: 0 });
    const browser = await chromium.launch({ channel: 'chrome', headless: true });
    let png: Buffer;
    try { const page = await browser.newPage({ viewport: { width: 40, height: 20 } }); await page.setContent('<html><body style="margin:0;background:#176370"></body></html>'); png = await page.screenshot({ type: 'png' }); }
    finally { await browser.close(); }
    const payload = { revision: 0, institutionTitle: 'مؤسسة تعليمية تجريبية', logo: { mime: 'image/png', base64: png.toString('base64') }, privacyReviewed: true };
    const response = await app.inject({ method: 'PUT', url: '/v1/reports/settings', headers: headers(owner), payload });
    expect(response.statusCode).toBe(200);
    const saved = response.json<{ settings: { institutionTitle: string; logo: { mime: string; width: number; height: number } }; revision: number }>();
    expect(saved.revision).toBe(1); expect(saved.settings.logo).toMatchObject({ mime: 'image/png', width: 40, height: 20 });
    expect((await app.inject({ method: 'PUT', url: '/v1/reports/settings', headers: headers(owner), payload })).statusCode).toBe(409);
    expect((await app.inject({ url: '/v1/reports/settings', headers: headers(other) })).json<{ revision: number }>().revision).toBe(0);
    const rows = await prisma.record.findMany({ where: { ownerId: owner.user.id, kind: 'institutionProfile' } });
    expect(rows).toHaveLength(1); expect(rows[0]!.encryptedPayload).not.toContain(payload.institutionTitle);
    expect((await app.inject({ method: 'PUT', url: '/v1/reports/settings', headers: headers(owner), payload: { ...payload, revision: 1, logo: { mime: 'image/svg+xml', base64: 'PHN2Zz4=' } } })).statusCode).toBe(400);
  }, 30000);
  it('requires a specialist role for report reads and exports', async () => {
    const owner = await account(); await prisma.user.update({ where: { id: owner.user.id }, data: { role: 'teacher' } });
    for (const url of ['/v1/reports/settings', '/v1/reports/exports']) expect((await app.inject({ url, headers: headers(owner) })).statusCode).toBe(403);
    expect((await app.inject({ method: 'POST', url: '/v1/reports/export', headers: headers(owner), payload: {} })).statusCode).toBe(403);
  });
  it('prints an approved owned activity and denies another owner or a draft activity', async () => {
    const owner = await account(), other = await account(), data = await fixture(owner);
    const activity = approvedActivity(data.student.id, data.plan.id, data.plan.content.goals[0]!.id);
    await save(owner.user.id, activity);
    const url = `/v1/activities/${activity.id}/export`;
    expect((await app.inject({ method: 'POST', url, headers: headers(other), payload: {} })).statusCode).toBe(404);
    const response = await app.inject({ method: 'POST', url, headers: headers(owner), payload: { optionalSections: { title: false, duration: false } } });
    expect(response.statusCode).toBe(200); expect(response.rawPayload.subarray(0, 5).toString()).toBe('%PDF-');
    const logs = (await app.inject({ url: '/v1/reports/exports', headers: headers(owner) })).json<{ exports: { type: string }[] }>().exports;
    expect(logs[0]!.type).toBe('activity');
    await prisma.record.update({ where: { ownerId_id: { ownerId: owner.user.id, id: activity.id } }, data: { encryptedPayload: cipher.encrypt({ ...activity.data, status: 'draft' }, `record:${owner.user.id}:${activity.id}`) } });
    expect((await app.inject({ method: 'POST', url, headers: headers(owner), payload: {} })).statusCode).toBe(409);
  }, 30000);
});
