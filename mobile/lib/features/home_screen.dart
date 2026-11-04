import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../core/app_state.dart';
import '../core/auth_state.dart';
import '../models/assessment.dart';
import '../widgets/common.dart';
import 'students_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.state, required this.auth});
  final AppState state;
  final AuthState auth;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _tab = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(widget.auth.sync());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !widget.state.syncing) {
      unawaited(widget.auth.sync());
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
        title: const Text('خطوة'),
        actions: [
          IconButton(
            tooltip: 'مزامنة الآن',
            onPressed: widget.state.syncing ? null : widget.auth.sync,
            icon: const Icon(Icons.sync),
          ),
          PopupMenuButton<String>(
            enabled: !widget.state.syncing,
            onSelected: _accountAction,
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'logout',
                child: Text('تسجيل الخروج وإبطال الجلسة'),
              ),
              PopupMenuItem(
                value: 'lock',
                child: Text('قفل محلي وحفظ العمل غير المتزامن'),
              ),
              PopupMenuItem(
                value: 'delete',
                child: Text('حذف الحساب والبيانات'),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Material(
              color: const Color(0xFFE7F3F2),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(
                      widget.state.syncing
                          ? Icons.sync
                          : widget.state.syncError != null
                          ? Icons.cloud_off
                          : Icons.lock_outline,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.state.syncing
                            ? 'جارٍ المزامنة…'
                            : '${widget.state.pendingCount} تغيير بانتظار المزامنة · ${widget.state.conflicts.length} تعارض',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() => _tab = 2),
                      child: const Text('التفاصيل'),
                    ),
                  ],
                ),
              ),
            ),
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
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (value) => setState(() => _tab = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            label: 'الرئيسية',
          ),
          NavigationDestination(
            icon: Icon(Icons.school_outlined),
            label: 'ملفات الطلبة',
          ),
          NavigationDestination(
            icon: Icon(Icons.sync),
            label: 'المزامنة والحساب',
          ),
        ],
      ),
    ),
  );
  Widget _dashboard() => ListView(
    padding: const EdgeInsets.all(18),
    children: [
      Text(
        'لكل طالب طريقته في التعلم،',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      Text(
        'ولكل خطوة أثر في التقدم',
        style: Theme.of(context).textTheme.titleLarge
            ?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
      const SizedBox(height: 18),
      const PrototypeNote(),
      const SectionHeading('نظرة سريعة'),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            '${widget.state.students.length} ملفات مجهّلة    ·    ${widget.state.assessments.where((a) => a.status == AssessmentStatus.approved).length} تقييمات معتمدة',
          ),
        ),
      ),
      const SectionHeading('ابدأ العمل'),
      Card(
        child: ListTile(
          leading: const Icon(Icons.assignment_outlined),
          title: const Text('ملفات الطلبة والتقييم الأكاديمي'),
          subtitle: const Text('بطاقات العربية والرياضيات للأعمار 6–12 سنة'),
          trailing: const Icon(Icons.chevron_left),
          onTap: () => setState(() => _tab = 1),
        ),
      ),
      const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'الخطط الذكية والجلسات والتقارير والتقييم التربوي الحر قيد التطوير، وليست متاحة في هذا التسليم.',
          ),
        ),
      ),
      const SectionHeading('مسار الاستخدام'),
      const Text(
        '١. أنشئي ملفًا برمز عشوائي وسجّلي إقرار الموافقة.\n٢. نفّذي البطاقات وسجّلي الأداء واحفظيه مشفّرًا.\n٣. راجعي الملخص واعتمديه بقرار صريح.\n٤. زامني العمل قبل الانتقال لجهاز آخر؛ العمل غير المتزامن يبقى على هذا الجهاز.',
      ),
    ],
  );
  Widget _syncPanel() => ListView(
    padding: const EdgeInsets.all(18),
    children: [
      Text(widget.auth.email ?? '', textDirection: TextDirection.ltr),
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
        onPressed: widget.state.syncing ? null : widget.auth.sync,
        icon: const Icon(Icons.sync),
        label: const Text('مزامنة / إعادة المحاولة'),
      ),
      const SizedBox(height: 12),
      const Text(
        kIsWeb
            ? 'معاينة المتصفح تحفظ البيانات في الذاكرة مؤقتًا فقط. تُستعاد البيانات المتزامنة من الخادم بعد تسجيل الدخول. التشفير المحلي مخصص لتطبيق Android وiOS.'
            : 'البيانات المحلية محفوظة بتشفير AES-GCM، ومفتاحها في مخزن الجهاز الآمن. عند التعارض تبقى النسختان محفوظتين. لا تُحذف السجلات بسبب غيابها من استجابة الخادم.',
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
