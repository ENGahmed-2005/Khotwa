import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:khotwa/core/api_client.dart';
import 'package:khotwa/core/auth_state.dart';
import 'package:khotwa/main.dart';

import 'app_state_test.dart' show FakeStore;
import 'encrypted_store_test.dart' show MemorySecrets;

Map<String, dynamic> syntheticSession() => {
  'token': 'synthetic-token',
  'expiresAt': '2099-01-01T00:00:00Z',
  'user': {'id': 'owner-a', 'email': 'a@example.test', 'role': 'specialist'},
};

class UnavailableSecrets extends MemorySecrets {
  @override
  Future<void> write(String key, String value) async =>
      throw PlatformException(code: 'SyntheticKeystoreFailure');
}

class AbortProbeClient extends http.BaseClient {
  bool aborted = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await (request as http.Abortable).abortTrigger;
    aborted = true;
    throw http.RequestAbortedException();
  }
}

void main() {
  testWidgets(
    'an existing account opens login with retained fields and no automatic login request',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var registrations = 0, logins = 0;
      final auth = AuthState(
        api: ApiClient(
          baseUrl: 'https://example.test',
          client: MockClient((request) async {
            if (request.url.path == '/health') {
              return http.Response('{"status":"ok","database":"ready"}', 200);
            }
            if (request.url.path.endsWith('/register')) registrations++;
            if (request.url.path.endsWith('/login')) logins++;
            return http.Response(
              '{"error":{"code":"ACCOUNT_UNAVAILABLE"}}',
              409,
            );
          }),
        ),
        secrets: MemorySecrets(),
        storeForOwner: (_) async => FakeStore(),
      );
      await tester.pumpWidget(KhotwaApp(auth: auth));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'a@example.test');
      await tester.enterText(find.byType(TextField).at(1), 'SyntheticPass123!');
      await tester.tap(find.text('إنشاء حساب جديد'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('إنشاء الحساب'));
      await tester.pumpAndSettle();
      expect(find.text('تسجيل الدخول'), findsOneWidget);
      expect(find.text('ابدأ الآن'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
        'a@example.test',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        'SyntheticPass123!',
      );
      expect(registrations, 1);
      expect(logins, 0);
      expect(auth.signedIn, isFalse);
    },
  );

  test('a deadline aborts the outstanding native request', () async {
    final client = AbortProbeClient();
    final api = ApiClient(baseUrl: 'https://example.test', client: client);
    await expectLater(
      api.request('GET', '/health', timeout: const Duration(milliseconds: 15)),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'connection_timeout'),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(client.aborted, isTrue);
  });

  test(
    'startup has a finite budget even when the host keeps returning HTML',
    () async {
      var calls = 0;
      final api = ApiClient(
        baseUrl: 'https://example.test',
        client: MockClient((request) async {
          calls++;
          expect(request.method, 'GET');
          return http.Response('<html>Starting</html>', 503);
        }),
      );
      await expectLater(
        api.prepareAuthentication(
          startupTimeout: const Duration(milliseconds: 25),
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'server_starting_timeout',
          ),
        ),
      );
      expect(calls, 1);
    },
  );
  test(
    'incorrect credentials are distinct from an expired private session',
    () async {
      final api = ApiClient(
        baseUrl: 'https://example.test',
        client: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'error': {
                'code': request.url.path.endsWith('/login')
                    ? 'INVALID_CREDENTIALS'
                    : 'UNAUTHORIZED',
                'message': 'sensitive-server-detail',
              },
            }),
            401,
          ),
        ),
      );
      await expectLater(
        api.request('POST', '/v1/auth/login'),
        throwsA(
          isA<ApiException>()
              .having(
                (e) => e.message,
                'message',
                contains('كلمة المرور غير صحيحة'),
              )
              .having(
                (e) => e.message,
                'message',
                isNot(contains('انتهت الجلسة')),
              )
              .having(
                (e) => e.message,
                'message',
                isNot(contains('sensitive-server-detail')),
              ),
        ),
      );
      await expectLater(
        api.request('GET', '/v1/records'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            contains('انتهت الجلسة'),
          ),
        ),
      );
    },
  );

  test(
    'malformed gateway errors preserve HTTP status instead of claiming offline',
    () async {
      for (final body in [
        '{"error":"gateway-detail"}',
        '<html>gateway-detail</html>',
      ]) {
        final api = ApiClient(
          baseUrl: 'https://example.test',
          client: MockClient((_) async => http.Response(body, 503)),
        );
        await expectLater(
          api.request('POST', '/v1/auth/login'),
          throwsA(
            isA<ApiException>()
                .having((e) => e.status, 'status', 503)
                .having((e) => e.code, 'code', isNot('offline'))
                .having(
                  (e) => e.message,
                  'message',
                  isNot(contains('gateway-detail')),
                ),
          ),
        );
      }
    },
  );

  test(
    'uncertain signup times out once and recommends login without retrying POST',
    () async {
      var posts = 0;
      final api = ApiClient(
        baseUrl: 'https://example.test',
        client: MockClient((_) {
          posts++;
          return Completer<http.Response>().future;
        }),
      );
      await expectLater(
        api.request(
          'POST',
          '/v1/auth/register',
          timeout: const Duration(milliseconds: 15),
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'auth_outcome_unknown')
              .having((e) => e.message, 'message', contains('تسجيل الدخول')),
        ),
      );
      expect(posts, 1);
    },
  );

  testWidgets(
    'a 25-second startup finishes before sending credentials exactly once',
    (tester) async {
      final calls = <http.Request>[];
      final api = ApiClient(
        baseUrl: 'https://example.test',
        client: MockClient((request) async {
          calls.add(request);
          if (request.url.path == '/health') {
            await Future<void>.delayed(const Duration(seconds: 25));
            return http.Response('{"status":"ok","database":"ready"}', 200);
          }
          return http.Response(jsonEncode(syntheticSession()), 201);
        }),
      );
      final auth = AuthState(
        api: api,
        secrets: MemorySecrets(),
        storeForOwner: (_) async => FakeStore(),
      );
      final action = auth.authenticate(
        email: 'a@example.test',
        password: 'SyntheticPass123!',
        register: true,
      );
      await tester.pump();
      expect(calls.single.url.path, '/health');
      expect(calls.single.body, isEmpty);
      expect(calls.single.headers, isNot(contains('authorization')));
      await tester.pump(const Duration(seconds: 21));
      expect(calls, hasLength(1));
      expect(auth.signedIn, isFalse);
      await tester.pump(const Duration(seconds: 5));
      await action;
      expect(calls.map((r) => r.url.path), ['/health', '/v1/auth/register']);
      expect(auth.signedIn, isTrue);
    },
  );

  testWidgets('only readiness GET is retried while the gateway is starting', (
    tester,
  ) async {
    var health = 0, posts = 0;
    final api = ApiClient(
      baseUrl: 'https://example.test',
      client: MockClient((request) async {
        if (request.url.path == '/health') {
          health++;
          return health == 1
              ? http.Response('<html>Starting</html>', 503)
              : http.Response('{"status":"ok","database":"ready"}', 200);
        }
        posts++;
        return http.Response(jsonEncode(syntheticSession()), 201);
      }),
    );
    final auth = AuthState(
      api: api,
      secrets: MemorySecrets(),
      storeForOwner: (_) async => FakeStore(),
    );
    final action = auth.authenticate(
      email: 'a@example.test',
      password: 'SyntheticPass123!',
      register: true,
    );
    await tester.pump();
    expect(posts, 0);
    await tester.pump(const Duration(seconds: 3));
    await action;
    expect(health, 2);
    expect(posts, 1);
  });

  test('an unavailable server never receives a signup POST', () async {
    final methods = <String>[];
    final api = ApiClient(
      baseUrl: 'https://example.test',
      client: MockClient((request) async {
        methods.add(request.method);
        throw http.ClientException('synthetic network unavailable');
      }),
    );
    final auth = AuthState(
      api: api,
      secrets: MemorySecrets(),
      storeForOwner: (_) async => FakeStore(),
    );
    await expectLater(
      auth.authenticate(
        email: 'a@example.test',
        password: 'SyntheticPass123!',
        register: true,
      ),
      throwsA(isA<ApiException>()),
    );
    expect(methods, ['GET']);
    expect(auth.busy, isFalse);
    expect(auth.signedIn, isFalse);
  });

  test(
    'storage failure after authentication preserves owner keys and explains the account exists',
    () async {
      final secrets = UnavailableSecrets();
      secrets.values['owner-b-key'] = 'synthetic-existing-key';
      final auth = AuthState(
        api: ApiClient(
          baseUrl: 'https://example.test',
          client: MockClient(
            (request) async => http.Response(
              request.url.path == '/health'
                  ? '{"status":"ok","database":"ready"}'
                  : jsonEncode(syntheticSession()),
              200,
            ),
          ),
        ),
        secrets: secrets,
        storeForOwner: (_) async => FakeStore(),
      );
      await expectLater(
        auth.authenticate(
          email: 'a@example.test',
          password: 'SyntheticPass123!',
          register: true,
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'secure_storage_unavailable',
          ),
        ),
      );
      expect(secrets.values['owner-b-key'], 'synthetic-existing-key');
      expect(auth.signedIn, isFalse);
      expect(auth.busy, isFalse);
    },
  );
}
