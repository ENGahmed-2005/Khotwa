import { randomUUID } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { unzipSync, strFromU8 } from 'fflate';
import { mkdir, writeFile } from 'node:fs/promises';
import { emptySettings, exportRequestSchema, batchRequestSchema, reportSnapshot, criterionPercent, type ReportDocument } from '../src/reports/model.js';
import { goalCharts } from '../src/reports/charts.js';
import { renderActivityPdf, renderReport, reportHtml, normalizeLogo } from '../src/reports/render.js';
import { approvedActivity, reportFixtures } from './reports.fixtures.js';

const fixtures = reportFixtures();
const selected = { studentId: fixtures.student.id, planId: fixtures.plan.id, periodStart: '2026-11-01', periodEnd: '2026-11-30', type: 'progress' as const, format: 'pdf' as const };
function document(overrides: Partial<ReportDocument> = {}) {
  const request = exportRequestSchema.parse(selected);
  return { ...reportSnapshot(request, fixtures.studentRecord, fixtures.planRecord, fixtures.sessionRecords, emptySettings(), `KH-RPT-${randomUUID().toUpperCase()}`, new Date('2026-11-08T10:00:00Z')).document, ...overrides };
}

describe('report selection and descriptive data boundary', () => {
  it('projects the selected student, period, approved plan and sessions without demographic or free observation fields', () => {
    const report = document();
    expect(report.grade).toBeNull();
    expect(report.goals[0]!.sessions).toHaveLength(4);
    expect(report.attendance.completed).toBe(2); expect(report.attendance.scheduled).toBe(3);
    expect(report.attendance.percent).toBeCloseTo(66.6667, 4);
    const html = reportHtml(report);
    expect(html).not.toContain(fixtures.student.grade);
    expect(html).not.toContain('NEVER_EXPORT');
    expect(html).not.toContain('2026-10-01');
    expect(html).toContain('50%'); expect(html).toContain('100%');
    expect(html).toContain('لا أداء مسجل');
    expect(document({ grade: fixtures.student.grade }).grade).toBe(fixtures.student.grade);
  });
  it('rejects reversed periods and undeclared input and enforces each batch period', () => {
    expect(() => exportRequestSchema.parse({ ...selected, periodEnd: '2026-10-01' })).toThrow();
    expect(() => exportRequestSchema.parse({ ...selected, studentName: 'SYNTHETIC_FORBIDDEN_INPUT' })).toThrow();
    expect(() => batchRequestSchema.parse({ reports: [{ ...selected, format: undefined, periodEnd: '2026-10-01' }], format: 'pdf' })).toThrow();
  });
  it('requires an approved matching source and ignores sessions belonging to other plans', () => {
    expect(() => reportSnapshot(exportRequestSchema.parse(selected), fixtures.studentRecord, { ...fixtures.planRecord, data: { ...fixtures.planRecord.data, status: 'draft' } }, [], emptySettings(), 'serial', new Date())).toThrow();
    const alien = { ...fixtures.sessionRecords[0]!, data: { ...fixtures.sessionRecords[0]!.data, planVersionId: randomUUID() } };
    const report = reportSnapshot(exportRequestSchema.parse(selected), fixtures.studentRecord, fixtures.planRecord, [alien], emptySettings(), 'serial', new Date()).document;
    expect(report.goals[0]!.sessions).toHaveLength(0);
    expect(report.attendance.percent).toBeNull();
  });
  it('renders absence/cancellation without accuracy bars and splits long charts into legible panels', () => {
    const goal = document().goals[0]!;
    expect(goalCharts(goal)[0]!.svg).toContain('>غ</text>');
    expect(goalCharts(goal)[0]!.svg).toContain('>أ</text>');
    expect(criterionPercent({ type: 'independence', support: 'independent' })).toBeNull();
    expect(criterionPercent({ type: 'trials', correct: 4, total: 5 })).toBe(80);
    expect(goalCharts({ ...goal, sessions: Array.from({ length: 25 }, () => fixtures.session()) })).toHaveLength(3);
  });
  it('escapes text and respects optional layout choices without hiding required goals', () => {
    const report = document({ optionalSections: { strategies: false, recommendations: false, sessionSchedule: false } });
    report.content = { ...report.content, generalGoal: '<script>test()</script>' };
    const html = reportHtml(report);
    expect(html).toContain('&lt;script&gt;'); expect(html).not.toContain('<script>');
    expect(html).not.toContain('<h2>التدخلات التربوية');
    expect(html).not.toContain('<h2>توصيات المتابعة');
    expect(html).toContain('الهدف 1');
  });
});

describe('actual Arabic document renderers', () => {
  it.each(['progress', 'parent', 'administration', 'plan'] as const)('creates real PDF and editable DOCX for %s', async type => {
    const report = document({ type });
    const [pdf, docx] = await Promise.all([renderReport(report, 'pdf'), renderReport(report, 'docx')]);
    expect(pdf.subarray(0, 5).toString()).toBe('%PDF-');
    expect(pdf.toString('latin1').match(/\/Type\s*\/Page\b/g)?.length).toBeGreaterThan(0);
    const entries = unzipSync(docx);
    const xml = strFromU8(entries['word/document.xml']!);
    const header = strFromU8(entries['word/header1.xml']!);
    expect(xml).toContain('w:bidi');
    expect(xml).toContain(report.studentCode);
    expect(xml).toContain('يحذف الصوت الأول');
    expect(xml).not.toContain('NEVER_EXPORT');
    expect(xml).not.toContain(fixtures.student.grade);
    expect(header).toContain(report.serial);
    expect(header).toContain(report.studentCode);
    expect(header).toMatch(/PAGE/); expect(header).toMatch(/NUMPAGES/);
    if (type !== 'plan') expect(Object.keys(entries).some(path => path.startsWith('word/media/'))).toBe(true);
    await mkdir('../.artifacts/reports', { recursive: true });
    await writeFile(`../.artifacts/reports/${type}.pdf`, pdf);
    await writeFile(`../.artifacts/reports/${type}.docx`, docx);
  }, 60000);
  it('renders all pages with code/serial metadata and real chart data for a longer report', async () => {
    const report = document();
    report.goals = Array.from({ length: 4 }, (_, index) => ({ ...report.goals[0]!, behavior: `مهارة تعليمية تجريبية ${index + 1}`, sessions: Array.from({ length: 15 }, (_, session) => fixtures.session({ occurredOn: `2026-11-${String(session + 1).padStart(2, '0')}` })) }));
    const pdf = await renderReport(report, 'pdf');
    expect(pdf.toString('latin1').match(/\/Type\s*\/Page\b/g)!.length).toBeGreaterThan(3);
    await writeFile('../.artifacts/reports/multipage.pdf', pdf);
    await writeFile('../.artifacts/reports/multipage-metadata.json', JSON.stringify({ code: report.studentCode, serial: report.serial }));
  }, 60000);
  it('rejects fake, excessive or medical logo inputs before rendering', async () => {
    await expect(normalizeLogo({ mime: 'image/png', base64: Buffer.from('<svg>INVALID</svg>INVALID').toString('base64') })).rejects.toThrow();
    const bytes = Buffer.alloc(30); Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]).copy(bytes); bytes.writeUInt32BE(50000, 16); bytes.writeUInt32BE(50000, 20);
    await expect(normalizeLogo({ mime: 'image/png', base64: bytes.toString('base64') })).rejects.toThrow();
  });
  it('exports an actual linked activity PDF without demographics', async () => {
    const activity = approvedActivity(fixtures.student.id, fixtures.plan.id, fixtures.plan.content.goals[0]!.id);
    const input = activity.data.content as Parameters<typeof renderActivityPdf>[0]['content'];
    const pdf = await renderActivityPdf({ studentCode: fixtures.student.code, serial: `KH-ACT-${randomUUID()}`, goal: 'يحذف الصوت الأول عند عرض كلمة مسموعة', settings: emptySettings(), status: 'approved', content: { ...input, tools: ['البطاقات'] } });
    expect(pdf.subarray(0, 5).toString()).toBe('%PDF-');
    await writeFile('../.artifacts/reports/activity.pdf', pdf);
  }, 30000);
});
