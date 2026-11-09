import { randomUUID } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { unzipSync, strFromU8 } from 'fflate';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { chromium } from 'playwright-core';
import { emptySettings, exportRequestSchema, batchRequestSchema, reportSnapshot, criterionPercent, referenceHeadings, type ReportDocument, type StudentReference } from '../src/reports/model.js';
import { goalCharts } from '../src/reports/charts.js';
import { renderActivityPdf, renderReport, reportHtml, normalizeLogo } from '../src/reports/render.js';
import { approvedActivity, reportFixtures } from './reports.fixtures.js';

const fixtures = reportFixtures();
const selected = { studentId: fixtures.student.id, planId: fixtures.plan.id, periodStart: '2026-11-01', periodEnd: '2026-11-30', type: 'progress' as const, format: 'pdf' as const };
function document(overrides: Partial<ReportDocument> = {}) {
  const request = exportRequestSchema.parse(selected);
  return { ...reportSnapshot(request, fixtures.studentRecord, fixtures.planRecord, fixtures.sessionRecords, emptySettings(), `KH-RPT-${randomUUID().toUpperCase()}`, new Date('2026-11-08T10:00:00Z')).document, ...overrides };
}
function withReference(reference?: StudentReference) {
  const content = { ...fixtures.planRecord.data.content as ReportDocument['content'], generalGoal: 'يدعم التدريب مشاركة الطالب في التعلم' };
  const plan = { ...fixtures.planRecord, data: { ...fixtures.planRecord.data, content,
    ...(reference === undefined ? {} : { presentation: { studentReference: reference } }) } };
  return reportSnapshot(exportRequestSchema.parse(selected), fixtures.studentRecord, plan, fixtures.sessionRecords, emptySettings(), 'KH-RPT-REFERENCE-CHECK', new Date('2026-11-08T10:00:00Z')).document;
}
const referenceCases = [
  { reference: 'الطالب' as const, stem: 'reference-student', plan: 'الخطة الفردية للطالب', goals: 'الأهداف الإجرائية للطالب' },
  { reference: 'الطالبة' as const, stem: 'reference-student-female', plan: 'الخطة الفردية للطالبة', goals: 'الأهداف الإجرائية للطالبة' },
  { reference: 'الطالب/الطالبة' as const, stem: 'reference-neutral', plan: 'الخطة الفردية للطالب أو الطالبة', goals: 'الأهداف الإجرائية للطالب أو الطالبة' },
];
const referenceExpectations: { stem: string; plan: string; goals: string }[] = [];

describe('report selection and descriptive data boundary', () => {
  it.each(referenceCases)('uses only fixed presentation headings for $reference and preserves recorded content and calculations', ({ reference, plan, goals }) => {
    const before = JSON.stringify(fixtures.planRecord.data);
    const baseline = withReference(), report = withReference(reference);
    expect(report.studentReference).toBe(reference);
    expect(report.content).toEqual(baseline.content);
    expect(report.content.generalGoal).toBe('يدعم التدريب مشاركة الطالب في التعلم');
    expect(report.goals).toEqual(baseline.goals);
    expect(report.attendance).toEqual(baseline.attendance);
    expect(report.optionalSections).toEqual(baseline.optionalSections);
    expect(report).not.toHaveProperty('gender');
    expect(referenceHeadings(reference)).toEqual({ plan, goals });
    const html = reportHtml(report);
    expect(html).toContain(plan); expect(html).toContain(goals);
    expect(html).toContain(report.content.generalGoal);
    expect(JSON.stringify(fixtures.planRecord.data)).toBe(before);
  });
  it('uses neutral legacy presentation and rejects an unvalidated plan reference', () => {
    expect(withReference().studentReference).toBe('الطالب/الطالبة');
    const plan = { ...fixtures.planRecord, data: { ...fixtures.planRecord.data, presentation: { studentReference: 'UNREVIEWED_REFERENCE' } } };
    expect(() => reportSnapshot(exportRequestSchema.parse(selected), fixtures.studentRecord, plan, fixtures.sessionRecords, emptySettings(), 'serial', new Date())).toThrow();
    const genderOnStudent = { ...fixtures.studentRecord, data: { ...fixtures.studentRecord.data, gender: 'female' } };
    const report = reportSnapshot(exportRequestSchema.parse(selected), genderOnStudent, fixtures.planRecord, fixtures.sessionRecords, emptySettings(), 'serial', new Date()).document;
    expect(report.studentReference).toBe('الطالب/الطالبة');
    expect(report).not.toHaveProperty('gender');
  });
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
  it('keeps twelve recorded dates and accuracy labels readable without changing the data', async () => {
    const goal = { ...document().goals[0]!, sessions: Array.from({ length: 12 }, (_, index) => fixtures.session({ occurredOn: `2026-11-${String(index + 1).padStart(2, '0')}` })) };
    const recorded = JSON.stringify(goal);
    const chart = goalCharts(goal)[0]!.svg;
    expect(JSON.stringify(goal)).toBe(recorded);
    const browser = await chromium.launch({ headless: true, ...(process.env.KHOTWA_CHROMIUM_EXECUTABLE ? { executablePath: process.env.KHOTWA_CHROMIUM_EXECUTABLE } : { channel: 'chrome' }) });
    try {
      const page = await browser.newPage();
      const font = await readFile(new URL('../src/reports/assets/NotoSansArabic.ttf', import.meta.url));
      await page.setContent(`<style>@font-face{font-family:NotoSansArabic;src:url(data:font/ttf;base64,${font.toString('base64')})}body{direction:rtl}</style>${chart}`);
      await page.evaluate(() => globalThis.document.fonts.ready);
      const labels = await page.locator('svg text').evaluateAll(nodes => nodes.map(node => {
        const bounds = (node as SVGTextElement).getBBox();
        return { text: node.textContent!, date: node.getAttribute('aria-label') ?? node.textContent!,
          left: bounds.x, right: bounds.x + bounds.width, top: bounds.y, bottom: bounds.y + bounds.height };
      }));
      expect(labels.filter(label => /^\d{4}-\d{2}-\d{2}$/.test(label.date)).map(label => label.date)).toEqual(goal.sessions.map(session => session.occurredOn));
      expect(labels.filter(label => label.text === '50%')).toHaveLength(13);
      expect(labels.some(label => label.text === '80%')).toBe(true);
      for (let first = 0; first < labels.length; first++) for (let second = first + 1; second < labels.length; second++) {
        const a = labels[first]!, b = labels[second]!;
        const overlap = Math.min(a.right, b.right) - Math.max(a.left, b.left) > 0.5
          && Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > 0.5;
        expect(overlap, `Overlapping chart labels: ${a.date} / ${b.date}`).toBe(false);
      }
    } finally { await browser.close(); }
  }, 30000);
  it.each(referenceCases)('writes the approved $reference headings into real Word and PDF fixtures', async ({ reference, stem, plan, goals }) => {
    const report = { ...withReference(reference), type: 'plan' as const, serial: `KH-RPT-${randomUUID().toUpperCase()}` };
    const [pdf, docx] = await Promise.all([renderReport(report, 'pdf'), renderReport(report, 'docx')]);
    const xml = strFromU8(unzipSync(docx)['word/document.xml']!);
    expect(xml).toContain(plan); expect(xml).toContain(goals);
    expect(xml).toContain('يدعم التدريب مشاركة الطالب في التعلم');
    expect(pdf.subarray(0, 5).toString()).toBe('%PDF-');
    await mkdir('../.artifacts/reports', { recursive: true });
    await writeFile(`../.artifacts/reports/${stem}.pdf`, pdf);
    await writeFile(`../.artifacts/reports/${stem}.docx`, docx);
    referenceExpectations.push({ stem, plan, goals });
    await writeFile('../.artifacts/reports/REFERENCE_EXPECTATIONS.json', JSON.stringify(referenceExpectations, null, 2));
  }, 60000);
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
