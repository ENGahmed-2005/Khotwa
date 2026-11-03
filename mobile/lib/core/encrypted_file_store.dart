import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import 'secure_local_store.dart';

/// Records and outbox commit together in an authenticated encrypted snapshot.
/// The key is stored only in the platform secure store, never beside the file.
class EncryptedFileStore implements LocalStore {
  EncryptedFileStore({required this.directory, required this.ownerId, required this.secrets});
  final Directory directory;
  final String ownerId;
  final SecretStore secrets;
  final _cipher = AesGcm.with256bits();
  bool _failedClosed = false;
  static Future<EncryptedFileStore> forOwner(String ownerId, SecretStore secrets) async =>
      EncryptedFileStore(directory: Directory('${(await getApplicationSupportDirectory()).path}/khotwa-v2'), ownerId: ownerId, secrets: secrets);
  File get file {
    if (!RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(ownerId)) throw StateError('معرّف حساب غير صالح.');
    return File('${directory.path}/$ownerId.enc');
  }
  Future<SecretKey> _key({required bool existing}) async {
    final encoded = await secrets.read('khotwa-key-v2-$ownerId');
    if (encoded != null) return SecretKey(base64Decode(encoded));
    if (existing) throw StateError('مفتاح البيانات المحلية غير متاح.');
    final key = await _cipher.newSecretKey();
    await secrets.write('khotwa-key-v2-$ownerId', base64Encode(await key.extractBytes()));
    return key;
  }
  @override
  Future<String?> read() async {
    try {
      if (!await file.exists()) return null;
      final envelope = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (envelope['version'] != 2 || envelope['owner'] != ownerId) throw StateError('صيغة تخزين أو حساب غير مطابق.');
      final box = SecretBox(base64Decode(envelope['ciphertext'] as String), nonce: base64Decode(envelope['nonce'] as String), mac: Mac(base64Decode(envelope['mac'] as String)));
      return utf8.decode(await _cipher.decrypt(box, secretKey: await _key(existing: true), aad: utf8.encode('khotwa-v2:$ownerId')));
    } catch (_) {
      _failedClosed = true;
      throw StateError('تعذّر التحقق من سلامة التخزين المشفّر. احتُفظ بالملف دون تغيير.');
    }
  }
  @override
  Future<void> write(String data) async {
    if (_failedClosed) throw StateError('التخزين مقفل لحماية البيانات المتعذّر قراءتها.');
    await directory.create(recursive: true);
    final box = await _cipher.encrypt(utf8.encode(data), secretKey: await _key(existing: await file.exists()), aad: utf8.encode('khotwa-v2:$ownerId'));
    final pending = File('${file.path}.pending');
    await pending.writeAsString(jsonEncode({'version': 2, 'owner': ownerId, 'nonce': base64Encode(box.nonce), 'mac': base64Encode(box.mac.bytes), 'ciphertext': base64Encode(box.cipherText)}), flush: true);
    // Rename is the commit point; interrupted writes retain the prior snapshot.
    await pending.rename(file.path);
  }
  @override
  Future<void> clear() async {
    if (await file.exists()) await file.delete();
    final pending = File('${file.path}.pending');
    if (await pending.exists()) await pending.delete();
    await secrets.delete('khotwa-key-v2-$ownerId');
  }
}

