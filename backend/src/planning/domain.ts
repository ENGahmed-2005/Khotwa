import { createHash, randomUUID } from 'node:crypto';
import { z } from 'zod';
import { educationalText } from '../intake/schema.js';

const text = z.string().trim().min(1).max(2000);
const support = z.enum(['independent', 'verbal', 'partial', 'full']);
export const criterionSchema = z.discriminatedUnion('type', [
  z.strictObject({ type: z.literal('percentage'), target: z.number().min(0).max(100) }),
  z.strictObject({ type: z.literal('trials'), correct: z.int().positive(), total: z.int().positive() })
    .refine(value => value.correct <= value.total, 'Correct trials cannot exceed total'),
  z.strictObject({ type: z.literal('consistency'), sessions: z.int().positive(), targetPercent: z.number().min(0).max(100) }),
  z.strictObject({ type: z.literal('independence'), support }),
]);

export const goalSchema = z.strictObject({
  id: z.uuid(), skillId: z.string().regex(/^[a-z][a-z0-9_.-]{1,80}$/),
  behavior: text, condition: text, criterion: criterionSchema,
  timeframeWeeks: z.int().min(1).max(104),
});

export const planContentSchema = z.strictObject({
  needsSummary: text, strengthsSummary: text, generalGoal: text,
  baseline: text, tools: z.array(text).min(1).max(30),
  measurementTools: z.array(text).min(1).max(30),
  durationWeeks: z.int().min(1).max(104), sessionsPerWeek: z.int().min(1).max(14),
  goals: z.array(goalSchema).min(1).max(30),
  strategies: z.array(text).max(30), recommendations: z.array(text).max(30),
  nextFollowUp: z.iso.date(),
}).superRefine((plan, context) => {
  const ids = new Set<string>();
  plan.goals.forEach((goal, index) => {
    if (goal.timeframeWeeks > plan.durationWeeks) context.addIssue({ code: 'custom', path: ['goals', index, 'timeframeWeeks'], message: 'Goal exceeds plan duration' });
    if (ids.has(goal.id)) context.addIssue({ code: 'custom', path: ['goals', index, 'id'], message: 'Duplicate goal identifier' });
    ids.add(goal.id);
  });
});

export type PlanContent = z.infer<typeof planContentSchema>;
export interface PlanVersion {
  id: string; studentId: string; version: number;
  status: 'draft' | 'approved'; source: 'ai' | 'specialist';
  suggested: boolean; content: PlanContent;
  createdAt: string; approvedAt: string | null; approvedBy: string | null;
  previousVersionId: string | null;
  /** A display reference only. Gender never changes goals, criteria, tools or AI input. */
  presentation?: { studentReference: 'الطالب' | 'الطالبة' | 'الطالب/الطالبة' };
}
export function studentPresentation(gender?: 'male' | 'female' | 'unspecified'): NonNullable<PlanVersion['presentation']> {
  return { studentReference: gender === 'female' ? 'الطالبة' : gender === 'male' ? 'الطالب' : 'الطالب/الطالبة' };
}

export function createDraft(input: unknown, studentId: string, source: PlanVersion['source'], now = new Date()): PlanVersion {
  const content = planContentSchema.parse(input);
  return { id: randomUUID(), studentId, version: 1, status: 'draft', source,
    suggested: source === 'ai', content, createdAt: now.toISOString(),
    approvedAt: null, approvedBy: null, previousVersionId: null };
}

/** Always creates a separate immutable history entry; never changes the input object. */
export function revisePlan(previous: PlanVersion, input: unknown, now = new Date()): PlanVersion {
  return { ...createDraft(input, previous.studentId, 'specialist', now),
    version: previous.version + 1, previousVersionId: previous.id,
    ...(previous.presentation ? { presentation: structuredClone(previous.presentation) } : {}) };
}

/** Called only after authenticated owner authorization; model output cannot invoke it. */
export function approvePlan(plan: PlanVersion, actorId: string, explicitlyConfirmed: boolean, now = new Date()): PlanVersion {
  if (!explicitlyConfirmed || !actorId) throw new Error('Explicit specialist approval is required');
  if (plan.status !== 'draft') throw new Error('Only a draft can be approved');
  planContentSchema.parse(plan.content);
  return { ...plan, content: structuredClone(plan.content), status: 'approved',
    suggested: false, approvedBy: actorId, approvedAt: now.toISOString() };
}

// Controlled identifiers only. Provider sees no student code, account, age, raw answer or free text.
export const aiSkillReferenceSchema = z.strictObject({
  skillId: z.string().regex(/^[a-z][a-z0-9_.-]{1,80}$/),
  level: z.enum(['mastered', 'developing', 'needsSupport']),
  evidence: z.enum(['approvedAcademicAssessment', 'approvedAlternativeAssessment']),
});
export const customSkillId = z.string().refine(value => value.startsWith('custom.') && z.uuid({ version: 'v4' }).safeParse(value.slice(7)).success, 'Custom skills use an anonymous generated identifier');
export const reviewedSkillLabel = educationalText.min(1).max(80).refine(value => !/[\r\n]|https?:|www\.|<|>/iu.test(value), 'Use one short, reviewed educational label without links');
export const aiSkillSchema = aiSkillReferenceSchema.extend({ reviewedLabel: reviewedSkillLabel.optional() }).superRefine((skill, context) => {
  const custom = customSkillId.safeParse(skill.skillId).success;
  if (custom !== (skill.reviewedLabel !== undefined)) context.addIssue({ code: 'custom', path: ['reviewedLabel'], message: 'Only custom skills require an explicitly reviewed label' });
});
export const generationInputSchema = z.strictObject({
  skills: z.array(aiSkillSchema).min(1).max(40),
  durationWeeks: z.int().min(1).max(104), sessionsPerWeek: z.int().min(1).max(14),
  availableTools: z.array(z.enum(['board', 'pencils', 'cards', 'paper', 'colors'])).min(1),
});
export type GenerationInput = z.infer<typeof generationInputSchema>;

export interface VerifiedSource {
  consentConfirmed: boolean; assessmentApproved: boolean;
  hasReviewedStrengths: boolean; hasReviewedNeeds: boolean; hasBaseline: boolean;
}
export function prepareGeneration(input: unknown, source: VerifiedSource, allowedSkillIds: ReadonlySet<string>) {
  if (!source.consentConfirmed || !source.assessmentApproved || !source.hasReviewedStrengths || !source.hasReviewedNeeds || !source.hasBaseline) {
    throw new Error('Complete consent and specialist-reviewed assessment before generation');
  }
  const payload = generationInputSchema.parse(input);
  if (payload.skills.some(skill => !allowedSkillIds.has(skill.skillId))) throw new Error('Unapproved skill identifier');
  if (!payload.skills.some(skill => skill.level !== 'mastered')) throw new Error('At least one development need is required');
  const hash = createHash('sha256').update(JSON.stringify(payload)).digest('hex');
  return { payload, hash };
}

export const sessionSchema = z.strictObject({
  id: z.uuid(), studentId: z.uuid(), planVersionId: z.uuid(), goalId: z.uuid(),
  occurredOn: z.iso.date(), status: z.enum(['completed', 'absent', 'cancelled']),
  total: z.int().nonnegative().nullable(), correct: z.int().nonnegative().nullable(),
  support: support.nullable(),
  // Institution-selected label; no unapproved scale is silently declared standard.
  engagement: z.string().trim().min(1).max(100).nullable(),
  durationMinutes: z.int().min(1).max(1440).nullable(),
  createdAt: z.iso.datetime({ offset: true }).optional(),
  activityId: z.uuid().nullable().optional(), notes: educationalText.optional(), privacyReviewed: z.literal(true).optional(),
}).superRefine((session, context) => {
  if (session.status === 'completed') {
    if (!session.total || session.correct === null || session.correct > session.total || session.support === null || session.engagement === null) {
      context.addIssue({ code: 'custom', message: 'Completed session needs valid trials, support and engagement' });
    }
  } else if (session.total !== null || session.correct !== null || session.support !== null || session.engagement !== null || session.durationMinutes !== null) {
    context.addIssue({ code: 'custom', message: 'Absence/cancellation must not invent performance data' });
  }
});
export type InterventionSession = z.infer<typeof sessionSchema>;

export function validateSession(input: unknown, approvedPlan: PlanVersion, today: string): InterventionSession {
  const session = sessionSchema.parse(input);
  if (approvedPlan.status !== 'approved' || session.planVersionId !== approvedPlan.id || session.studentId !== approvedPlan.studentId || !approvedPlan.content.goals.some(goal => goal.id === session.goalId)) {
    throw new Error('Session must reference the student and goal of an approved plan version');
  }
  if (session.occurredOn > today) throw new Error('Cannot record future performance');
  return session;
}

export function sessionAccuracy(session: InterventionSession): number | null {
  sessionSchema.parse(session);
  return session.status === 'completed' ? session.correct! / session.total! * 100 : null;
}

export function progressForGoal(sessions: InterventionSession[], goalId: string) {
  return sessions.filter(session => session.goalId === goalId)
    .sort((a, b) => a.occurredOn.localeCompare(b.occurredOn) || a.id.localeCompare(b.id))
    .map(session => ({ id: session.id, date: session.occurredOn, accuracy: sessionAccuracy(session), status: session.status }));
}

export function attendance(sessions: InterventionSession[]) {
  sessions.forEach(session => sessionSchema.parse(session));
  const scheduled = sessions.filter(session => session.status !== 'cancelled');
  const completed = scheduled.filter(session => session.status === 'completed').length;
  return { completed, scheduled: scheduled.length, percent: scheduled.length ? completed / scheduled.length * 100 : null };
}
