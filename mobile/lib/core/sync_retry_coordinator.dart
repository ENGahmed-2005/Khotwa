import 'dart:async';

/// Retries the existing durable outbox while its owner is in the foreground.
///
/// This does not monitor connectivity or generate content: a failed sync is
/// retried with bounded backoff, and a healthy, idle account makes no requests.
class SyncRetryCoordinator {
  SyncRetryCoordinator({
    required this.ownerId,
    required String? Function() currentOwnerId,
    required Future<void> Function() sync,
    required bool Function() isSyncing,
    required bool Function() hasPendingWork,
    required bool Function() hasSyncError,
    this.retryInterval = const Duration(seconds: 30),
    this.maxRetryInterval = const Duration(minutes: 5),
  }) : _currentOwnerId = currentOwnerId,
       _sync = sync,
       _isSyncing = isSyncing,
       _hasPendingWork = hasPendingWork,
       _hasSyncError = hasSyncError,
       _nextRetry = retryInterval {
    if (retryInterval <= Duration.zero || maxRetryInterval < retryInterval) {
      throw ArgumentError('Invalid sync retry intervals');
    }
  }

  final String ownerId;
  final Duration retryInterval, maxRetryInterval;
  final String? Function() _currentOwnerId;
  final Future<void> Function() _sync;
  final bool Function() _isSyncing, _hasPendingWork, _hasSyncError;
  Timer? _timer;
  Duration _nextRetry;
  bool _foreground = false, _disposed = false, _inFlight = false;
  bool _forceRequested = false, _lastAttemptFailed = false;

  bool get _allowed =>
      !_disposed && _foreground && _currentOwnerId() == ownerId;
  bool get _needsSync =>
      _forceRequested ||
      _lastAttemptFailed ||
      _hasPendingWork() ||
      _hasSyncError();

  /// Also used for the first foreground activation, even with an empty outbox.
  void resume() {
    if (_disposed) return;
    _foreground = true;
    unawaited(syncNow());
  }

  void pause() {
    _foreground = false;
    _cancelTimer();
  }

  void dispose() {
    _disposed = true;
    pause();
  }

  /// Called when records/auth change. Scheduling never changes outbox entries.
  void stateChanged() {
    if (!_allowed) {
      _cancelTimer();
      return;
    }
    if (!_inFlight && !_isSyncing() && !_hasPendingWork() && !_hasSyncError()) {
      // A successful manual sync can recover before our retry timer fires.
      _lastAttemptFailed = false;
      _nextRetry = retryInterval;
    }
    _scheduleIfNeeded();
  }

  /// Manual, startup and resume requests share the same no-overlap guard.
  Future<void> syncNow() async {
    if (!_allowed || _inFlight) return;
    _forceRequested = true;
    _cancelTimer();
    await _attempt();
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _scheduleIfNeeded() {
    if (!_allowed || !_needsSync) {
      _cancelTimer();
      return;
    }
    if (_inFlight || _timer != null) return;
    _timer = Timer(_nextRetry, () {
      _timer = null;
      unawaited(_attempt());
    });
  }

  Future<void> _attempt() async {
    if (!_allowed || _inFlight || !_needsSync) return;
    if (_isSyncing()) {
      // Another screen/manual action owns the transport. Do not queue a sync.
      _scheduleIfNeeded();
      return;
    }
    _inFlight = true;
    _forceRequested = false;
    var failed = true;
    try {
      await _sync();
      // Do not inspect a replacement owner's state after awaiting the request.
      if (_allowed) failed = _hasSyncError();
    } catch (_) {
      // AppState displays normal transport errors. Unexpected async failures
      // must also be consumed and retried without logging account data.
    } finally {
      _inFlight = false;
      if (_allowed) {
        if (failed && _lastAttemptFailed) {
          final doubled = _nextRetry * 2;
          _nextRetry = doubled > maxRetryInterval ? maxRetryInterval : doubled;
        } else {
          _nextRetry = retryInterval;
        }
        _lastAttemptFailed = failed;
        _scheduleIfNeeded();
      }
    }
  }
}
