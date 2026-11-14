import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class ApiException implements Exception {
  const ApiException(this.code, this.message, [this.status]);
  final String code, message;
  final int? status;
  @override
  String toString() => message;
}

class ApiClient {
  ApiClient({
    required String baseUrl,
    http.Client? client,
    bool allowDebugHttp = kDebugMode,
  }) : base = Uri.parse(baseUrl),
       _client = client ?? http.Client() {
    final local = const {
      'localhost',
      '127.0.0.1',
      '10.0.2.2',
      '::1',
    }.contains(base.host);
    if (base.scheme != 'https' &&
        !(allowDebugHttp && local && base.scheme == 'http')) {
      throw const ApiException(
        'unsafe_url',
        'عنوان الخادم يجب أن يستخدم HTTPS.',
      );
    }
    if (base.userInfo.isNotEmpty || base.hasQuery || base.hasFragment) {
      throw const ApiException('unsafe_url', 'عنوان خادم غير صالح.');
    }
  }
  final Uri base;
  final http.Client _client;

  /// Wake a sleeping host without sending credentials or repeating a mutation.
  Future<void> prepareAuthentication({
    Duration startupTimeout = const Duration(seconds: 90),
  }) async {
    final elapsed = Stopwatch()..start();
    while (elapsed.elapsed < startupTimeout) {
      try {
        final health = await request(
          'GET',
          '/health',
          timeout: startupTimeout - elapsed.elapsed,
        );
        if (health['status'] == 'ok' && health['database'] == 'ready') return;
      } on ApiException catch (error) {
        final starting =
            error.code == 'invalid_response' ||
            error.code == 'connection_timeout' ||
            const {500, 502, 503, 504}.contains(error.status);
        if (!starting) rethrow;
      }
      final remaining = startupTimeout - elapsed.elapsed;
      if (remaining <= Duration.zero) break;
      await Future<void>.delayed(
        remaining < const Duration(seconds: 2)
            ? remaining
            : const Duration(seconds: 2),
      );
    }
    throw const ApiException(
      'server_starting_timeout',
      'استغرق تجهيز الاتصال وقتًا أطول من المتوقع. لم نرسل بيانات الدخول؛ حاول مجددًا.',
    );
  }

  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? data,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final abort = Completer<void>();
    try {
      return await _send(method, path, token, data, abort.future).timeout(
        timeout,
        onTimeout: () {
          abort.complete();
          if (method == 'POST' && path == '/v1/auth/register') {
            throw const ApiException(
              'auth_outcome_unknown',
              'لم نتمكن من تأكيد إنشاء الحساب. جرّب تسجيل الدخول بنفس البريد وكلمة المرور قبل إعادة إنشاء الحساب.',
            );
          }
          throw const ApiException(
            'connection_timeout',
            'استغرق الاتصال وقتًا أطول من المتوقع. احتُفظ بالعمل المحلي؛ حاول مجددًا.',
          );
        },
      );
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException(
        'offline',
        'تعذّر الاتصال بالخادم. احتُفظ ببياناتك المحفوظة محليًا.',
      );
    }
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path,
    String? token,
    Map<String, dynamic>? data,
    Future<void> abortTrigger,
  ) async {
    final request = http.AbortableRequest(
      method,
      base.resolve(path),
      abortTrigger: abortTrigger,
    );
    request.followRedirects = false;
    request.headers['content-type'] = 'application/json';
    if (token != null) {
      request.headers['authorization'] = 'Bearer $token';
    }
    if (data != null) {
      request.body = jsonEncode(data);
    }
    final response = await http.Response.fromStream(
      await _client.send(request),
    );
    final failed = response.statusCode < 200 || response.statusCode >= 300;
    Map<String, dynamic> body = {};
    if (response.body.isNotEmpty) {
      try {
        body =
            jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      } catch (_) {
        if (!failed) {
          throw ApiException(
            'invalid_response',
            'استجابة غير صالحة من الخادم.',
            response.statusCode,
          );
        }
      }
    }
    if (failed) {
      final error = body['error'];
      final code = error is Map && error['code'] is String
          ? error['code'] as String
          : 'request_failed';
      final message = switch (code) {
        'INVALID_CREDENTIALS' =>
          'البريد الإلكتروني أو كلمة المرور غير صحيحة. راجع الكتابة وجرّب إظهار كلمة المرور.',
        'ACCOUNT_UNAVAILABLE' =>
          'يوجد حساب بهذا البريد. اختر «لدي حساب بالفعل» وسجّل الدخول بنفس كلمة المرور.',
        'AI_PROVIDER_BUSY' =>
          'خدمة التوليد مزدحمة حاليًا. احتُفظ بالمدخلات؛ حاولي لاحقًا.',
        'AI_PROVIDER_LIMITED' =>
          'بلغت خدمة التوليد حد الاستخدام. احتُفظ بالمدخلات؛ حاولي لاحقًا.',
        'AI_PROVIDER_CONFIGURATION' =>
          'خدمة التوليد تحتاج ضبطًا من مسؤول التطبيق. احتُفظ بالمدخلات.',
        'AI_REQUEST_REJECTED' =>
          'تعذّر تنفيذ طلب التوليد. احتُفظ بالمدخلات؛ تواصلي مع مسؤول التطبيق.',
        'STUDENT_INPUTS_INCOMPLETE' =>
          'أكملي الجنس وسبب الإحالة في تعديل ملف الطالب، ثم زامني الملف قبل التوليد.',
        _ => switch (response.statusCode) {
          401 =>
            path == '/v1/auth/login'
                ? 'البريد الإلكتروني أو كلمة المرور غير صحيحة. راجع الكتابة وجرّب إظهار كلمة المرور.'
                : 'انتهت الجلسة. أعد تسجيل الدخول.',
          409 => 'تعارض في البيانات أو الحساب موجود بالفعل.',
          429 => 'طلبات كثيرة. حاول مجددًا بعد قليل.',
          503 => 'الخدمة غير متاحة الآن. احتُفظ بالعمل المحلي.',
          _ => 'تعذّر إتمام الطلب. راجع المدخلات وحاول مجددًا.',
        },
      };
      throw ApiException(code, message, response.statusCode);
    }
    return body;
  }
}
