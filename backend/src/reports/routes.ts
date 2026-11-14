import { randomUUID } from 'node:crypto';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import type { PrismaClient } from '@prisma/client';
import { zipSync, strToU8 } from 'fflate';
import { z } from 'zod';
import { AuthService, type Clock } from '../auth.js';
import { RecordStore, type Envelope } from '../records.js';
import { ApiError, missing } from '../errors.js';
import { batchRequestSchema, emptySettings, exportRequestSchema, reportSnapshot, reviewSafeText, settingsRequestSchema, type ExportRequest, type ReportSettings, type ReportSnapshot } from './model.js';
import { normalizeLogo, renderActivityPdf, renderReport, type ActivityPrintInput } from './render.js';
import { planContentSchema } from '../planning/domain.js';

export interface ReportRouteOptions { auth: AuthService; records: RecordStore; prisma: PrismaClient; clock?: Clock }
interface RenderedExport { snapshot: ReportSnapshot; bytes: Buffer; request: ExportRequest; filename: string }
export interface ExportLog {
  id: string; serial: string; studentCode: string; type: ExportRequest['type'] | 'activity'; format: ExportRequest['format'];
  exportedAt: string; periodStart: string; periodEnd: string; includeGrade: boolean;
}
export class ReportService {
  private readonly now: Clock;
  constructor(private readonly options: ReportRouteOptions) { this.now = options.clock ?? (() => new Date()); }

  async getSettings(ownerId: string): Promise<{ settings: ReportSettings; revision: number }> {
    const row = await this.options.prisma.record.findFirst({ where: { ownerId, kind: 'institutionProfile', deletedAt: null } });
    if (!row) return { settings: emptySettings(), revision: 0 };
    return { settings: this.options.records.toEnvelope(row).data as unknown as ReportSettings, revision: row.revision };
  }
  async updateSettings(ownerId: string, raw: unknown) {
    const input = settingsRequestSchema.parse(raw);
    reviewSafeText([input.institutionTitle]);
    const logo = input.logo ? await normalizeLogo(input.logo) : null;
    const settings: ReportSettings = { institutionTitle: input.institutionTitle, logo, privacyReviewed: true };
    return this.options.prisma.$transaction(async tx => {
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${ownerId}))`;
      const previous = await tx.record.findFirst({ where: { ownerId, kind: 'institutionProfile', deletedAt: null } });
      if (input.revision !== (previous?.revision ?? 0)) throw new ApiError(409, 'REVISION_CONFLICT', 'تغيرت إعدادات الترويسة؛ حدّثيها وراجعيها قبل الحفظ.');
      const id = previous?.id ?? randomUUID();
      const encryptedPayload = this.options.records.cipher.encrypt(settings, this.options.records.recordContext(ownerId, id));
      const saved = previous
        ? await tx.record.update({ where: { ownerId_id: { ownerId, id } }, data: { encryptedPayload, revision: { increment: 1 } } })
        : await tx.record.create({ data: { ownerId, id, kind: 'institutionProfile', parentId: null, encryptedPayload } });
      await tx.auditEvent.create({ data: { ownerId, action: 'report.settings_updated', entityId: id } });
      return { settings, revision: saved.revision };
    });
  }
  async exports(ownerId: string): Promise<ExportLog[]> {
    const rows = await this.options.records.list(ownerId, 'reportExport');
    return rows.map(row => row.data as unknown as ExportLog).sort((a, b) => b.exportedAt.localeCompare(a.exportedAt));
  }
  private async render(ownerId: string, request: ExportRequest): Promise<RenderedExport> {
    const [student, plan, records, profile] = await Promise.all([
      this.options.records.get(ownerId, request.studentId), this.options.records.get(ownerId, request.planId),
      this.options.records.list(ownerId, 'session'), this.getSettings(ownerId),
    ]);
    const serial = `KH-RPT-${randomUUID().toUpperCase()}`;
    const snapshot = reportSnapshot(request, student, plan, records, profile.settings, serial, this.now());
    const bytes = await renderReport(snapshot.document, request.format);
    if (bytes.length > 20 * 1024 * 1024) throw new ApiError(400, 'REPORT_TOO_LARGE', 'التقرير كبير؛ اختاري فترة أقصر.');
    return { snapshot, bytes, request, filename: `${serial}-${snapshot.document.studentCode}.${request.format}` };
  }
  private async saveLogs(ownerId: string, rendered: RenderedExport[]): Promise<ExportLog[]> {
    return this.options.prisma.$transaction(async tx => {
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${ownerId}))`;
      const logs: ExportLog[] = [];
      for (const file of rendered) {
        const { snapshot, request } = file;
        const parentRows = await tx.record.findMany({ where: { ownerId, id: { in: [snapshot.studentId, snapshot.planId] }, deletedAt: null } });
        const student = parentRows.find(row => row.id === snapshot.studentId);
        const plan = parentRows.find(row => row.id === snapshot.planId);
        if (!student || !plan) throw missing();
        if (student.revision !== snapshot.studentRevision || plan.revision !== snapshot.planRevision) throw new ApiError(409, 'REPORT_SOURCE_CHANGED', 'تغير مصدر التقرير أثناء الطباعة؛ راجعيه ثم أعيدي التصدير.');
        const id = randomUUID();
        const data: ExportLog = { id, serial: snapshot.document.serial, studentCode: snapshot.document.studentCode, type: request.type, format: request.format,
          exportedAt: this.now().toISOString(), periodStart: request.periodStart, periodEnd: request.periodEnd, includeGrade: request.includeGrade };
        await tx.record.create({ data: { ownerId, id, kind: 'reportExport', parentId: snapshot.studentId,
          encryptedPayload: this.options.records.cipher.encrypt(data, this.options.records.recordContext(ownerId, id)) } });
        await tx.auditEvent.create({ data: { ownerId, action: 'report.exported', entityId: id } });
        logs.push(data);
      }
      return logs;
    }, { timeout: 15000 });
  }
  async export(ownerId: string, raw: unknown) {
    const request = exportRequestSchema.parse(raw);
    const rendered = await this.render(ownerId, request);
    const [log] = await this.saveLogs(ownerId, [rendered]);
    return { bytes: rendered.bytes, filename: rendered.filename, log: log!, mime: request.format === 'pdf' ? 'application/pdf' : 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' };
  }
  async exportActivity(ownerId: string, id: string, raw: unknown) {
    const request = z.strictObject({ optionalSections: z.strictObject({ title: z.boolean().optional(), goal: z.boolean().optional(), duration: z.boolean().optional(), alternatives: z.boolean().optional(), teacherNotes: z.boolean().optional() }).optional() }).parse(raw);
    const activity = await this.options.records.get(ownerId, id);
    if (activity.deletedAt || activity.kind !== 'activity') throw missing();
    const data = z.object({ id: z.uuid(), studentId: z.uuid(), planId: z.uuid(), goalId: z.uuid(), status: z.enum(['draft', 'approved']),
      content: z.object({ title: z.string(), steps: z.array(z.string()), examples: z.array(z.string()), feedback: z.string(), measurement: z.string(), preparation: z.array(z.string()), tools: z.array(z.string()), minutes: z.number(), lowCostAlternatives: z.array(z.string()), teacherNotes: z.string() }),
      toolSnapshot: z.array(z.object({ id: z.string(), label: z.string() })).optional(),
    }).parse(activity.data);
    if (data.status !== 'approved') throw new ApiError(409, 'APPROVED_ACTIVITY_REQUIRED', 'راجعي النشاط واعتمديه قبل طباعة نسخة التنفيذ.');
    const [student, plan, profile, toolProfiles] = await Promise.all([this.options.records.get(ownerId, data.studentId), this.options.records.get(ownerId, data.planId), this.getSettings(ownerId), this.options.records.list(ownerId, 'activityTools')]);
    if (data.id !== id || activity.parentId !== student.id || student.kind !== 'student' || student.deletedAt || plan.kind !== 'plan' || plan.deletedAt || plan.parentId !== student.id || plan.data.studentId !== student.id || plan.data.status !== 'approved') throw missing();
    const code = z.string().regex(/^ST-[A-F0-9]{8}$/).parse(student.data.code);
    const goal = planContentSchema.parse(plan.data.content).goals.find(item => item.id === data.goalId);
    if (!goal) throw new ApiError(409, 'ACTIVITY_GOAL_INVALID', 'ارتباط النشاط بهدف الخطة يحتاج مراجعة.');
    const standard = [{ id: 'board', label: 'السبورة' }, { id: 'pencils', label: 'الأقلام' }, { id: 'cards', label: 'البطاقات' }, { id: 'paper', label: 'الأوراق' }, { id: 'colors', label: 'الألوان' }];
    const currentTools = z.array(z.object({ id: z.string(), label: z.string() })).parse(toolProfiles[0]?.data.tools ?? []);
    const catalog = new Map([...standard, ...currentTools, ...(data.toolSnapshot ?? [])].map(tool => [tool.id, tool.label]));
    const tools = data.content.tools.map(tool => {
      const label = catalog.get(tool);
      if (!label) throw new ApiError(409, 'ACTIVITY_TOOL_LABEL_MISSING', 'أعيدي توثيق اسم الأداة المخصصة قبل تصدير النشاط.');
      return label;
    });
    const serial = `KH-ACT-${randomUUID().toUpperCase()}`;
    const input: ActivityPrintInput = { studentCode: code, serial, goal: `${goal.behavior} ${goal.condition}`, settings: profile.settings, status: 'approved', content: { ...data.content, tools }, optionalSections: request.optionalSections };
    const bytes = await renderActivityPdf(input);
    const log = await this.options.prisma.$transaction(async tx => {
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${ownerId}))`;
      const sources = await tx.record.findMany({ where: { ownerId, id: { in: [activity.id, student.id, plan.id] }, deletedAt: null } });
      for (const source of [activity, student, plan]) if (!sources.some(row => row.id === source.id && row.revision === source.revision)) throw new ApiError(409, 'REPORT_SOURCE_CHANGED', 'تغير مصدر النشاط أثناء الطباعة؛ راجعيه ثم أعيدي التصدير.');
      const logId = randomUUID(), today = this.now().toISOString().slice(0, 10);
      const log: ExportLog = { id: logId, serial, studentCode: code, type: 'activity', format: 'pdf', exportedAt: this.now().toISOString(), periodStart: today, periodEnd: today, includeGrade: false };
      await tx.record.create({ data: { ownerId, id: logId, kind: 'reportExport', parentId: student.id, encryptedPayload: this.options.records.cipher.encrypt(log, this.options.records.recordContext(ownerId, logId)) } });
      await tx.auditEvent.create({ data: { ownerId, action: 'activity.exported', entityId: activity.id } });
      return log;
    });
    return { bytes, filename: `${serial}-${code}.pdf`, log };
  }
  async batch(ownerId: string, raw: unknown) {
    const input = batchRequestSchema.parse(raw);
    const files: RenderedExport[] = [];
    // Authorize every selection before expensive rendering. No partial successful export is returned.
    for (const selected of input.reports) {
      const student = await this.options.records.get(ownerId, selected.studentId);
      const plan = await this.options.records.get(ownerId, selected.planId);
      if (student.deletedAt || student.kind !== 'student' || plan.deletedAt || plan.kind !== 'plan' || plan.parentId !== student.id) throw missing();
    }
    for (const selected of input.reports) files.push(await this.render(ownerId, exportRequestSchema.parse({ ...selected, format: input.format })));
    const entries: Record<string, Uint8Array> = {};
    for (const file of files) entries[file.filename] = file.bytes;
    const matching = files.map(file => ({ studentCode: file.snapshot.document.studentCode, serial: file.snapshot.document.serial, filename: file.filename, type: file.request.type, format: file.request.format }));
    entries['MATCHING.json'] = strToU8(JSON.stringify(matching, null, 2));
    entries['MATCHING.csv'] = strToU8('\uFEFFstudent_code,report_serial,file,type,format\r\n' + matching.map(row => [row.studentCode, row.serial, row.filename, row.type, row.format].join(',')).join('\r\n'));
    const bytes = Buffer.from(zipSync(entries, { level: 6 }));
    if (bytes.length > 100 * 1024 * 1024) throw new ApiError(400, 'REPORT_BATCH_TOO_LARGE', 'الحزمة كبيرة؛ اختاري عددًا أقل أو فترة أقصر.');
    const logs = await this.saveLogs(ownerId, files);
    return { bytes, filename: `Khotwa-reports-${this.now().toISOString().slice(0, 10)}.zip`, logs };
  }
}

export function registerReportRoutes(app: FastifyInstance, options: ReportRouteOptions) {
  const service = new ReportService(options);
  async function specialist(request: FastifyRequest) {
    const user = await options.auth.requireUser(request);
    if (user.role !== 'specialist') throw new ApiError(403, 'SPECIALIST_REQUIRED', 'يلزم حساب مختصة مخوّل لتصدير التقارير.');
    return user;
  }
  const limit = { config: { rateLimit: { max: 12, timeWindow: '1 minute' } } };
  app.get('/v1/reports/settings', async request => { const user = await specialist(request); z.strictObject({}).parse(request.query); return service.getSettings(user.id); });
  app.put('/v1/reports/settings', limit, async request => { const user = await specialist(request); return service.updateSettings(user.id, request.body); });
  app.get('/v1/reports/exports', async request => { const user = await specialist(request); z.strictObject({}).parse(request.query); return { exports: await service.exports(user.id) }; });
  app.post('/v1/reports/export', limit, async (request, reply) => {
    const user = await specialist(request);
    const file = await service.export(user.id, request.body);
    return reply.type(file.mime).header('Content-Disposition', `attachment; filename="${file.filename}"`).header('X-Khotwa-Report-Serial', file.log.serial).send(file.bytes);
  });
  app.post('/v1/reports/batch', { config: { rateLimit: { max: 4, timeWindow: '1 minute' } } }, async (request, reply) => {
    const user = await specialist(request);
    const file = await service.batch(user.id, request.body);
    return reply.type('application/zip').header('Content-Disposition', `attachment; filename="${file.filename}"`).send(file.bytes);
  });
  app.post('/v1/activities/:id/export', limit, async (request, reply) => {
    const user = await specialist(request);
    const { id } = z.strictObject({ id: z.uuid() }).parse(request.params);
    const file = await service.exportActivity(user.id, id, request.body);
    return reply.type('application/pdf').header('Content-Disposition', `attachment; filename="${file.filename}"`).header('X-Khotwa-Report-Serial', file.log.serial).send(file.bytes);
  });
  return service;
}

export type { Envelope };
