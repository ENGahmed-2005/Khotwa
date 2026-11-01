import 'package:flutter_test/flutter_test.dart';
import 'package:khotwa/core/app_state.dart';
import 'package:khotwa/core/secure_local_store.dart';
import 'package:khotwa/models/assessment.dart';
import 'package:khotwa/data/assessment_templates.dart';

class FakeStore implements LocalStore {
  String? content;
  @override
  Future<String?> read() async => content;
  @override
  Future<void> write(String data) async { content = data; }
  @override
  Future<void> clear() async { content = null; }
}

void main() {
  test('consent is mandatory and student codes must be unique', () async {
    final state = AppState(FakeStore());
    await expectLater(
      state.createStudent(code: 'KH-0001', grade: 'الثاني الأساسي',
        ageYears: 7, ageMonths: 0, consentConfirmed: false),
      throwsStateError,
    );
    await state.createStudent(code: 'KH-0001', grade: 'الثاني الأساسي',
      ageYears: 7, ageMonths: 0, consentConfirmed: true);
    await expectLater(
      state.createStudent(code: 'kh-0001', grade: 'الثاني الأساسي',
        ageYears: 7, ageMonths: 0, consentConfirmed: true),
      throwsStateError,
    );
    expect(state.students, hasLength(1));
  });

  test('assessment is persisted, requires professional approval, then locked', () async {
    final store = FakeStore();
    final state = AppState(store);
    final student = await state.createStudent(
      code: 'KH-0001', grade: 'الثاني الأساسي', ageYears: 7,
      ageMonths: 4, consentConfirmed: true);
    final assessment = await state.createAssessment(studentId: student.id);
    await expectLater(state.approveAssessment(assessment.id), throwsStateError);
    await state.saveResult(
      assessmentId: assessment.id,
      itemId: '1a',
      result: const AssessmentItemResult(
        execution: ItemExecution.performed,
        judgment: ItemJudgment.independentCorrect,
      ),
    );
    for (final task in tasksForAge('6-8').where((task) => task.id != '1a')) {
      await state.saveResult(assessmentId: assessment.id, itemId: task.id,
          result: const AssessmentItemResult(execution: ItemExecution.notDone));
    }
    await state.saveSummary(assessmentId: assessment.id,
      strengths: 'يميز الصوت الأول', needs: 'مراجعة الدمج الصوتي');
    await state.approveAssessment(assessment.id);
    expect(state.assessmentById(assessment.id).status, AssessmentStatus.approved);
    await expectLater(
      state.saveResult(assessmentId: assessment.id, itemId: '1a',
          result: const AssessmentItemResult()),
      throwsStateError,
    );
    final reloaded = AppState(store);
    await reloaded.load();
    expect(reloaded.assessments.single.status, AssessmentStatus.approved);
    expect(reloaded.students.single.code, 'KH-0001');
  });
}
