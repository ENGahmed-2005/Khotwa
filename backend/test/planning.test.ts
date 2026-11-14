import { randomUUID } from 'node:crypto';
import { describe, expect, it, vi } from 'vitest';
import { approvePlan, attendance, createDraft, planContentSchema, prepareGeneration, progressForGoal, revisePlan, sessionAccuracy, validateSession, type InterventionSession } from '../src/planning/domain.js';
import { generateReviewedDraft, validateGeneratedPlan } from '../src/planning/gateway.js';

const content = () => ({ needsSummary: 'تنمية تعرف الحروف', strengthsSummary: 'المشاركة في الأنشطة', generalGoal: 'تعرف الحروف', baseline: 'يحتاج إلى دعم إضافي', tools: ['بطاقات'], measurementTools: ['قائمة رصد'], durationWeeks: 6, sessionsPerWeek: 2, goals: [{ id: randomUUID(), skillId: 'reading.letters', behavior: 'يميز حرف الباء', condition: 'عند عرض ثلاث بطاقات', criterion: { type: 'trials' as const, correct: 4, total: 5 }, timeframeWeeks: 2 }], strategies: ['العرض المتدرج'], recommendations: ['مراجعة الأداء'], nextFollowUp: '2026-11-16' });
const source = { consentConfirmed: true, assessmentApproved: true, hasReviewedStrengths: true, hasReviewedNeeds: true, hasBaseline: true };
const input = { skills: [{ skillId: 'reading.letters', level: 'developing' as const, evidence: 'approvedAcademicAssessment' as const }], durationWeeks: 6, sessionsPerWeek: 2, availableTools: ['cards' as const] };
const preview = () => prepareGeneration(input, source, new Set(['reading.letters']));

describe('plan quality and immutable human review', () => {
  it.each(['behavior', 'condition', 'criterion', 'timeframeWeeks'])('rejects missing goal element %s', field => {
    const plan = content();
    delete (plan.goals[0] as unknown as Record<string, unknown>)[field];
    expect(() => planContentSchema.parse(plan)).toThrow();
  });
  it('rejects duplicate goals, impossible criterion and duration beyond plan', () => {
    const plan = content(); plan.goals.push(plan.goals[0]!);
    expect(() => planContentSchema.parse(plan)).toThrow();
    const invalid = content(); invalid.goals[0]!.criterion.correct = 6;
    expect(() => planContentSchema.parse(invalid)).toThrow();
    invalid.goals[0]!.criterion.correct = 4; invalid.goals[0]!.timeframeWeeks = 7;
    expect(() => planContentSchema.parse(invalid)).toThrow();
  });
  it('always creates draft and requires explicit actor approval', () => {
    const draft = createDraft(content(), randomUUID(), 'ai');
    expect(draft.status).toBe('draft'); expect(draft.suggested).toBe(true);
    expect(() => approvePlan(draft, 'specialist', false)).toThrow();
    const approved = approvePlan(draft, 'specialist', true);
    expect(draft.status).toBe('draft'); expect(approved.status).toBe('approved');
    expect(approved.approvedBy).toBe('specialist');
    expect(() => approvePlan(approved, 'specialist', true)).toThrow();
    const revision = revisePlan(approved, content());
    expect(revision.status).toBe('draft'); expect(revision.version).toBe(2);
    expect(revision.previousVersionId).toBe(approved.id);
  });
});

describe('reviewed minimum AI payload and fail-closed gateway', () => {
  it.each(Object.keys(source))('requires %s', field => {
    expect(() => prepareGeneration(input, { ...source, [field]: false }, new Set(['reading.letters']))).toThrow();
  });
  it('rejects unknown fields, raw responses and unapproved skill identifiers', () => {
    expect(() => prepareGeneration({ ...input, studentCode: 'ST-00000001' }, source, new Set(['reading.letters']))).toThrow();
    expect(() => prepareGeneration({ ...input, rawResponses: ['anything'] }, source, new Set(['reading.letters']))).toThrow();
    expect(() => prepareGeneration(input, source, new Set())).toThrow();
  });
  it('does not send until policy and exact preview confirmation pass', async () => {
    const provider = { generate: vi.fn().mockResolvedValue(content()) };
    const reviewed = preview();
    const args = { provider, policy: { enabled: false, processingApproved: false }, preview: reviewed, confirmedHash: reviewed.hash, confirmed: true, studentId: randomUUID() };
    await expect(generateReviewedDraft(args)).rejects.toThrow();
    await expect(generateReviewedDraft({ ...args, policy: { enabled: true, processingApproved: true }, confirmedHash: 'stale' })).rejects.toThrow();
    expect(provider.generate).not.toHaveBeenCalled();
    const plan = await generateReviewedDraft({ ...args, policy: { enabled: true, processingApproved: true } });
    expect(plan.status).toBe('draft'); expect(provider.generate).toHaveBeenCalledWith(input, undefined);
  });
  it.each(['تشخيص طبي', 'الطالب كسول', 'medication', 'contact@example.test', '+970599123456'])('rejects unsafe generated content %s', phrase => {
    expect(() => validateGeneratedPlan({ ...content(), recommendations: [phrase] }, input)).toThrow();
  });
  it('rejects payload changed after preview even when caller repeats the old hash', async () => {
    const reviewed = preview();
    reviewed.payload.durationWeeks = 7;
    const provider = { generate: vi.fn() };
    await expect(generateReviewedDraft({ provider, preview: reviewed, confirmed: true, confirmedHash: reviewed.hash, policy: { enabled: true, processingApproved: true }, studentId: randomUUID() })).rejects.toThrow();
    expect(provider.generate).not.toHaveBeenCalled();
  });
  it('rejects injected approval and invented skills; retains retry input after provider error', async () => {
    expect(() => validateGeneratedPlan({ ...content(), status: 'approved' }, input)).toThrow();
    const plan = content(); plan.goals[0]!.skillId = 'unapproved.skill';
    expect(() => validateGeneratedPlan(plan, input)).toThrow();
    const reviewed = preview(); const saved = structuredClone(reviewed);
    await expect(generateReviewedDraft({ provider: { generate: async () => { throw new Error('provider offline'); } }, policy: { enabled: true, processingApproved: true }, preview: reviewed, confirmed: true, confirmedHash: reviewed.hash, studentId: randomUUID() })).rejects.toThrow('provider offline');
    expect(reviewed).toEqual(saved);
  });
});

describe('intervention performance is separate from initial assessment', () => {
  const setup = () => {
    const approved = approvePlan(createDraft(content(), randomUUID(), 'specialist'), 'specialist', true);
    const session: InterventionSession = { id: randomUUID(), studentId: approved.studentId, planVersionId: approved.id, goalId: approved.content.goals[0]!.id, occurredOn: '2026-11-01', status: 'completed', total: 5, correct: 4, support: 'verbal', engagement: 'وصف المختصة', durationMinutes: null };
    return { approved, session };
  };
  it('validates past entry, approved goal and real ratios', () => {
    const { approved, session } = setup();
    expect(sessionAccuracy(validateSession(session, approved, '2026-11-02'))).toBe(80);
    expect(() => validateSession({ ...session, total: 0 }, approved, '2026-11-02')).toThrow();
    expect(() => validateSession({ ...session, correct: 6 }, approved, '2026-11-02')).toThrow();
    expect(() => validateSession({ ...session, studentId: randomUUID() }, approved, '2026-11-02')).toThrow();
    expect(() => validateSession({ ...session, occurredOn: '2026-11-03' }, approved, '2026-11-02')).toThrow();
    expect(() => validateSession(session, { ...approved, status: 'draft' }, '2026-11-02')).toThrow();
  });
  it('absence has no score, cancelled session does not reduce attendance, no invented zero', () => {
    const { session } = setup();
    const absent: InterventionSession = { ...session, id: randomUUID(), status: 'absent', total: null, correct: null, support: null, engagement: null, durationMinutes: null };
    const cancelled: InterventionSession = { ...absent, id: randomUUID(), status: 'cancelled' };
    expect(sessionAccuracy(absent)).toBeNull();
    expect(attendance([session, absent, cancelled])).toEqual({ completed: 1, scheduled: 2, percent: 50 });
    expect(attendance([]).percent).toBeNull();
    expect(progressForGoal([absent, session], session.goalId).map(point => point.accuracy)).toContain(null);
    expect(() => sessionAccuracy({ ...absent, correct: 0 })).toThrow();
  });
});
