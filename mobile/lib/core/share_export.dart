import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'api_client.dart';
import 'auth_state.dart';
import 'export_cache.dart';
import 'feature_api.dart';

typedef ExportPreparer =
    Future<ExportCacheFile> Function({
      required Uint8List bytes,
      required String filename,
      required String ownerId,
    });
typedef ExportPresenter = Future<ShareResult> Function(ShareParams params);

class _ShareLifecycle with WidgetsBindingObserver {
  _ShareLifecycle() {
    WidgetsBinding.instance.addObserver(this);
  }
  var _returned = Completer<void>();
  var _leftApplication = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _leftApplication = true;
      if (_returned.isCompleted) _returned = Completer<void>();
    } else if (state == AppLifecycleState.resumed &&
        _leftApplication &&
        !_returned.isCompleted) {
      _returned.complete();
    }
  }

  Future<void> waitForAndroidReturn() async {
    // Android reports a chooser selection before the receiving app has read
    // the FileProvider URI. Keep its managed copy until our app returns.
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        _leftApplication &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      await _returned.future;
    }
  }

  void dispose() => WidgetsBinding.instance.removeObserver(this);
}

Future<void> shareExport(
  BuildContext context,
  ExportDocument document, {
  required AuthState auth,
  ExportPreparer? prepare,
  ExportPresenter? present,
}) async {
  void checkOwner() {
    if (!auth.signedIn ||
        auth.ownerId != document.ownerId ||
        !(auth.records?.active ?? false)) {
      throw const ApiException(
        'unauthenticated',
        'تغيّر الحساب؛ أعيدي فتح التقرير من حسابه قبل تصديره.',
      );
    }
  }

  checkOwner();
  if (!context.mounted) return;
  final box = context.findRenderObject() as RenderBox?;
  final position = box == null
      ? const Rect.fromLTWH(0, 0, 1, 1)
      : box.localToGlobal(Offset.zero) & box.size;
  ExportCacheFile? temporary;
  _ShareLifecycle? lifecycle;
  try {
    temporary = await (prepare ?? prepareExportFile)(
      bytes: document.bytes,
      filename: document.filename,
      ownerId: document.ownerId,
    );
    checkOwner();
    if (temporary.ownerId != document.ownerId ||
        temporary.filename != document.filename) {
      throw const ApiException(
        'invalid_export',
        'ملف التصدير لا يطابق الحساب أو التقرير المطلوب.',
      );
    }
    if (!context.mounted) return;
    lifecycle = _ShareLifecycle();
    await (present ?? SharePlus.instance.share)(
      ShareParams(
        files: [
          temporary.path == null
              ? XFile.fromData(document.bytes, mimeType: document.mimeType)
              : XFile(temporary.path!, mimeType: document.mimeType),
        ],
        fileNameOverrides: [document.filename],
        title: 'حفظ تقرير خطوة',
        sharePositionOrigin: position,
      ),
    );
    await lifecycle.waitForAndroidReturn();
    checkOwner();
  } finally {
    try {
      await temporary?.dispose();
    } finally {
      lifecycle?.dispose();
    }
  }
}
