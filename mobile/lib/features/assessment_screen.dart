import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/form_draft.dart';
import '../data/assessment_templates.dart';
import '../models/assessment.dart';
import '../models/initial_assessment.dart' show educationalTextIssue;
import '../widgets/common.dart';

class AssessmentScreen extends StatefulWidget {
  const AssessmentScreen({
    super.key,
    required this.state,
    required this.assessmentId,
  });
  final AppState state;
  final String assessmentId;

  @override
  State<AssessmentScreen> createState() => _AssessmentScreenState();
}

class _AssessmentScreenState extends State<AssessmentScreen> {
  int _index = 0;
  ItemExecution _execution = ItemExecution.notDone;
  ItemJudgment? _judgment;
  SupportLevel _support = SupportLevel.independent;
  late final TextEditingController _response;
  late final TextEditingController _notes;
  late final TextEditingController _readingSeconds;
  late final TextEditingController _readingErrors;
  late final TextEditingController _wordsRead;
  late final TextEditingController _selfCorrections;
  final _structured = <String, TextEditingController>{
    for (final key in structuredObservationLabels.keys)
      key: TextEditingController(),
  };
  FormDraftController? _activeDraft;
  FormDraftController get _formDraft => _activeDraft!;
  bool _loadingTask = false, _restorationFailed = false;
  String? _draftError;
  bool _saving = false;
  bool get _canEdit => !_locked && !_saving && !_restorationFailed;
  List<TextEditingController> get _controllers => [
    _response,
    _notes,
    _readingSeconds,
    _readingErrors,
    _wordsRead,
    _selfCorrections,
    ..._structured.values,
  ];
  String _draftKey(String itemId) =>
      'assessment-form:${widget.assessmentId}:$itemId';

  AssessmentRecord get _assessment =>
      widget.state.assessmentById(widget.assessmentId);
  List<AssessmentTask> get _tasks => tasksForAge(_assessment.ageGroup);
  AssessmentTask get _task => _tasks[_index];
  bool get _locked =>
      _assessment.status == AssessmentStatus.approved ||
      _assessment.templateVersion != assessmentTemplateVersion;

  @override
  void initState() {
    super.initState();
    _response = TextEditingController();
    _notes = TextEditingController();
    _readingSeconds = TextEditingController();
    _readingErrors = TextEditingController();
    _wordsRead = TextEditingController();
    _selfCorrections = TextEditingController();
    if (!_locked) {
      String latest = '';
      for (var index = 0; index < _tasks.length; index++) {
        final saved = widget.state.draftFor(_draftKey(_tasks[index].id));
        final editedAtValue = saved?['editedAt'];
        final editedAt = editedAtValue is String ? editedAtValue : '';
        if (saved != null && editedAt.compareTo(latest) >= 0) {
          latest = editedAt;
          _index = index;
        }
      }
    }
    _loadTask();
    for (final controller in _controllers) {
      controller.addListener(_changed);
    }
  }

  void _loadTask() {
    _loadingTask = true;
    _activeDraft?.dispose();
    _restorationFailed = false;
    _draftError = null;
    final item = _assessment.results[_task.id];
    _execution = item?.execution ?? ItemExecution.notDone;
    _judgment = item?.judgment;
    _support = item?.support ?? SupportLevel.independent;
    _response.text = item?.response ?? '';
    _notes.text = item?.observation ?? '';
    _readingSeconds.text = item?.readingSeconds?.toString() ?? '';
    _readingErrors.text = item?.readingErrors?.toString() ?? '';
    _wordsRead.text = item?.wordsRead?.toString() ?? '';
    _selfCorrections.text = item?.selfCorrections?.toString() ?? '';
    for (final entry in _structured.entries) {
      entry.value.text = item?.structuredObservations[entry.key] ?? '';
    }
    final itemId = _task.id;
    _activeDraft = FormDraftController(
      state: widget.state,
      key: _draftKey(itemId),
      validate: (value) {
        if (value['itemId'] != itemId) {
          return 'مسودة البند لا تطابق البند المعروض.';
        }
        final structured = Map<String, String>.from(
          value['structuredObservations'] as Map,
        );
        if (structured.keys.any(
          (key) => !structuredKeysForTask(itemId).contains(key),
        )) {
          return 'ملاحظة منظمة لا تنتمي إلى هذا البند.';
        }
        return educationalTextIssue([
              value['response'] as String,
              value['observation'] as String,
            ]) ??
            structuredObservationIssue(structured) ??
            structuredFormInputIssue(
              numbers: [
                for (final key in [
                  'readingSeconds',
                  'readingErrors',
                  'wordsRead',
                  'selfCorrections',
                ])
                  value[key] as String,
              ],
            );
      },
    );
    final restored = _formDraft.restored;
    if (restored != null && !_locked) {
      try {
        final issue = _formDraft.validate?.call(restored);
        if (issue != null) {
          throw FormatException(issue);
        }
        _execution = ItemExecution.values.byName(
          restored['execution'] as String,
        );
        _judgment = restored['judgment'] == null
            ? null
            : ItemJudgment.values.byName(restored['judgment'] as String);
        _support = SupportLevel.values.byName(restored['support'] as String);
        _response.text = restored['response'] as String;
        _notes.text = restored['observation'] as String;
        _readingSeconds.text = restored['readingSeconds'] as String;
        _readingErrors.text = restored['readingErrors'] as String;
        _wordsRead.text = restored['wordsRead'] as String;
        _selfCorrections.text = restored['selfCorrections'] as String;
        final structured = Map<String, String>.from(
          restored['structuredObservations'] as Map,
        );
        for (final key in structuredKeysForTask(itemId)) {
          _structured[key]!.text = structured[key] ?? '';
        }
      } catch (_) {
        _restorationFailed = true;
        _draftError =
            'تعذّر فتح مسودة هذا البند. بقيت محفوظة؛ يمكن إلغاؤها صراحةً.';
      }
    }
    _loadingTask = false;
  }

  void _changed() {
    if (_loadingTask || !_canEdit) {
      return;
    }
    _formDraft.update({
      'itemId': _task.id,
      'editedAt': DateTime.now().toUtc().toIso8601String(),
      'execution': _execution.name,
      'judgment': _judgment?.name,
      'support': _support.name,
      'response': _response.text,
      'observation': _notes.text,
      'readingSeconds': _readingSeconds.text,
      'readingErrors': _readingErrors.text,
      'wordsRead': _wordsRead.text,
      'selfCorrections': _selfCorrections.text,
      'structuredObservations': {
        for (final key in structuredKeysForTask(_task.id))
          key: _structured[key]!.text,
      },
    });
  }

  void _edit(VoidCallback action) {
    if (!_canEdit) {
      return;
    }
    setState(action);
    _changed();
  }

  Future<void> _openSummary() async {
    try {
      await _formDraft.flush();
      if (!_locked &&
          _tasks.any(
            (task) => widget.state.draftFor(_draftKey(task.id)) != null,
          )) {
        throw StateError(
          'احفظي مدخلات البند صراحةً أو ألغِي مسودته قبل مراجعة ملخص السجلات.',
        );
      }
      if (!mounted) {
        return;
      }
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => AssessmentSummaryScreen(
            state: widget.state,
            assessmentId: widget.assessmentId,
          ),
        ),
      );
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  @override
  void dispose() {
    _activeDraft?.dispose();
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  int? _intOrNull(String text) =>
      text.trim().isEmpty ? null : int.tryParse(text.trim());

  Future<void> _saveAndMove({required bool forward}) async {
    if (!_canEdit) {
      return;
    }
    setState(() => _saving = true);
    try {
      await _formDraft.flush();
      final seconds = _intOrNull(_readingSeconds.text);
      final errors = _intOrNull(_readingErrors.text);
      final rawNumbers = [
        _readingSeconds.text,
        _readingErrors.text,
        _wordsRead.text,
        _selfCorrections.text,
      ];
      if (rawNumbers.any(
        (raw) =>
            raw.trim().isNotEmpty &&
            (_intOrNull(raw) == null || _intOrNull(raw)! < 0),
      )) {
        throw StateError(
          'مدة القراءة والأخطاء يجب أن تكون أعدادًا صحيحة غير سالبة.',
        );
      }
      await widget.state.saveResult(
        assessmentId: widget.assessmentId,
        itemId: _task.id,
        draftKey: _formDraft.key,
        result: AssessmentItemResult(
          execution: _execution,
          judgment: _execution == ItemExecution.performed ? _judgment : null,
          support: _support,
          response: _execution == ItemExecution.performed
              ? _response.text.trim()
              : '',
          observation: _notes.text.trim(),
          readingSeconds:
              _task.isReading && _execution == ItemExecution.performed
              ? seconds
              : null,
          readingErrors:
              _task.isReading && _execution == ItemExecution.performed
              ? errors
              : null,
          wordsRead: _task.isReading && _execution == ItemExecution.performed
              ? _intOrNull(_wordsRead.text)
              : null,
          selfCorrections:
              _task.isReading && _execution == ItemExecution.performed
              ? _intOrNull(_selfCorrections.text)
              : null,
          structuredObservations: {
            for (final key in structuredKeysForTask(_task.id))
              if (_structured[key]!.text.trim().isNotEmpty)
                key: _structured[key]!.text.trim(),
          },
        ),
      );
      _formDraft.acknowledgeSaved();
      if (!mounted) {
        return;
      }
      if (forward && _index == _tasks.length - 1) {
        await _openSummary();
      } else {
        setState(() {
          _index = (forward ? _index + 1 : _index - 1)
              .clamp(0, _tasks.length - 1)
              .toInt();
          _loadTask();
        });
      }
    } catch (error) {
      if (mounted) {
        showError(context, error);
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _tasks;
    final task = _task;
    final card = cardsForAge(
      _assessment.ageGroup,
    ).firstWhere((card) => card.number == task.cardNumber);
    return FormDraftGuard(
      key: ValueKey(_formDraft.key),
      controller: _formDraft,
      child: Scaffold(
        appBar: AppBar(
          title: Text('التقييم · ${_index + 1} / ${tasks.length}'),
          actions: [
            if (!_locked)
              DiscardFormDraftButton(controller: _formDraft, enabled: !_saving),
            IconButton(
              icon: const Icon(Icons.summarize_outlined),
              tooltip: 'ملخص التقييم',
              onPressed: _saving ? null : _openSummary,
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            const PrototypeNote(),
            if (!_locked) FormDraftStatus(controller: _formDraft),
            if (_draftError != null) Text(_draftError!),
            LinearProgressIndicator(
              value: (_index + 1) / tasks.length,
              minHeight: 6,
              borderRadius: BorderRadius.circular(10),
            ),
            const SizedBox(height: 15),
            Text(
              'البطاقة ${card.number}: ${card.title}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              'تاريخ التقييم: ${_assessment.assessedOn ?? 'غير موثق في السجل القديم'}',
            ),
            Text(
              'الصف وقت التقييم: ${_assessment.gradeAtAssessment ?? 'غير موثق في السجل القديم'}',
            ),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 14),
                    SelectableText(
                      task.prompt,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    if (task.instruction.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(task.instruction),
                    ],
                  ],
                ),
              ),
            ),
            Card(
              child: ExpansionTile(
                title: const Text('مرجع التصحيح (للمختصة فقط)'),
                leading: const Icon(Icons.menu_book_outlined),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: SelectableText(task.reference),
                    ),
                  ),
                ],
              ),
            ),
            if (_locked)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('هذا التقييم معتمد ولا يمكن تعديله.'),
              ),
            const SectionHeading('تسجيل الأداء'),
            const Text('حالة تنفيذ المهمة'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _option(
                  'لم تُجرَ',
                  ItemExecution.notDone,
                  _execution,
                  (value) => _edit(() => _execution = value),
                ),
                _option(
                  'أُجريت',
                  ItemExecution.performed,
                  _execution,
                  (value) => _edit(() => _execution = value),
                ),
                _option(
                  'تعذّر',
                  ItemExecution.unable,
                  _execution,
                  (value) => _edit(() => _execution = value),
                ),
              ],
            ),
            if (_execution == ItemExecution.performed) ...[
              const SizedBox(height: 18),
              const Text('حكم المختصة على الأداء'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (task.isObjective)
                    _option<ItemJudgment>(
                      'صحيح مستقل',
                      ItemJudgment.independentCorrect,
                      _judgment,
                      (v) => _edit(() => _judgment = v),
                    ),
                  if (task.isObjective)
                    _option<ItemJudgment>(
                      'صحيح بمساعدة/جزئي',
                      ItemJudgment.supportedCorrect,
                      _judgment,
                      (v) => _edit(() => _judgment = v),
                    ),
                  if (task.isObjective)
                    _option<ItemJudgment>(
                      'غير صحيح',
                      ItemJudgment.incorrect,
                      _judgment,
                      (v) => _edit(() => _judgment = v),
                    ),
                  _option<ItemJudgment>(
                    'وصفي، غير قابل للتصحيح العددي',
                    ItemJudgment.notScorable,
                    _judgment,
                    (v) => _edit(() => _judgment = v),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              DropdownButtonFormField<SupportLevel>(
                key: ValueKey(_task.id),
                initialValue: _support,
                decoration: const InputDecoration(labelText: 'مستوى المساعدة'),
                items: const [
                  DropdownMenuItem(
                    value: SupportLevel.independent,
                    child: Text('مستقل'),
                  ),
                  DropdownMenuItem(
                    value: SupportLevel.verbal,
                    child: Text('لفظي'),
                  ),
                  DropdownMenuItem(
                    value: SupportLevel.partial,
                    child: Text('جزئي'),
                  ),
                  DropdownMenuItem(
                    value: SupportLevel.full,
                    child: Text('كلي'),
                  ),
                ],
                onChanged: !_canEdit
                    ? null
                    : (value) => _edit(() => _support = value ?? _support),
              ),
              const SizedBox(height: 16),
              TextField(
                enabled: _canEdit,
                controller: _response,
                maxLength: 160,
                decoration: const InputDecoration(
                  labelText: 'استجابة مختصرة غير تعريفية (اختياري)',
                  helperText: 'لا تُدخل أسماء أشخاص أو بيانات صحية',
                ),
              ),
            ],
            if (task.isReading && _execution == ItemExecution.performed) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      enabled: _canEdit,
                      controller: _readingSeconds,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'زمن القراءة بالثواني',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      enabled: _canEdit,
                      controller: _readingErrors,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'عدد الأخطاء',
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (task.isReading && _execution == ItemExecution.performed)
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      enabled: _canEdit,
                      controller: _wordsRead,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'عدد الكلمات المقروءة',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      enabled: _canEdit,
                      controller: _selfCorrections,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'التصحيح الذاتي',
                      ),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 12),
            TextField(
              enabled: _canEdit,
              controller: _notes,
              maxLength: 500,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'ملاحظات الأداء / سبب التعذّر (اختياري)',
                helperText: 'ملاحظات تربوية غير تعريفية؛ بدون أسماء أو تشخيصات',
              ),
            ),
            if (structuredKeysForTask(task.id).isNotEmpty) ...[
              const SectionHeading('ملاحظات الأداء المنظمة'),
              const Text(
                'وصف تربوي فقط. طريقة مسك القلم أو استخدام الرسم لا تدل وحدها على تشخيص، ولا تُصحح هذه الحقول تلقائيًا.',
              ),
              for (final key in structuredKeysForTask(task.id))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: TextField(
                    key: ValueKey('structured:${task.id}:$key'),
                    enabled: _canEdit,
                    controller: _structured[key],
                    maxLength: 1000,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: structuredObservationLabels[key],
                      helperText: 'دون أسماء أو بيانات اتصال أو معلومات صحية',
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 18),
            if (!_locked)
              Row(
                children: [
                  if (_index > 0) ...[
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _saving
                            ? null
                            : () => _saveAndMove(forward: false),
                        child: const Text('حفظ والسابق'),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: FilledButton(
                      onPressed: _saving
                          ? null
                          : () => _saveAndMove(forward: true),
                      child: Text(
                        _index == tasks.length - 1
                            ? 'حفظ ومراجعة'
                            : 'حفظ والتالي',
                      ),
                    ),
                  ),
                ],
              )
            else
              Column(
                children: [
                  Row(
                    children: [
                      if (_index > 0)
                        TextButton(
                          onPressed: () => setState(() {
                            _index--;
                            _loadTask();
                          }),
                          child: const Text('البند السابق'),
                        ),
                      if (_index < tasks.length - 1)
                        TextButton(
                          onPressed: () => setState(() {
                            _index++;
                            _loadTask();
                          }),
                          child: const Text('البند التالي'),
                        ),
                    ],
                  ),
                  FilledButton(
                    onPressed: _openSummary,
                    child: const Text('عرض النتائج المعتمدة'),
                  ),
                ],
              ),
            const SizedBox(height: 10),
            const Text(
              'تُحفظ مدخلات النموذج مشفّرة على هذا الجهاز. الحفظ الصريح وحده يضيف نتيجة البند إلى سجل التقييم.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _option<T>(
    String text,
    T value,
    T? selected,
    ValueChanged<T> onChosen,
  ) {
    return ChoiceChip(
      label: Text(text),
      selected: value == selected,
      onSelected: !_canEdit ? null : (_) => onChosen(value),
    );
  }
}

class AssessmentSummaryScreen extends StatefulWidget {
  const AssessmentSummaryScreen({
    super.key,
    required this.state,
    required this.assessmentId,
  });
  final AppState state;
  final String assessmentId;

  @override
  State<AssessmentSummaryScreen> createState() =>
      _AssessmentSummaryScreenState();
}

class _AssessmentSummaryScreenState extends State<AssessmentSummaryScreen> {
  late final TextEditingController _strengths;
  late final TextEditingController _needs;
  late final FormDraftController _formDraft;
  bool _busy = false;
  bool _privacyReviewed = false;
  bool _restorationFailed = false;
  String? _draftError;
  bool get _approved =>
      widget.state.assessmentById(widget.assessmentId).status ==
      AssessmentStatus.approved;

  @override
  void initState() {
    super.initState();
    final assessment = widget.state.assessmentById(widget.assessmentId);
    _strengths = TextEditingController(text: assessment.strengths);
    _needs = TextEditingController(text: assessment.needs);
    _formDraft = FormDraftController(
      state: widget.state,
      key: 'assessment-summary:${widget.assessmentId}',
      validate: (value) => educationalTextIssue([
        value['strengths'] as String,
        value['needs'] as String,
      ]),
    );
    final restored = _formDraft.restored;
    if (restored != null && !_approved) {
      try {
        final issue = _formDraft.validate?.call(restored);
        if (issue != null) {
          throw FormatException(issue);
        }
        _strengths.text = restored['strengths'] as String;
        _needs.text = restored['needs'] as String;
      } catch (_) {
        _restorationFailed = true;
        _draftError =
            'تعذّر فتح مسودة الملخص. بقيت محفوظة ويمكن إلغاؤها صراحةً.';
      }
    }
    _strengths.addListener(_changed);
    _needs.addListener(_changed);
  }

  void _changed() {
    if (_approved || _busy || _restorationFailed) {
      return;
    }
    _formDraft.update({'strengths': _strengths.text, 'needs': _needs.text});
  }

  @override
  void dispose() {
    _formDraft.dispose();
    _strengths.dispose();
    _needs.dispose();
    super.dispose();
  }

  Future<void> _persist({required bool approve}) async {
    if (_busy || _restorationFailed) {
      return;
    }
    setState(() => _busy = true);
    try {
      await _formDraft.flush();
      final assessment = widget.state.assessmentById(widget.assessmentId);
      if (tasksForAge(assessment.ageGroup).any(
        (task) =>
            widget.state.draftFor(
              'assessment-form:${widget.assessmentId}:${task.id}',
            ) !=
            null,
      )) {
        throw StateError(
          'احفظي مدخلات البنود أو ألغِي مسوداتها قبل اعتماد الملخص.',
        );
      }
      await widget.state.saveSummary(
        assessmentId: widget.assessmentId,
        strengths: _strengths.text,
        needs: _needs.text,
        privacyReviewed: _privacyReviewed,
        draftKey: _formDraft.key,
      );
      _formDraft.acknowledgeSaved();
      if (approve) {
        await widget.state.approveAssessment(widget.assessmentId);
      }
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            approve ? 'اعتمدت المختصة التقييم.' : 'حُفظ ملخص التقييم.',
          ),
        ),
      );
      setState(() {});
    } catch (error) {
      if (mounted) {
        showError(context, error);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.state,
    builder: (context, _) {
      final assessment = widget.state.assessmentById(widget.assessmentId);
      final tasks = tasksForAge(assessment.ageGroup);
      final approved = assessment.status == AssessmentStatus.approved;
      final completed = assessment.results.values
          .where((value) => value.execution == ItemExecution.performed)
          .length;
      return FormDraftGuard(
        controller: _formDraft,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('مراجعة التقييم'),
            actions: [
              if (!approved)
                DiscardFormDraftButton(controller: _formDraft, enabled: !_busy),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(18),
            children: [
              const PrototypeNote(),
              if (!approved) FormDraftStatus(controller: _formDraft),
              if (_draftError != null) Text(_draftError!),
              const SectionHeading(
                'ملخص النتائج',
                subtitle:
                    'أرقام وصفية داخل هذا التقييم فقط، وليست درجة تشخيصية',
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'حالة التقييم: ${approved ? 'معتمد' : 'قيد المراجعة'}',
                      ),
                      Text('المهام المنفّذة: $completed من ${tasks.length}'),
                      Text('نسخة القالب: ${assessment.templateVersion}'),
                      if (assessment.approvedAt != null)
                        Text(
                          'تاريخ الاعتماد: ${assessment.approvedAt!.substring(0, 10)}',
                        ),
                    ],
                  ),
                ),
              ),
              for (final domain in ['القراءة', 'الكتابة', 'الرياضيات'])
                _domainSummary(context, domain, assessment, tasks),
              const SectionHeading('الرأي المهني للمختصة'),
              TextField(
                enabled: !approved && !_busy && !_restorationFailed,
                controller: _strengths,
                minLines: 2,
                maxLines: 4,
                maxLength: 350,
                decoration: const InputDecoration(
                  labelText: 'نقاط القوة (مطلوب للاعتماد)',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                enabled: !approved && !_busy && !_restorationFailed,
                controller: _needs,
                minLines: 2,
                maxLines: 4,
                maxLength: 350,
                decoration: const InputDecoration(
                  labelText: 'المهارات التي تحتاج إلى تطوير (مطلوب للاعتماد)',
                ),
              ),
              const SizedBox(height: 10),
              if (!approved)
                CheckboxListTile(
                  value: _privacyReviewed,
                  onChanged: _busy || _restorationFailed
                      ? null
                      : (v) => setState(() => _privacyReviewed = v ?? false),
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'راجعت النصوص وأؤكد خلوها من الأسماء وبيانات التعريف والتشخيص.',
                  ),
                ),
              if (approved)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'هذا التقييم معتمد ومجمّد. يُنشأ تقييم آخر لإعادة القياس.',
                    ),
                  ),
                )
              else ...[
                OutlinedButton(
                  onPressed: _busy || _restorationFailed
                      ? null
                      : () => _persist(approve: false),
                  child: const Text('حفظ الملخص للمراجعة'),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  icon: const Icon(Icons.verified_outlined),
                  onPressed: _busy || _restorationFailed
                      ? null
                      : () => _persist(approve: true),
                  label: const Text('اعتماد التقييم بقرار المختصة'),
                ),
              ],
              const SizedBox(height: 20),
              const Text(
                'تُزامن النتائج مع خادم الحساب. لا تُرسل إجابات البنود أو ملاحظاتها إلى الذكاء الاصطناعي تلقائيًا. الأرقام وصفية وليست تشخيصًا.',
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _domainSummary(
    BuildContext context,
    String domain,
    AssessmentRecord assessment,
    List<AssessmentTask> tasks,
  ) {
    final domainTasks = tasks.where((task) => task.domain == domain).toList();
    final objective = domainTasks.where((task) => task.isObjective).toList();
    final judged = objective
        .map((task) => assessment.results[task.id])
        .whereType<AssessmentItemResult>();
    final score = AssessmentScore.fromResults(judged);
    final notDone = domainTasks
        .where(
          (task) =>
              (assessment.results[task.id]?.execution ??
                  ItemExecution.notDone) !=
              ItemExecution.performed,
        )
        .length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              domain,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'صحيح مستقل في البنود الموضوعية القابلة للتصحيح: ${score.label}',
            ),
            Text('بنود لم تُجرَ أو تعذّرت: $notDone (مستبعدة من التصحيح)'),
          ],
        ),
      ),
    );
  }
}
