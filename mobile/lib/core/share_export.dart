import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'feature_api.dart';

Future<void> shareExport(BuildContext context, ExportDocument document) async {
  final box = context.findRenderObject() as RenderBox?;
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile.fromData(document.bytes, mimeType: document.mimeType)],
      fileNameOverrides: [document.filename],
      title: 'حفظ تقرير خطوة',
      sharePositionOrigin: box == null
          ? const Rect.fromLTWH(0, 0, 1, 1)
          : box.localToGlobal(Offset.zero) & box.size,
    ),
  );
}
