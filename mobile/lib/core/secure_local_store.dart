import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Prototype adapter: encrypted key-value storage on each device.
/// NOT a substitute for production encrypted DB, accounts, audit logs or sync.
abstract class LocalStore {
  Future<String?> read();
  Future<void> write(String data);
  Future<void> clear();
}

class SecureLocalStore implements LocalStore {
  SecureLocalStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'khotwa_snapshot_v1';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String data) => _storage.write(key: _key, value: data);

  @override
  Future<void> clear() => _storage.delete(key: _key);
}
