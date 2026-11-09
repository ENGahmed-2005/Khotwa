import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'api_client.dart';
import 'app_state.dart';
import 'secure_local_store.dart';

typedef OwnerStoreFactory = Future<LocalStore> Function(String ownerId);

class AuthState extends ChangeNotifier {
  AuthState({
    required this.api,
    required this.secrets,
    required this.storeForOwner,
  });
  final ApiClient api;
  final SecretStore secrets;
  final OwnerStoreFactory storeForOwner;
  AppState? records;
  String? email, ownerId, token, error;
  bool busy = false;
  bool get signedIn => token != null && records != null;
  static const _sessionKey = 'khotwa-session-v2';

  Future<void> restore() async {
    try {
      final value = await secrets.read(_sessionKey);
      if (value != null) {
        final session = jsonDecode(value) as Map<String, dynamic>;
        if (DateTime.parse(
          session['expiresAt'] as String,
        ).isAfter(DateTime.now())) {
          await _open(session);
        } else {
          await secrets.delete(_sessionKey);
        }
      }
    } catch (_) {
      error = 'تعذّر استعادة الجلسة بأمان. أعد تسجيل الدخول.';
    }
    notifyListeners();
  }

  Future<void> _open(Map<String, dynamic> session) async {
    final user = session['user'] as Map<String, dynamic>;
    final id = user['id'] as String;
    await AppState.flushDraftsForOwner(id);
    var deviceId = await secrets.read('khotwa-device-v1');
    if (deviceId == null) {
      deviceId = const Uuid().v4();
      await secrets.write('khotwa-device-v1', deviceId);
    }
    final next = AppState(
      await storeForOwner(id),
      ownerId: id,
      deviceId: deviceId,
      draftStore: await storeForOwner('$id-form-inputs'),
    );
    await next.load();
    records?.dispose();
    records = next;
    ownerId = id;
    email = user['email'] as String;
    token = session['token'] as String;
  }

  Future<void> authenticate({
    required String email,
    required String password,
    required bool register,
  }) async {
    if (busy) {
      return;
    }
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email.trim()) ||
        password.length < 12 ||
        password.length > 128) {
      throw const ApiException(
        'validation',
        'أدخل بريدًا صحيحًا وكلمة مرور من 12 إلى 128 حرفًا.',
      );
    }
    busy = true;
    error = null;
    notifyListeners();
    try {
      final response = await api.request(
        'POST',
        register ? '/v1/auth/register' : '/v1/auth/login',
        data: {'email': email.trim(), 'password': password},
      );
      await secrets.write(_sessionKey, jsonEncode(response));
      await _open(response);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    if (token == null) {
      return;
    }
    // Server revocation must succeed. An offline button is labelled lock instead.
    await api.request('POST', '/v1/auth/logout', token: token);
    await lock();
  }

  Future<void> lock() async {
    await secrets.delete(_sessionKey);
    token = null;
    ownerId = null;
    email = null;
    // Keep encrypted unsynced work; it is only reopened for the same owner.
    records?.dispose();
    records = null;
    notifyListeners();
  }

  Future<void> sync() async {
    if (signedIn) {
      await records!.sync(api, token!);
    }
  }

  Future<void> requestReset(String email) async {
    await api.request(
      'POST',
      '/v1/auth/password-reset/request',
      data: {'email': email.trim()},
    );
  }

  Future<void> confirmReset(String resetToken, String password) async {
    await api.request(
      'POST',
      '/v1/auth/password-reset/confirm',
      data: {'token': resetToken.trim(), 'password': password},
    );
  }

  Future<void> deleteAccount(String password) async {
    if (!signedIn) {
      return;
    }
    await api.request(
      'DELETE',
      '/v1/auth/account',
      token: token,
      data: {'password': password, 'confirmed': true},
    );
    await records!.deleteLocalAfterAccountDeletion();
    for (final suffix in ['plan-inputs', 'activity-inputs', 'report-inputs']) {
      final inputs = await storeForOwner('$ownerId-$suffix');
      await inputs.clear();
    }
    await lock();
  }
}
