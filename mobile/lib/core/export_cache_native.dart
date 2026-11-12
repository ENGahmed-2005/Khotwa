import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'export_cache_contract.dart';

typedef ExportByteWriter = Future<void> Function(File file, Uint8List bytes);

class _ExportScope {
  Future<void> tail = Future.value();
  int generation = 0;
  final owners = <String, int>{};
  Future<T> serial<T>(Future<T> Function() action) {
    final next = tail.then((_) => action());
    tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}

/// The app's disposable share files, never the user's chosen saved location.
/// A root queue orders native I/O; generations revoke old writers immediately.
class ExportFileCache {
  ExportFileCache({
    required this.directory,
    required this.ownerId,
    this.sharedDirectory,
    ExportByteWriter? writer,
  }) : _writer = writer {
    validateExportOwner(ownerId);
    _scope = _scopeFor(directory);
    _rootGeneration = _scope.generation;
    _ownerGeneration = _scope.owners[ownerId] ?? 0;
  }
  final Directory directory;
  // Android's pinned share_plus version copies each native file here. Manage
  // that copy as well; saved copies chosen outside the app are never touched.
  final Directory? sharedDirectory;
  final String ownerId;
  final ExportByteWriter? _writer;
  late final _ExportScope _scope;
  late final int _rootGeneration, _ownerGeneration;
  static final _scopes = <String, _ExportScope>{};
  static String _path(String value) {
    final normalized = File(value).absolute.uri.normalizePath().toFilePath();
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  static _ExportScope _scopeFor(Directory directory) =>
      _scopes.putIfAbsent(_path(directory.path), _ExportScope.new);
  Directory get _ownerDirectory => Directory('${directory.path}/$ownerId');
  static String _ownerTag(String ownerId) => const DartSha256()
      .hashSync(utf8.encode(ownerId))
      .bytes
      .take(16)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  void _checkWritable() {
    if (_rootGeneration != _scope.generation ||
        _ownerGeneration != (_scope.owners[ownerId] ?? 0)) {
      throw StateError('أُلغي ملف التصدير بعد تنظيف بيانات الحساب.');
    }
  }

  static Future<bool> _directory(
    Directory directory, {
    bool create = false,
  }) async {
    var type = await FileSystemEntity.type(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound && create) {
      await directory.create();
      type = await FileSystemEntity.type(directory.path, followLinks: false);
    }
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.directory) {
      throw StateError(
        'مسار ملفات التصدير غير آمن؛ لم يُفتح أو يُحذف محتوى خارجه.',
      );
    }
    if (_path(directory.path) !=
        _path(await directory.resolveSymbolicLinks())) {
      throw StateError('مسار ملفات التصدير يحتوي رابطًا غير موثوق.');
    }
    return true;
  }

  static bool _ownedName(String name) =>
      RegExp(
        r'^share-(?:[a-f0-9]{32}-)?[a-f0-9-]{36}-[A-Za-z0-9][A-Za-z0-9_.-]{0,159}\.(pdf|docx|zip)$',
        caseSensitive: false,
      ).hasMatch(name) &&
      !name.contains('..');

  Future<ExportCacheFile> prepare(Uint8List bytes, String filename) {
    validateExportFilename(filename);
    final snapshot = Uint8List.fromList(bytes);
    return _scope.serial(() async {
      _checkWritable();
      await _directory(directory, create: true);
      await _directory(_ownerDirectory, create: true);
      _checkWritable();
      final file = File(
        '${_ownerDirectory.path}/share-${_ownerTag(ownerId)}-${const Uuid().v4()}-$filename',
      );
      var complete = false;
      try {
        await file.create(exclusive: true);
        _checkWritable();
        if (_writer == null) {
          await file.writeAsBytes(snapshot, flush: true);
        } else {
          await _writer(file, snapshot);
        }
        _checkWritable();
        await _directory(directory);
        await _directory(_ownerDirectory);
        complete = true;
        return ExportCacheFile(
          ownerId: ownerId,
          filename: filename,
          path: file.path,
          remove: () => _scope.serial(() => _remove(file.path)),
        );
      } finally {
        if (!complete) await _remove(file.path);
      }
    });
  }

  Future<void> _remove(String path) async {
    if (_path(File(path).parent.path) != _path(_ownerDirectory.path) ||
        !_ownedName(File(path).uri.pathSegments.last)) {
      throw StateError('ملف التنظيف لا ينتمي إلى ملفات التصدير المؤقتة.');
    }
    Object? failure;
    StackTrace? trace;
    try {
      if (await _directory(directory) && await _directory(_ownerDirectory)) {
        await _removeFile(path);
      }
    } catch (error, stack) {
      failure = error;
      trace = stack;
    }
    try {
      await _clearSharedFiles(
        sharedDirectory,
        ownerId: ownerId,
        filename: File(path).uri.pathSegments.last,
      );
    } catch (error, stack) {
      failure ??= error;
      trace ??= stack;
    }
    if (failure != null) Error.throwWithStackTrace(failure, trace!);
  }

  static Future<void> _removeFile(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      await Link(path).delete();
    } else if (type == FileSystemEntityType.file) {
      await File(path).delete();
    } else if (type != FileSystemEntityType.notFound) {
      throw StateError('مسار ملف التصدير تغيّر؛ احتُفظ بالمحتوى غير المعروف.');
    }
  }

  static Future<void> _clearSharedFiles(
    Directory? directory, {
    String? ownerId,
    String? filename,
  }) async {
    if (directory == null || !await _directory(directory)) return;
    // The fixed owner digest and app prefix distinguish these copies from
    // other owners, legacy plugin files and user-selected saved documents.
    final prefix = ownerId == null ? null : 'share-${_ownerTag(ownerId)}-';
    for (final item in await directory.list(followLinks: false).toList()) {
      final name = item.uri.pathSegments.last;
      if (!_ownedName(name) ||
          !RegExp(r'^share-[a-f0-9]{32}-').hasMatch(name) ||
          (prefix != null && !name.startsWith(prefix)) ||
          (filename != null && name != filename)) {
        continue;
      }
      await _removeFile(item.path);
    }
  }

  Future<void> clear() {
    _scope.owners[ownerId] = (_scope.owners[ownerId] ?? 0) + 1;
    return _scope.serial(() async {
      try {
        await _clearOwner(directory, ownerId);
      } finally {
        await _clearSharedFiles(sharedDirectory, ownerId: ownerId);
      }
    });
  }

  static Future<void> _clearOwner(Directory directory, String ownerId) async {
    validateExportOwner(ownerId);
    if (!await _directory(directory)) return;
    final owner = Directory('${directory.path}/$ownerId');
    final type = await FileSystemEntity.type(owner.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      await Link(owner.path).delete();
      return;
    }
    if (!await _directory(owner)) return;
    for (final entity in await owner.list(followLinks: false).toList()) {
      if (!_ownedName(entity.uri.pathSegments.last)) continue;
      if (entity is File) {
        await entity.delete();
      } else if (entity is Link) {
        await entity.delete();
      }
    }
    if (await owner.list(followLinks: false).isEmpty) await owner.delete();
  }

  static Future<void> clearAll(
    Directory directory, {
    Directory? sharedDirectory,
  }) {
    final scope = _scopeFor(directory);
    scope.generation++;
    return scope.serial(() async {
      try {
        if (await _directory(directory)) {
          for (final entity
              in await directory.list(followLinks: false).toList()) {
            final owner = entity.uri.pathSegments
                .where((part) => part.isNotEmpty)
                .last;
            if (!RegExp(r'^[A-Za-z0-9-]{1,128}$').hasMatch(owner)) continue;
            if (entity is Directory || entity is Link) {
              await _clearOwner(directory, owner);
            }
          }
        }
      } finally {
        await _clearSharedFiles(sharedDirectory);
      }
    });
  }
}

Future<Directory> _cacheDirectory() async {
  final temporary = await getTemporaryDirectory();
  // iOS may expose /var through an OS symlink. Canonicalize the trusted parent,
  // then refuse links inside the app-owned cache itself.
  return Directory(
    '${await temporary.resolveSymbolicLinks()}/khotwa-exports-v1',
  );
}

Future<ExportCacheFile> prepareExportFile({
  required Uint8List bytes,
  required String filename,
  required String ownerId,
}) async {
  final directory = await _cacheDirectory();
  return ExportFileCache(
    directory: directory,
    ownerId: ownerId,
    sharedDirectory: Platform.isAndroid
        ? Directory('${directory.parent.path}/share_plus')
        : null,
  ).prepare(bytes, filename);
}

Future<void> clearExportFiles({String? ownerId}) async {
  final directory = await _cacheDirectory();
  final sharedDirectory = Platform.isAndroid
      ? Directory('${directory.parent.path}/share_plus')
      : null;
  if (ownerId == null) {
    await ExportFileCache.clearAll(directory, sharedDirectory: sharedDirectory);
  } else {
    await ExportFileCache(
      directory: directory,
      ownerId: ownerId,
      sharedDirectory: sharedDirectory,
    ).clear();
  }
}
