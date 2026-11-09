import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:khotwa/core/api_client.dart';
import 'package:khotwa/core/auth_state.dart';
import 'package:khotwa/core/feature_api.dart';
import 'package:khotwa/core/secure_local_store.dart';

class FeatureMemoryStore implements LocalStore {
  String? value;
  bool fail = false;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String data) async {
    if (fail) throw StateError('synthetic disk failure');
    value = data;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

AuthState account({http.Client? apiClient}) =>
    AuthState(
        api: ApiClient(
          baseUrl: 'https://synthetic.example.test',
          client: apiClient,
        ),
        secrets: PreviewSecretStore(),
        storeForOwner: (_) async => FeatureMemoryStore(),
      )
      ..ownerId = 'synthetic-owner-a'
      ..token = 'synthetic-session';

void main() {
  test(
    'binary export authorizes only the captured owner and checks PDF response',
    () async {
      final auth = account();
      final client = MockClient((request) async {
        expect(request.followRedirects, isFalse);
        expect(request.headers['authorization'], 'Bearer synthetic-session');
        expect(jsonDecode(request.body), {'format': 'pdf'});
        return http.Response(
          '%PDF-1.4\nSynthetic transport fixture',
          200,
          headers: {
            'content-type': 'application/pdf',
            'content-disposition': 'attachment; filename="KH-RPT-test.pdf"',
            'x-khotwa-report-serial': 'KH-RPT-test',
          },
        );
      });
      final document = await FeatureApi(
        auth,
        downloadClient: client,
      ).export('/v1/reports/export', {'format': 'pdf'});
      expect(document.filename, 'KH-RPT-test.pdf');
      expect(document.serial, 'KH-RPT-test');
    },
  );
  test(
    'redirects, HTML and wrong magic never become exported documents',
    () async {
      for (final response in [
        http.Response(
          'redirect',
          302,
          headers: {'location': 'https://other.example.test'},
        ),
        http.Response(
          '<html>login</html>',
          200,
          headers: {'content-type': 'text/html'},
        ),
        http.Response(
          'INVALID PDF',
          200,
          headers: {'content-type': 'application/pdf'},
        ),
      ]) {
        await expectLater(
          FeatureApi(
            account(),
            downloadClient: MockClient((_) async => response),
          ).export('/v1/reports/export', {}),
          throwsA(isA<ApiException>()),
        );
      }
    },
  );
  test(
    'a response from the previous account is discarded after account switching',
    () async {
      final auth = account();
      final pending = Completer<http.Response>();
      final api = FeatureApi(
        auth,
        downloadClient: MockClient((_) => pending.future),
      );
      final future = api.export('/v1/reports/export', {});
      auth.ownerId = 'synthetic-owner-b';
      pending.complete(
        http.Response(
          '%PDF-fixture',
          200,
          headers: {'content-type': 'application/pdf'},
        ),
      );
      await expectLater(
        future,
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'unauthenticated',
          ),
        ),
      );
    },
  );
  test('JSON responses have the same account-switch boundary', () async {
    final pending = Completer<http.Response>();
    final auth = account(apiClient: MockClient((_) => pending.future));
    final future = FeatureApi(auth).json('GET', '/v1/reports/settings');
    auth.ownerId = 'synthetic-owner-b';
    pending.complete(
      http.Response(
        '{"settings":{}}',
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    );
    await expectLater(future, throwsA(isA<ApiException>()));
  });
  test(
    'an unauthorized export never exposes server body to the user',
    () async {
      final api = FeatureApi(
        account(),
        downloadClient: MockClient(
          (_) async => http.Response('SYNTHETIC_PRIVATE_SERVER_DETAIL', 401),
        ),
      );
      await expectLater(
        api.export('/v1/reports/export', {}),
        throwsA(
          isA<ApiException>().having(
            (error) => error.message,
            'message',
            isNot(contains('PRIVATE')),
          ),
        ),
      );
    },
  );
  test(
    'separate report and activity namespaces preserve owner boundaries',
    () async {
      final auth = account();
      final backing = FeatureMemoryStore();
      final drafts = FeatureDraftStore(auth, 'activity-inputs', store: backing);
      await drafts.write({
        'operationId': 'synthetic-operation',
        'tools': ['cards'],
      });
      expect(await drafts.read(), {
        'operationId': 'synthetic-operation',
        'tools': ['cards'],
      });
      auth.ownerId = 'synthetic-owner-b';
      await expectLater(drafts.read(), throwsStateError);
      expect(backing.value, contains('synthetic-owner-a'));
    },
  );
  test(
    'failed write preserves old durable draft and does not poison later retries',
    () async {
      final store = FeatureMemoryStore();
      final drafts = FeatureDraftStore(
        account(),
        'report-inputs',
        store: store,
      );
      await drafts.write({'period': 'saved'});
      final before = store.value;
      store.fail = true;
      await expectLater(drafts.write({'period': 'unsaved'}), throwsStateError);
      expect(store.value, before);
      store.fail = false;
      await drafts.write({'period': 'retry'});
      expect(await drafts.read(), {'period': 'retry'});
    },
  );
  test('corrupt or wrong-owner cache fails closed without overwrite', () async {
    final store = FeatureMemoryStore()
      ..value = jsonEncode({'version': 1, 'ownerId': 'other', 'data': {}});
    final before = store.value;
    await expectLater(
      FeatureDraftStore(account(), 'report-inputs', store: store).read(),
      throwsStateError,
    );
    expect(store.value, before);
  });
}
