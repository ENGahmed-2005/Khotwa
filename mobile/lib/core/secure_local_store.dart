import 'package:flutter_secure_storage/flutter_secure_storage.dart';

export 'encrypted_file_store.dart'
    if (dart.library.html) 'web_local_store.dart';

abstract class LocalStore {
  Future<String?> read();
  Future<void> write(String data);
  Future<void> clear();
}

abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class DeviceSecretStore implements SecretStore {
  const DeviceSecretStore();
  // A transient Keystore error must not erase keys needed by offline records.
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Browser development preview only; all values disappear on reload.
class PreviewSecretStore implements SecretStore {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}
