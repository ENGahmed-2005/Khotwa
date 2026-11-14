import { randomUUID } from 'node:crypto';
import { assessmentTemplate, type AssessmentData, type ItemResult, type Operation, type StudentData } from '../src/schemas.js';

export const fixtureTime = '2026-11-01T10:00:00.000Z';
export function studentFixture(overrides: Partial<StudentData> = {}): StudentData {
  return { id: randomUUID(), code: `ST-${randomUUID().slice(0, 8).toUpperCase()}`, grade: 'الثاني الأساسي', ageYears: 7, ageMonths: 2,
    gender: 'female', referralReason: 'دعم مهارة تعليمية اصطناعية',
    consentConfirmed: true, consentDate: fixtureTime, createdAt: fixtureTime, ...overrides };
}
export function itemFixture(overrides: Partial<ItemResult> = {}): ItemResult {
  return { execution: 'performed', judgment: 'independentCorrect', support: 'independent', response: '', observation: '', readingSeconds: null, readingErrors: null, ...overrides };
}
export function assessmentFixture(studentId: string, overrides: Partial<AssessmentData> = {}): AssessmentData {
  const group = overrides.ageGroup ?? '6-8';
  const results: Record<string, ItemResult> = {};
  for (const id of assessmentTemplate.groups[group]) results[id] = itemFixture({ judgment: (assessmentTemplate.subjective as readonly string[]).includes(id) ? 'notScorable' : 'independentCorrect' });
  return { id: randomUUID(), studentId, ageGroup: group, templateVersion: '1.1', createdAt: fixtureTime, status: 'draft', ageOverrideReason: '', results, strengths: '', needs: '', approvedAt: null, privacyReviewed: true, ...overrides };
}
export function operationFixture(kind: Operation['kind'], data: Record<string, unknown>, overrides: Partial<Operation> = {}): Operation {
  return { operationId: randomUUID(), deviceId: randomUUID(), entityId: data.id as string, kind, parentId: kind === 'student' ? null : data.studentId as string, baseRevision: 0, occurredAt: fixtureTime, action: 'upsert', data, ...overrides };
}

