import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/auth_state.dart';
import '../core/plan_api.dart';
import '../models/intervention_session.dart';
import '../widgets/common.dart';

class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key, required this.auth});
  final AuthState auth;
  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionInput {
  final id = const Uuid().v4();
  final createdAt = DateTime.now().toUtc().toIso8601String();
  final date = TextEditingController(
    text: DateTime.now().toIso8601String().substring(0, 10),
  );
  final total = TextEditingController(),
      correct = TextEditingController(),
      engagement = TextEditingController(),
      duration = TextEditingController(),
      notes = TextEditingController();
  String status = 'completed', support = 'independent';
  String? goalId, activityId;
  void dispose() {
    for (final c in [date, total, correct, engagement, duration, notes]) {
      c.dispose();
    }
  }
}

class _SessionsScreenState extends State<SessionsScreen> {
  final _inputs = <_SessionInput>[_SessionInput()];
  String? _studentId, _planId, _error;
  bool _busy = false, _privacy = false;
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    for (final row in _inputs) {
      row.dispose();
    }
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final plans = await PlanApi(
        api: widget.auth.api,
        tokenForRequest: () => widget.auth.token,
      ).plans();
      await widget.auth.records!.cachePlanRecords(plans);
    } catch (_) {
      _error =
          'تعذّر تحديث الخطط. يمكن استخدام النسخ المعتمدة المحفوظة على هذا الجهاز.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final state = widget.auth.records!;
    if (_studentId == null || _planId == null || !_privacy) {
      setState(
        () => _error = 'اختاري الطالب والخطة المعتمدة وأكدي مراجعة الخصوصية.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final batch = _inputs
          .map(
            (row) => InterventionSession(
              id: row.id,
              studentId: _studentId!,
              planVersionId: _planId!,
              goalId: row.goalId ?? '',
              occurredOn: row.date.text.trim(),
              createdAt: row.createdAt,
              status: row.status,
              total: row.status == 'completed'
                  ? int.tryParse(row.total.text)
                  : null,
              correct: row.status == 'completed'
                  ? int.tryParse(row.correct.text)
                  : null,
              support: row.status == 'completed' ? row.support : null,
              engagement: row.status == 'completed'
                  ? row.engagement.text.trim()
                  : null,
              durationMinutes:
                  row.status == 'completed' &&
                      row.duration.text.trim().isNotEmpty
                  ? int.tryParse(row.duration.text) ?? -1
                  : null,
              activityId: row.activityId,
              notes: row.notes.text.trim(),
              privacyReviewed: true,
            ),
          )
          .toList();
      await state.saveSessions(batch);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'حُفظت ${batch.length} جلسة محليًا؛ ستنتقل عند المزامنة.',
            ),
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      _error = e is StateError
          ? e.message.toString()
          : 'تعذر الحفظ؛ احتُفظ بجميع المدخلات لإعادة المحاولة.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.auth.records!;
    final students = state.students;
    final plans = state.plans
        .where((p) => p.approved && p.studentId == _studentId)
        .toList();
    final selected = plans.where((p) => p.id == _planId).firstOrNull;
    final goals = ((selected?.content['goals'] as List?) ?? [])
        .map((g) => Map<String, dynamic>.from(g as Map))
        .toList();
    final previous =
        state.sessions.where((s) => s.studentId == _studentId).toList()
          ..sort((a, b) => b.occurredOn.compareTo(a.occurredOn));
    return Scaffold(
      appBar: AppBar(
        title: const Text('تسجيل الجلسات'),
        actions: [
          IconButton(
            tooltip: 'تحديث الخطط المعتمدة',
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          const PrototypeNote(),
          const Text(
            'يمكن التسجيل دون اتصال بعد حفظ الخطة المعتمدة على الجهاز. التاريخ السابق مسموح؛ الدقة من نتائج الجلسة وحدها. لا تُحوّل نتائج البطاقات إلى محاولات تدخل.',
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                _error!,
                key: const Key('session-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_busy) const LinearProgressIndicator(),
          DropdownButtonFormField<String>(
            initialValue: _studentId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'رمز الطالب'),
            items: students
                .map((s) => DropdownMenuItem(value: s.id, child: Text(s.code)))
                .toList(),
            onChanged: _busy
                ? null
                : (v) => setState(() {
                    _studentId = v;
                    _planId = null;
                    for (final row in _inputs) {
                      row.goalId = null;
                      row.activityId = null;
                    }
                  }),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            key: ValueKey('session-plan-$_studentId-$_planId'),
            initialValue: _planId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'نسخة الخطة المعتمدة'),
            items: plans
                .map(
                  (p) => DropdownMenuItem(
                    value: p.id,
                    child: Text(
                      'خطة ${p.data['version']} · ${p.data['approvedAt']?.toString().substring(0, 10) ?? ''}',
                    ),
                  ),
                )
                .toList(),
            onChanged: _busy
                ? null
                : (v) => setState(() {
                    _planId = v;
                    for (final row in _inputs) {
                      row.goalId = null;
                      row.activityId = null;
                    }
                  }),
          ),
          if (_studentId != null && plans.isEmpty)
            const Text(
              'يلزم اعتماد خطة ومزامنتها أو تحديثها قبل تسجيل الجلسات.',
            ),
          for (var i = 0; i < _inputs.length; i++) _row(_inputs[i], i, goals),
          OutlinedButton.icon(
            onPressed: _busy || _inputs.length >= 50
                ? null
                : () => setState(() => _inputs.add(_SessionInput())),
            icon: const Icon(Icons.add),
            label: const Text('إضافة جلسة أخرى إلى الدفعة'),
          ),
          CheckboxListTile(
            value: _privacy,
            onChanged: _busy
                ? null
                : (v) => setState(() => _privacy = v ?? false),
            title: const Text(
              'راجعت الملاحظات؛ لا تحتوي أسماء أو بيانات تعريفية أو صحية',
            ),
          ),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: Text('حفظ ${_inputs.length} جلسة محليًا معًا'),
          ),
          const SectionHeading('الجلسات السابقة لهذا الطالب'),
          for (final session in previous)
            Card(
              child: ListTile(
                title: Text(
                  '${session.occurredOn} · ${sessionStatuses[session.status]}',
                ),
                subtitle: Text(
                  '${session.accuracy == null ? 'لا توجد نتيجة أداء' : '${session.correct}/${session.total} · ${session.accuracy!.toStringAsFixed(1)}٪'}\n${syncStatusLabel(state.stateFor(session.id))}',
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(_SessionInput row, int index, List<Map<String, dynamic>> goals) {
    final activities = widget.auth.records!.activitiesForGoal(row.goalId ?? '');
    return Card(
      key: ValueKey(row.id),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'جلسة ${index + 1}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (_inputs.length > 1)
                  IconButton(
                    tooltip: 'إزالة من الدفعة',
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _inputs.remove(row);
                            row.dispose();
                          }),
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
              ],
            ),
            TextField(
              controller: row.date,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'تاريخ الجلسة YYYY-MM-DD',
              ),
            ),
            DropdownButtonFormField<String>(
              key: ValueKey('goal-${row.id}-${row.goalId}'),
              initialValue: row.goalId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'الهدف المعتمد'),
              items: goals
                  .map(
                    (g) => DropdownMenuItem(
                      value: g['id'] as String,
                      child: Text(
                        g['behavior'] as String,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                      row.goalId = v;
                      row.activityId = null;
                    }),
            ),
            DropdownButtonFormField<String>(
              initialValue: row.status,
              decoration: const InputDecoration(labelText: 'حالة الجلسة'),
              items: sessionStatuses.entries
                  .map(
                    (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                  )
                  .toList(),
              onChanged: _busy ? null : (v) => setState(() => row.status = v!),
            ),
            if (row.status == 'completed') ...[
              _number(row.total, 'عدد المحاولات (مطلوب)'),
              _number(row.correct, 'الإجابات الصحيحة (مطلوب)'),
              Text(
                'الدقة: ${int.tryParse(row.total.text) != null && int.parse(row.total.text) > 0 && int.tryParse(row.correct.text) != null ? '${(int.parse(row.correct.text) / int.parse(row.total.text) * 100).toStringAsFixed(1)}٪' : 'تُحسب من الصحيح ÷ المحاولات × 100'}',
              ),
              DropdownButtonFormField<String>(
                initialValue: row.support,
                decoration: const InputDecoration(labelText: 'مستوى الدعم'),
                items: supportLevels.entries
                    .map(
                      (e) =>
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                    )
                    .toList(),
                onChanged: _busy
                    ? null
                    : (v) => setState(() => row.support = v!),
              ),
              TextField(
                controller: row.engagement,
                enabled: !_busy,
                maxLength: 100,
                decoration: const InputDecoration(
                  labelText: 'مستوى التفاعل وفق سلم المؤسسة',
                  helperText:
                      'وصف تختارينه؛ سلم المستويات الثلاثة ينتظر تأكيد المختصة',
                ),
              ),
              _number(row.duration, 'مدة الجلسة بالدقائق (اختياري)'),
            ],
            DropdownButtonFormField<String>(
              key: ValueKey('activity-${row.id}-${row.goalId}'),
              initialValue: row.activityId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'النشاط المنفذ (اختياري)',
              ),
              items: [
                const DropdownMenuItem<String>(
                  value: null,
                  child: Text('دون نشاط مرتبط'),
                ),
                for (final a in activities)
                  DropdownMenuItem(
                    value: a['id'] as String,
                    child: Text(
                      (a['content'] as Map?)?['title'] as String? ??
                          'نشاط محفوظ',
                    ),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (v) => setState(() => row.activityId = v),
            ),
            TextField(
              controller: row.notes,
              enabled: !_busy,
              maxLength: 2000,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'ملاحظات الأداء (اختياري)',
                helperText: 'دون أسماء أو تشخيص أو بيانات اتصال',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _number(TextEditingController controller, String label) => TextField(
    controller: controller,
    enabled: !_busy,
    keyboardType: TextInputType.number,
    decoration: InputDecoration(labelText: label),
    onChanged: (_) => setState(() {}),
  );
}
