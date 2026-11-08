import { z } from 'zod';
import { planContentSchema, sessionSchema, type PlanContent, type InterventionSession, attendance, sessionAccuracy } from '../planning/domain.js';
import type { Envelope } from '../records.js';
import { ApiError } from '../errors.js';

export const reportTypeSchema = z.enum(['progress', 'parent', 'administration', 'plan']);
export type ReportType = z.infer<typeof reportTypeSchema>;
const exportSelectionSchema = z.strictObject({
  studentId: z.uuid(), planId: z.uuid(), type: reportTypeSchema,
  periodStart: z.iso.date(), periodEnd: z.iso.date(),
  format: z.enum(['pdf', 'docx']), includeGrade: z.boolean().default(false),
});
export const exportRequestSchema = exportSelectionSchema.refine(value => value.periodStart <= value.periodEnd, 'Report period must be chronological');
export type ExportRequest = z.infer<typeof exportRequestSchema>;
export const batchRequestSchema = z.strictObject({
  reports: z.array(exportSelectionSchema.omit({ format: true }).refine(value => value.periodStart <= value.periodEnd, 'Report period must be chronological')).min(1).max(10),
  format: z.enum(['pdf', 'docx']),
});

const settingsText = z.string().trim().max(160);
export const settingsRequestSchema = z.strictObject({
  revision: z.int().nonnegative(), institutionTitle: settingsText,
  logo: z.strictObject({ mime: z.enum(['image/png', 'image/jpeg']), base64: z.string().min(4).max(400000).regex(/^[A-Za-z0-9+/]+={0,2}$/) }).nullable(),
  privacyReviewed: z.literal(true),
});
export interface InstitutionLogo { mime: 'image/png'; base64: string; width: number; height: number }
export interface ReportSettings { institutionTitle: string; logo: InstitutionLogo | null; privacyReviewed: true }
export const emptySettings = (): ReportSettings => ({ institutionTitle: '', logo: null, privacyReviewed: true });
export interface ReportGoal {
  id: string; behavior: string; condition: string; criterion: string; targetPercent: number | null;
  timeframeWeeks: number; sessions: InterventionSession[];
}
export interface ReportDocument {
  type: ReportType; serial: string; studentCode: string; grade: string | null;
  exportedOn: string; periodStart: string; periodEnd: string;
  settings: ReportSettings; content: PlanContent; goals: ReportGoal[];
  attendance: { completed: number; scheduled: number; percent: number | null };
  optionalSections: { strategies: boolean; recommendations: boolean; sessionSchedule: boolean };
}
export interface ReportSnapshot {
  studentId: string; planId: string; studentRevision: number; planRevision: number;
  document: ReportDocument;
}

/** Free observations, names, demographics and assessment answers are never selected. */
export function reportSnapshot(request: ExportRequest, student: Envelope, plan: Envelope, records: Envelope[], settings: ReportSettings, serial: string, now: Date): ReportSnapshot {
  if (student.deletedAt || student.kind !== 'student' || student.id !== request.studentId || plan.deletedAt || plan.kind !== 'plan' || plan.id !== request.planId || plan.parentId !== student.id) {
    throw new ApiError(404, 'NOT_FOUND', 'ملف الطالب أو الخطة غير متاح.');
  }
  const studentData = z.object({ id: z.uuid(), code: z.string().regex(/^ST-[A-F0-9]{8}$/), grade: z.string(), consentConfirmed: z.literal(true) }).parse(student.data);
  const planData = z.object({ id: z.uuid(), studentId: z.uuid(), status: z.literal('approved'), content: planContentSchema,
    templateOptions: z.union([
      z.object({ showStrategies: z.boolean(), showRecommendations: z.boolean(), showSessionSchedule: z.boolean() }).transform(value => ({ strategies: value.showStrategies, recommendations: value.showRecommendations, sessionSchedule: value.showSessionSchedule })),
      z.object({ strategies: z.boolean(), recommendations: z.boolean(), sessionSchedule: z.boolean() }),
    ]).optional(),
  }).safeParse(plan.data);
  if (!planData.success || planData.data.id !== plan.id || planData.data.studentId !== student.id || studentData.id !== student.id) throw new ApiError(409, 'APPROVED_PLAN_REQUIRED', 'اختاري خطة معتمدة مرتبطة بهذا الطالب قبل التصدير.');
  const content = planData.data.content;
  reviewSafeText([content.needsSummary, content.strengthsSummary, content.generalGoal, content.baseline, ...content.tools, ...content.measurementTools,
    ...content.strategies, ...content.recommendations, ...content.goals.flatMap(goal => [goal.behavior, goal.condition])]);
  const allowedGoals = new Set(content.goals.map(goal => goal.id));
  const sessions: InterventionSession[] = [];
  for (const row of records) {
    if (row.kind !== 'session' || row.deletedAt || row.parentId !== student.id || row.data.studentId !== student.id || row.data.planVersionId !== plan.id) continue;
    // Projection deliberately excludes notes and future metadata from a report.
    const picked = Object.fromEntries(['id', 'studentId', 'planVersionId', 'goalId', 'occurredOn', 'status', 'total', 'correct', 'support', 'engagement', 'durationMinutes'].map(key => [key, row.data[key]]));
    const session = sessionSchema.parse(picked);
    if (!allowedGoals.has(session.goalId)) throw new ApiError(409, 'SESSION_RELATION_INVALID', 'تحتاج علاقة جلسة بالهدف إلى مراجعة.');
    if (session.occurredOn >= request.periodStart && session.occurredOn <= request.periodEnd) sessions.push(session);
  }
  if (sessions.length > 300) throw new ApiError(400, 'REPORT_PERIOD_TOO_LARGE', 'اختاري فترة أقصر من 300 جلسة للتقرير الواحد.');
  sessions.sort((a, b) => a.occurredOn.localeCompare(b.occurredOn) || a.id.localeCompare(b.id));
  const goals = content.goals.map(goal => ({ id: goal.id, behavior: goal.behavior, condition: goal.condition,
    criterion: criterionText(goal.criterion), targetPercent: criterionPercent(goal.criterion), timeframeWeeks: goal.timeframeWeeks,
    sessions: sessions.filter(session => session.goalId === goal.id) }));
  return { studentId: student.id, planId: plan.id, studentRevision: student.revision, planRevision: plan.revision,
    document: { type: request.type, serial, studentCode: studentData.code, grade: request.includeGrade ? studentData.grade : null,
      exportedOn: now.toISOString().slice(0, 10), periodStart: request.periodStart, periodEnd: request.periodEnd, settings, content, goals,
      attendance: attendance(sessions), optionalSections: planData.data.templateOptions ?? { strategies: true, recommendations: true, sessionSchedule: true } } };
}

export function criterionText(criterion: PlanContent['goals'][number]['criterion']): string {
  switch (criterion.type) {
    case 'percentage': return `دقة مستهدفة ${criterion.target}%`;
    case 'trials': return `${criterion.correct} إجابات صحيحة من ${criterion.total} محاولات`;
    case 'consistency': return `دقة ${criterion.targetPercent}% عبر ${criterion.sessions} جلسات`;
    case 'independence': return `مستوى الدعم المستهدف ${supportLabel(criterion.support)}`;
  }
}
export function criterionPercent(criterion: PlanContent['goals'][number]['criterion']): number | null {
  switch (criterion.type) {
    case 'percentage': return criterion.target;
    case 'trials': return criterion.correct / criterion.total * 100;
    case 'consistency': return criterion.targetPercent;
    case 'independence': return null;
  }
}
export function supportLabel(support: InterventionSession['support']): string {
  return support === null ? 'غير مسجل' : ({ independent: 'مستقل', verbal: 'لفظي', partial: 'جزئي', full: 'كلي' })[support];
}
export const statusLabel = (status: InterventionSession['status']) => ({ completed: 'تمت', absent: 'غياب', cancelled: 'ألغيت' })[status];
export const percentLabel = (percent: number | null) => percent === null ? 'غير متاح' : `${Number(percent.toFixed(2))}%`;
export const accuracyLabel = (session: InterventionSession) => percentLabel(sessionAccuracy(session));
export const titleForType = (type: ReportType) => ({ progress: 'تقرير التقدم الدوري', parent: 'تقرير المتابعة لولي الأمر', administration: 'ملخص المتابعة للإدارة', plan: 'الخطة العلاجية المعتمدة' })[type];

/** A second output boundary; it cannot identify every name and does not replace specialist review. */
export function reviewSafeText(texts: string[]): void {
  const forbidden = /(?:تشخيص|توحد|التوحد|ديسلكسيا|إعاقة|دواء|أدوية|كسول|فاشل|غبي|ضعيف|diagnos|autis|dyslex|medicat|stupid|lazy)|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|(?:\+?\d[\s-]?){9,}|\b\d{4}[-/]\d{2}[-/]\d{2}\b/iu;
  if (texts.some(text => forbidden.test(text))) throw new ApiError(409, 'REPORT_CONTENT_REVIEW_REQUIRED', 'راجعي محتوى الخطة أو الترويسة لإزالة البيانات التعريفية أو الأوصاف غير التربوية قبل التصدير.');
}
