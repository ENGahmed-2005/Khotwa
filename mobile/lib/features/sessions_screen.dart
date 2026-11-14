import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/auth_state.dart';
import '../core/app_state.dart';
import '../core/form_draft.dart';
import '../core/khotwa_theme.dart';
import '../core/plan_api.dart';
import '../models/intervention_session.dart';
import '../models/initial_assessment.dart';
import '../widgets/common.dart';
import '../widgets/khotwa_ui.dart';
import 'plans_screen.dart';
import 'students_screen.dart';

class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key, required this.auth});
  final AuthState auth;
  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionInput {
  _SessionInput({String? id, String? createdAt})
    : id = id ?? const Uuid().v4(),
      createdAt = createdAt ?? DateTime.now().toUtc().toIso8601String();
  final String id, createdAt;
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
  List<TextEditingController> get controllers => [
    date,
    total,
    correct,
    engagement,
    duration,
    notes,
  ];
  Map<String, dynamic> toDraft() => {
    'id': id,
    'createdAt': createdAt,
    'date': date.text,
    'total': total.text,
    'correct': correct.text,
    'engagement': engagement.text,
    'duration': duration.text,
    'notes': notes.text,
    'status': status,
    'support': support,
    'goalId': goalId,
    'activityId': activityId,
  };
  factory _SessionInput.fromDraft(Map<String, dynamic> value) {
    final row = _SessionInput(
      id: value['id'] as String,
      createdAt: value['createdAt'] as String,
    );
    row.date.text = value['date'] as String;
    row.total.text = value['total'] as String;
    row.correct.text = value['correct'] as String;
    row.engagement.text = value['engagement'] as String;
    row.duration.text = value['duration'] as String;
    row.notes.text = value['notes'] as String;
    row.status = value['status'] as String;
    row.support = value['support'] as String;
    row.goalId = value['goalId'] as String?;
    row.activityId = value['activityId'] as String?;
    return row;
  }
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
  late final AppState _state;
  late final String _ownerId;
  late final FormDraftController _formDraft;
  bool _restorationFailed = false;
  @override
  void initState() {
    super.initState();
    _state = widget.auth.records!;
    _ownerId = _state.ownerId;
    _formDraft = FormDraftController(
      state: _state,
      key: 'session-batch',
      isCurrentOwner: () => widget.auth.ownerId == _ownerId,
      validate: (value) =>
          educationalTextIssue([
            for (final row in value['rows'] as List) ...[
              (row as Map)['notes'] as String,
              row['engagement'] as String,
            ],
          ]) ??
          structuredFormInputIssue(
            dates: [
              for (final row in value['rows'] as List)
                (row as Map)['date'] as String,
            ],
            numbers: [
              for (final row in value['rows'] as List)
                for (final key in ['total', 'correct', 'duration'])
                  (row as Map)[key] as String,
            ],
          ),
    );
    final restored = _formDraft.restored;
    if (restored != null) {
      try {
        final rows = (restored['rows'] as List)
            .map(
              (r) =>
                  _SessionInput.fromDraft(Map<String, dynamic>.from(r as Map)),
            )
            .toList();
        if (rows.isEmpty || rows.length > 50) throw StateError('Invalid batch');
        for (final row in _inputs) {
          row.dispose();
        }
        _inputs
          ..clear()
          ..addAll(rows);
        _studentId = restored['studentId'] as String?;
        _planId = restored['planId'] as String?;
      } catch (_) {
        _restorationFailed = true;
        _error =
            'تعذّر فتح مسودة دفعة الجلسات. بقيت محفوظة؛ يمكن إلغاؤها صراحةً.';
      }
    }
    for (final row in _inputs) {
      _watch(row);
    }
    _refresh();
  }

  void _watch(_SessionInput row) {
    for (final c in row.controllers) {
      c.addListener(_changed);
    }
  }

  void _changed() {
    if (_restorationFailed) return;
    _formDraft.update({
      'studentId': _studentId,
      'planId': _planId,
      'rows': _inputs.map((r) => r.toDraft()).toList(),
    });
  }

  void _edit(VoidCallback action) {
    if (_busy) return;
    setState(action);
    _changed();
  }

  void _addRow() {
    final row = _SessionInput();
    _watch(row);
    _edit(() => _inputs.add(row));
  }

  @override
  void dispose() {
    _formDraft.dispose();
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
        tokenForRequest: () => widget.auth.ownerId == _ownerId && _state.active
            ? widget.auth.token
            : null,
      ).plans();
      if (!_formDraft.current) return;
      await _state.cachePlanRecords(plans);
    } catch (_) {
      _error =
          'تعذّر تحديث الخطط. يمكن استخدام النسخ المعتمدة المحفوظة على هذا الجهاز.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_restorationFailed || !_formDraft.current) return;
    final state = _state;
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
      await _formDraft.flush();
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
      await state.saveSessions(batch, draftKey: _formDraft.key);
      _formDraft.acknowledgeSaved();
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

  Future<void> _openStudents() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('ملفات الطلبة')),
          body: StudentsScreen(state: _state),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openPlans() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => PlansScreen(auth: widget.auth)),
    );
    if (mounted) setState(() {});
  }

  Future<void> _chooseSessionDate(_SessionInput row) async {
    final today = DateUtils.dateOnly(DateTime.now());
    final parsed = DateTime.tryParse(row.date.text);
    final initial =
        parsed == null || parsed.isAfter(today) || parsed.year < 1900
        ? today
        : parsed;
    final chosen = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1900),
      lastDate: today,
    );
    if (chosen != null && mounted) {
      _edit(
        () => row.date.text =
            '${chosen.year.toString().padLeft(4, '0')}-${chosen.month.toString().padLeft(2, '0')}-${chosen.day.toString().padLeft(2, '0')}',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
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
    return FormDraftGuard(
      controller: _formDraft,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('تسجيل الجلسات'),
          actions: [
            DiscardFormDraftButton(controller: _formDraft, enabled: !_busy),
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
            FormDraftStatus(controller: _formDraft),
            const KhotwaPageIntro(
              title: 'متابعة الطالب، جلسة بجلسة',
              description:
                  'سجلي الأداء الفعلي وتابعي الأهداف من جلسة إلى أخرى.',
              icon: Icons.edit_calendar_outlined,
            ),
            const Text(
              'يمكن التسجيل دون اتصال بعد حفظ الخطة المعتمدة على الجهاز. تُحسب الدقة من نتائج هذه الجلسة فقط.',
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
            if (students.isEmpty)
              KhotwaEmptyState(
                title: 'ملف الطالب أولًا',
                message:
                    'ابدئي بإضافة ملف الطالب وتقييمه، ثم اعتمدي خطته لتسجيل الجلسات المرتبطة بأهدافه.',
                icon: Icons.assignment_ind_outlined,
                action: FilledButton.icon(
                  onPressed: _busy ? null : _openStudents,
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: const Text('فتح ملفات الطلبة'),
                ),
              ),
            if (students.isNotEmpty || _formDraft.restored != null) ...[
              KhotwaSectionCard(
                title: '١. الطالب والخطة',
                subtitle: 'اربطي الجلسة بأهداف الخطة المعتمدة.',
                icon: Icons.folder_shared_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: students.any((s) => s.id == _studentId)
                          ? _studentId
                          : null,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'رمز الطالب',
                      ),
                      items: students
                          .map(
                            (s) => DropdownMenuItem(
                              value: s.id,
                              child: Text(s.code),
                            ),
                          )
                          .toList(),
                      onChanged: _busy
                          ? null
                          : (v) => _edit(() {
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
                      initialValue: plans.any((p) => p.id == _planId)
                          ? _planId
                          : null,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'نسخة الخطة المعتمدة',
                      ),
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
                          : (v) => _edit(() {
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

                    if (_studentId != null && plans.isEmpty)
                      TextButton.icon(
                        onPressed: _busy ? null : _openPlans,
                        icon: const Icon(Icons.auto_awesome_outlined),
                        label: const Text('فتح الخطط ومراجعتها'),
                      ),
                  ],
                ),
              ),
              const SectionHeading(
                '٢. سجلي ما حدث في الجلسة',
                subtitle: 'يمكن إضافة أكثر من جلسة وحفظها معًا.',
              ),
              for (var i = 0; i < _inputs.length; i++)
                _row(_inputs[i], i, goals),
              OutlinedButton.icon(
                onPressed: _busy || _inputs.length >= 50 ? null : _addRow,
                icon: const Icon(Icons.add),
                label: const Text('إضافة جلسة أخرى إلى الدفعة'),
              ),
              CheckboxListTile(
                value: _privacy,
                onChanged: _busy
                    ? null
                    : (v) => _edit(() => _privacy = v ?? false),
                title: const Text(
                  'راجعت الملاحظات؛ لا تحتوي أسماء أو بيانات تعريفية أو صحية',
                ),
              ),
              FilledButton.icon(
                onPressed:
                    _busy ||
                        !students.any((student) => student.id == _studentId) ||
                        selected == null ||
                        !_privacy
                    ? null
                    : _save,
                icon: const Icon(Icons.save_outlined),
                label: Text('حفظ ${_inputs.length} جلسة محليًا معًا'),
              ),
            ],
            SectionHeading(
              'الجلسات السابقة لهذا الطالب',
              subtitle: '${previous.length} جلسة محفوظة',
            ),
            if (previous.isEmpty)
              KhotwaEmptyState(
                title: _studentId == null
                    ? 'سجل الجلسات'
                    : 'لا توجد جلسات لهذا الطالب بعد',
                message: _studentId == null
                    ? 'اختاري ملف الطالب لعرض جلساته السابقة.'
                    : 'بعد حفظ أول جلسة ستظهر هنا نتيجتها وحالة حفظها.',
                icon: Icons.history_rounded,
              ),
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
      ),
    );
  }

  Widget _row(_SessionInput row, int index, List<Map<String, dynamic>> goals) {
    final activities = _state.activitiesForGoal(row.goalId ?? '');
    return Card(
      key: ValueKey(row.id),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: KhotwaPalette.paleAmber,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.event_note_outlined),
                ),
                const SizedBox(width: 10),
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
                        : () => _edit(() {
                            _inputs.remove(row);
                            row.dispose();
                          }),
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: row.date,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'تاريخ الجلسة YYYY-MM-DD',
                helperText: 'اختاري من التقويم أو اكتبي تاريخ جلسة سابقة',
                suffixIcon: IconButton(
                  tooltip: 'اختيار تاريخ الجلسة',
                  onPressed: _busy ? null : () => _chooseSessionDate(row),
                  icon: const Icon(Icons.calendar_month_outlined),
                ),
              ),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              key: ValueKey('goal-${row.id}-${row.goalId}'),
              initialValue: goals.any((g) => g['id'] == row.goalId)
                  ? row.goalId
                  : null,
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
                  : (v) => _edit(() {
                      row.goalId = v;
                      row.activityId = null;
                    }),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: row.status,
              decoration: const InputDecoration(labelText: 'حالة الجلسة'),
              items: sessionStatuses.entries
                  .map(
                    (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                  )
                  .toList(),
              onChanged: _busy ? null : (v) => _edit(() => row.status = v!),
            ),
            if (row.status == 'completed') ...[
              const SizedBox(height: 14),
              _number(row.total, 'عدد المحاولات (مطلوب)'),
              const SizedBox(height: 14),
              _number(row.correct, 'الإجابات الصحيحة (مطلوب)'),
              Text(
                'الدقة: ${int.tryParse(row.total.text) != null && int.parse(row.total.text) > 0 && int.tryParse(row.correct.text) != null ? '${(int.parse(row.correct.text) / int.parse(row.total.text) * 100).toStringAsFixed(1)}٪' : 'تُحسب من الصحيح ÷ المحاولات × 100'}',
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: row.support,
                decoration: const InputDecoration(labelText: 'مستوى الدعم'),
                items: supportLevels.entries
                    .map(
                      (e) =>
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                    )
                    .toList(),
                onChanged: _busy ? null : (v) => _edit(() => row.support = v!),
              ),
              const SizedBox(height: 14),
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
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              key: ValueKey('activity-${row.id}-${row.goalId}'),
              initialValue: activities.any((a) => a['id'] == row.activityId)
                  ? row.activityId
                  : null,
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
              onChanged: _busy ? null : (v) => _edit(() => row.activityId = v),
            ),
            const SizedBox(height: 14),
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
