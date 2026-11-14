import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:khotwa/core/secure_local_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const store = DeviceSecretStore();
  late List<MethodCall> calls;
  late Map<String, String> values;
  var failReads = false;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls = [];
    values = {};
    failReads = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          final args = Map<String, dynamic>.from(call.arguments as Map);
          final key = args['key'] as String;
          switch (call.method) {
            case 'read':
              if (failReads) {
                throw PlatformException(
                  code: 'KeystoreUnavailable',
                  message: 'Synthetic native Keystore failure',
                );
              }
              return values[key];
            case 'write':
              values[key] = args['value'] as String;
              return null;
            case 'delete':
              values.remove(key);
              return null;
            default:
              throw StateError('Unexpected secret-store operation');
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'Android operations forbid automatic resets and retain strong ciphers',
    () async {
      await store.write('owner-a-key', 'synthetic-key');
      expect(await store.read('owner-a-key'), 'synthetic-key');
      await store.delete('owner-a-key');
      expect(calls.map((call) => call.method), ['write', 'read', 'delete']);
      for (final call in calls) {
        final options = (call.arguments as Map)['options'] as Map;
        expect(options['resetOnError'], 'false');
        expect(
          options['keyCipherAlgorithm'],
          'RSA_ECB_OAEPwithSHA_256andMGF1Padding',
        );
        expect(options['storageCipherAlgorithm'], 'AES_GCM_NoPadding');
      }
    },
  );

  test(
    'Keystore errors propagate without replacing or clearing owner keys',
    () async {
      values.addAll({
        'owner-a-key': 'synthetic-a',
        'owner-b-key': 'synthetic-b',
      });
      failReads = true;
      await expectLater(
        store.read('owner-a-key'),
        throwsA(isA<PlatformException>()),
      );
      expect(calls.map((call) => call.method), ['read']);
      expect(
        ((calls.single.arguments as Map)['options'] as Map)['resetOnError'],
        'false',
      );
      failReads = false;
      expect(await store.read('owner-a-key'), 'synthetic-a');
      expect(await store.read('owner-b-key'), 'synthetic-b');
      expect(
        calls.any(
          (call) => call.method == 'deleteAll' || call.method == 'write',
        ),
        isFalse,
      );
    },
  );
}
