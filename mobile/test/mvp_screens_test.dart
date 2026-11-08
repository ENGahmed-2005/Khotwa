import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:khotwa/core/api_client.dart';
import 'package:khotwa/core/auth_state.dart';
import 'package:khotwa/core/plan_api.dart';
import 'package:khotwa/features/initial_assessment_screen.dart';
import 'package:khotwa/features/plan_editor_screen.dart';
import 'package:khotwa/features/progress_screen.dart';
import 'package:khotwa/features/sessions_screen.dart';

import 'app_state_test.dart' show FakeStore, stateFor, addStudent;
import 'encrypted_store_test.dart' show MemorySecrets;
import 'mvp_features_test.dart' show syntheticDomain, seedPlan, session;

Widget launcher(WidgetBuilder builder) => MaterialApp(
  locale: const Locale('ar'),
  supportedLocales: const [Locale('ar')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: Builder(
    builder: (context) => Scaffold(
      body: FilledButton(
        onPressed: () =>
            Navigator.push(context, MaterialPageRoute<void>(builder: builder)),
        child: const Text('افتح الصفحة'),
      ),
    ),
  ),
);
Future<void> largeSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1000, 5000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

Finder field(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);
void main() {
  testWidgets(
    'manual assessment screen saves evidence and explicit approval freezes it',
    (tester) async {
      await largeSurface(tester);
      final state = stateFor(FakeStore());
      final student = await addStudent(state, age: 15);
      final record = await state.createInitialAssessment(student.id);
      await state.saveInitialAssessment(
        record.copyWith(
          alternativeReason: 'ملاحظة أداء تعليمية خارج البطاقات',
          domains: [syntheticDomain()],
          privacyReviewed: true,
        ),
      );
      await tester.pumpWidget(
        launcher(
          (_) => InitialAssessmentScreen(state: state, assessmentId: record.id),
        ),
      );
      await tester.tap(find.text('افتح الصفحة'));
      await tester.pumpAndSettle();
      expect(
        Directionality.of(tester.element(find.text('التقييم الأولي الحر'))),
        TextDirection.rtl,
      );
      await tester.enterText(
        field('شاهد الأداء ومصدر النتيجة'),
        'ملاحظة تعليمية اصطناعية مسجلة',
      );
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('حفظ مسودة التقييم محليًا'));
      await tester.pumpAndSettle();
      expect(
        state.initialAssessments.single.domains.single.skills.single.evidence,
        'ملاحظة تعليمية اصطناعية مسجلة',
      );
      await tester.tap(find.text('مراجعة واعتماد التقييم'));
      await tester.pumpAndSettle();
      expect(state.initialAssessments.single.approved, isFalse);
      await tester.tap(find.text('أوافق وأعتمد'));
      await tester.pumpAndSettle();
      expect(state.initialAssessments.single.approved, isTrue);
      expect(find.text('حفظ مسودة التقييم محليًا'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'session form records two backdated sessions atomically with actual fields',
    (tester) async {
      await largeSurface(tester);
      final state = stateFor(FakeStore());
      final student = await addStudent(state);
      await seedPlan(state, student.id);
      final api = ApiClient(
        baseUrl: 'https://example.test',
        client: MockClient((_) async => throw Exception('offline')),
      );
      final auth =
          AuthState(
              api: api,
              secrets: MemorySecrets(),
              storeForOwner: (_) async => FakeStore(),
            )
            ..ownerId = 'owner-a'
            ..token = 'synthetic-token'
            ..records = state;
      await tester.pumpWidget(launcher((_) => SessionsScreen(auth: auth)));
      await tester.tap(find.text('افتح الصفحة'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).at(0));
      await tester.pumpAndSettle();
      await tester.tap(find.text(student.code).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('خطة 1').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('إضافة جلسة أخرى إلى الدفعة'));
      await tester.pumpAndSettle();
      final goalFields = find.byWidgetPredicate(
        (w) =>
            w is DropdownButtonFormField<String> &&
            w.key is ValueKey &&
            (w.key as ValueKey).value.toString().startsWith('goal-'),
      );
      for (var i = 0; i < 2; i++) {
        await tester.tap(goalFields.at(i));
        await tester.pumpAndSettle();
        await tester.tap(find.text('يتعرف على الحرف').last);
        await tester.pumpAndSettle();
        await tester.enterText(
          field('تاريخ الجلسة YYYY-MM-DD').at(i),
          '2026-01-0${i + 1}',
        );
        await tester.enterText(field('عدد المحاولات (مطلوب)').at(i), '5');
        await tester.enterText(
          field('الإجابات الصحيحة (مطلوب)').at(i),
          '${i + 3}',
        );
        await tester.enterText(
          field('مستوى التفاعل وفق سلم المؤسسة').at(i),
          'وصف تفاعل اصطناعي',
        );
      }
      expect(state.sessions, isEmpty);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('حفظ 2 جلسة محليًا معًا'));
      await tester.pumpAndSettle();
      expect(state.sessions, hasLength(2));
      expect(state.sessions.map((s) => s.accuracy), [60, 80]);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'plan editor handles empty numeric input and keeps offline changes without approving',
    (tester) async {
      await largeSurface(tester);
      final state = stateFor(FakeStore());
      final student = await addStudent(state);
      final plan = await seedPlan(state, student.id);
      var calls = 0;
      final api = PlanApi(
        api: ApiClient(
          baseUrl: 'https://example.test',
          client: MockClient((_) async {
            calls++;
            throw Exception('offline');
          }),
        ),
        tokenForRequest: () => 'synthetic-token',
      );
      await tester.pumpWidget(
        launcher(
          (_) => PlanEditorScreen(
            plan: plan,
            api: api,
            state: state,
            onSaved: (_) async {},
          ),
        ),
      );
      await tester.tap(find.text('افتح الصفحة'));
      await tester.pumpAndSettle();
      await tester.enterText(
        field('السلوك القابل للملاحظة'),
        'يميز الحرف في النشاط الاصطناعي',
      );
      await tester.enterText(field('مدة الخطة بالأسابيع'), '');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('حفظ التعديلات على هذا الجهاز'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('plan-editor-error')), findsOneWidget);
      await tester.enterText(field('مدة الخطة بالأسابيع'), '6');
      await tester.tap(find.text('حفظ التعديلات على هذا الجهاز'));
      await tester.pumpAndSettle();
      final saved = state.draftFor('plan-edit:${plan.id}')!;
      expect(
        ((saved['content'] as Map)['goals'] as List).single['behavior'],
        'يميز الحرف في النشاط الاصطناعي',
      );
      expect(state.plans.single.approved, isTrue);
      expect(calls, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'chart is readable at phone width with large text and no fabricated absence score',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: ProgressChart(
                  sessions: [
                    session('one', 's'),
                    session('two', 's', status: 'absent'),
                  ],
                  criterion: const {'type': 'trials', 'correct': 4, 'total': 5},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('الخط المتقطع: معيار الهدف 80.0٪'), findsOneWidget);
      expect(
        find.text('الرمز × يعني غيابًا أو إلغاءً بلا نتيجة، وليس صفرًا.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
