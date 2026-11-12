import 'dart:typed_data';
import 'export_cache_contract.dart';

Future<ExportCacheFile> prepareExportFile({
  required Uint8List bytes,
  required String filename,
  required String ownerId,
}) async {
  validateExportOwner(ownerId);
  validateExportFilename(filename);
  return ExportCacheFile(
    ownerId: ownerId,
    filename: filename,
    remove: () async {},
  );
}

Future<void> clearExportFiles({String? ownerId}) async {
  if (ownerId != null) validateExportOwner(ownerId);
}
