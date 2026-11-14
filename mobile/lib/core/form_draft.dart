import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'app_state.dart';

/// Keep unfinished numeric/date prefixes without treating structured dates or
/// identifiers as free text. Arbitrary pasted text never reaches the store.
String? structuredFormInputIssue({
  Iterable<String> dates = const [],
  Iterable<String> numbers = const [],
}) {
  final datePrefix = RegExp(r'^\d{0,4}(?:-\d{0,2}){0,2}$');
  final numberPrefix = RegExp(r'^[+-]?\d*(?:\.\d*)?(?:[eE][+-]?\d*)?$');
  if (dates.any((value) => !datePrefix.hasMatch(value)) ||
      numbers.any((value) => !numberPrefix.hasMatch(value))) {
    return 'راجعي حقول الأرقام والتواريخ؛ استخدمي الأرقام وصيغة YYYY-MM-DD دون نصوص تعريفية.';
  }
  return null;
}

/// A separate, encrypted form snapshot: it never creates records or outbox work.
/// Each update is copied immediately. Writes coalesce only while a prior write
/// is in flight, so a slow disk cannot replace newer input with an older value.
class FormDraftController extends ChangeNotifier {
  FormDraftController({
    required this.state,
    required this.key,
    this.isCurrentOwner,
    this.validate,
  }) {
    _drain = () async {
      if ((_disposed || !state.active) &&
          _latest != null &&
          validate?.call(_latest!) != null) {
        // Rejected identifying/clinical text is deliberately never persisted;
        // it must not prevent reopening the last valid encrypted snapshot.
        AppState.unregisterDraftDrain(state.ownerId, _drain);
        return;
      }
      await flush();
      if (_disposed) AppState.unregisterDraftDrain(state.ownerId, _drain);
    };
    AppState.registerDraftDrain(state.ownerId, _drain);
  }
  late final Future<void> Function() _drain;
  final AppState state;
  final String key;
  final bool Function()? isCurrentOwner;
  final String? Function(Map<String, dynamic>)? validate;
  Map<String, dynamic>? _latest;
  Future<void>? _running;
  int _revision = 0, _savedRevision = 0;
  bool _disposed = false, _suspended = false, _discarded = false;
  String? error;
  bool get dirty => _revision != _savedRevision;
  bool get saving => _running != null;
  Map<String, dynamic>? get restored => state.draftFor(key);
  bool get current => state.active && (isCurrentOwner?.call() ?? true);
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void update(Map<String, dynamic> snapshot) {
    if (_disposed || _suspended || _discarded || !current) return;
    _latest = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(snapshot)) as Map,
    );
    _revision++;
    error = validate?.call(_latest!);
    _notify();
    if (error == null) _start();
  }

  void _start() {
    if (_running != null ||
        !dirty ||
        _latest == null ||
        error != null ||
        state.accountDeleted) {
      return;
    }
    final completer = Completer<void>();
    _running = completer.future;
    _notify();
    unawaited(() async {
      try {
        while (dirty && error == null && !state.accountDeleted) {
          final revision = _revision;
          final snapshot = Map<String, dynamic>.from(
            jsonDecode(jsonEncode(_latest)) as Map,
          );
          await state.saveDraft(key, snapshot);
          _savedRevision = revision;
        }
      } catch (_) {
        error =
            'تعذّر حفظ مسودة النموذج. المدخلات باقية؛ أعيدي المحاولة قبل المغادرة.';
      } finally {
        _running = null;
        completer.complete();
        _notify();
      }
    }());
  }

  Future<void> flush() async {
    if (_discarded || state.accountDeleted) return;
    if (_running != null) await _running;
    final issue = _latest == null ? null : validate?.call(_latest!);
    if (issue != null) {
      error = issue;
      _notify();
      throw StateError(issue);
    }
    if (dirty) {
      error = null;
      _start();
      if (_running != null) await _running;
    }
    if (error != null || dirty) {
      throw StateError(error ?? 'لم يكتمل حفظ المسودة.');
    }
  }

  /// Used after records, outbox and the draft completion marker commit together.
  void acknowledgeSaved() {
    _latest = null;
    _savedRevision = _revision;
    error = null;
    _notify();
  }

  Future<void> discard() async {
    _suspended = true;
    try {
      if (_running != null) await _running;
      await state.clearDraft(key);
      _discarded = true;
      acknowledgeSaved();
      AppState.unregisterDraftDrain(state.ownerId, _drain);
    } finally {
      _suspended = false;
    }
  }

  Future<void> clearAfterSave() async {
    await flush();
    _suspended = true;
    try {
      await state.completeDraft(key);
      _discarded = true;
      acknowledgeSaved();
      AppState.unregisterDraftDrain(state.ownerId, _drain);
    } finally {
      _suspended = false;
    }
  }

  @override
  void dispose() {
    // Capture happened on the editing event. This flush never reads disposed
    // text controllers, and always targets the original account's store.
    _disposed = true;
    if (!_discarded && !state.accountDeleted) {
      unawaited(_drain().catchError((Object _) {}));
    } else {
      AppState.unregisterDraftDrain(state.ownerId, _drain);
    }
    super.dispose();
  }
}

class FormDraftGuard extends StatefulWidget {
  const FormDraftGuard({
    super.key,
    required this.controller,
    required this.child,
  });
  final FormDraftController controller;
  final Widget child;
  @override
  State<FormDraftGuard> createState() => _FormDraftGuardState();
}

class _FormDraftGuardState extends State<FormDraftGuard>
    with WidgetsBindingObserver {
  bool _leaving = false, _allowPop = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(widget.controller.flush().catchError((Object _) {}));
    }
  }

  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    try {
      await widget.controller.flush();
      if (!mounted) return;
      setState(() => _allowPop = true);
      final route = ModalRoute.of(context);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && (route?.isCurrent ?? false)) {
          Navigator.of(context).pop();
        }
      });
    } catch (_) {
      _leaving = false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'تعذّر حفظ آخر المدخلات. راجعي حالة المسودة أو ألغِيها صراحةً.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _allowPop,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) unawaited(_leave());
    },
    child: widget.child,
  );
}

class FormDraftStatus extends StatelessWidget {
  const FormDraftStatus({super.key, required this.controller});
  final FormDraftController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            controller.error ??
                (controller.saving || controller.dirty
                    ? 'جارٍ حفظ مسودة النموذج على الجهاز…'
                    : 'المسودة محفوظة على هذا الجهاز. الحفظ الصريح يضيف السجل.'),
            key: ValueKey('draft-status:${controller.key}'),
          ),
          if (controller.error != null)
            TextButton(
              onPressed: () async {
                try {
                  await controller.flush();
                } catch (_) {}
              },
              child: const Text('إعادة محاولة حفظ المسودة'),
            ),
        ],
      ),
    ),
  );
}

class DiscardFormDraftButton extends StatelessWidget {
  const DiscardFormDraftButton({
    super.key,
    required this.controller,
    this.enabled = true,
  });
  final FormDraftController controller;
  final bool enabled;
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'إلغاء مسودة النموذج',
    icon: const Icon(Icons.delete_sweep_outlined),
    onPressed: !enabled
        ? null
        : () async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('إلغاء مسودة النموذج؟'),
                content: const Text(
                  'تُحذف التعديلات غير المحفوظة في هذا النموذج فقط. تبقى السجلات المحفوظة والخطط المعتمدة كما هي.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('الاحتفاظ بالمسودة'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('أوافق على إلغاء المسودة'),
                  ),
                ],
              ),
            );
            if (confirmed != true || !context.mounted) return;
            try {
              await controller.discard();
              if (context.mounted) Navigator.of(context).pop();
            } catch (_) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('تعذّر إلغاء المسودة؛ احتُفظ بها.'),
                  ),
                );
              }
            }
          },
  );
}
