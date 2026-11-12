import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:khotwa/core/export_cache_native.dart';
import 'package:khotwa/core/export_cache_web.dart' as web;

Future<void> directoryLink(String path, String target) async {
  if (!Platform.isWindows) {
    await Link(path).create(target);
    return;
  }
  String quote(String value) => "'${value.replaceAll("'", "''")}'";
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    'New-Item -ItemType Junction -Path ${quote(path)} -Target ${quote(target)} | Out-Null',
  ]);
  if (result.exitCode != 0) {
    throw StateError('Could not create synthetic test junction');
  }
}

void main() {
  late Directory temporary, directory;
  final bytes = Uint8List.fromList('%PDF-synthetic-export'.codeUnits);
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('khotwa-exports-test-');
    directory = Directory('${temporary.path}/exports');
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });
  ExportFileCache cache(
    String owner, {
    ExportByteWriter? writer,
    Directory? sharedDirectory,
  }) => ExportFileCache(
    directory: directory,
    ownerId: owner,
    writer: writer,
    sharedDirectory: sharedDirectory,
  );

  test(
    'browser exports remain in memory without allocating a local cache path',
    () async {
      final export = await web.prepareExportFile(
        bytes: bytes,
        filename: 'report.pdf',
        ownerId: 'owner-a',
      );
      expect(export.path, isNull);
      expect(export.ownerId, 'owner-a');
      await export.dispose();
      await web.clearExportFiles(ownerId: 'owner-a');
      expect(await directory.exists(), false);
    },
  );
  test(
    'native plugin copies are removed on disposal, account cleanup and startup without touching other owners',
    () async {
      final shared = await Directory('${temporary.path}/share_plus').create();
      final a = await cache(
        'owner-a',
        sharedDirectory: shared,
      ).prepare(bytes, 'report.pdf');
      final b = await cache(
        'owner-b',
        sharedDirectory: shared,
      ).prepare(bytes, 'report.pdf');
      Future<File> copy(String path) =>
          File(path).copy('${shared.path}/${File(path).uri.pathSegments.last}');
      final pluginA = await copy(a.path!), pluginB = await copy(b.path!);
      final saved = File('${shared.path}/user-saved.pdf');
      await saved.writeAsBytes(bytes);
      await a.dispose();
      expect(await pluginA.exists(), false);
      expect(await File(a.path!).exists(), false);
      expect(await pluginB.exists(), true);
      final nextA = await cache(
        'owner-a',
        sharedDirectory: shared,
      ).prepare(bytes, 'another.pdf');
      final nextPluginA = await copy(nextA.path!);
      // Deletion must also remove orphaned plugin copies whose source vanished.
      await Directory('${directory.path}/owner-a').delete(recursive: true);
      await cache('owner-a', sharedDirectory: shared).clear();
      expect(await nextPluginA.exists(), false);
      expect(await pluginB.exists(), true);
      await directory.delete(recursive: true);
      await ExportFileCache.clearAll(directory, sharedDirectory: shared);
      expect(await pluginB.exists(), false);
      expect(await saved.readAsBytes(), bytes);
    },
  );
  test(
    'native copy cleanup refuses a redirected plugin directory and preserves the outside target',
    () async {
      final outside = await Directory(
        '${temporary.path}/outside-plugin',
      ).create();
      final a = await cache('owner-a').prepare(bytes, 'report.pdf');
      final saved = await File(
        a.path!,
      ).copy('${outside.path}/${File(a.path!).uri.pathSegments.last}');
      final shared = Directory('${temporary.path}/share_plus');
      await directoryLink(shared.path, outside.path);
      await expectLater(
        cache('owner-a', sharedDirectory: shared).clear(),
        throwsStateError,
      );
      expect(await saved.readAsBytes(), bytes);
      await Link(shared.path).delete();
    },
  );

  test(
    'real temporary files are owner-bound and individual disposal preserves other owners and user copies',
    () async {
      final a = await cache('owner-a').prepare(bytes, 'Khotwa-report.pdf');
      final b = await cache('owner-b').prepare(bytes, 'Khotwa-report.pdf');
      final userCopy = File('${temporary.path}/user-saved-report.pdf');
      await userCopy.writeAsBytes(bytes);
      expect(await File(a.path!).readAsBytes(), bytes);
      expect(a.path, contains('owner-a'));
      await a.dispose();
      await a.dispose();
      expect(await File(a.path!).exists(), false);
      expect(await File(b.path!).exists(), true);
      await cache('owner-a').clear();
      expect(await File(b.path!).exists(), true);
      expect(await userCopy.readAsBytes(), bytes);
    },
  );
  test(
    'owner and filename traversal and unsupported suffixes are rejected before I/O',
    () {
      for (final owner in [
        '../outside',
        'owner/a',
        'owner\\a',
        '',
        'x' * 129,
      ]) {
        expect(() => cache(owner), throwsStateError);
      }
      for (final name in [
        '../report.pdf',
        'report\\bad.pdf',
        '.hidden.pdf',
        'report.exe',
        'report..pdf',
        'تقرير.pdf',
      ]) {
        expect(() => cache('owner-a').prepare(bytes, name), throwsStateError);
      }
      expect(directory.existsSync(), false);
    },
  );
  test(
    'clearing waits for native writes and revokes every older writer without resurrecting files',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final a = cache(
        'owner-a',
        writer: (file, data) async {
          entered.complete();
          await release.future;
          await file.writeAsBytes(data, flush: true);
        },
      );
      final old = cache('owner-a');
      final writing = a.prepare(bytes, 'report.pdf');
      final rejected = expectLater(writing, throwsStateError);
      await entered.future;
      final clearing = old.clear();
      release.complete();
      await rejected;
      await clearing;
      expect(await Directory('${directory.path}/owner-a').exists(), false);
      await expectLater(old.prepare(bytes, 'old.pdf'), throwsStateError);
      final fresh = await cache('owner-a').prepare(bytes, 'fresh.pdf');
      expect(await File(fresh.path!).exists(), true);
    },
  );
  test(
    'startup cleanup removes only app share files and invalidates pre-startup instances',
    () async {
      final old = cache('owner-a');
      await old.prepare(bytes, 'report.pdf');
      await cache('owner-b').prepare(bytes, 'report.zip');
      final unknown = File('${directory.path}/owner-a/user-saved.pdf');
      await unknown.writeAsBytes(bytes);
      await ExportFileCache.clearAll(directory);
      expect(await unknown.exists(), true);
      expect(await Directory('${directory.path}/owner-b').exists(), false);
      final remaining =
          (await directory.list(recursive: true, followLinks: false).toList())
              .whereType<File>()
              .toList();
      expect(remaining, hasLength(1));
      expect(
        await remaining.single.resolveSymbolicLinks(),
        await unknown.resolveSymbolicLinks(),
      );
      await expectLater(old.prepare(bytes, 'old.pdf'), throwsStateError);
    },
  );
  test(
    'directory links never expose or delete files outside the cache',
    () async {
      await directory.create();
      final outside = await Directory('${temporary.path}/outside').create();
      final saved = File(
        '${outside.path}/share-00000000-0000-4000-8000-000000000000-report.pdf',
      );
      await saved.writeAsBytes(bytes);
      final link = '${directory.path}/owner-a';
      await directoryLink(link, outside.path);
      await expectLater(
        cache('owner-a').prepare(bytes, 'report.pdf'),
        throwsStateError,
      );
      await cache('owner-a').clear();
      expect(
        await FileSystemEntity.type(link, followLinks: false),
        FileSystemEntityType.notFound,
      );
      expect(await saved.readAsBytes(), bytes);
      await directory.delete();
      await directoryLink(directory.path, outside.path);
      await expectLater(ExportFileCache.clearAll(directory), throwsStateError);
      expect(await saved.readAsBytes(), bytes);
      await Link(directory.path).delete();
    },
  );
}
