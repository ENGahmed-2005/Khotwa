import 'package:flutter_test/flutter_test.dart';
import 'package:khotwa/data/assessment_templates.dart';
import 'package:khotwa/models/assessment.dart';
import 'package:khotwa/models/student.dart';

void main() {
  test('six cards exist in 3+3 age groups', () {
    expect(assessmentCards, hasLength(6));
    expect(cardsForAge('6-8'), hasLength(3));
    expect(cardsForAge('9-12'), hasLength(3));
    expect(tasksForAge('6-8'), isNotEmpty);
    expect(tasksForAge('9-12'), isNotEmpty);
  });

  test('age boundaries choose correct grouping', () {
    StudentRecord build(int years, int months) => StudentRecord(
      id: 'local',
      code: 'TEST-0001',
      grade: 'الثاني الأساسي',
      ageYears: years,
      ageMonths: months,
      consentConfirmed: true,
      consentDate: '2026-10-28',
      createdAt: '2026-10-28',
    );
    expect(recommendedAgeGroup(build(5, 11)), isNull);
    expect(recommendedAgeGroup(build(6, 0)), '6-8');
    expect(recommendedAgeGroup(build(8, 11)), '6-8');
    expect(recommendedAgeGroup(build(9, 0)), '9-12');
    expect(recommendedAgeGroup(build(12, 11)), '9-12');
    expect(recommendedAgeGroup(build(13, 0)), isNull);
  });

  test('unperformed, unavailable and descriptive tasks are excluded from denominator', () {
    const items = [
      AssessmentItemResult(
        execution: ItemExecution.performed,
        judgment: ItemJudgment.independentCorrect,
      ),
      AssessmentItemResult(
        execution: ItemExecution.performed,
        judgment: ItemJudgment.supportedCorrect,
      ),
      AssessmentItemResult(
        execution: ItemExecution.notDone,
        judgment: ItemJudgment.incorrect,
      ),
      AssessmentItemResult(execution: ItemExecution.unable),
      AssessmentItemResult(
        execution: ItemExecution.performed,
        judgment: ItemJudgment.notScorable,
      ),
    ];
    final score = AssessmentScore.fromResults(items);
    expect(score.independentCorrect, 1);
    expect(score.scorable, 2);
  });

  test('student JSON does not store identity or diagnostic fields', () {
    const student = StudentRecord(
      id: 'localid',
      code: 'KH-0001',
      grade: 'الثالث الأساسي',
      ageYears: 9,
      ageMonths: 3,
      consentConfirmed: true,
      consentDate: '2026-10-28',
      createdAt: '2026-10-28',
    );
    final json = student.toJson();
    for (final forbidden in [
      'name',
      'birthDate',
      'dob',
      'medicalDiagnosis',
      'diagnosis',
    ]) {
      expect(json.containsKey(forbidden), isFalse);
    }
  });

  test('item result serializes correctly', () {
    const item = AssessmentItemResult(
      execution: ItemExecution.performed,
      judgment: ItemJudgment.independentCorrect,
      support: SupportLevel.independent,
      observation: 'حل ذهني',
      readingSeconds: 27,
      readingErrors: 1,
    );
    final restored = AssessmentItemResult.fromJson(item.toJson());
    expect(restored.execution, ItemExecution.performed);
    expect(restored.judgment, ItemJudgment.independentCorrect);
    expect(restored.readingSeconds, 27);
    expect(restored.observation, 'حل ذهني');
  });
}
