import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../core/app_state.dart';
import '../core/auth_state.dart';
import '../core/sync_retry_coordinator.dart';
import '../core/khotwa_theme.dart';
import '../widgets/khotwa_ui.dart';
import '../widgets/specialist_dashboard.dart';
import '../widgets/common.dart';
import 'students_screen.dart';
import 'plans_screen.dart';
import 'sessions_screen.dart';
import 'progress_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.state,
    required this.auth,
    this.activitiesBuilder,
    this.reportsBuilder,
  });
  final AppState state;
  final AuthState auth;
  final WidgetBuilder? activitiesBuilder, reportsBuilder;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _tab = 0;
  late SyncRetryCoordinator _syncRetry;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _configureSyncRetry();
  }

  void _configureSyncRetry() {
    _syncRetry = SyncRetryCoordinator(
      ownerId: widget.state.ownerId,
      currentOwnerId: () =>
          mounted &&
              widget.auth.signedIn &&
              identical(widget.auth.records, widget.state) &&
              widget.auth.ownerId == widget.state.ownerId
          ? widget.state.ownerId
          : null,
      sync: widget.auth.sync,
      isSyncing: () => widget.state.syncing || widget.auth.busy,
      hasPendingWork: () => widget.state.pendingCount > 0,
      hasSyncError: () => widget.state.syncError != null,
    );
    widget.state.addListener(_syncRetry.stateChanged);
    widget.auth.addListener(_syncRetry.stateChanged);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == null || lifecycle == AppLifecycleState.resumed) {
      _syncRetry.resume();
    }
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state, widget.state) ||
        !identical(oldWidget.auth, widget.auth)) {
      oldWidget.state.removeListener(_syncRetry.stateChanged);
      oldWidget.auth.removeListener(_syncRetry.stateChanged);
      _syncRetry.dispose();
      _configureSyncRetry();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.state.removeListener(_syncRetry.stateChanged);
    widget.auth.removeListener(_syncRetry.stateChanged);
    _syncRetry.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncRetry.resume();
    } else {
      _syncRetry.pause();
    }
  }

  Future<void> _accountAction(String value) async {
    try {
      if (value == 'logout') {
        await widget.auth.logout();
      }
      if (value == 'lock') {
        await widget.auth.lock();
      }
      if (value == 'delete') {
        if (!mounted) {
          return;
        }
        final password = TextEditingController();
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('حذف الحساب وبياناته نهائيًا؟'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'يحذف الحساب وملفاته من الخادم، ثم بيانات هذا الحساب المحلية على هذا الجهاز. لا يمكن التراجع. أدخل كلمة المرور للتأكيد.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'كلمة المرور'),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('حذف نهائي'),
              ),
            ],
          ),
        );
        final value = password.text;
        password.dispose();
        if (confirmed == true) {
          await widget.auth.deleteAccount(value);
        }
      }
    } catch (e) {
      if (mounted) {
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.state,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            KhotwaBrandMark(size: 36),
            SizedBox(width: 9),
            Text('خطوة'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'مزامنة الآن',
            onPressed: widget.state.syncing ? null : _syncRetry.syncNow,
            icon: const Icon(Icons.sync_rounded),
          ),
          IconButton(
            tooltip: 'الإعدادات والحساب',
            onPressed: () => setState(() => _tab = 2),
            icon: const Icon(Icons.tune_rounded),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              children: [
                if (widget.state.pendingCount > 0 ||
                    widget.state.syncing ||
                    widget.state.syncError != null ||
                    widget.state.conflicts.isNotEmpty)
                  _syncNotice(),
                Expanded(
                  child: _tab == 0
                      ? _dashboard()
                      : _tab == 1
                      ? StudentsScreen(state: widget.state)
                      : _syncPanel(),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: KhotwaPalette.line)),
        ),
        child: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (value) => setState(() => _tab = value),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: 'الرئيسية',
            ),
            NavigationDestination(
              icon: Icon(Icons.groups_2_outlined),
              selectedIcon: Icon(Icons.groups_2_rounded),
              label: 'الطلبة',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings_rounded),
              label: 'الإعدادات',
            ),
          ],
        ),
      ),
    ),
  );

  Widget _syncNotice() => Container(
    margin: const EdgeInsets.fromLTRB(20, 3, 20, 8),
    padding: const EdgeInsetsDirectional.fromSTEB(13, 4, 5, 4),
    decoration: BoxDecoration(
      color: widget.state.syncError != null || widget.state.conflicts.isNotEmpty
          ? KhotwaPalette.paleAmber
          : KhotwaPalette.paleBlue,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      children: [
        Icon(
          widget.state.syncError != null
              ? Icons.cloud_off_outlined
              : Icons.cloud_sync_outlined,
          size: 20,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            widget.state.syncing
                ? 'جارٍ مزامنة عملكِ…'
                : widget.state.conflicts.isNotEmpty
                ? 'يوجد تعارض يحتاج مراجعتكِ'
                : widget.state.syncError != null
                ? 'تعذّرت المزامنة. عملكِ المحفوظ باقٍ على هذا الجهاز.'
                : '${widget.state.pendingCount} تغييرات بانتظار المزامنة',
            style: const TextStyle(fontSize: 11, height: 1.6),
          ),
        ),
        TextButton(
          onPressed: () => setState(() => _tab = 2),
          child: const Text('التفاصيل'),
        ),
      ],
    ),
  );

  void _open(WidgetBuilder builder) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: builder));

  Widget _dashboard() => SpecialistDashboard(
    state: widget.state,
    onStudents: () => setState(() => _tab = 1),
    onAddStudent: () => _open((_) => StudentFormScreen(state: widget.state)),
    onPlans: () => _open((_) => PlansScreen(auth: widget.auth)),
    onSessions: () => _open((_) => SessionsScreen(auth: widget.auth)),
    onProgress: () => _open((_) => ProgressScreen(state: widget.state)),
    onActivities: widget.activitiesBuilder == null
        ? null
        : () => _open(widget.activitiesBuilder!),
    onReports: widget.reportsBuilder == null
        ? null
        : () => _open(widget.reportsBuilder!),
  );

  Widget _syncPanel() => ListView(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
    children: [
      const KhotwaPageIntro(
        title: 'الإعدادات والحساب',
        description: 'راجعي حفظ عملكِ واتصال أجهزتكِ من مكان واحد.',
        icon: Icons.tune_rounded,
      ),
      KhotwaSectionCard(
        title: 'حساب المختصّة',
        icon: Icons.person_outline_rounded,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.auth.email != null)
              Text(widget.auth.email!, textDirection: TextDirection.ltr),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: widget.state.syncing || widget.auth.busy
                      ? null
                      : () => _accountAction('lock'),
                  icon: const Icon(Icons.lock_outline_rounded),
                  label: const Text('قفل التطبيق'),
                ),
                TextButton(
                  onPressed: widget.state.syncing || widget.auth.busy
                      ? null
                      : () => _accountAction('logout'),
                  child: const Text('تسجيل الخروج'),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              'قفل التطبيق يحتفظ بعملكِ على الجهاز إلى حين تسجيل الدخول مجددًا.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      const Card(
        child: ExpansionTile(
          title: Text('دليل الاستخدام'),
          leading: Icon(Icons.lightbulb_outline_rounded),
          childrenPadding: EdgeInsets.fromLTRB(18, 0, 18, 18),
          children: [
            Text(
              '١. أضيفي ملف طالب برمز مجهّل وأكدي الموافقة.\n٢. سجّلي التقييم وشواهد الأداء وراجعيها.\n٣. عايني بيانات التوليد ثم راجعي مسودة الخطة واعتمديها.\n٤. سجّلي الجلسات وتابعي التقدّم وصدّري التقرير.\n٥. زامني العمل قبل الانتقال لجهاز آخر.',
            ),
          ],
        ),
      ),
      const SectionHeading('حالة البيانات'),
      Text('تغييرات معلّقة: ${widget.state.pendingCount}'),
      Text('آخر مزامنة: ${widget.state.lastSyncedAt ?? 'لم تتم بعد'}'),
      if (widget.state.syncError != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            widget.state.syncError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      FilledButton.icon(
        onPressed: widget.state.syncing ? null : _syncRetry.syncNow,
        icon: const Icon(Icons.sync),
        label: const Text('مزامنة / إعادة المحاولة'),
      ),
      const SizedBox(height: 12),
      const Text(
        kIsWeb
            ? 'معاينة المتصفح تحفظ البيانات في الذاكرة مؤقتًا فقط. تُستعاد البيانات المتزامنة من الخادم بعد تسجيل الدخول. التشفير المحلي مخصص لتطبيق Android وiOS.'
            : 'يُحفظ عملكِ مشفّرًا على هذا الجهاز. زامني قبل الانتقال إلى جهاز آخر. عند التعارض تحتفظ خطوة بالنسختين حتى تراجعي القرار.',
      ),
      for (final entry in widget.state.conflicts.entries)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'تعارض يحتاج إلى قرارك',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Text('السجل: ${entry.key}'),
                Text(
                  'نسخة الجهاز: ${(entry.value['local'] as Map)['updatedAt']}',
                ),
                Text(
                  'نسخة الخادم: ${(entry.value['server'] as Map)['updatedAt']}',
                ),
                const Text(
                  'تُؤرشف النسختان عند القرار؛ الحذف والاعتماد على الخادم لا يُستبدلان.',
                ),
                OutlinedButton(
                  onPressed: () => _resolve(entry.key, true),
                  child: const Text('الاحتفاظ بتعديلي وإعادة إرساله'),
                ),
                OutlinedButton(
                  onPressed: () => _resolve(entry.key, false),
                  child: const Text('استخدام نسخة الخادم وأرشفة تعديلي'),
                ),
              ],
            ),
          ),
        ),
      const SizedBox(height: 22),
      TextButton.icon(
        onPressed: widget.state.syncing || widget.auth.busy
            ? null
            : () => _accountAction('delete'),
        icon: const Icon(Icons.delete_outline_rounded),
        label: const Text('حذف الحساب والبيانات'),
        style: TextButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.error,
        ),
      ),
    ],
  );
  Future<void> _resolve(String id, bool keepLocal) async {
    try {
      await widget.state.resolveConflict(id, keepLocal: keepLocal);
    } catch (e) {
      if (mounted) {
        showError(context, e);
      }
    }
  }
}
