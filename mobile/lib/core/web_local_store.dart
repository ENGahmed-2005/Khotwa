import 'package:flutter/foundation.dart';
import 'secure_local_store.dart';

/// Browser preview deliberately has no disk persistence. It exercises the real
/// API and UI, but is never evidence of native encryption/offline support.
class EncryptedFileStore implements LocalStore {
  EncryptedFileStore._(this.ownerId);
  final String ownerId;
  static final _stores = <String, EncryptedFileStore>{};
  String? _value;
  static Future<EncryptedFileStore> forOwner(String ownerId, SecretStore secrets) async {
    if (kReleaseMode && !const bool.fromEnvironment('ALLOW_SYNTHETIC_WEB_PREVIEW')) {
      throw StateError('نسخة المتصفح التجريبية غير مفعّلة.');
    }
    return _stores.putIfAbsent(ownerId, () => EncryptedFileStore._(ownerId));
  }
  @override
  Future<String?> read() async => _value;
  @override
  Future<void> write(String data) async { _value = data; }
  @override
  Future<void> clear() async { _value = null; }
}
