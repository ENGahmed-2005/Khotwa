import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:khotwa/core/api_client.dart';
import 'package:khotwa/core/auth_state.dart';
import 'package:khotwa/core/khotwa_theme.dart';
import 'package:khotwa/core/plan_api.dart';
import 'package:khotwa/features/plans_screen.dart';
import 'package:khotwa/features/reports_screen.dart';
import 'package:khotwa/features/sessions_screen.dart';
import 'package:khotwa/features/students_screen.dart';

import 'app_state_test.dart' show FakeStore, stateFor, addStudent;
import 'encrypted_store_test.dart' show MemorySecrets;
import 'mvp_features_test.dart' show seedPlan;
import 'mvp_screens_test.dart' show field;
import 'plan_api_test.dart' show syntheticPlan, syntheticPreview;
import 'plans_screen_test.dart' show snapshot;

AuthState account({
  List<Map<String, dynamic>> plans = const [],
  Map<String, FakeStore>? stores,
}) {
  final storage = stores ?? <String, FakeStore>{};
  return AuthState(
      api: ApiClient(
        baseUrl: 'https://example.test',
        client: MockClient((request) async {
          final data = switch (request.url.path) {
            '/v1/reports/settings' => {
              'settings': {'institutionTitle': '', 'logo': null, 'revision': 0},
            },
            '/v1/reports/exports' => {'exports': []},
            _ => {'records': plans},
          };
          return http.Response(
            jsonEncode(data),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      ),
      secrets: MemorySecrets(),
      storeForOwner: (id) async => storage.putIfAbsent(id, FakeStore.new),
    )
    ..ownerId = 'owner-a'
    ..token = 'synthetic-token'
    ..records = stateFor(FakeStore());
}

Future<void> screen(
  WidgetTester tester,
  Widget child, {
  double width = 390,
  double scale = 1,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: KhotwaTheme.light,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: child,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    250,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 40,
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> readWholePage(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    expect(tester.takeException(), isNull);
    final scrolling = find.byType(Scrollable).first;
    final position = tester.state<ScrollableState>(scrolling).position;
    final before = position.pixels;
    await tester.drag(scrolling, const Offset(0, -500));
    await tester.pumpAndSettle();
    if ((position.pixels - before).abs() < 1) break;
  }
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('empty plan workflow leads to actual student files', (
    tester,
  ) async {
    final auth = account();
    await screen(tester, PlansScreen(auth: auth, draftStore: FakeStore()));
    expect(find.text('ابدئي بملف الطالب'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    await reveal(tester, find.text('فتح ملفات الطلبة'));
    await tester.tap(find.text('فتح ملفات الطلبة'));
    await tester.pumpAndSettle();
    expect(find.byType(StudentsScreen), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'empty session workflow offers its prerequisite without creating session records',
    (tester) async {
      final auth = account();
      await screen(tester, SessionsScreen(auth: auth));
      expect(find.text('ملف الطالب أولًا'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await reveal(tester, find.text('فتح ملفات الطلبة'));
      await tester.tap(find.text('فتح ملفات الطلبة'));
      await tester.pumpAndSettle();
      expect(find.byType(StudentsScreen), findsOneWidget);
      expect(auth.records!.sessions, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'complete readable AI preview preserves every nested value and optional raw JSON',
    (tester) async {
      final auth = account();
      final original = syntheticPreview();
      final payload = {
        ...original.payload,
        'schemaVersion': 1,
        'ageGroup': '6-8',
        'additional': {
          'unknownField': 'future-safe-value',
          'flag': false,
          'empty': null,
          'emptyList': [],
          'emptyMap': <String, dynamic>{},
          'emptyString': '',
        },
      };
      final preview = PlanPreview(
        payload: payload,
        hash: original.hash,
        token: original.token,
        expiresAt: original.expiresAt,
      );
      final cached = jsonDecode(snapshot()) as Map<String, dynamic>;
      cached['preview'] = preview.toJson();
      cached['operationId'] = 'retained-operation';
      final store = FakeStore()..content = jsonEncode(cached);
      await screen(
        tester,
        PlansScreen(auth: auth, draftStore: store),
        width: 1000,
      );
      final text = tester
          .widget<SelectableText>(find.byKey(const Key('exact-ai-payload')))
          .data!;
      for (final value in [
        'reading.letters',
        'developing',
        'approvedAcademicAssessment',
        'cards',
        '6-8',
        'future-safe-value',
        'false',
        'null',
        '[]',
        '{}',
        '""',
      ]) {
        expect(text, contains(value));
      }
      expect(text, contains('مدة الخطة بالأسابيع: 6'));
      expect(text, contains('عدد الجلسات أسبوعيًا: 2'));
      await reveal(tester, find.text('عرض الحقول التقنية الكاملة'));
      await tester.tap(find.text('عرض الحقول التقنية الكاملة'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SelectableText>(find.byKey(const Key('raw-ai-payload')))
            .data,
        const JsonEncoder.withIndent('  ').convert(payload),
      );
      expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const Key('confirm-ai-send')))
            .value,
        isFalse,
      );
      final saved = jsonDecode(store.content!) as Map;
      expect((saved['preview'] as Map)['previewToken'], original.token);
      expect(saved['operationId'], 'retained-operation');
    },
  );

  testWidgets(
    'report starts with the output choices and opens optional institution fields on demand',
    (tester) async {
      final stores = <String, FakeStore>{};
      final auth = account(stores: stores);
      await screen(tester, ReportsScreen(auth: auth));
      expect(find.text('١. نوع التقرير وفترته'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await reveal(tester, find.text('ترويسة المؤسسة (اختياري)'));
      await tester.tap(find.text('ترويسة المؤسسة (اختياري)'));
      await tester.pumpAndSettle();
      await reveal(tester, field('عنوان المؤسسة (اختياري)'));
      await tester.enterText(
        field('عنوان المؤسسة (اختياري)'),
        'مؤسسة تدريب اصطناعية',
      );
      await tester.pumpAndSettle();
      final raw = jsonDecode(stores['owner-a-report-inputs']!.content!) as Map;
      expect((raw['data'] as Map)['institutionTitle'], 'مؤسسة تدريب اصطناعية');
      expect((raw['data'] as Map)['headerDirty'], isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'report requires a real plan selection and a fresh privacy review before export',
    (tester) async {
      final stores = <String, FakeStore>{};
      final auth = account(
        plans: [syntheticPlan(approved: true)],
        stores: stores,
      );
      await screen(tester, ReportsScreen(auth: auth), width: 1000);
      final export = find.widgetWithText(FilledButton, 'تصدير وحفظ التقرير');
      await reveal(tester, export);
      expect(tester.widget<FilledButton>(export).onPressed, isNull);
      await reveal(tester, find.byType(CheckboxListTile).first);
      await tester.tap(find.byType(CheckboxListTile).first);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(export).onPressed, isNull);
      await reveal(tester, find.byType(CheckboxListTile).last);
      await tester.tap(find.byType(CheckboxListTile).last);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(export).onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await screen(tester, ReportsScreen(auth: auth), width: 1000);
      await reveal(tester, export);
      expect(
        tester
            .widget<CheckboxListTile>(find.byType(CheckboxListTile).last)
            .value,
        isFalse,
      );
      expect(tester.widget<FilledButton>(export).onPressed, isNull);
    },
  );

  testWidgets(
    'session calendar replaces an incomplete date only after explicit confirmation',
    (tester) async {
      final auth = account();
      final student = await addStudent(auth.records!);
      await seedPlan(auth.records!, student.id);
      await screen(tester, SessionsScreen(auth: auth), width: 1000);
      await reveal(tester, field('تاريخ الجلسة YYYY-MM-DD'));
      await tester.enterText(field('تاريخ الجلسة YYYY-MM-DD'), '2026-01-');
      await tester.pumpAndSettle();
      await reveal(tester, find.byTooltip('اختيار تاريخ الجلسة'));
      await tester.tap(find.byTooltip('اختيار تاريخ الجلسة'));
      await tester.pumpAndSettle();
      final dialog = find.byType(DatePickerDialog);
      final initial = tester.widget<DatePickerDialog>(dialog).initialDate!;
      final label = MaterialLocalizations.of(
        tester.element(dialog),
      ).okButtonLabel;
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(field('تاريخ الجلسة YYYY-MM-DD'))
            .controller!
            .text,
        '${initial.year.toString().padLeft(4, '0')}-${initial.month.toString().padLeft(2, '0')}-${initial.day.toString().padLeft(2, '0')}',
      );
      expect(auth.records!.sessions, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [320.0, 390.0, 768.0]) {
    testWidgets(
      'workflows remain readable at ${width.toInt()}px with enlarged Arabic text',
      (tester) async {
        for (final type in ['plans', 'sessions', 'reports']) {
          final auth = account();
          await addStudent(auth.records!);
          final page = switch (type) {
            'plans' => PlansScreen(auth: auth, draftStore: FakeStore()),
            'sessions' => SessionsScreen(auth: auth),
            _ => ReportsScreen(auth: auth),
          };
          await screen(tester, page, width: width, scale: 1.6);
          expect(
            Directionality.of(tester.element(find.byType(Scaffold).first)),
            TextDirection.rtl,
          );
          if (type == 'reports') {
            await reveal(tester, find.text('ترويسة المؤسسة (اختياري)'));
            await tester.tap(find.text('ترويسة المؤسسة (اختياري)'));
            await tester.pumpAndSettle();
          }
          await readWholePage(tester);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }
      },
    );
  }
}
