import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:khotwa/core/sync_retry_coordinator.dart';

class _SyncHarness {
  String? currentOwner = 'synthetic-owner-a';
  bool pending = false, error = false, manualBusy = false, offline = false;
  int calls = 0;
  Future<void> Function()? onSync;
  late final coordinator = SyncRetryCoordinator(
    ownerId: 'synthetic-owner-a',
    currentOwnerId: () => currentOwner,
    isSyncing: () => manualBusy,
    hasPendingWork: () => pending,
    hasSyncError: () => error,
    sync: () async {
      calls++;
      if (onSync != null) {
        await onSync!();
      } else if (offline) {
        error = true;
      } else {
        pending = false;
        error = false;
      }
    },
  );
}

void main() {
  testWidgets('startup pulls once, then healthy idle has no network attempts', (
    tester,
  ) async {
    final h = _SyncHarness();
    h.coordinator.resume();
    await tester.pump();
    expect(h.calls, 1);
    h.coordinator.stateChanged();
    await tester.pump(const Duration(hours: 1));
    expect(h.calls, 1);
    h.coordinator.dispose();
  });

  testWidgets('new local work is scheduled without another lifecycle event', (
    tester,
  ) async {
    final h = _SyncHarness();
    h.coordinator.resume();
    await tester.pump();
    h.pending = true;
    h.coordinator.stateChanged();
    await tester.pump(const Duration(seconds: 29));
    expect(h.calls, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(h.calls, 2);
    expect(h.pending, isFalse);
    h.coordinator.dispose();
  });

  testWidgets('offline work retries and recovers while still foreground', (
    tester,
  ) async {
    final h = _SyncHarness()
      ..pending = true
      ..offline = true;
    h.coordinator.resume();
    await tester.pump();
    expect(h.calls, 1);
    expect(h.pending, isTrue);
    await tester.pump(const Duration(seconds: 30));
    expect(h.calls, 2);
    h.offline = false;
    await tester.pump(const Duration(seconds: 59));
    expect(h.calls, 2);
    await tester.pump(const Duration(seconds: 1));
    expect(h.calls, 3);
    expect(h.pending, isFalse);
    expect(h.error, isFalse);
    await tester.pump(const Duration(minutes: 10));
    expect(h.calls, 3);
    h.coordinator.dispose();
  });

  testWidgets('consecutive failures back off up to five minutes', (
    tester,
  ) async {
    final h = _SyncHarness()..offline = true;
    h.coordinator.resume();
    await tester.pump();
    var expectedCalls = 1;
    for (final seconds in [30, 60, 120, 240, 300, 300]) {
      await tester.pump(Duration(milliseconds: seconds * 1000 - 1));
      expect(h.calls, expectedCalls);
      await tester.pump(const Duration(milliseconds: 1));
      expectedCalls++;
      expect(h.calls, expectedCalls);
    }
    h.coordinator.dispose();
  });

  testWidgets('successful recovery resets backoff for newly pending work', (
    tester,
  ) async {
    final h = _SyncHarness()..offline = true;
    h.coordinator.resume();
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    h.offline = false;
    await tester.pump(const Duration(seconds: 60));
    expect(h.calls, 3);
    h.pending = true;
    h.coordinator.stateChanged();
    await tester.pump(const Duration(seconds: 30));
    expect(h.calls, 4);
    h.coordinator.dispose();
  });

  testWidgets('background pauses retries and resume immediately syncs', (
    tester,
  ) async {
    final h = _SyncHarness()..offline = true;
    h.coordinator.resume();
    await tester.pump();
    h.coordinator.pause();
    h.coordinator.stateChanged();
    await tester.pump(const Duration(minutes: 10));
    expect(h.calls, 1);
    h.coordinator.resume();
    await tester.pump();
    expect(h.calls, 2);
    h.coordinator.dispose();
  });

  testWidgets('resume also pulls an account with no pending local work', (
    tester,
  ) async {
    final h = _SyncHarness();
    h.coordinator.resume();
    await tester.pump();
    h.coordinator.pause();
    h.coordinator.resume();
    await tester.pump();
    expect(h.calls, 2);
    h.coordinator.dispose();
  });

  testWidgets('lock cancels pending retry and rejects explicit sync', (
    tester,
  ) async {
    final h = _SyncHarness()..offline = true;
    h.coordinator.resume();
    await tester.pump();
    h.currentOwner = null;
    h.coordinator.stateChanged();
    await h.coordinator.syncNow();
    h.coordinator.resume();
    await tester.pump(const Duration(minutes: 10));
    expect(h.calls, 1);
    h.coordinator.dispose();
  });

  testWidgets('timer rechecks owner even without a state notification', (
    tester,
  ) async {
    final h = _SyncHarness()..pending = true;
    h.coordinator.resume();
    await tester.pump();
    h.pending = true;
    h.coordinator.stateChanged();
    h.currentOwner = 'synthetic-owner-b';
    await tester.pump(const Duration(seconds: 30));
    await h.coordinator.syncNow();
    expect(h.calls, 1);
    h.coordinator.dispose();
  });

  testWidgets('external manual sync prevents an overlapping request', (
    tester,
  ) async {
    final h = _SyncHarness()
      ..pending = true
      ..manualBusy = true;
    h.coordinator.resume();
    await tester.pump(const Duration(seconds: 30));
    expect(h.calls, 0);
    h.manualBusy = false;
    h.coordinator.stateChanged();
    await tester.pump(const Duration(seconds: 30));
    expect(h.calls, 1);
    h.coordinator.dispose();
  });

  testWidgets('repeated manual requests and resume cannot overlap a retry', (
    tester,
  ) async {
    final h = _SyncHarness();
    final completion = Completer<void>();
    h.onSync = () => completion.future;
    h.coordinator.resume();
    await tester.pump();
    await h.coordinator.syncNow();
    h.coordinator.resume();
    h.coordinator.stateChanged();
    await tester.pump(const Duration(minutes: 10));
    expect(h.calls, 1);
    completion.complete();
    await tester.pump();
    await tester.pump(const Duration(minutes: 10));
    expect(h.calls, 1);
    h.coordinator.dispose();
  });

  testWidgets('successful external manual sync cancels an obsolete retry', (
    tester,
  ) async {
    final h = _SyncHarness()..offline = true;
    h.coordinator.resume();
    await tester.pump();
    h.manualBusy = true;
    h.error = false;
    h.coordinator.stateChanged();
    h.manualBusy = false;
    h.coordinator.stateChanged();
    await tester.pump(const Duration(minutes: 10));
    expect(h.calls, 1);
    h.coordinator.dispose();
  });

  testWidgets('disposing during an in-flight failure cannot schedule again', (
    tester,
  ) async {
    final h = _SyncHarness();
    final completion = Completer<void>();
    h.onSync = () => completion.future;
    h.coordinator.resume();
    await tester.pump();
    h.coordinator.dispose();
    completion.completeError(StateError('synthetic transport failure'));
    await tester.pump();
    h.coordinator.resume();
    h.coordinator.stateChanged();
    await h.coordinator.syncNow();
    await tester.pump(const Duration(hours: 1));
    expect(h.calls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unexpected async failures are consumed and retried safely', (
    tester,
  ) async {
    final h = _SyncHarness();
    h.onSync = () async => throw StateError('synthetic transport failure');
    h.coordinator.resume();
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    expect(h.calls, 2);
    h.onSync = null;
    await tester.pump(const Duration(seconds: 60));
    expect(h.calls, 3);
    expect(tester.takeException(), isNull);
    h.coordinator.dispose();
  });

  testWidgets(
    'owner change during an in-flight failure prevents further sync',
    (tester) async {
      final h = _SyncHarness()..pending = true;
      final completion = Completer<void>();
      h.onSync = () => completion.future;
      h.coordinator.resume();
      await tester.pump();
      h.currentOwner = 'synthetic-owner-b';
      h.coordinator.stateChanged();
      completion.completeError(StateError('synthetic transport failure'));
      await tester.pump();
      await tester.pump(const Duration(hours: 1));
      expect(h.calls, 1);
      expect(tester.takeException(), isNull);
      h.coordinator.dispose();
    },
  );
}
