import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:khotwa/core/secure_local_store.dart';

class MemorySecrets implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  late Directory directory;
  late MemorySecrets secrets;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('khotwa-test-');
    secrets = MemorySecrets();
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  EncryptedFileStore store(String owner) => EncryptedFileStore(
    directory: directory,
    ownerId: owner,
    secrets: secrets,
  );
  test(
    'AES-GCM roundtrip keeps student/outbox plaintext out of the file',
    () async {
      final first = store('owner-a');
      await first.write(
        '{"student":"ST-1234ABCD","outbox":["synthetic-pending"]}',
      );
      final raw = await first.file.readAsString();
      expect(raw, isNot(contains('ST-1234ABCD')));
      expect(raw, isNot(contains('synthetic-pending')));
      expect(secrets.values.values.single, isNot(contains('ST-1234ABCD')));
      final reopened = store('owner-a');
      expect(await reopened.read(), contains('ST-1234ABCD'));
      await reopened.write('replacement');
      expect(await store('owner-a').read(), 'replacement');
    },
  );
  test('tampered ciphertext fails closed and cannot be overwritten', () async {
    final first = store('owner-a');
    await first.write('synthetic-record');
    final envelope =
        jsonDecode(await first.file.readAsString()) as Map<String, dynamic>;
    final bytes = base64Decode(envelope['ciphertext'] as String);
    bytes[0] ^= 1;
    envelope['ciphertext'] = base64Encode(bytes);
    final corrupt = jsonEncode(envelope);
    await first.file.writeAsString(corrupt);
    final reopened = store('owner-a');
    await expectLater(reopened.read(), throwsStateError);
    await expectLater(reopened.write('overwrite'), throwsStateError);
    expect(await first.file.readAsString(), corrupt);
  });
  test('missing key does not generate new key for an existing file', () async {
    final first = store('owner-a');
    await first.write('record');
    secrets.values.clear();
    final before = await first.file.readAsString();
    final reopened = store('owner-a');
    await expectLater(reopened.read(), throwsStateError);
    await expectLater(reopened.write('replacement'), throwsStateError);
    expect(secrets.values, isEmpty);
    expect(await first.file.readAsString(), before);
  });
  test(
    'separate accounts cannot read each other even if ciphertext is copied',
    () async {
      final a = store('owner-a');
      final b = store('owner-b');
      await a.write('account-a');
      await b.write('account-b');
      expect(await b.read(), 'account-b');
      await a.file.copy(b.file.path);
      await expectLater(store('owner-b').read(), throwsStateError);
      expect(await a.read(), 'account-a');
    },
  );
  test(
    'orphan interrupted pending file never replaces a durable snapshot',
    () async {
      final first = store('owner-a');
      await first.write('durable');
      await File(
        '${first.file.path}.pending',
      ).writeAsString('partial interrupted write');
      expect(await store('owner-a').read(), 'durable');
    },
  );
}
