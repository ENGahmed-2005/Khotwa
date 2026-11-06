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
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? data,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    try {
      final request = http.Request(method, base.resolve(path));
      request.followRedirects = false;
      request.headers['content-type'] = 'application/json';
      if (token != null) {
        request.headers['authorization'] = 'Bearer $token';
      }
      if (data != null) {
        request.body = jsonEncode(data);
      }
      final response = await http.Response.fromStream(
        await _client.send(request).timeout(timeout),
      ).timeout(timeout);
      Map<String, dynamic> body = {};
      if (response.body.isNotEmpty) {
        try {
          body =
              jsonDecode(utf8.decode(response.bodyBytes))
                  as Map<String, dynamic>;
        } catch (_) {
          throw const ApiException(
            'invalid_response',
            'استجابة غير صالحة من الخادم.',
          );
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final error = body['error'] as Map<String, dynamic>?;
        final message = switch (response.statusCode) {
          401 => 'انتهت الجلسة أو بيانات الدخول غير صحيحة. أعد تسجيل الدخول.',
          409 => 'تعارض في البيانات أو الحساب موجود بالفعل.',
          429 => 'طلبات كثيرة. حاول مجددًا بعد قليل.',
          503 => 'الخدمة غير متاحة الآن. احتُفظ بالعمل المحلي.',
          _ => 'تعذّر إتمام الطلب. راجع المدخلات وحاول مجددًا.',
        };
        throw ApiException(
          error?['code'] as String? ?? 'request_failed',
          message,
          response.statusCode,
        );
      }
      return body;
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException(
        'offline',
        'تعذّر الاتصال بالخادم. احتُفظ ببياناتك المحفوظة محليًا.',
      );
    }
  }
}
