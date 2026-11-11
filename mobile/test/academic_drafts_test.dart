import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:khotwa/core/app_state.dart';
import 'package:khotwa/features/assessment_screen.dart';
import 'package:khotwa/models/assessment.dart';

import 'app_state_test.dart' show FakeStore, addStudent;
import 'form_draft_screens_test.dart' show formState, open, backgroundAndClose;
import 'mvp_screens_test.dart' show field, largeSurface;

Map<String, dynamic> itemDraft(String itemId, {String note = ''}) => {
  'itemId': itemId,
  'editedAt': '2026-11-01T10:00:00Z',
  'execution': 'performed',
  'judgment': 'notScorable',
  'support': 'independent',
  'response': '',
  'observation': note,
  'readingSeconds': '',
  'readingErrors': '',
  'wordsRead': '',
  'selfCorrections': '',
  'structuredObservations': {
    for (final key in structuredKeysForTask(itemId)) key: '',
  },
};

Future<AssessmentRecord> newAcademic(AppState state, {int age = 7}) async {
  final student = await addStudent(state, age: age);
  return state.createAssessment(studentId: student.id, privacyReviewed: true);
}

void main() {
  test(
    'new assessment captures date and grade; legacy edits preserve absent metadata',
    () async {
      final records = FakeStore(), drafts = FakeStore();
      final state = formState(records, drafts, 'metadata');
      final assessment = await newAcademic(state);
      expect(assessment.assessedOn, assessment.createdAt.substring(0, 10));
      expect(assessment.gradeAtAssessment, 'الثاني الأساسي');
      expect(
        assessment.copyWith(strengths: 'مشاركة تعليمية').assessedOn,
        assessment.assessedOn,
      );
      final snapshot = jsonDecode(records.content!) as Map<String, dynamic>;
      for (final record in snapshot['records'] as List) {
        if (record['id'] == assessment.id) {
          (record['data'] as Map).remove('assessedOn');
          (record['data'] as Map).remove('gradeAtAssessment');
        }
      }
      records.content = jsonEncode(snapshot);
      final reopened = formState(records, drafts, 'metadata');
      await reopened.load();
      await reopened.saveResult(
        assessmentId: assessment.id,
        itemId: '1a',
        result: const AssessmentItemResult(),
      );
      expect(
        reopened.assessments.single.toJson(),
        isNot(contains('assessedOn')),
      );
      expect(
        reopened.assessments.single.toJson(),
        isNot(contains('gradeAtAssessment')),
      );
    },
  );

  test(
    'structured observations roundtrip without scores and reject unsafe, oversized or misplaced fields',
    () async {
      const structured = {
        'pencilGrip': 'اختار مسكة مناسبة للنشاط',
        'spellingNotes': 'راجع التنوين',
      };
      const result = AssessmentItemResult(
        execution: ItemExecution.performed,
        judgment: ItemJudgment.notScorable,
        structuredObservations: structured,
      );
      expect(
        AssessmentItemResult.fromJson(result.toJson()).structuredObservations,
        structured,
      );
      expect(AssessmentScore.fromResults([result]).scorable, 0);
      final state = formState(FakeStore(), FakeStore(), 'structured');
      final assessment = await newAcademic(state);
      final before = state.pendingCount;
      await expectLater(
        state.saveResult(
          assessmentId: assessment.id,
          itemId: '1a',
          result: result,
        ),
        throwsStateError,
      );
      for (final value in [
        'synthetic-private@example.test',
        '0000000000',
        'تشخيص طبي اصطناعي',
        'س' * 1001,
      ]) {
        await expectLater(
          state.saveResult(
            assessmentId: assessment.id,
            itemId: '2a',
            result: AssessmentItemResult(
              execution: ItemExecution.performed,
              judgment: ItemJudgment.notScorable,
              structuredObservations: {'pencilGrip': value},
            ),
          ),
          throwsStateError,
        );
      }
      expect(state.pendingCount, before);
      await state.saveResult(
        assessmentId: assessment.id,
        itemId: '2a',
        result: result,
      );
      expect(
        state.assessments.single.results['2a']!.structuredObservations,
        structured,
      );
      expect(structuredKeysForTask('3a'), ['solutionMethod']);
      expect(structuredKeysForTask('4a'), isEmpty);
    },
  );

  testWidgets(
    'academic reading inputs survive background and reopening without saving a result',
    (tester) async {
      await largeSurface(tester);
      const owner = 'academic-reading';
      final records = FakeStore(), drafts = FakeStore();
      final state = formState(records, drafts, owner);
      final assessment = await newAcademic(state, age: 10);
      final before = records.content, count = state.pendingCount;
      await open(
        tester,
        (_) => AssessmentScreen(state: state, assessmentId: assessment.id),
      );
      await tester.tap(find.text('أُجريت'));
      await tester.pumpAndSettle();
      await tester.enterText(field('زمن القراءة بالثواني'), '17');
      await tester.enterText(field('عدد الكلمات المقروءة'), '4');
      await tester.enterText(
        field('ملاحظات الأداء / سبب التعذّر (اختياري)'),
        'ملاحظة تعليمية اصطناعية',
      );
      await backgroundAndClose(tester, owner);
      expect(records.content, before);
      expect(state.pendingCount, count);
      expect(state.assessments.single.results, isEmpty);
      final reopened = formState(records, drafts, owner);
      await reopened.load();
      await open(
        tester,
        (_) => AssessmentScreen(state: reopened, assessmentId: assessment.id),
      );
      expect(
        tester
            .widget<TextField>(field('زمن القراءة بالثواني'))
            .controller!
            .text,
        '17',
      );
      expect(
        tester
            .widget<TextField>(field('عدد الكلمات المقروءة'))
            .controller!
            .text,
        '4',
      );
      expect(
        tester.widget<TextField>(field('عدد الأخطاء')).controller!.text,
        '',
      );
      expect(
        tester.widget<TextField>(field('التصحيح الذاتي')).controller!.text,
        '',
      );
      expect(
        tester
            .widget<TextField>(field('ملاحظات الأداء / سبب التعذّر (اختياري)'))
            .controller!
            .text,
        'ملاحظة تعليمية اصطناعية',
      );
      expect(reopened.assessments.single.results, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'writing observations recover only for their assessment and clear atomically after explicit save',
    (tester) async {
      await largeSurface(tester);
      const owner = 'academic-writing';
      final records = FakeStore(), drafts = FakeStore();
      final state = formState(records, drafts, owner);
      final first = await newAcademic(state), second = await newAcademic(state);
      final key = 'assessment-form:${first.id}:2a';
      await state.saveDraft(
        key,
        itemDraft('2a', note: 'ملاحظة مسودة خاصة بهذا البند'),
      );
      final before = records.content;
      await open(
        tester,
        (_) => AssessmentScreen(state: state, assessmentId: second.id),
      );
      expect(field('ملاحظة مسك القلم'), findsNothing);
      expect(find.text('ملاحظة مسودة خاصة بهذا البند'), findsNothing);
      await backgroundAndClose(tester, owner);
      await open(
        tester,
        (_) => AssessmentScreen(state: state, assessmentId: first.id),
      );
      await tester.enterText(
        field('ملاحظة مسك القلم'),
        'وصف مسكة القلم في تمرين اصطناعي',
      );
      await tester.enterText(
        field('ملاحظات الإملاء'),
        'راجع التنوين في كلمة التدريب',
      );
      await backgroundAndClose(tester, owner);
      expect(records.content, before);
      final reopened = formState(records, drafts, owner);
      await reopened.load();
      await open(
        tester,
        (_) => AssessmentScreen(state: reopened, assessmentId: first.id),
      );
      expect(
        tester.widget<TextField>(field('ملاحظة مسك القلم')).controller!.text,
        'وصف مسكة القلم في تمرين اصطناعي',
      );
      await tester.ensureVisible(find.text('حفظ والتالي'));
      await tester.tap(find.text('حفظ والتالي'));
      await tester.pumpAndSettle();
      expect(reopened.draftFor(key), isNull);
      expect(
        reopened
            .assessmentById(first.id)
            .results['2a']!
            .structuredObservations['spellingNotes'],
        'راجع التنوين في كلمة التدريب',
      );
      expect(
        tester.widget<TextField>(field('ملاحظة مسك القلم')).controller!.text,
        '',
      );
      expect(reopened.assessmentById(second.id).results, isEmpty);
      await backgroundAndClose(tester, owner);
      final after = formState(records, drafts, owner);
      await after.load();
      expect(after.draftFor(key), isNull);
      expect(
        after
            .assessmentById(first.id)
            .results['2a']!
            .structuredObservations['pencilGrip'],
        'وصف مسكة القلم في تمرين اصطناعي',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unsafe writing text cannot replace the last safe academic draft or save a record',
    (tester) async {
      await largeSurface(tester);
      const owner = 'academic-unsafe';
      final records = FakeStore(), drafts = FakeStore();
      final state = formState(records, drafts, owner);
      final assessment = await newAcademic(state);
      final key = 'assessment-form:${assessment.id}:2a';
      await state.saveDraft(key, itemDraft('2a'));
      await open(
        tester,
        (_) => AssessmentScreen(state: state, assessmentId: assessment.id),
      );
      await tester.enterText(
        field('ملاحظة مسك القلم'),
        'وصف تعليمي آمن للمهمة',
      );
      await tester.pumpAndSettle();
      final safe = drafts.content, before = records.content;
      await tester.enterText(
        field('ملاحظة مسك القلم'),
        'synthetic-private@example.test',
      );
      await tester.pumpAndSettle();
      expect(drafts.content, safe);
      expect(find.textContaining('أزيلي بيانات الاتصال'), findsOneWidget);
      await tester.ensureVisible(find.text('حفظ والتالي'));
      await tester.tap(find.text('حفظ والتالي'));
      await tester.pumpAndSettle();
      expect(records.content, before);
      expect(state.assessments.single.results, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await AppState.flushDraftsForOwner(owner);
      final reopened = formState(records, drafts, owner);
      await reopened.load();
      await open(
        tester,
        (_) => AssessmentScreen(state: reopened, assessmentId: assessment.id),
      );
      expect(
        tester.widget<TextField>(field('ملاحظة مسك القلم')).controller!.text,
        'وصف تعليمي آمن للمهمة',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'summary drafts recover without privacy approval and explicit saving alone changes the assessment',
    (tester) async {
      await largeSurface(tester);
      const owner = 'academic-summary';
      final records = FakeStore(), drafts = FakeStore();
      final state = formState(records, drafts, owner);
      final assessment = await newAcademic(state);
      final before = records.content, count = state.pendingCount;
      await open(
        tester,
        (_) =>
            AssessmentSummaryScreen(state: state, assessmentId: assessment.id),
      );
      await tester.enterText(
        field('نقاط القوة (مطلوب للاعتماد)'),
        'يشارك في مهمة تعليمية اصطناعية',
      );
      await tester.enterText(
        field('المهارات التي تحتاج إلى تطوير (مطلوب للاعتماد)'),
        'يحتاج إلى تدريب على الحروف',
      );
      await tester.tap(find.byType(CheckboxListTile));
      await backgroundAndClose(tester, owner);
      expect(records.content, before);
      expect(state.pendingCount, count);
      final reopened = formState(records, drafts, owner);
      await reopened.load();
      await open(
        tester,
        (_) => AssessmentSummaryScreen(
          state: reopened,
          assessmentId: assessment.id,
        ),
      );
      expect(
        tester
            .widget<TextField>(field('نقاط القوة (مطلوب للاعتماد)'))
            .controller!
            .text,
        'يشارك في مهمة تعليمية اصطناعية',
      );
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        false,
      );
      await tester.tap(find.text('حفظ الملخص للمراجعة'));
      await tester.pumpAndSettle();
      expect(records.content, before);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.tap(find.text('حفظ الملخص للمراجعة'));
      await tester.pumpAndSettle();
      expect(
        reopened.assessments.single.strengths,
        'يشارك في مهمة تعليمية اصطناعية',
      );
      expect(reopened.assessments.single.status, AssessmentStatus.draft);
      expect(reopened.draftFor('assessment-summary:${assessment.id}'), isNull);
      expect(reopened.pendingCount, count + 1);
      expect(tester.takeException(), isNull);
    },
  );
}
