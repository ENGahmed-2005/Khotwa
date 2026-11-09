import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/app_state.dart';
import '../core/form_draft.dart';
import '../models/assessment.dart';
import '../models/initial_assessment.dart';
import '../widgets/common.dart';

class InitialAssessmentScreen extends StatefulWidget {
  const InitialAssessmentScreen({
    super.key,
    required this.state,
    required this.assessmentId,
  });
  final AppState state;
  final String assessmentId;
  @override
  State<InitialAssessmentScreen> createState() =>
      _InitialAssessmentScreenState();
}

class _InitialAssessmentScreenState extends State<InitialAssessmentScreen> {
  late InitialAssessmentRecord _draft;
  late final TextEditingController _reason;
  late final TextEditingController _date;
  final List<Map<String, dynamic>> _domains = [];
  final List<Map<String, String>> _strategies = [];
  bool _privacy = false, _busy = false;
  String? _error;
  late final FormDraftController _formDraft;
  bool _restorationFailed = false;

  @override
  void initState() {
    super.initState();
    _draft = widget.state.initialAssessmentById(widget.assessmentId);
    _formDraft = FormDraftController(
      state: widget.state,
      key: 'initial-form:${widget.assessmentId}',
      validate: (value) => educationalTextIssue([
        value['alternativeReason'] as String,
        for (final raw in value['domains'] as List) ...[
          for (final key in [
            'label',
            'currentPerformance',
            'strengths',
            'needs',
          ])
            (raw as Map)[key] as String,
          for (final skill in raw['skills'] as List) ...[
            (skill as Map)['label'] as String,
            skill['evidence'] as String,
          ],
        ],
        for (final raw in value['previousStrategies'] as List)
          ...(raw as Map).values.cast<String>(),
      ]),
    );
    final restored = _formDraft.restored;
    if (restored != null && !_draft.approved) {
      try {
        _draft = _draft.copyWith(
          assessedOn: restored['assessedOn'] as String,
          method: restored['method'] as String,
          alternativeReason: restored['alternativeReason'] as String,
          academicAssessmentId: restored['academicAssessmentId'] as String?,
          domains: (restored['domains'] as List)
              .map(
                (d) =>
                    InitialDomain.fromJson(Map<String, dynamic>.from(d as Map)),
              )
              .toList(),
          previousStrategies: (restored['previousStrategies'] as List)
              .map((s) => Map<String, String>.from(s as Map))
              .toList(),
          privacyReviewed: false,
        );
      } catch (_) {
        _restorationFailed = true;
        _error =
            'تعذّر فتح مسودة النموذج؛ حُفظت دون تغيير. ألغِيها صراحةً لإنشاء مدخلات جديدة.';
      }
    }
    _reason = TextEditingController(text: _draft.alternativeReason);
    _date = TextEditingController(text: _draft.assessedOn);
    _domains.addAll(_draft.domains.map((d) => d.toJson()));
    _strategies.addAll(_draft.previousStrategies.map((s) => {...s}));
    _privacy = _draft.approved;
    _reason.addListener(_changed);
    _date.addListener(_changed);
  }

  void _changed() {
    if (_draft.approved || _restorationFailed) return;
    _formDraft.update({
      'assessedOn': _date.text,
      'method': _draft.method,
      'academicAssessmentId': _draft.academicAssessmentId,
      'alternativeReason': _reason.text,
      'domains': _domains,
      'previousStrategies': _strategies,
    });
  }

  void _edit(VoidCallback action) {
    if (_busy || _draft.approved) return;
    setState(action);
    _changed();
  }

  @override
  void dispose() {
    _formDraft.dispose();
    _reason.dispose();
    _date.dispose();
    super.dispose();
  }

  Future<void> _save({bool approve = false}) async {
    if (_restorationFailed) return;
    final next = _draft.copyWith(
      assessedOn: _date.text.trim(),
      alternativeReason: _reason.text.trim(),
      domains: _domains.map((d) => InitialDomain.fromJson(d)).toList(),
      previousStrategies: _strategies,
      privacyReviewed: _privacy,
    );
    final issue = next.validate(forApproval: approve);
    if (issue != null) {
      setState(() => _error = issue);
      return;
    }
    if (approve) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('اعتماد التقييم الأولي'),
          content: const Text(
            'أؤكد أن المستويات وشواهد الأداء ونقاط القوة والاحتياج تعكس تقييمي الفعلي، وأن النصوص خالية من الهوية والمعلومات الصحية. سيصبح هذا التقييم للقراءة فقط.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('مراجعة'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('أوافق وأعتمد'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _formDraft.flush();
      await widget.state.saveInitialAssessment(
        next,
        approve: approve,
        draftKey: _formDraft.key,
      );
      _formDraft.acknowledgeSaved();
      _draft = widget.state.initialAssessmentById(widget.assessmentId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              approve
                  ? 'تم اعتماد التقييم وحفظه محليًا.'
                  : 'حُفظت المسودة محليًا.',
            ),
          ),
        );
      }
    } catch (e) {
      final saved = widget.state.initialAssessmentById(widget.assessmentId);
      if (saved.approved) _draft = saved;
      _error = e is StateError
          ? e.message.toString()
          : 'تعذر الحفظ الآمن؛ احتُفظ بالمدخلات على الشاشة.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addDomain() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('اختاري مجالًا تربويًا'),
        children: [
          for (final domain in educationalDomains.entries.where(
            (d) => !_domains.any((v) => v['id'] == d.key),
          ))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, domain.key),
              child: Text(domain.value['label']!),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'custom'),
            child: const Text('مجال مخصص'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    String id = choice, label = educationalDomains[choice]?['label'] ?? '';
    if (choice == 'custom') {
      final value = await _askText('اسم مجال تربوي مخصص');
      if (value == null || value.trim().isEmpty || !mounted) return;
      id = 'custom.${const Uuid().v4()}';
      label = value.trim();
    }
    _edit(
      () => _domains.add({
        'id': id,
        'label': label,
        'currentPerformance': '',
        'strengths': '',
        'needs': '',
        'skills': <Map<String, dynamic>>[],
      }),
    );
  }

  Future<String?> _askText(String title) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          maxLength: 120,
          decoration: const InputDecoration(
            helperText: 'دون أسماء أو تشخيص أو بيانات تعريفية',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('إضافة'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _addSkill(Map<String, dynamic> domain) async {
    final library = educationalDomains[domain['id']];
    final skills = domain['skills'] as List;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('اختاري مهارة'),
        children: [
          if (library != null)
            for (final entry in library.entries.where(
              (e) =>
                  e.key != 'label' &&
                  !skills.any((s) => (s as Map)['id'] == e.key),
            ))
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, entry.key),
                child: Text(entry.value),
              ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'custom'),
            child: const Text('مهارة مخصصة'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    final custom = choice == 'custom'
        ? await _askText('اسم مهارة تعليمية قابلة للملاحظة')
        : null;
    if (!mounted ||
        (choice == 'custom' && (custom == null || custom.trim().isEmpty))) {
      return;
    }
    _edit(
      () => skills.add({
        'id': choice == 'custom' ? 'custom.${const Uuid().v4()}' : choice,
        'label': custom?.trim() ?? library![choice]!,
        'level': 'developing',
        'evidence': '',
      }),
    );
  }

  Widget _text(
    String label,
    String initial,
    ValueChanged<String> changed, {
    int maxLines = 3,
    int maxLength = 2000,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: TextFormField(
      initialValue: initial,
      readOnly: _draft.approved || _busy,
      maxLines: maxLines,
      maxLength: maxLength,
      decoration: InputDecoration(
        labelText: label,
        helperText: 'وصف تربوي دون أسماء أو بيانات صحية',
        border: const OutlineInputBorder(),
      ),
      onChanged: (value) {
        changed(value);
        _changed();
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final readonly = _draft.approved || _busy;
    final cards = widget.state
        .assessmentsFor(_draft.studentId)
        .where((a) => a.status == AssessmentStatus.approved)
        .toList();
    return FormDraftGuard(
      controller: _formDraft,
      child: Scaffold(
        appBar: AppBar(
          actions: [
            if (!_draft.approved)
              DiscardFormDraftButton(controller: _formDraft, enabled: !_busy),
          ],
          title: Text(
            _draft.approved ? 'تقييم أولي معتمد' : 'التقييم الأولي الحر',
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            const PrototypeNote(),
            if (!_draft.approved) FormDraftStatus(controller: _formDraft),
            const Text(
              'هذا توصيف أداء تربوي، وليس تشخيصًا طبيًا أو نفسيًا. تُحال مسائل التشخيص للمختصين خارج التطبيق. لا تكتبي الاسم أو تاريخ الميلاد أو معلومات الاتصال.',
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            TextField(
              controller: _date,
              readOnly: readonly,
              decoration: const InputDecoration(
                labelText: 'تاريخ التقييم YYYY-MM-DD',
              ),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _draft.method,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'أسلوب التقييم'),
              items: assessmentMethods.entries
                  .map(
                    (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                  )
                  .toList(),
              onChanged: readonly
                  ? null
                  : (v) => _edit(() => _draft = _draft.copyWith(method: v)),
            ),
            if (_draft.method == 'academicCards')
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: DropdownButtonFormField<String>(
                  initialValue:
                      cards.any((c) => c.id == _draft.academicAssessmentId)
                      ? _draft.academicAssessmentId
                      : null,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'البطاقة المعتمدة مصدر النتائج',
                  ),
                  items: cards
                      .map(
                        (c) => DropdownMenuItem(
                          value: c.id,
                          child: Text(
                            '${c.ageGroup} · ${c.createdAt.substring(0, 10)}',
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: readonly
                      ? null
                      : (v) => _edit(
                          () =>
                              _draft = _draft.copyWith(academicAssessmentId: v),
                        ),
                ),
              ),
            TextField(
              controller: _reason,
              readOnly: readonly,
              maxLength: 2000,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'سبب اختيار التقييم البديل / وصف المصدر',
                helperText: 'مطلوب لاعتماد تقييم خارج البطاقات',
              ),
            ),
            for (final domain in _domains)
              Card(
                key: ValueKey(domain['id']),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              domain['label'] as String,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                          if (!readonly)
                            IconButton(
                              tooltip: 'إزالة المجال',
                              onPressed: () =>
                                  _edit(() => _domains.remove(domain)),
                              icon: const Icon(Icons.remove_circle_outline),
                            ),
                        ],
                      ),
                      for (final entry in const {
                        'currentPerformance': 'مستوى الأداء الحالي',
                        'strengths': 'نقاط القوة',
                        'needs': 'الاحتياجات الفردية',
                      }.entries)
                        _text(
                          entry.value,
                          domain[entry.key] as String,
                          (v) => domain[entry.key] = v,
                        ),
                      for (final raw in domain['skills'] as List)
                        _skillCard(
                          domain,
                          raw as Map<String, dynamic>,
                          readonly,
                        ),
                      if (!readonly)
                        OutlinedButton.icon(
                          onPressed: () => _addSkill(domain),
                          icon: const Icon(Icons.add),
                          label: const Text('إضافة مهارة وشاهد أداء'),
                        ),
                    ],
                  ),
                ),
              ),
            if (!readonly)
              OutlinedButton.icon(
                onPressed: _addDomain,
                icon: const Icon(Icons.add),
                label: const Text('إضافة مجال'),
              ),
            const SectionHeading('استراتيجيات سابقة (اختياري)'),
            for (final strategy in _strategies)
              Card(
                key: ObjectKey(strategy),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    children: [
                      _text(
                        'اسم الاستراتيجية',
                        strategy['name']!,
                        (v) => strategy['name'] = v,
                        maxLines: 1,
                        maxLength: 120,
                      ),
                      _text(
                        'نتيجتها الفعلية',
                        strategy['result']!,
                        (v) => strategy['result'] = v,
                      ),
                      if (!readonly)
                        TextButton(
                          onPressed: () =>
                              _edit(() => _strategies.remove(strategy)),
                          child: const Text('إزالة الاستراتيجية'),
                        ),
                    ],
                  ),
                ),
              ),
            if (!readonly)
              TextButton(
                onPressed: () =>
                    _edit(() => _strategies.add({'name': '', 'result': ''})),
                child: const Text('إضافة استراتيجية سابقة'),
              ),
            if (_draft.approved)
              Text(
                'معتمد في ${_draft.approvedAt?.substring(0, 10)} · ${syncStatusLabel(widget.state.stateFor(_draft.id))}',
              )
            else ...[
              CheckboxListTile(
                value: _privacy,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _privacy = v ?? false),
                title: const Text(
                  'راجعت النصوص: أوصاف أداء فعلية دون هوية أو معلومات صحية',
                ),
              ),
              FilledButton(
                onPressed: _busy ? null : () => _save(),
                child: const Text('حفظ مسودة التقييم محليًا'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : () => _save(approve: true),
                child: const Text('مراجعة واعتماد التقييم'),
              ),
              const Text(
                'احفظي المسودة قبل مغادرة الشاشة. الاعتماد يحفظ التقييم للقراءة فقط، والتوليد يحتاج مزامنته أولًا.',
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _skillCard(
    Map<String, dynamic> domain,
    Map<String, dynamic> skill,
    bool readonly,
  ) => Card(
    key: ValueKey(skill['id']),
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(skill['label'] as String),
          DropdownButtonFormField<String>(
            initialValue: skill['level'] as String,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'مستوى الأداء بحكم المختصة',
            ),
            items: performanceLevels.entries
                .map(
                  (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                )
                .toList(),
            onChanged: readonly
                ? null
                : (v) => _edit(() => skill['level'] = v!),
          ),
          _text(
            'شاهد الأداء ومصدر النتيجة',
            skill['evidence'] as String,
            (v) => skill['evidence'] = v,
          ),
          if (!readonly)
            TextButton(
              onPressed: () =>
                  _edit(() => (domain['skills'] as List).remove(skill)),
              child: const Text('إزالة المهارة'),
            ),
        ],
      ),
    ),
  );
}
