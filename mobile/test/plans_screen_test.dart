import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:khotwa/core/api_client.dart';
import 'package:khotwa/core/auth_state.dart';
import 'package:khotwa/features/plans_screen.dart';

import 'app_state_test.dart' show FakeStore;
import 'encrypted_store_test.dart' show MemorySecrets;
import 'plan_api_test.dart' show syntheticPlan, syntheticPreview;

String snapshot({
  String owner = 'owner-a',
  bool preview = false,
  bool plan = false,
}) => jsonEncode({
  'version': 1,
  'ownerId': owner,
  'studentId': null,
  'assessmentId': null,
  'levels': <String, String>{},
  'weeks': 6,
  'sessions': 2,
  'tools': ['cards'],
  'preview': preview ? syntheticPreview().toJson() : null,
  'operationId': preview ? 'retained-operation' : null,
  'plans': plan ? [syntheticPlan()] : [],
});

Widget app(AuthState auth, FakeStore store) => MaterialApp(
  locale: const Locale('ar'),
  supportedLocales: const [Locale('ar')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: PlansScreen(auth: auth, draftStore: store),
);

AuthState authFor(ApiClient api) =>
    AuthState(
        api: api,
        secrets: MemorySecrets(),
        storeForOwner: (_) async => FakeStore(),
      )
      ..ownerId = 'owner-a'
      ..token = 'synthetic-token';

Future<void> largeSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1000, 3000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

void main() {
  testWidgets(
    'restored preview never restores send consent or automatically generates',
    (tester) async {
      await largeSurface(tester);
      var generationCalls = 0;
      final api = ApiClient(
        baseUrl: 'https://example.test',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/generate')) {
            generationCalls++;
          }
          return http.Response(jsonEncode({'records': []}), 200);
        }),
      );
      final store = FakeStore()..content = snapshot(preview: true);
      await tester.pumpWidget(app(authFor(api), store));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('exact-ai-payload')), findsOneWidget);
      expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const Key('confirm-ai-send')))
            .value,
        isFalse,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('generate-plan')))
            .onPressed,
        isNull,
      );
      expect(generationCalls, 0);
      expect(
        (jsonDecode(store.content!) as Map)['operationId'],
        'retained-operation',
      );
    },
  );

  testWidgets(
    'cached plan remains viewable offline and approval requires a separate human confirmation',
    (tester) async {
      await largeSurface(tester);
      var approvalCalls = 0;
      var online = false;
      final api = ApiClient(
        baseUrl: 'https://example.test',
        client: MockClient((request) async {
          if (!online) {
            throw Exception('offline');
          }
          if (request.url.path.endsWith('/approve')) {
            approvalCalls++;
            return http.Response(
              jsonEncode({'record': syntheticPlan(approved: true)}),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response(
            jsonEncode({
              'records': [syntheticPlan()],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final store = FakeStore()..content = snapshot(plan: true);
      await tester.pumpWidget(app(authFor(api), store));
      await tester.pumpAndSettle();
      expect(find.textContaining('مسودة مقترحة — غير معتمدة'), findsOneWidget);
      expect(find.text('السلوك: يتعرف على الحرف'), findsOneWidget);
      expect(find.text('شرط الأداء: عند عرض بطاقات'), findsOneWidget);
      expect(find.text('معيار الإتقان: 4 محاولات صحيحة من 5'), findsOneWidget);
      expect(find.text('الإطار الزمني: 2 أسابيع'), findsOneWidget);
      online = true;
      await tester.tap(find.text('مراجعة واعتماد هذه المسودة'));
      await tester.pumpAndSettle();
      expect(approvalCalls, 0);
      await tester.tap(find.text('العودة للمراجعة'));
      await tester.pumpAndSettle();
      expect(approvalCalls, 0);
      await tester.tap(find.text('مراجعة واعتماد هذه المسودة'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('أوافق وأعتمد الخطة'));
      await tester.pumpAndSettle();
      expect(approvalCalls, 1);
      expect(find.textContaining('معتمدة بقرار المختصة'), findsOneWidget);
      final saved = (jsonDecode(store.content!) as Map)['plans'] as List;
      expect((saved.single as Map)['data']['status'], 'approved');
    },
  );

  testWidgets(
    'owner mismatch preserves encrypted snapshot and prevents requests',
    (tester) async {
      var calls = 0;
      final api = ApiClient(
        baseUrl: 'https://example.test',
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      final store = FakeStore()
        ..content = snapshot(owner: 'owner-b', plan: true);
      final original = store.content;
      await tester.pumpWidget(app(authFor(api), store));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('plan-error')), findsOneWidget);
      expect(calls, 0);
      expect(store.content, original);
      expect(find.textContaining('مسودة مقترحة — غير معتمدة'), findsNothing);
    },
  );

  test('criterion labels preserve all supported mastery types', () {
    expect(criterionLabel({'type': 'percentage', 'target': 80}), 'دقة 80٪');
    expect(
      criterionLabel({'type': 'trials', 'correct': 4, 'total': 5}),
      '4 محاولات صحيحة من 5',
    );
    expect(
      criterionLabel({
        'type': 'consistency',
        'targetPercent': 80,
        'sessions': 3,
      }),
      'دقة 80٪ عبر 3 جلسات',
    );
    expect(
      criterionLabel({'type': 'independence', 'support': 'verbal'}),
      'مستوى المساعدة: لفظي',
    );
  });
}
