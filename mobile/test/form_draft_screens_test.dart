import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:khotwa/core/api_client.dart';
import 'package:khotwa/core/app_state.dart';
import 'package:khotwa/core/auth_state.dart';
import 'package:khotwa/core/form_draft.dart';
import 'package:khotwa/core/plan_api.dart';
import 'package:khotwa/core/secure_local_store.dart';
import 'package:khotwa/features/students_screen.dart';
import 'package:khotwa/features/initial_assessment_screen.dart';
import 'package:khotwa/features/sessions_screen.dart';
import 'package:khotwa/features/plan_editor_screen.dart';

import 'app_state_test.dart' show FakeStore, addStudent;
import 'encrypted_store_test.dart' show MemorySecrets;
import 'mvp_features_test.dart' show seedPlan, syntheticDomain;
import 'mvp_screens_test.dart' show launcher, largeSurface, field;

AppState formState(FakeStore records, FakeStore drafts, String owner) =>
    AppState(
      records,
      draftStore: drafts,
      ownerId: owner,
      deviceId: 'synthetic',
    );
ApiClient offlineApi() => ApiClient(
  baseUrl: 'https://example.test',
  client: MockClient((_) async => throw Exception('offline')),
);
AuthState authFor(AppState state) =>
    AuthState(
        api: offlineApi(),
        secrets: MemorySecrets(),
        storeForOwner: (_) async => FakeStore(),
      )
      ..records = state
      ..ownerId = state.ownerId
      ..token = 'synthetic-token';
Future<void> open(WidgetTester tester, WidgetBuilder builder) async {
  await tester.pumpWidget(launcher(builder));
  await tester.tap(find.text('افتح الصفحة'));
  await tester.pumpAndSettle();
}

Future<void> backgroundAndClose(WidgetTester tester, String owner) async {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await AppState.flushDraftsForOwner(owner);
  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pumpWidget(const SizedBox.shrink());
  await AppState.flushDraftsForOwner(owner);
}

void main() {
  testWidgets(
    'repeated back requests leave the form once and retain the previous route',
    (tester) async {
      await largeSurface(tester);
      final state = formState(FakeStore(), FakeStore(), 'repeated-back');
      await open(tester, (_) => StudentFormScreen(state: state));
      await tester.enterText(field('سبب الإحالة'), 'مدخل تعليمي اصطناعي');
      await tester.tap(find.byType(BackButton));
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('افتح الصفحة'), findsOneWidget);
      expect(
        state.draftFor('student-form:new')!['referralReason'],
        'مدخل تعليمي اصطناعي',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'student form survives background and a fresh state without storing approval checkboxes',
    (tester) async {
      await largeSurface(tester);
      final records = FakeStore(), drafts = FakeStore();
      const owner = 'student-autosave';
      final state = formState(records, drafts, owner);
      await open(tester, (_) => StudentFormScreen(state: state));
      await tester.enterText(
        field('سبب الإحالة'),
        'مراجعة أداء تعليمي اصطناعي',
      );
      await tester.enterText(
        field('ملاحظات الأسرة دون أسمائهم'),
        'ملاحظة تعليمية مصطنعة',
      );
      for (final checkbox
          in find.byType(CheckboxListTile).evaluate().toList()) {
        await tester.tap(find.byWidget(checkbox.widget));
      }
      await tester.pumpAndSettle();
      await backgroundAndClose(tester, owner);
      expect(state.students, isEmpty);
      expect(state.pendingCount, 0);
      expect(records.content, isNull);
      final reopened = formState(records, drafts, owner);
      await reopened.load();
      await open(tester, (_) => StudentFormScreen(state: reopened));
      expect(
        tester.widget<TextField>(field('سبب الإحالة')).controller!.text,
        'مراجعة أداء تعليمي اصطناعي',
      );
      expect(
        tester
            .widget<TextField>(field('ملاحظات الأسرة دون أسمائهم'))
            .controller!
            .text,
        'ملاحظة تعليمية مصطنعة',
      );
      expect(
        tester
            .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
            .every((w) => w.value == false),
        isTrue,
      );
      final snapshot = jsonDecode(drafts.content!) as Map;
      expect(snapshot.toString(), isNot(contains('privacyReviewed')));
      expect(snapshot.toString(), isNot(contains('consentConfirmed')));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'manual assessment inputs recover while the source record and outbox remain unchanged',
    (tester) async {
      await largeSurface(tester);
      final records = FakeStore(), drafts = FakeStore();
      const owner = 'initial-autosave';
      final state = formState(records, drafts, owner);
      final student = await addStudent(state, age: 15);
      final initial = await state.createInitialAssessment(student.id);
      await state.saveInitialAssessment(
        initial.copyWith(
          alternativeReason: 'ملاحظة تعليمية موثقة',
          domains: [syntheticDomain()],
          privacyReviewed: true,
        ),
      );
      final before = records.content, count = state.pendingCount;
      await open(
        tester,
        (_) => InitialAssessmentScreen(state: state, assessmentId: initial.id),
      );
      await tester.enterText(
        field('نقاط القوة'),
        'مشاركة في تمرين اصطناعي جديد',
      );
      await tester.enterText(
        field('شاهد الأداء ومصدر النتيجة'),
        'شاهد تعليمي جديد لم يعتمد بعد',
      );
      await backgroundAndClose(tester, owner);
      expect(records.content, before);
      expect(state.pendingCount, count);
      final reopened = formState(records, drafts, owner);
      await reopened.load();
      await open(
        tester,
        (_) =>
            InitialAssessmentScreen(state: reopened, assessmentId: initial.id),
      );
      expect(
        tester.widget<TextField>(field('نقاط القوة')).controller!.text,
        'مشاركة في تمرين اصطناعي جديد',
      );
      expect(
        tester
            .widget<TextField>(field('شاهد الأداء ومصدر النتيجة'))
            .controller!
            .text,
        'شاهد تعليمي جديد لم يعتمد بعد',
      );
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse,
      );
      expect(reopened.initialAssessments.single.approved, isFalse);
      expect(
        reopened.initialAssessments.single.domains.single.strengths,
        syntheticDomain().strengths,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'session batch keeps row IDs and raw incomplete fields across offline reopen',
    (tester) async {
      await largeSurface(tester);
      final records = FakeStore(), drafts = FakeStore();
      const owner = 'sessions-autosave';
      final state = formState(records, drafts, owner);
      final student = await addStudent(state);
      await seedPlan(state, student.id);
      final before = records.content, count = state.pendingCount;
      await open(tester, (_) => SessionsScreen(auth: authFor(state)));
      await tester.enterText(field('عدد المحاولات (مطلوب)'), '12');
      await tester.enterText(field('الإجابات الصحيحة (مطلوب)'), '');
      await tester.enterText(field('تاريخ الجلسة YYYY-MM-DD'), '2026-01-02');
      await tester.tap(find.text('إضافة جلسة أخرى إلى الدفعة'));
      await tester.pumpAndSettle();
      await tester.enterText(field('عدد المحاولات (مطلوب)').last, '7');
      await tester.enterText(
        field('ملاحظات الأداء (اختياري)').last,
        'ملاحظة اصطناعية للدفعة',
      );
      await backgroundAndClose(tester, owner);
      final ids = (state.draftFor('session-batch')!['rows'] as List)
          .map((r) => (r as Map)['id'])
          .toList();
      expect(records.content, before);
      expect(state.sessions, isEmpty);
      expect(state.pendingCount, count);
      final reopened = formState(records, drafts, owner);
      await reopened.load();
      await open(tester, (_) => SessionsScreen(auth: authFor(reopened)));
      expect(field('عدد المحاولات (مطلوب)'), findsNWidgets(2));
      expect(
        tester
            .widget<TextField>(field('عدد المحاولات (مطلوب)').first)
            .controller!
            .text,
        '12',
      );
      expect(
        tester
            .widget<TextField>(field('عدد المحاولات (مطلوب)').last)
            .controller!
            .text,
        '7',
      );
      expect(
        tester
            .widget<TextField>(field('الإجابات الصحيحة (مطلوب)').first)
            .controller!
            .text,
        '',
      );
      expect(
        tester
            .widget<TextField>(field('ملاحظات الأداء (اختياري)').last)
            .controller!
            .text,
        'ملاحظة اصطناعية للدفعة',
      );
      expect(
        (reopened.draftFor('session-batch')!['rows'] as List).map(
          (r) => (r as Map)['id'],
        ),
        ids,
      );
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'plan edits and incomplete numeric input recover without changing an approved plan',
    (tester) async {
      await largeSurface(tester);
      final records = FakeStore(), drafts = FakeStore();
      const owner = 'plan-autosave';
      final state = formState(records, drafts, owner);
      final student = await addStudent(state);
      final plan = await seedPlan(state, student.id);
      final before = records.content;
      PlanApi api() =>
          PlanApi(api: offlineApi(), tokenForRequest: () => 'synthetic-token');
      await open(
        tester,
        (_) => PlanEditorScreen(
          plan: plan,
          api: api(),
          state: state,
          onSaved: (_) async {},
        ),
      );
      await tester.enterText(
        field('السلوك القابل للملاحظة'),
        'يميز الحرف في تمرين اصطناعي جديد',
      );
      await tester.enterText(field('مدة الخطة بالأسابيع'), '');
      await tester.enterText(field('المحاولات الصحيحة المستهدفة'), '1e');
      await backgroundAndClose(tester, owner);
      expect(records.content, before);
      expect(state.plans.single.approved, isTrue);
      final reopened = formState(records, drafts, owner);
      await reopened.load();
      await open(
        tester,
        (_) => PlanEditorScreen(
          plan: reopened.plans.single,
          api: api(),
          state: reopened,
          onSaved: (_) async {},
        ),
      );
      expect(
        tester
            .widget<TextField>(field('السلوك القابل للملاحظة'))
            .controller!
            .text,
        'يميز الحرف في تمرين اصطناعي جديد',
      );
      expect(
        tester.widget<TextField>(field('مدة الخطة بالأسابيع')).controller!.text,
        '',
      );
      expect(
        tester
            .widget<TextField>(field('المحاولات الصحيحة المستهدفة'))
            .controller!
            .text,
        '1e',
      );
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse,
      );
      expect(
        (reopened.plans.single.content['goals'] as List).single['behavior'],
        'يتعرف على الحرف',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'a failed autosave prevents silent departure and succeeds after retry',
    (tester) async {
      await largeSurface(tester);
      final records = FakeStore(), drafts = FakeStore()..failWrites = true;
      const owner = 'failed-autosave';
      final state = formState(records, drafts, owner);
      await open(tester, (_) => StudentFormScreen(state: state));
      await tester.enterText(
        field('سبب الإحالة'),
        'مدخل اصطناعي يجب الحفاظ عليه',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('ملف طالب جديد'), findsOneWidget);
      expect(state.students, isEmpty);
      drafts.failWrites = false;
      await tester.tap(find.text('إعادة محاولة حفظ المسودة'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('افتح الصفحة'), findsOneWidget);
      expect(
        state.draftFor('student-form:new')!['referralReason'],
        'مدخل اصطناعي يجب الحفاظ عليه',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('discard requires confirmation and removes only the form draft', (
    tester,
  ) async {
    await largeSurface(tester);
    final records = FakeStore(), drafts = FakeStore();
    const owner = 'discard-autosave';
    final state = formState(records, drafts, owner);
    await addStudent(state);
    final before = records.content, count = state.pendingCount;
    await open(tester, (_) => StudentFormScreen(state: state));
    await tester.enterText(field('سبب الإحالة'), 'مسودة اصطناعية');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('إلغاء مسودة النموذج'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('الاحتفاظ بالمسودة'));
    await tester.pumpAndSettle();
    expect(state.draftFor('student-form:new'), isNotNull);
    await tester.tap(find.byTooltip('إلغاء مسودة النموذج'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('أوافق على إلغاء المسودة'));
    await tester.pumpAndSettle();
    expect(state.draftFor('student-form:new'), isNull);
    expect(records.content, before);
    expect(state.pendingCount, count);
    expect(state.students, hasLength(1));
    expect(tester.takeException(), isNull);
  });
  test(
    'separate form snapshots are actually AES encrypted and clear deletes both file and key',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'khotwa-form-encrypted-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final secrets = MemorySecrets();
      final records = EncryptedFileStore(
            directory: directory,
            ownerId: 'encrypted-form',
            secrets: secrets,
          ),
          drafts = EncryptedFileStore(
            directory: directory,
            ownerId: 'encrypted-form-form-inputs',
            secrets: secrets,
          );
      final state = AppState(
        records,
        draftStore: drafts,
        ownerId: 'encrypted-form',
        deviceId: 'synthetic',
      );
      final controller = FormDraftController(state: state, key: 'form');
      controller.update({'text': 'synthetic-private-draft-ST-A1B2C3D4'});
      await controller.flush();
      final raw = await drafts.file.readAsString();
      expect(raw, isNot(contains('synthetic-private-draft')));
      expect(raw, isNot(contains('ST-A1B2C3D4')));
      expect(await records.file.exists(), isFalse);
      await state.deleteLocalAfterAccountDeletion();
      expect(await drafts.file.exists(), isFalse);
      expect(secrets.values, isEmpty);
      controller.dispose();
    },
  );
}
