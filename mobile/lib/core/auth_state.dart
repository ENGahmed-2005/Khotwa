import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
    this.clearExportsForOwner,
    this.clearStaleExports,
  });
  final ApiClient api;
  final SecretStore secrets;
  final OwnerStoreFactory storeForOwner;
  final Future<void> Function(String ownerId)? clearExportsForOwner;
  final Future<void> Function()? clearStaleExports;
  AppState? records;
  String? email, ownerId, token, error;
  String? cleanupWarning;
  bool busy = false;
  String? busyMessage;
  bool get signedIn => token != null && records != null;
  static const _sessionKey = 'khotwa-session-v2';
  static const _deletionKey = 'khotwa-deletion-cleanup-v1';
  static const _cleanupMessage =
      'حُذف الحساب من الخادم وأُغلقت جلسته. تعذّر إكمال تنظيف بعض الملفات المحلية؛ ستُعاد المحاولة عند فتح التطبيق.';
  static const _pendingMessage =
      'لم يُحسم طلب حذف الحساب. أُغلقت جلسته واحتُفظ بالعمل المحلي؛ أعيدي تسجيل الدخول للتحقق من حالته.';

  Future<Map<String, bool>> _deletions() async {
    final raw = await secrets.read(_deletionKey);
    if (raw == null) return {};
    final value = jsonDecode(raw) as Map<String, dynamic>;
    if (value['version'] != 1 || value['owners'] is! Map) {
      throw StateError('سجل تنظيف الحساب غير صالح.');
    }
    final owners = Map<String, dynamic>.from(value['owners'] as Map);
    if (owners.length > 128 ||
        owners.entries.any(
          (entry) =>
              !RegExp(r'^[A-Za-z0-9-]{1,128}$').hasMatch(entry.key) ||
              entry.value is! bool,
        )) {
      throw StateError('سجل تنظيف الحساب غير صالح.');
    }
    return owners.map((key, value) => MapEntry(key, value as bool));
  }

  Future<void> _writeDeletions(Map<String, bool> owners) async {
    if (owners.isEmpty) {
      await secrets.delete(_deletionKey);
    } else {
      await secrets.write(
        _deletionKey,
        jsonEncode({'version': 1, 'owners': owners}),
      );
    }
  }

  String? _sessionOwner(String? raw) {
    if (raw == null) return null;
    return ((jsonDecode(raw) as Map)['user'] as Map)['id'] as String;
  }

  Future<bool> _cleanDeletedOwner(String id, {AppState? liveRecords}) async {
    var complete = true;
    Future<void> attempt(Future<void> Function() action) async {
      try {
        await action();
      } catch (_) {
        complete = false;
      }
    }

    // Revoke the live state's writers first. Even if its first clear fails,
    // every separate namespace below still gets its own cleanup attempt.
    if (liveRecords != null) {
      await attempt(liveRecords.deleteLocalAfterAccountDeletion);
    }
    for (final name in [
      id,
      '$id-form-inputs',
      '$id-plan-inputs',
      '$id-activity-inputs',
      '$id-report-inputs',
    ]) {
      await attempt(() async => (await storeForOwner(name)).clear());
    }
    if (clearExportsForOwner != null) {
      await attempt(() => clearExportsForOwner!(id));
    }
    await attempt(() async {
      if (_sessionOwner(await secrets.read(_sessionKey)) == id) {
        await secrets.delete(_sessionKey);
      }
    });
    return complete;
  }

  Future<Map<String, bool>> _resumeDeletions() async {
    final owners = await _deletions();
    final remaining = {...owners};
    for (final entry in owners.entries) {
      // A prepared request is not evidence of server deletion. Keep all of its
      // unsynced records until an online login resolves that exact owner.
      if (entry.value && await _cleanDeletedOwner(entry.key)) {
        remaining.remove(entry.key);
      }
    }
    if (remaining.length != owners.length) {
      try {
        await _writeDeletions(remaining);
      } catch (_) {
        cleanupWarning = _cleanupMessage;
        return owners;
      }
    }
    if (remaining.values.any((confirmed) => confirmed)) {
      cleanupWarning = _cleanupMessage;
    } else if (cleanupWarning == _cleanupMessage) {
      cleanupWarning = null;
    }
    return remaining;
  }

  void _lockMemory() {
    token = null;
    ownerId = null;
    email = null;
    records?.dispose();
    records = null;
    notifyListeners();
  }

  Future<void> restore() async {
    _lockMemory();
    error = null;
    cleanupWarning = null;
    try {
      try {
        await clearStaleExports?.call();
      } catch (_) {
        cleanupWarning =
            'تعذّر تنظيف بعض ملفات التصدير المؤقتة. أعيدي فتح التطبيق لإعادة المحاولة.';
      }
      final deletions = await _resumeDeletions();
      final value = await secrets.read(_sessionKey);
      if (value != null) {
        final session = jsonDecode(value) as Map<String, dynamic>;
        if (deletions.containsKey(_sessionOwner(value))) {
          error = deletions[_sessionOwner(value)] == true
              ? _cleanupMessage
              : 'يوجد طلب حذف غير محسوم لهذا الحساب. أعيدي تسجيل الدخول للتحقق؛ احتُفظ بالعمل المحلي.';
          notifyListeners();
          return;
        }
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
    busyMessage = 'جارٍ الاتصال… قد يستغرق ذلك نحو دقيقة.';
    error = null;
    notifyListeners();
    try {
      await api.prepareAuthentication();
      busyMessage = register ? 'جارٍ إنشاء حسابك…' : 'جارٍ تسجيل الدخول…';
      notifyListeners();
      final response = await api.request(
        'POST',
        register ? '/v1/auth/register' : '/v1/auth/login',
        data: {'email': email.trim(), 'password': password},
      );
      try {
        final id = (response['user'] as Map)['id'] as String;
        final deletions = await _resumeDeletions();
        if (deletions[id] == true) {
          throw const ApiException('local_cleanup_pending', _cleanupMessage);
        }
        if (deletions.containsKey(id)) {
          // A successful server login resolves an unconfirmed delete request
          // without deleting any of this account's pending offline work.
          deletions.remove(id);
          await _writeDeletions(deletions);
          if (cleanupWarning == _pendingMessage) cleanupWarning = null;
        }
        await secrets.write(_sessionKey, jsonEncode(response));
        await _open(response);
      } on PlatformException {
        throw const ApiException(
          'secure_storage_unavailable',
          'تم التحقق من الحساب، لكن تعذّر حفظ الجلسة بأمان على هذا الجهاز. احتُفظ بالملفات؛ لا تُعِد إنشاء الحساب.',
        );
      }
    } finally {
      busy = false;
      busyMessage = null;
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
    // Keep encrypted unsynced work; it is only reopened for the same owner.
    _lockMemory();
    await secrets.delete(_sessionKey);
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
    if (!signedIn || busy) {
      return;
    }
    final deletingOwner = ownerId!,
        deletingRecords = records!,
        deletingToken = token!;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final previous = await _deletions();
      // Persist a guard before the irreversible request. A restart between the
      // response and its confirmation cannot reopen a possibly deleted owner.
      await _writeDeletions({...previous, deletingOwner: false});
      try {
        await api.request(
          'DELETE',
          '/v1/auth/account',
          token: deletingToken,
          data: {'password': password, 'confirmed': true},
        );
      } catch (failure) {
        final rejected =
            failure is ApiException &&
            failure.status != null &&
            failure.status! >= 400 &&
            failure.status! < 500 &&
            failure.status != 408;
        if (rejected) {
          try {
            await _writeDeletions(previous);
          } catch (_) {
            cleanupWarning = _pendingMessage;
          }
        } else {
          // A timeout, broken response or server error can follow a committed
          // deletion. Keep the durable pending guard without erasing records.
          _lockMemory();
          cleanupWarning = _pendingMessage;
          error = _pendingMessage;
        }
        rethrow;
      }
      _lockMemory();
      final confirmed = {...previous, deletingOwner: true};
      var confirmedSaved = false;
      try {
        await _writeDeletions(confirmed);
        confirmedSaved = true;
      } catch (_) {}
      final cleaned = await _cleanDeletedOwner(
        deletingOwner,
        liveRecords: deletingRecords,
      );
      if (cleaned) {
        try {
          await _writeDeletions(previous);
          return;
        } catch (_) {}
      } else if (!confirmedSaved) {
        try {
          await _writeDeletions(confirmed);
        } catch (_) {}
      }
      cleanupWarning = _cleanupMessage;
      error = _cleanupMessage;
      throw const ApiException('local_cleanup_pending', _cleanupMessage);
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
