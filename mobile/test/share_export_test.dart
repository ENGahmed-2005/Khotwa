import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:khotwa/core/api_client.dart';
import 'package:khotwa/core/auth_state.dart';
import 'package:khotwa/core/export_cache.dart';
import 'package:khotwa/core/export_cache_web.dart' as web;
import 'package:khotwa/core/feature_api.dart';
import 'package:khotwa/core/share_export.dart';
import 'package:share_plus/share_plus.dart';

import 'app_state_test.dart' show FakeStore, stateFor;
import 'encrypted_store_test.dart' show MemorySecrets;

AuthState sharingAccount() =>
    AuthState(
        api: ApiClient(baseUrl: 'https://example.test'),
        secrets: MemorySecrets(),
        storeForOwner: (_) async => FakeStore(),
      )
      ..ownerId = 'owner-a'
      ..token = 'synthetic-token'
      ..records = stateFor(FakeStore());
ExportDocument document() => ExportDocument(
  bytes: Uint8List.fromList('%PDF-synthetic-report'.codeUnits),
  filename: 'Khotwa-report.pdf',
  mimeType: 'application/pdf',
  ownerId: 'owner-a',
);

void main() {
  testWidgets(
    'Android keeps a share file readable until returning from the receiving app',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      );
      var cleaned = 0, completed = false;
      final entered = Completer<void>();
      final operation =
          shareExport(
            context,
            document(),
            auth: sharingAccount(),
            prepare:
                ({required bytes, required filename, required ownerId}) async =>
                    ExportCacheFile(
                      ownerId: ownerId,
                      filename: filename,
                      remove: () async {
                        cleaned++;
                      },
                    ),
            present: (_) async {
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.inactive,
              );
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.paused,
              );
              // The chooser can briefly resume before its receiving activity opens.
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.resumed,
              );
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.inactive,
              );
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.paused,
              );
              entered.complete();
              return const ShareResult(
                'synthetic-receiver',
                ShareResultStatus.success,
              );
            },
          ).then((_) {
            completed = true;
          });
      await entered.future;
      await tester.pump();
      expect(completed, false);
      expect(cleaned, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await operation;
      expect(completed, true);
      expect(cleaned, 1);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
  testWidgets(
    'browser share uses bytes in memory and the validated report filename',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      );
      await shareExport(
        context,
        document(),
        auth: sharingAccount(),
        prepare: web.prepareExportFile,
        present: (params) async {
          expect(params.files!.single.path, '');
          expect(await params.files!.single.readAsBytes(), document().bytes);
          expect(params.fileNameOverrides, ['Khotwa-report.pdf']);
          return const ShareResult('', ShareResultStatus.dismissed);
        },
      );
    },
  );
  testWidgets(
    'leaving the report while a file is being prepared disposes it without opening a share sheet',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      );
      final pending = Completer<ExportCacheFile>();
      var cleaned = 0;
      final operation = shareExport(
        context,
        document(),
        auth: sharingAccount(),
        prepare: ({required bytes, required filename, required ownerId}) =>
            pending.future,
        present: (_) async {
          fail('An unmounted report must not open the share sheet');
        },
      );
      await tester.pumpWidget(const SizedBox());
      pending.complete(
        ExportCacheFile(
          ownerId: 'owner-a',
          filename: 'Khotwa-report.pdf',
          remove: () async {
            cleaned++;
          },
        ),
      );
      await operation;
      expect(cleaned, 1);
    },
  );
  testWidgets(
    'a failed native share disposes the real temporary file and preserves saved user copies',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      );
      await tester.runAsync(() async {
        final created = await Directory.systemTemp.createTemp(
          'khotwa-share-test-',
        );
        // The native adapter resolves the trusted OS temp parent before use.
        final temporary = Directory(await created.resolveSymbolicLinks());
        try {
          final saved = File('${temporary.path}/user-saved.pdf');
          await saved.writeAsString('%PDF-synthetic-user-copy');
          final cache = ExportFileCache(
            directory: Directory('${temporary.path}/exports'),
            ownerId: 'owner-a',
          );
          String? sharedPath;
          await expectLater(
            shareExport(
              context,
              document(),
              auth: sharingAccount(),
              prepare:
                  ({required bytes, required filename, required ownerId}) =>
                      cache.prepare(bytes, filename),
              present: (params) async {
                sharedPath = params.files!.single.path;
                expect(await File(sharedPath!).exists(), true);
                expect(
                  await params.files!.single.readAsBytes(),
                  document().bytes,
                );
                throw StateError('synthetic cancelled native share');
              },
            ),
            throwsStateError,
          );
          expect(sharedPath, isNotNull);
          expect(await File(sharedPath!).exists(), false);
          expect(await saved.readAsString(), '%PDF-synthetic-user-copy');
        } finally {
          await temporary.delete(recursive: true);
        }
      });
    },
  );
  testWidgets(
    'account changes before preparation or after sharing cannot expose another owner and still clean up',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      );
      final auth = sharingAccount();
      final pending = Completer<ExportCacheFile>();
      var cleaned = 0, presented = 0;
      final operation = shareExport(
        context,
        document(),
        auth: auth,
        prepare: ({required bytes, required filename, required ownerId}) =>
            pending.future,
        present: (params) async {
          presented++;
          return const ShareResult('', ShareResultStatus.dismissed);
        },
      );
      auth.ownerId = 'owner-b';
      pending.complete(
        ExportCacheFile(
          ownerId: 'owner-a',
          filename: 'Khotwa-report.pdf',
          remove: () async {
            cleaned++;
          },
        ),
      );
      await expectLater(operation, throwsA(isA<ApiException>()));
      expect(presented, 0);
      expect(cleaned, 1);
      auth.ownerId = 'owner-a';
      await expectLater(
        shareExport(
          context,
          document(),
          auth: auth,
          prepare:
              ({required bytes, required filename, required ownerId}) async =>
                  ExportCacheFile(
                    ownerId: ownerId,
                    filename: filename,
                    remove: () async {
                      cleaned++;
                    },
                  ),
          present: (_) async {
            auth.ownerId = 'owner-b';
            return const ShareResult('', ShareResultStatus.dismissed);
          },
        ),
        throwsA(isA<ApiException>()),
      );
      expect(cleaned, 2);
      await expectLater(
        shareExport(
          context,
          document(),
          auth: auth,
          prepare:
              ({required bytes, required filename, required ownerId}) async {
                fail('Preparing old-owner document is forbidden');
              },
        ),
        throwsA(isA<ApiException>()),
      );
    },
  );
}
