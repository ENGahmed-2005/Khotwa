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
  it('preserves optional historical assessment metadata without inventing it for legacy records', () => {
    const legacy = assessmentSchema.parse(assessmentFixture(randomUUID()));
    expect(legacy).not.toHaveProperty('assessedOn');
    expect(legacy).not.toHaveProperty('gradeAtAssessment');
    const current = assessmentSchema.parse({ ...legacy, assessedOn: '2026-11-01', gradeAtAssessment: 'الثاني الأساسي' });
    expect(current.assessedOn).toBe('2026-11-01');
    expect(current.gradeAtAssessment).toBe('الثاني الأساسي');
    expect(assessmentSchema.safeParse({ ...legacy, assessedOn: '2026-02-30' }).success).toBe(false);
    expect(assessmentSchema.safeParse({ ...legacy, gradeAtAssessment: 'unapproved grade' }).success).toBe(false);
  });
  it('keeps structured writing and solution observations descriptive and outside scoring', () => {
    const before = assessmentFixture(randomUUID());
    const after = structuredClone(before);
    after.results['2a']!.structuredObservations = {
      pencilGrip: 'استخدم القبضة التي تناسبه في النشاط', writingDirection: 'كتب من اليمين إلى اليسار',
      letterDots: 'راجع مواضع النقاط', taaForms: 'راجع نهاية الكلمة', tanween: 'جرّب كتابة التنوين', spellingNotes: 'ملاحظة إملائية تعليمية اصطناعية',
    };
    after.results['3a']!.structuredObservations = { solutionMethod: 'عدّ باستخدام الرسم' };
    expect(assessmentSchema.parse(after)).toEqual(after);
    expect(assessmentCounts(after)).toEqual(assessmentCounts(before));
  });
  it('rejects unsupported or misplaced observation fields', () => {
    const data = assessmentFixture(randomUUID());
    for (const [itemId, structuredObservations] of [
      ['2a', { diagnosis: 'synthetic' }], ['2a', { solutionMethod: 'عدّ' }],
      ['3a', { pencilGrip: 'وصف تعليمي' }], ['1a', { writingDirection: 'وصف تعليمي' }],
    ] as const) {
      const result = { ...data.results[itemId]!, structuredObservations };
      expect(assessmentSchema.safeParse({ ...data, results: { ...data.results, [itemId]: result } }).success).toBe(false);
    }
  });
  it.each(['synthetic-private@example.test', '0000000000', 'تشخيص طبي اصطناعي', 'س'.repeat(1001)])('rejects identifying, clinical or oversized structured observation %#', value => {
    const data = assessmentFixture(randomUUID());
    data.results['2a']!.structuredObservations = { spellingNotes: value };
    expect(assessmentSchema.safeParse(data).success).toBe(false);
  });
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
