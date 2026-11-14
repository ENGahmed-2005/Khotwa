String validateExportOwner(String ownerId) {
  if (!RegExp(r'^[A-Za-z0-9-]{1,128}$').hasMatch(ownerId)) {
    throw StateError('معرّف حساب التصدير غير صالح.');
  }
  return ownerId;
}

String validateExportFilename(String filename) {
  if (!RegExp(
        r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,159}\.(pdf|docx|zip)$',
        caseSensitive: false,
      ).hasMatch(filename) ||
      filename.contains('..')) {
    throw StateError('اسم ملف التصدير غير صالح.');
  }
  return filename;
}

/// A temporary app-owned copy created only by an explicit export action.
/// A saved copy outside this cache belongs to the user and is never removed.
class ExportCacheFile {
  ExportCacheFile({
    required this.ownerId,
    required this.filename,
    this.path,
    required Future<void> Function() remove,
  }) : _remove = remove;
  final String ownerId, filename;
  final String? path;
  final Future<void> Function() _remove;
  bool _removed = false;
  Future<void> dispose() async {
    if (_removed) return;
    await _remove();
    _removed = true;
  }
}
