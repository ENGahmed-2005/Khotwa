import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'auth_state.dart';
import 'secure_local_store.dart';

class ExportDocument {
  const ExportDocument({
    required this.bytes,
    required this.mimeType,
    required this.filename,
    this.serial,
  });
  final Uint8List bytes;
  final String mimeType, filename;
  final String? serial;
}

/// Requests retain the original owner boundary even if the account changes in flight.
class FeatureApi {
  FeatureApi(this.auth, {http.Client? downloadClient})
    : ownerId = auth.ownerId,
      _downloadClient = downloadClient;
  final AuthState auth;
  final String? ownerId;
  final http.Client? _downloadClient;
  String get _token {
    if (ownerId == null || ownerId != auth.ownerId || auth.token == null) {
      throw const ApiException(
        'unauthenticated',
        'سجّلي الدخول لهذا الحساب مجددًا.',
      );
    }
    return auth.token!;
  }

  Future<Map<String, dynamic>> json(
    String method,
    String path, {
    Map<String, dynamic>? data,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final result = await auth.api.request(
      method,
      path,
      token: _token,
      data: data,
      timeout: timeout,
    );
    _token;
    return result;
  }

  Future<ExportDocument> export(String path, Map<String, dynamic> data) async {
    final client = _downloadClient ?? http.Client();
    try {
      final request = http.Request('POST', auth.api.base.resolve(path));
      request.followRedirects = false;
      request.headers.addAll({
        'authorization': 'Bearer $_token',
        'content-type': 'application/json',
      });
      request.body = jsonEncode(data);
      final response = await http.Response.fromStream(
        await client.send(request).timeout(const Duration(seconds: 90)),
      ).timeout(const Duration(seconds: 90));
      _token;
      if (response.statusCode != 200) {
        throw ApiException(
          'export_failed',
          response.statusCode == 401
              ? 'انتهت الجلسة. سجّلي الدخول مجددًا.'
              : 'تعذّر التصدير. تحققي من اعتماد الخطة والاتصال بالخادم.',
          response.statusCode,
        );
      }
      final mime = (response.headers['content-type'] ?? '').split(';').first;
      const extensions = {
        'application/pdf': 'pdf',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
            'docx',
        'application/zip': 'zip',
      };
      if (!extensions.containsKey(mime) ||
          response.bodyBytes.length > 30 * 1024 * 1024 ||
          response.bodyBytes.length < 4) {
        throw const ApiException(
          'invalid_export',
          'صيغة الملف غير صالحة. لم يُفتح أي ملف.',
        );
      }
      final signature = ascii.decode(
        response.bodyBytes.take(4).toList(),
        allowInvalid: true,
      );
      if ((mime == 'application/pdf' && signature != '%PDF') ||
          (mime != 'application/pdf' && !signature.startsWith('PK'))) {
        throw const ApiException(
          'invalid_export',
          'الاستجابة ليست ملف التقرير المطلوب.',
        );
      }
      final disposition = response.headers['content-disposition'] ?? '';
      final name = RegExp(
        r'filename="?([A-Za-z0-9_.-]{1,180})"?',
      ).firstMatch(disposition)?.group(1);
      return ExportDocument(
        bytes: response.bodyBytes,
        mimeType: mime,
        filename: name ?? 'Khotwa-report.${extensions[mime]}',
        serial:
            response.headers['x-khotwa-report-serial'] ??
            response.headers['x-report-serial'],
      );
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException(
        'timeout',
        'استغرق التصدير وقتًا طويلًا. احتُفظ بالاختيارات ويمكن إعادة المحاولة.',
      );
    } catch (_) {
      throw const ApiException(
        'offline',
        'تعذّر الاتصال بالخادم. احتُفظ بالاختيارات محليًا.',
      );
    } finally {
      if (_downloadClient == null) client.close();
    }
  }
}

/// The native store encrypts drafts, preview tokens and cached output at rest.
/// Confirmation to send is deliberately never persisted by this class's callers.
class FeatureDraftStore {
  FeatureDraftStore(this.auth, this.suffix, {LocalStore? store})
    : ownerId = auth.ownerId,
      _override = store;
  final AuthState auth;
  final String suffix;
  final String? ownerId;
  final LocalStore? _override;
  Future<LocalStore>? _opened;
  Future<void> _writes = Future.value();
  void _checkOwner() {
    if (ownerId == null || auth.ownerId != ownerId) {
      throw StateError('حساب المسودة غير مطابق.');
    }
    if (suffix != 'activity-inputs' && suffix != 'report-inputs') {
      throw StateError('مساحة التخزين غير صالحة.');
    }
  }

  Future<LocalStore> _store() {
    _checkOwner();
    return _opened ??= _override != null
        ? Future.value(_override)
        : auth.storeForOwner('$ownerId-$suffix');
  }

  Future<Map<String, dynamic>> read() async {
    final raw = await (await _store()).read();
    _checkOwner();
    if (raw == null) return {};
    final value = jsonDecode(raw) as Map<String, dynamic>;
    if (value['version'] != 1 || value['ownerId'] != ownerId) {
      throw StateError('المسودة المحلية غير مطابقة للحساب.');
    }
    return Map<String, dynamic>.from(value['data'] as Map);
  }

  Future<void> write(Map<String, dynamic> data) {
    _checkOwner();
    final serialized = jsonEncode({
      'version': 1,
      'ownerId': ownerId,
      'data': data,
    });
    final next = _writes.then((_) async {
      final store = await _store();
      _checkOwner();
      await store.write(serialized);
    });
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}
