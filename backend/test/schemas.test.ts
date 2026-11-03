import { randomUUID } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { assessmentCounts, assessmentSchema, credentialsSchema, recommendedAgeGroup, studentSchema } from '../src/schemas.js';
import { assessmentFixture, fixtureTime, itemFixture, studentFixture } from './fixtures.js';

describe('strict anonymous student contract', () => {
  it('accepts anonymous minimal intake and normalizes adult account email', () => {
    expect(studentSchema.safeParse(studentFixture()).success).toBe(true);
    expect(credentialsSchema.parse({ email: 'USER@Example.test', password: 'Strong-test-password' }).email).toBe('user@example.test');
  });
  it.each(['real_name', 'birth_date', 'medical_diagnosis', 'photo', 'ownerId'])('rejects unexpected field %s', field => {
    expect(studentSchema.safeParse({ ...studentFixture(), [field]: 'forbidden synthetic value' }).success).toBe(false);
  });
  it.each([{ code: 'StudentName' }, { grade: 'unapproved grade' }, { consentConfirmed: false }, { ageMonths: 12 }, { ageYears: 2 }])('rejects invalid intake %#', override => {
    expect(studentSchema.safeParse({ ...studentFixture(), ...override }).success).toBe(false);
  });
  it.each([[5, 11, null], [6, 0, '6-8'], [8, 11, '6-8'], [9, 0, '9-12'], [12, 11, '9-12'], [13, 0, null]] as const)('maps %i years %i months without forcing out-of-range cards', (ageYears, ageMonths, group) => {
    expect(recommendedAgeGroup({ ageYears, ageMonths })).toBe(group);
  });
});

describe('academic assessment without invented scoring', () => {
  it('accepts both complete template groups', () => {
    for (const ageGroup of ['6-8', '9-12'] as const) expect(assessmentSchema.safeParse(assessmentFixture(randomUUID(), { ageGroup, status: 'completed' })).success).toBe(true);
  });
  it('rejects 1.0 silently upgraded IDs and unknown item IDs', () => {
    const data = assessmentFixture(randomUUID());
    data.results['1d'] = itemFixture();
    expect(assessmentSchema.safeParse(data).success).toBe(false);
    expect(assessmentSchema.safeParse({ ...assessmentFixture(randomUUID()), templateVersion: '1.0' }).success).toBe(false);
  });
  it('does not score absent, unable, subjective, or unscorable items', () => {
    const data = assessmentFixture(randomUUID(), { results: {
      '1a': itemFixture(), '1b': itemFixture({ judgment: 'incorrect' }),
      '1c': itemFixture({ judgment: 'supportedCorrect', support: 'verbal' }),
      '1d1': itemFixture({ execution: 'notDone', judgment: null }),
      '1d2': itemFixture({ execution: 'unable', judgment: null }),
      '1d3': itemFixture({ judgment: 'notScorable' }), '2a': itemFixture({ judgment: 'notScorable' }),
    } });
    expect(assessmentCounts(data)).toEqual({ independentCorrect: 1, scorablePerformed: 3, descriptivePercent: 100 / 3 });
    expect(assessmentCounts({ ...data, results: {} }).descriptivePercent).toBeNull();
  });
  it('requires null judgment when not performed and independent support for independent correctness', () => {
    const a = assessmentFixture(randomUUID(), { results: { '1a': itemFixture({ execution: 'notDone' }) } });
    expect(assessmentSchema.safeParse(a).success).toBe(false);
    a.results['1a'] = itemFixture({ support: 'full' });
    expect(assessmentSchema.safeParse(a).success).toBe(false);
  });
  it('keeps extended tasks descriptive and rejects normative fields', () => {
    const data = assessmentFixture(randomUUID());
    data.results['2a'] = itemFixture();
    expect(assessmentSchema.safeParse(data).success).toBe(false);
    expect(assessmentSchema.safeParse({ ...assessmentFixture(randomUUID()), normativeScore: 80 }).success).toBe(false);
  });
  it('requires all item states and at least one judged performance to complete', () => {
    expect(assessmentSchema.safeParse(assessmentFixture(randomUUID(), { results: {}, status: 'completed' })).success).toBe(false);
    const data = assessmentFixture(randomUUID(), { status: 'completed' });
    for (const key of Object.keys(data.results)) data.results[key] = itemFixture({ execution: 'notDone', judgment: null });
    expect(assessmentSchema.safeParse(data).success).toBe(false);
  });
  it('requires reviewed strengths and needs and explicit approval action timestamp', () => {
    const data = assessmentFixture(randomUUID(), { status: 'approved', approvedAt: fixtureTime });
    expect(assessmentSchema.safeParse(data).success).toBe(false);
    expect(assessmentSchema.safeParse({ ...data, strengths: 'تمييز الأصوات', needs: 'دعم القراءة' }).success).toBe(true);
    expect(assessmentSchema.safeParse({ ...data, privacyReviewed: false }).success).toBe(false);
    expect(assessmentSchema.safeParse({ ...data, status: 'draft' }).success).toBe(false);
  });
});
