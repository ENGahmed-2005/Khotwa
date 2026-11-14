import { randomUUID } from 'node:crypto';
import { approvePlan, createDraft, type InterventionSession } from '../src/planning/domain.js';
import type { Envelope } from '../src/records.js';
import { studentFixture, fixtureTime } from './fixtures.js';
import { aiContent } from './ai.fixtures.js';

export function envelope(kind: string, data: Record<string, unknown>, parentId: string | null): Envelope {
  return { id: data.id as string, kind, parentId, revision: 1, deletedAt: null, createdAt: fixtureTime, updatedAt: fixtureTime, data };
}
export function reportFixtures() {
  const student = studentFixture();
  const plan = approvePlan(createDraft(aiContent(), student.id, 'specialist'), randomUUID(), true);
  const goalId = plan.content.goals[0]!.id;
  const session = (overrides: Partial<InterventionSession> = {}): InterventionSession => ({
    id: randomUUID(), studentId: student.id, planVersionId: plan.id, goalId,
    occurredOn: '2026-11-01', status: 'completed', correct: 4, total: 8, support: 'verbal', engagement: 'تفاعل موثق من المختصة', durationMinutes: 20,
    ...overrides,
  });
  const sessions = [session(), session({ occurredOn: '2026-11-02', correct: 8 }),
    session({ occurredOn: '2026-11-03', status: 'absent', correct: null, total: null, support: null, engagement: null, durationMinutes: null }),
    session({ occurredOn: '2026-11-04', status: 'cancelled', correct: null, total: null, support: null, engagement: null, durationMinutes: null }),
    session({ occurredOn: '2026-10-01', correct: 0 })];
  const studentRecord = envelope('student', { ...student, familyNotes: 'NEVER_EXPORT_FAMILY_NOTES', teacherNotes: 'NEVER_EXPORT_TEACHER_NOTES' }, null);
  const planRecord = envelope('plan', { ...plan }, student.id);
  const sessionRecords = sessions.map(data => envelope('session', { ...data, createdAt: fixtureTime, activityId: null, notes: 'NEVER_EXPORT_SESSION_FREE_TEXT', privacyReviewed: true }, student.id));
  return { student, plan, studentRecord, planRecord, sessionRecords, session };
}
export function approvedActivity(studentId: string, planId: string, goalId: string) {
  const id = randomUUID();
  return envelope('activity', { id, studentId, planId, goalId, status: 'approved', toolSnapshot: [{ id: 'cards', label: 'البطاقات' }],
    content: { title: 'ترتيب بطاقات الحروف', steps: ['تعرض المختصة بطاقتين.', 'تطلب تحديد البطاقة المطابقة.'], examples: ['بطاقتان لحرفين مختلفين.'],
      feedback: 'تقدم المختصة ملاحظة داعمة عن المحاولة.', measurement: 'تسجل المحاولات الصحيحة من عدد المحاولات المنفذة.', preparation: ['تجهز البطاقات المتاحة.'], tools: ['cards'], minutes: 15, lowCostAlternatives: ['استخدام أوراق مقصوصة للبطاقات.'], teacherNotes: '' },
  }, studentId);
}
