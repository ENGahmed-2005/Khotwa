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

const sessionKey = 'khotwa-session-v2',
    markerKey = 'khotwa-deletion-cleanup-v1';

class CleanupStore extends FakeStore {
  bool failClear = false;
  int attempts = 0;
  @override
  Future<void> clear() async {
    attempts++;
    if (failClear) throw StateError('synthetic storage failure');
    await super.clear();
  }
}

class CleanupSecrets extends MemorySecrets {
  bool failSessionDelete = false, failConfirmation = false, failRead = false;
  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('synthetic protected storage unavailable');
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    if (failConfirmation && key == markerKey && value.contains('true')) {
      throw StateError('synthetic confirmation write failure');
    }
    await super.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    if (failSessionDelete && key == sessionKey) {
      throw StateError('synthetic session delete failure');
    }
    await super.delete(key);
  }
}

Map<String, dynamic> session(String id) => {
  'token': 'synthetic-$id',
  'expiresAt': '2099-01-01T00:00:00Z',
  'user': {'id': id, 'email': '$id@example.test', 'role': 'specialist'},
};
ApiClient api() => ApiClient(
  baseUrl: 'https://example.test',
  client: MockClient((request) async {
    if (request.method == 'DELETE') return http.Response('', 204);
    final email = (jsonDecode(request.body) as Map)['email'] as String;
    return http.Response(
      jsonEncode(session(email.split('@').first)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }),
);

void main() {
  for (final response in ['lost', 'invalid', 'server']) {
    test(
      'uncertain deletion ($response) retains a restart guard and every unsynced record',
      () async {
        final secrets = CleanupSecrets(), stores = <String, CleanupStore>{};
        var deleteRequests = 0;
        AuthState auth() => AuthState(
          api: ApiClient(
            baseUrl: 'https://example.test',
            client: MockClient((request) async {
              if (request.method == 'DELETE') {
                deleteRequests++;
                if (response == 'lost') {
                  throw http.ClientException('synthetic lost response');
                }
                return http.Response(
                  response == 'invalid' ? '<invalid>' : '{}',
                  response == 'invalid' ? 200 : 500,
                );
              }
              return http.Response(jsonEncode(session('owner-a')), 200);
            }),
          ),
          secrets: secrets,
          storeForOwner: (id) async => stores.putIfAbsent(id, CleanupStore.new),
        );
        final first = auth();
        await first.authenticate(
          email: 'owner-a@example.test',
          password: 'SyntheticPass123!',
          register: false,
        );
        final originalState = first.records!;
        await originalState.createStudent(
          grade: 'الثاني الأساسي',
          ageYears: 7,
          ageMonths: 0,
          consentConfirmed: true,
        );
        for (final id in ['owner-a-plan-inputs', 'owner-b']) {
          await (await first.storeForOwner(id)).write('synthetic-$id');
        }
        final original = stores['owner-a']!.content;
        await expectLater(
          first.deleteAccount('SyntheticPass123!'),
          throwsA(isA<ApiException>()),
        );
        expect(deleteRequests, 1);
        expect(first.signedIn, false);
        expect(originalState.active, false);
        expect(stores['owner-a']!.content, original);
        expect(stores['owner-a-plan-inputs']!.content, isNotNull);
        expect(stores['owner-b']!.content, 'synthetic-owner-b');
        expect((jsonDecode(secrets.values[markerKey]!) as Map)['owners'], {
          'owner-a': false,
        });
        final restarted = auth();
        await restarted.restore();
        expect(restarted.signedIn, false);
        expect(stores['owner-a']!.content, original);
        expect(stores.values.every((store) => store.attempts == 0), true);
        await restarted.authenticate(
          email: 'owner-a@example.test',
          password: 'SyntheticPass123!',
          register: false,
        );
        expect(restarted.records!.students, hasLength(1));
        expect(restarted.records!.pendingCount, 1);
        expect(secrets.values[markerKey], isNull);
        expect(restarted.cleanupWarning, isNull);
      },
    );
  }
  test(
    'a definitive rejection removes only its pending guard and keeps the session',
    () async {
      final secrets = CleanupSecrets(), stores = <String, CleanupStore>{};
      final auth = AuthState(
        api: ApiClient(
          baseUrl: 'https://example.test',
          client: MockClient(
            (request) async => request.method == 'DELETE'
                ? http.Response('{"error":{"code":"invalid_credentials"}}', 401)
                : http.Response(jsonEncode(session('owner-a')), 200),
          ),
        ),
        secrets: secrets,
        storeForOwner: (id) async => stores.putIfAbsent(id, CleanupStore.new),
      );
      await auth.authenticate(
        email: 'owner-a@example.test',
        password: 'SyntheticPass123!',
        register: false,
      );
      secrets.values[markerKey] = jsonEncode({
        'version': 1,
        'owners': {'owner-b': false},
      });
      await expectLater(
        auth.deleteAccount('wrong-password'),
        throwsA(isA<ApiException>()),
      );
      expect(auth.signedIn, true);
      expect((jsonDecode(secrets.values[markerKey]!) as Map)['owners'], {
        'owner-b': false,
      });
      expect(stores.values.every((store) => store.attempts == 0), true);
    },
  );
  test(
    'confirmed deletion locks memory, attempts every namespace and retries failed cleanup after restart',
    () async {
      final secrets = CleanupSecrets(), stores = <String, CleanupStore>{};
      var failExports = true;
      final exportedOwners = <String>[];
      AuthState auth() => AuthState(
        api: api(),
        secrets: secrets,
        storeForOwner: (id) async => stores.putIfAbsent(id, CleanupStore.new),
        clearExportsForOwner: (id) async {
          exportedOwners.add(id);
          if (failExports) throw StateError('synthetic export cleanup failure');
        },
      );
      final first = auth();
      await first.authenticate(
        email: 'owner-a@example.test',
        password: 'SyntheticPass123!',
        register: false,
      );
      for (final name in [
        'owner-a',
        'owner-a-form-inputs',
        'owner-a-plan-inputs',
        'owner-a-activity-inputs',
        'owner-a-report-inputs',
        'owner-b',
      ]) {
        await (await first.storeForOwner(name)).write('synthetic-$name');
      }
      stores['owner-a']!.failClear = true;
      await expectLater(
        first.deleteAccount('SyntheticPass123!'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'local_cleanup_pending',
          ),
        ),
      );
      expect(first.signedIn, false);
      expect(first.records, isNull);
      expect(first.token, isNull);
      expect(first.cleanupWarning, isNotNull);
      for (final suffix in [
        'form-inputs',
        'plan-inputs',
        'activity-inputs',
        'report-inputs',
      ]) {
        expect(stores['owner-a-$suffix']!.content, isNull);
        expect(stores['owner-a-$suffix']!.attempts, greaterThan(0));
      }
      expect(stores['owner-b']!.content, 'synthetic-owner-b');
      expect((jsonDecode(secrets.values[markerKey]!) as Map)['owners'], {
        'owner-a': true,
      });
      expect(exportedOwners, ['owner-a']);
      stores['owner-a']!.failClear = false;
      failExports = false;
      final restarted = auth();
      await restarted.restore();
      expect(stores['owner-a']!.content, isNull);
      expect(stores['owner-b']!.content, 'synthetic-owner-b');
      expect(secrets.values[markerKey], isNull);
      expect(restarted.signedIn, false);
      expect(exportedOwners, ['owner-a', 'owner-a']);
    },
  );
  test(
    'failed session-secret deletion cannot restore a deleted account',
    () async {
      final secrets = CleanupSecrets(), stores = <String, CleanupStore>{};
      AuthState auth() => AuthState(
        api: api(),
        secrets: secrets,
        storeForOwner: (id) async => stores.putIfAbsent(id, CleanupStore.new),
      );
      final first = auth();
      await first.authenticate(
        email: 'owner-a@example.test',
        password: 'SyntheticPass123!',
        register: false,
      );
      secrets.failSessionDelete = true;
      await expectLater(
        first.deleteAccount('SyntheticPass123!'),
        throwsA(isA<ApiException>()),
      );
      expect(first.signedIn, false);
      final blocked = auth();
      await blocked.restore();
      expect(blocked.signedIn, false);
      expect(blocked.cleanupWarning, isNotNull);
      secrets.failSessionDelete = false;
      final retried = auth();
      await retried.restore();
      expect(retried.signedIn, false);
      expect(secrets.values[sessionKey], isNull);
      expect(secrets.values[markerKey], isNull);
    },
  );
  testWidgets(
    'server-confirmed deletion closes private routes even when local cleanup fails',
    (tester) async {
      final secrets = CleanupSecrets();
      final auth = AuthState(
        api: api(),
        secrets: secrets,
        storeForOwner: (_) async => CleanupStore(),
      );
      await auth.authenticate(
        email: 'owner-a@example.test',
        password: 'SyntheticPass123!',
        register: false,
      );
      await tester.pumpWidget(KhotwaApp(auth: auth));
      await tester.pumpAndSettle();
      tester
          .state<NavigatorState>(find.byType(Navigator).first)
          .push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  const Scaffold(body: Text('تفاصيل اصطناعية خاصة قبل الحذف')),
            ),
          );
      await tester.pumpAndSettle();
      secrets.failSessionDelete = true;
      await expectLater(
        auth.deleteAccount('SyntheticPass123!'),
        throwsA(isA<ApiException>()),
      );
      await tester.pumpAndSettle();
      expect(find.text('تفاصيل اصطناعية خاصة قبل الحذف'), findsNothing);
      expect(find.text('البريد الإلكتروني للمختصة'), findsOneWidget);
      expect(find.text(auth.cleanupWarning!), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'unconfirmed deletion preserves offline work and permits another owner before exact-owner online reconciliation',
    () async {
      final secrets = CleanupSecrets(), stores = <String, CleanupStore>{};
      AuthState auth() => AuthState(
        api: api(),
        secrets: secrets,
        storeForOwner: (id) async => stores.putIfAbsent(id, CleanupStore.new),
      );
      final first = auth();
      await first.authenticate(
        email: 'owner-a@example.test',
        password: 'SyntheticPass123!',
        register: false,
      );
      await first.records!.createStudent(
        grade: 'الثاني الأساسي',
        ageYears: 7,
        ageMonths: 0,
        consentConfirmed: true,
      );
      final original = stores['owner-a']!.content;
      secrets.values[markerKey] = jsonEncode({
        'version': 1,
        'owners': {'owner-a': false},
      });
      final restarted = auth();
      await restarted.restore();
      expect(restarted.signedIn, false);
      expect(stores['owner-a']!.content, original);
      await restarted.authenticate(
        email: 'owner-b@example.test',
        password: 'SyntheticPass123!',
        register: false,
      );
      expect(restarted.ownerId, 'owner-b');
      expect(stores['owner-a']!.content, original);
      expect(secrets.values[markerKey], isNotNull);
      await restarted.lock();
      await restarted.authenticate(
        email: 'owner-a@example.test',
        password: 'SyntheticPass123!',
        register: false,
      );
      expect(restarted.records!.students, hasLength(1));
      expect(restarted.records!.pendingCount, 1);
      expect(secrets.values[markerKey], isNull);
      expect(stores['owner-a']!.attempts, 0);
    },
  );
  test(
    'lost confirmation write leaves a durable unconfirmed guard and never guesses deletion on restart',
    () async {
      final secrets = CleanupSecrets(), stores = <String, CleanupStore>{};
      AuthState auth() => AuthState(
        api: api(),
        secrets: secrets,
        storeForOwner: (id) async => stores.putIfAbsent(id, CleanupStore.new),
      );
      final first = auth();
      await first.authenticate(
        email: 'owner-a@example.test',
        password: 'SyntheticPass123!',
        register: false,
      );
      secrets.failConfirmation = true;
      secrets.failSessionDelete = true;
      await expectLater(
        first.deleteAccount('SyntheticPass123!'),
        throwsA(isA<ApiException>()),
      );
      expect((jsonDecode(secrets.values[markerKey]!) as Map)['owners'], {
        'owner-a': false,
      });
      final count = stores['owner-a']!.attempts;
      final restarted = auth();
      await restarted.restore();
      expect(restarted.signedIn, false);
      expect(stores['owner-a']!.attempts, count);
    },
  );
  test(
    'malformed cleanup owners and unavailable protected storage fail closed without opening or deleting records',
    () async {
      final secrets = CleanupSecrets();
      var opened = 0;
      AuthState auth() => AuthState(
        api: api(),
        secrets: secrets,
        storeForOwner: (_) async {
          opened++;
          return CleanupStore();
        },
      );
      secrets.values[sessionKey] = jsonEncode(session('owner-a'));
      secrets.values[markerKey] = jsonEncode({
        'version': 1,
        'owners': {'../outside': true},
      });
      final invalid = auth();
      await invalid.restore();
      expect(invalid.signedIn, false);
      expect(invalid.error, isNotNull);
      expect(opened, 0);
      secrets.failRead = true;
      final unavailable = auth();
      await unavailable.restore();
      expect(unavailable.signedIn, false);
      expect(unavailable.error, isNotNull);
      expect(opened, 0);
    },
  );
}
