import { z } from 'zod';

export const uuid = z.uuid({ version: 'v4' });
export const timestamp = z.iso.datetime({ offset: true });
const text = z.string().max(2000);
export const recordKind = z.enum(['student', 'assessment', 'initialAssessment', 'plan', 'session']);
export const passwordSchema = z.string().min(12).max(128);
export const emailSchema = z.email().max(254).transform(value => value.trim().toLowerCase());
export const credentialsSchema = z.strictObject({ email: emailSchema, password: passwordSchema });
export const schoolGrades = ['التمهيدي', 'الأول الأساسي', 'الثاني الأساسي', 'الثالث الأساسي', 'الرابع الأساسي', 'الخامس الأساسي', 'السادس الأساسي', 'السابع الأساسي', 'الثامن الأساسي', 'التاسع الأساسي', 'العاشر الأساسي', 'الحادي عشر', 'الثاني عشر'] as const;

export const studentSchema = z.strictObject({
  id: uuid, code: z.string().regex(/^ST-[A-F0-9]{8}$/), grade: z.enum(schoolGrades),
  ageYears: z.number().int().min(3).max(21), ageMonths: z.number().int().min(0).max(11),
  consentConfirmed: z.literal(true), consentDate: timestamp, createdAt: timestamp,
});
export type StudentData = z.infer<typeof studentSchema>;

export const itemResultSchema = z.strictObject({
  execution: z.enum(['notDone', 'performed', 'unable']),
  judgment: z.enum(['independentCorrect', 'supportedCorrect', 'incorrect', 'notScorable']).nullable(),
  support: z.enum(['independent', 'verbal', 'partial', 'full']), response: text, observation: text,
  readingSeconds: z.number().int().min(0).max(86400).nullable(),
  readingErrors: z.number().int().nonnegative().nullable(),
  wordsRead: z.number().int().nonnegative().nullable().optional(),
  selfCorrections: z.number().int().nonnegative().nullable().optional(),
}).superRefine((result, ctx) => {
  if (result.execution !== 'performed' && result.judgment !== null) ctx.addIssue({ code: 'custom', message: 'Nonperformed items have no judgment' });
  if (result.judgment === 'independentCorrect' && result.support !== 'independent') ctx.addIssue({ code: 'custom', message: 'Independent correctness requires independent support' });
});
export type ItemResult = z.infer<typeof itemResultSchema>;

/** Immutable IDs from SRS Appendix B. Extended tasks are deliberately not scored. */
export const assessmentTemplate = {
  version: '1.1',
  groups: {
    '6-8': ['1a', '1b', '1c', '1d1', '1d2', '1d3', '1d4', '2a', '2b', '3a', '3b', '3c', '3d'],
    '9-12': ['4a', '4b', '4c', '4d', '5a', '5b', '6a', '6b', '6c', '6d'],
  },
  subjective: ['2a', '2b', '4a', '5a', '5b'],
} as const;

export const assessmentSchema = z.strictObject({
  id: uuid, studentId: uuid, ageGroup: z.enum(['6-8', '9-12']), templateVersion: z.literal('1.1'), createdAt: timestamp,
  status: z.enum(['draft', 'completed', 'approved']), ageOverrideReason: text,
  results: z.record(z.string(), itemResultSchema), strengths: text, needs: text,
  approvedAt: timestamp.nullable(), privacyReviewed: z.literal(true),
}).superRefine((assessment, ctx) => {
  const expected: readonly string[] = assessmentTemplate.groups[assessment.ageGroup];
  const subjective: readonly string[] = assessmentTemplate.subjective;
  for (const [id, result] of Object.entries(assessment.results)) {
    if (!expected.includes(id)) ctx.addIssue({ code: 'custom', path: ['results', id], message: 'Unknown item for this template and age group' });
    if (subjective.includes(id) && result.judgment !== null && result.judgment !== 'notScorable') ctx.addIssue({ code: 'custom', path: ['results', id], message: 'Extended tasks require descriptive specialist review' });
  }
  if ((assessment.status === 'approved') !== (assessment.approvedAt !== null)) ctx.addIssue({ code: 'custom', path: ['approvedAt'], message: 'Approval date only accompanies explicit approval' });
  if (assessment.status !== 'draft') {
    if (expected.some(id => !(id in assessment.results))) ctx.addIssue({ code: 'custom', path: ['results'], message: 'Record every item state before completion' });
    const performed = Object.values(assessment.results).filter(result => result.execution === 'performed');
    if (performed.length === 0 || performed.some(result => result.judgment === null)) ctx.addIssue({ code: 'custom', path: ['results'], message: 'At least one performed and reviewed item is required' });
  }
  if (assessment.status === 'approved' && (!assessment.strengths.trim() || !assessment.needs.trim())) ctx.addIssue({ code: 'custom', message: 'Review strengths and needs before approval' });
});
export type AssessmentData = z.infer<typeof assessmentSchema>;

export const operationSchema = z.strictObject({
  operationId: uuid, deviceId: uuid, entityId: uuid, kind: recordKind, parentId: uuid.nullable(),
  baseRevision: z.number().int().nonnegative(), occurredAt: timestamp, action: z.enum(['upsert', 'delete']),
  data: z.record(z.string(), z.unknown()),
});
export type Operation = z.infer<typeof operationSchema>;
export const pushSchema = z.strictObject({ operations: z.array(operationSchema).min(1).max(50) });

export function recommendedAgeGroup(student: Pick<StudentData, 'ageYears' | 'ageMonths'>): '6-8' | '9-12' | null {
  const months = student.ageYears * 12 + student.ageMonths;
  if (months >= 72 && months < 108) return '6-8';
  if (months >= 108 && months < 156) return '9-12';
  return null;
}

export function assessmentCounts(assessment: AssessmentData) {
  const objective = Object.entries(assessment.results).filter(([id, result]) =>
    !(assessmentTemplate.subjective as readonly string[]).includes(id) && result.execution === 'performed' && result.judgment !== null && result.judgment !== 'notScorable');
  const independentCorrect = objective.filter(([, result]) => result.judgment === 'independentCorrect').length;
  return { independentCorrect, scorablePerformed: objective.length, descriptivePercent: objective.length ? 100 * independentCorrect / objective.length : null };
}
