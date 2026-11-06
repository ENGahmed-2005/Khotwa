import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:khotwa/core/api_client.dart';
import 'package:khotwa/core/auth_state.dart';
import 'package:khotwa/main.dart';

import 'app_state_test.dart' show FakeStore;
import 'encrypted_store_test.dart' show MemorySecrets;

void main() {
  test(
    'account deletion clears its records and plan cache only after server success',
    () async {
      final stores = <String, FakeStore>{};
      var deleteAllowed = false;
      final auth = AuthState(
        api: ApiClient(
          baseUrl: 'https://example.test',
          client: MockClient((request) async {
            if (request.method == 'DELETE') {
              return http.Response(
                deleteAllowed ? '' : '{"error":{"code":"invalid_credentials"}}',
                deleteAllowed ? 204 : 401,
              );
            }
            return http.Response(
              jsonEncode({
                'token': 'synthetic-token',
                'expiresAt': '2099-01-01T00:00:00Z',
                'user': {
                  'id': 'owner-a',
                  'email': 'a@example.test',
                  'role': 'specialist',
                },
              }),
              200,
            );
          }),
        ),
        secrets: MemorySecrets(),
        storeForOwner: (id) async => stores.putIfAbsent(id, FakeStore.new),
      );
      await auth.authenticate(
        email: 'a@example.test',
        password: 'SyntheticPass123!',
        register: false,
      );
      await auth.records!.createStudent(
        grade: 'الثاني الأساسي',
        ageYears: 7,
        ageMonths: 0,
        consentConfirmed: true,
      );
      final plans = await auth.storeForOwner('owner-a-plan-inputs');
      await plans.write('{"syntheticPlan":"draft"}');
      final otherPlans = await auth.storeForOwner('owner-b-plan-inputs');
      await otherPlans.write('{"syntheticPlan":"other-owner"}');
      await expectLater(
        auth.deleteAccount('wrong-password'),
        throwsA(isA<ApiException>()),
      );
      expect(await plans.read(), isNotNull);
      expect(auth.signedIn, isTrue);
      deleteAllowed = true;
      await auth.deleteAccount('SyntheticPass123!');
      expect(await stores['owner-a']!.read(), isNull);
      expect(await plans.read(), isNull);
      expect(await otherPlans.read(), isNotNull);
      expect(auth.signedIn, isFalse);
    },
  );
  test(
    'unsafe production URLs and redirect credentials are not allowed',
    () async {
      expect(
        () => ApiClient(baseUrl: 'http://example.com', allowDebugHttp: false),
        throwsA(isA<ApiException>()),
      );
      final api = ApiClient(
        baseUrl: 'https://example.test',
        client: MockClient((r) async {
          expect(r.followRedirects, isFalse);
          return http.Response('', 302);
        }),
      );
      await expectLater(
        api.request('GET', '/v1/auth/me', token: 'synthetic-token'),
        throwsA(isA<ApiException>()),
      );
    },
  );
  test('auth errors never echo backend sensitive text', () async {
    final api = ApiClient(
      baseUrl: 'https://example.test',
      client: MockClient(
        (r) async => http.Response(
          '{"error":{"code":"invalid","message":"secret-password"}}',
          401,
        ),
      ),
    );
    try {
      await api.request('POST', '/v1/auth/login');
      fail('Expected failure');
    } on ApiException catch (e) {
      expect(e.status, 401);
      expect(e.message, isNot(contains('secret-password')));
    }
  });
  test(
    'invalid response and offline requests produce safe actionable errors',
    () async {
      final invalid = ApiClient(
        baseUrl: 'https://example.test',
        client: MockClient((_) async => http.Response('<html>', 200)),
      );
      await expectLater(
        invalid.request('GET', '/v1/auth/me'),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'invalid_response'),
        ),
      );
      final offline = ApiClient(
        baseUrl: 'https://example.test',
        client: MockClient((_) async => throw Exception('network')),
      );
      await expectLater(
        offline.request('GET', '/v1/auth/me'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'offline')),
      );
    },
  );
  test(
    'account switching isolates cache; offline work returns to the same owner',
    () async {
      final secrets = MemorySecrets();
      final stores = <String, FakeStore>{};
      final api = ApiClient(
        baseUrl: 'https://example.test',
        client: MockClient((r) async {
          if (r.url.path.endsWith('/logout')) {
            return http.Response('', 204);
          }
          final email = (jsonDecode(r.body) as Map)['email'] as String;
          final id = email.startsWith('a@') ? 'owner-a' : 'owner-b';
          return http.Response(
            jsonEncode({
              'token': 'synthetic-$id',
              'expiresAt': '2099-01-01T00:00:00Z',
              'user': {'id': id, 'email': email, 'role': 'specialist'},
            }),
            200,
          );
        }),
      );
      final auth = AuthState(
        api: api,
        secrets: secrets,
        storeForOwner: (id) async => stores.putIfAbsent(id, FakeStore.new),
      );
      await auth.authenticate(
        email: 'a@example.test',
        password: 'SyntheticPass123!',
        register: false,
      );
      final s = await auth.records!.createStudent(
        grade: 'الثاني الأساسي',
        ageYears: 7,
        ageMonths: 0,
        consentConfirmed: true,
      );
      await auth.logout();
      expect(auth.records, isNull);
      await auth.authenticate(
        email: 'b@example.test',
        password: 'SyntheticPass123!',
        register: false,
      );
      expect(auth.records!.students, isEmpty);
      await auth.lock();
      await auth.authenticate(
        email: 'a@example.test',
        password: 'SyntheticPass123!',
        register: false,
      );
      expect(auth.records!.students.single.id, s.id);
      expect(auth.records!.pendingCount, 1);
    },
  );
  testWidgets(
    'app starts in Arabic RTL with real account forms and no demo login',
    (tester) async {
      final auth = AuthState(
        api: ApiClient(baseUrl: 'https://example.test'),
        secrets: MemorySecrets(),
        storeForOwner: (_) async => FakeStore(),
      );
      await tester.pumpWidget(KhotwaApp(auth: auth));
      await tester.pumpAndSettle();
      expect(find.text('خطوة'), findsOneWidget);
      expect(find.text('البريد الإلكتروني للمختصة'), findsOneWidget);
      expect(
        Directionality.of(tester.element(find.text('خطوة'))),
        TextDirection.rtl,
      );
      await tester.scrollUntilVisible(
        find.text('إنشاء حساب جديد'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('إنشاء حساب جديد'));
      await tester.pumpAndSettle();
      expect(find.text('إنشاء حساب المختصة'), findsOneWidget);
    },
  );
}
