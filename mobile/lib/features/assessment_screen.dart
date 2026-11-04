import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../data/assessment_templates.dart';
import '../models/assessment.dart';
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
  bool _saving = false;

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
    _loadTask();
  }

  void _loadTask() {
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
  }

  @override
  void dispose() {
    _response.dispose();
    _notes.dispose();
    _readingSeconds.dispose();
    _readingErrors.dispose();
    _wordsRead.dispose();
    _selfCorrections.dispose();
    super.dispose();
  }

  int? _intOrNull(String text) =>
      text.trim().isEmpty ? null : int.tryParse(text.trim());

  Future<void> _saveAndMove({required bool forward}) async {
    if (_locked || _saving) {
      return;
    }
    setState(() => _saving = true);
    try {
      final seconds = _intOrNull(_readingSeconds.text);
      final errors = _intOrNull(_readingErrors.text);
      if ((_readingSeconds.text.trim().isNotEmpty && seconds == null) ||
          (_readingErrors.text.trim().isNotEmpty && errors == null) ||
          (seconds != null && seconds < 0) ||
          (errors != null && errors < 0)) {
        throw StateError(
          'مدة القراءة والأخطاء يجب أن تكون أعدادًا صحيحة غير سالبة.',
        );
      }
      await widget.state.saveResult(
        assessmentId: widget.assessmentId,
        itemId: _task.id,
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
        ),
      );
      if (!mounted) {
        return;
      }
      if (forward && _index == _tasks.length - 1) {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => AssessmentSummaryScreen(
              state: widget.state,
              assessmentId: widget.assessmentId,
            ),
          ),
        );
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
    final card = cardsForAge(_assessment.ageGroup)
        .firstWhere((card) => card.number == task.cardNumber);
    return Scaffold(
      appBar: AppBar(
        title: Text('التقييم · ${_index + 1} / ${tasks.length}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.summarize_outlined),
            tooltip: 'ملخص التقييم',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => AssessmentSummaryScreen(
                  state: widget.state,
                  assessmentId: widget.assessmentId,
                ),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
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
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.bold),
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
                (value) => setState(() => _execution = value),
              ),
              _option(
                'أُجريت',
                ItemExecution.performed,
                _execution,
                (value) => setState(() => _execution = value),
              ),
              _option(
                'تعذّر',
                ItemExecution.unable,
                _execution,
                (value) => setState(() => _execution = value),
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
                    (v) => setState(() => _judgment = v),
                  ),
                if (task.isObjective)
                  _option<ItemJudgment>(
                    'صحيح بمساعدة/جزئي',
                    ItemJudgment.supportedCorrect,
                    _judgment,
                    (v) => setState(() => _judgment = v),
                  ),
                if (task.isObjective)
                  _option<ItemJudgment>(
                    'غير صحيح',
                    ItemJudgment.incorrect,
                    _judgment,
                    (v) => setState(() => _judgment = v),
                  ),
                _option<ItemJudgment>(
                  'وصفي، غير قابل للتصحيح العددي',
                  ItemJudgment.notScorable,
                  _judgment,
                  (v) => setState(() => _judgment = v),
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
                DropdownMenuItem(value: SupportLevel.full, child: Text('كلي')),
              ],
              onChanged: _locked
                  ? null
                  : (value) => setState(() => _support = value ?? _support),
            ),
            const SizedBox(height: 16),
            TextField(
              enabled: !_locked,
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
                    enabled: !_locked,
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
                    enabled: !_locked,
                    controller: _readingErrors,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(labelText: 'عدد الأخطاء'),
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
                    enabled: !_locked,
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
                    enabled: !_locked,
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
            enabled: !_locked,
            controller: _notes,
            maxLength: 500,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'ملاحظات الأداء / سبب التعذّر (اختياري)',
              helperText: 'ملاحظات تربوية غير تعريفية؛ بدون أسماء أو تشخيصات',
            ),
          ),
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
            FilledButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => AssessmentSummaryScreen(
                    state: widget.state,
                    assessmentId: widget.assessmentId,
                  ),
                ),
              ),
              child: const Text('عرض النتائج المعتمدة'),
            ),
          const SizedBox(height: 10),
          const Text(
            'تنبيه: احفظ المهمة قبل الرجوع إلى الشاشة السابقة.',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ],
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
      onSelected: _locked ? null : (_) => onChosen(value),
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
  bool _busy = false;
  bool _privacyReviewed = false;

  @override
  void initState() {
    super.initState();
    final assessment = widget.state.assessmentById(widget.assessmentId);
    _strengths = TextEditingController(text: assessment.strengths);
    _needs = TextEditingController(text: assessment.needs);
  }

  @override
  void dispose() {
    _strengths.dispose();
    _needs.dispose();
    super.dispose();
  }

  Future<void> _persist({required bool approve}) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.state.saveSummary(
        assessmentId: widget.assessmentId,
        strengths: _strengths.text,
        needs: _needs.text,
        privacyReviewed: _privacyReviewed,
      );
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
      return Scaffold(
        appBar: AppBar(title: const Text('مراجعة التقييم')),
        body: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            const PrototypeNote(),
            const SectionHeading(
              'ملخص النتائج',
              subtitle: 'أرقام وصفية داخل هذا التقييم فقط، وليست درجة تشخيصية',
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
              enabled: !approved,
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
              enabled: !approved,
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
                onChanged: (v) => setState(() => _privacyReviewed = v ?? false),
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
                onPressed: _busy ? null : () => _persist(approve: false),
                child: const Text('حفظ الملخص للمراجعة'),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                icon: const Icon(Icons.verified_outlined),
                onPressed: _busy ? null : () => _persist(approve: true),
                label: const Text('اعتماد التقييم بقرار المختصة'),
              ),
            ],
            const SizedBox(height: 20),
            const Text(
              'تُزامن النتائج مع خادم الحساب. لا يُرسل أي محتوى لخدمة ذكاء اصطناعي في هذا التسليم. الأرقام وصفية وليست تشخيصًا.',
            ),
          ],
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
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
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
