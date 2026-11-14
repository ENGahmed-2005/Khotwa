import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/auth_state.dart';
import '../core/feature_api.dart';
import '../core/share_export.dart';
import '../widgets/common.dart';

class ActivitiesScreen extends StatefulWidget {
  const ActivitiesScreen({
    super.key,
    required this.auth,
    this.api,
    this.draftStore,
  });
  final AuthState auth;
  final FeatureApi? api;
  final FeatureDraftStore? draftStore;
  @override
  State<ActivitiesScreen> createState() => _ActivitiesScreenState();
}

class _ActivitiesScreenState extends State<ActivitiesScreen> {
  static const _standardTools = {
    'board': 'السبورة',
    'pencils': 'الأقلام',
    'cards': 'البطاقات',
    'paper': 'الأوراق',
    'colors': 'الألوان',
  };
  static const _domains = {
    'reading': 'القراءة',
    'writing': 'الكتابة والإملاء',
    'math': 'الرياضيات',
    'foundations': 'المهارات التأسيسية',
    'attention': 'الانتباه والمشاركة',
    'communication': 'التواصل واللغة',
    'lifeSkills': 'المهارات الحياتية',
    'custom': 'مجال مخصص من الخطة',
  };
  static const _types = {
    'worksheet': 'ورقة عمل',
    'cards': 'بطاقات',
    'story': 'قصة',
    'game': 'لعبة تعليمية',
    'sensory': 'نشاط حسي',
  };
  static const _difficultyLabels = {
    'introductory': 'تمهيدي',
    'practice': 'تدريب',
    'generalization': 'تعميم',
  };
  late final FeatureApi _api;
  late final FeatureDraftStore _store;
  List<Map<String, dynamic>> _plans = [], _activities = [], _tools = [];
  final _selectedTools = <String>{};
  final _sections = {
    'title': true,
    'goal': true,
    'duration': true,
    'alternatives': true,
    'teacherNotes': true,
  };
  String? _planId, _goalId, _operationId, _error;
  String _domain = 'reading',
      _type = 'cards',
      _difficulty = 'practice',
      _mode = 'individual';
  int _minutes = 20, _toolsRevision = 0;
  final _minutesInput = TextEditingController(text: '20');
  bool _toolsDirty = false;
  bool _busy = true,
      _storageReady = false,
      _configured = false,
      _reviewed = false,
      _synthetic = false,
      _confirmed = false;
  Map<String, dynamic>? _preview;

  Map<String, dynamic>? get _plan =>
      _plans.where((p) => p['id'] == _planId).firstOrNull;
  Map<String, dynamic>? get _planData =>
      _plan == null ? null : Map<String, dynamic>.from(_plan!['data'] as Map);
  List<Map<String, dynamic>> get _goals => _planData == null
      ? []
      : [
          for (final item in (_planData!['content'] as Map)['goals'] as List)
            Map<String, dynamic>.from(item as Map),
        ];

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? FeatureApi(widget.auth);
    _store =
        widget.draftStore ?? FeatureDraftStore(widget.auth, 'activity-inputs');
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final data = await _store.read();
      _plans = [
        for (final item in data['plans'] as List? ?? [])
          Map<String, dynamic>.from(item as Map),
      ];
      _activities = [
        for (final item in data['activities'] as List? ?? [])
          Map<String, dynamic>.from(item as Map),
      ];
      _tools = [
        for (final item in data['tools'] as List? ?? [])
          Map<String, dynamic>.from(item as Map),
      ];
      _toolsRevision = data['toolsRevision'] as int? ?? 0;
      _configured = data['configured'] == true;
      _toolsDirty = data['toolsDirty'] == true;
      _planId = data['planId'] as String?;
      _goalId = data['goalId'] as String?;
      _domain = data['domain'] as String? ?? _domain;
      _type = data['type'] as String? ?? _type;
      _difficulty = data['difficulty'] as String? ?? _difficulty;
      _mode = data['mode'] as String? ?? _mode;
      _minutes = data['minutes'] as int? ?? _minutes;
      _minutesInput.text = '$_minutes';
      _selectedTools.addAll(List<String>.from(data['toolIds'] as List? ?? []));
      _preview = data['preview'] == null
          ? null
          : Map<String, dynamic>.from(data['preview'] as Map);
      _operationId = data['operationId'] as String?;
      if (!_domains.containsKey(_domain) ||
          !_types.containsKey(_type) ||
          !_difficultyLabels.containsKey(_difficulty) ||
          !['individual', 'group'].contains(_mode)) {
        throw StateError('مدخلات محفوظة غير صالحة.');
      }
      _storageReady = true;
      await _refresh();
    } catch (e) {
      _error = _storageReady
          ? 'تعذّر التحديث. المدخلات والأنشطة المحفوظة متاحة دون اتصال.'
          : 'تعذّر فتح المدخلات المحفوظة بأمان؛ لم تُستبدل البيانات المحلية.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() => _store.write({
    'plans': _plans,
    'activities': _activities,
    'tools': _tools,
    'toolsRevision': _toolsRevision,
    'configured': _configured,
    'toolsDirty': _toolsDirty,
    'planId': _planId,
    'goalId': _goalId,
    'domain': _domain,
    'type': _type,
    'difficulty': _difficulty,
    'mode': _mode,
    'minutes': _minutes,
    'toolIds': _selectedTools.toList(),
    'preview': _preview,
    'operationId': _operationId,
  });

  @override
  void dispose() {
    _minutesInput.dispose();
    super.dispose();
  }

  void _edit(VoidCallback action) {
    setState(() {
      action();
      _preview = null;
      _operationId = null;
      _confirmed = false;
    });
    unawaited(
      _save().catchError((Object _) {
        if (mounted) {
          setState(() {
            _error = 'تعذّر حفظ التعديل محليًا. أعيدي الحفظ قبل إرسال الطلب.';
          });
        }
      }),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !_storageReady) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    final responses = await Future.wait([
      _api.json('GET', '/v1/records?kind=plan'),
      _api.json('GET', '/v1/records?kind=activity'),
      _api.json('GET', '/v1/activities/tools'),
    ]);
    _plans = [
      for (final item in responses[0]['records'] as List)
        if ((item as Map)['deletedAt'] == null &&
            (item['data'] as Map)['status'] == 'approved')
          Map<String, dynamic>.from(item),
    ];
    _activities = [
      for (final item in responses[1]['records'] as List)
        if ((item as Map)['deletedAt'] == null) Map<String, dynamic>.from(item),
    ];
    if (!_toolsDirty) {
      final savedTools = [
        for (final item in responses[2]['tools'] as List)
          Map<String, dynamic>.from(item as Map),
      ];
      _tools = [
        for (final entry in _standardTools.entries)
          {'id': entry.key, 'label': entry.value},
        ...savedTools.where((tool) => !_standardTools.containsKey(tool['id'])),
      ];
      _toolsRevision = responses[2]['revision'] as int;
      _configured = responses[2]['configured'] == true;
      _selectedTools
        ..clear()
        ..addAll(savedTools.map((tool) => tool['id'] as String));
    }
    if (_plan == null) {
      _planId = null;
      _goalId = null;
      _preview = null;
      _confirmed = false;
    }
    await _save();
  }

  Future<void> _saveTools() async {
    if (_selectedTools.isEmpty) {
      throw StateError('اختاري أداة متاحة واحدة على الأقل.');
    }
    await _save();
    final response = await _api.json(
      'PUT',
      '/v1/activities/tools',
      data: {
        'revision': _toolsRevision,
        'tools': _tools
            .where((tool) => _selectedTools.contains(tool['id']))
            .toList(),
        'privacyReviewed': true,
      },
    );
    _toolsRevision = response['revision'] as int;
    _configured = true;
    _toolsDirty = false;
    _preview = null;
    _confirmed = false;
    await _save();
  }

  Future<void> _makePreview() async {
    if (_planData == null ||
        _goalId == null ||
        !_reviewed ||
        !_synthetic ||
        !_configured ||
        _selectedTools.isEmpty ||
        _minutes < 1 ||
        _minutes > 180) {
      throw StateError(
        'اختاري هدفًا معتمدًا والأدوات واحفظي ملفها، وحددي مدة 1–180 دقيقة وأكّدي مراجعة الخصوصية والبيانات الاصطناعية.',
      );
    }
    final studentId = _planData!['studentId'] as String;
    final student = widget.auth.records!.students
        .where((s) => s.id == studentId)
        .firstOrNull;
    if (student == null) {
      throw StateError('زامني ملف الطالب المرتبط بهذه الخطة أولًا.');
    }
    await _save();
    _preview = await _api.json(
      'POST',
      '/v1/activities/preview',
      data: {
        'studentId': studentId,
        'planId': _planId,
        'goalId': _goalId,
        'grade': student.grade,
        'domain': _domain,
        'difficulty': _difficulty,
        'type': _type,
        'toolIds': _selectedTools.toList(),
        'minutes': _minutes,
        'mode': _mode,
        'privacyReviewed': true,
        'syntheticDataConfirmed': true,
      },
    );
    _operationId = const Uuid().v4();
    _confirmed = false;
    await _save();
  }

  Future<void> _generate() async {
    if (_preview == null ||
        _operationId == null ||
        !_confirmed ||
        !_reviewed ||
        !_synthetic) {
      throw StateError('راجعي الحمولة وأكّدي إرسالها أولًا.');
    }
    await _save();
    final response = await _api.json(
      'POST',
      '/v1/activities/generate',
      timeout: const Duration(seconds: 100),
      data: {
        'previewToken': _preview!['previewToken'],
        'confirmedHash': _preview!['hash'],
        'operationId': _operationId,
        'confirmed': true,
        'syntheticDataConfirmed': true,
      },
    );
    final record = Map<String, dynamic>.from(response['record'] as Map);
    _activities = [
      ..._activities.where((a) => a['id'] != record['id']),
      record,
    ];
    _confirmed = false;
    await _save();
  }

  Future<void> _operationStatus() async {
    if (_operationId == null) return;
    final response = await _api.json(
      'GET',
      '/v1/activities/operations/$_operationId',
    );
    if (response['state'] == 'completed' && response['recordId'] != null) {
      final result = await _api.json(
        'GET',
        '/v1/records/${response['recordId']}',
      );
      final record = Map<String, dynamic>.from(result['record'] as Map);
      if (record['deletedAt'] != null) throw StateError('النشاط محذوف.');
      _activities = [
        ..._activities.where((item) => item['id'] != record['id']),
        record,
      ];
      await _save();
    }
    _error = const {
      'pending': 'الطلب قيد المعالجة؛ لا حاجة لإرساله مرتين.',
      'expired': 'انتهت المهلة. ألغِي الطلب ثم راجعي معاينة جديدة.',
      'cancelled': 'أُلغي الطلب ولن تُحفظ نتيجة متأخرة.',
      'completed': 'اكتمل الطلب واستُعيد النشاط المحفوظ.',
      'failed': 'فشلت المحاولة. راجعي معاينة جديدة لمحاولة أخرى.',
    }[response['state']];
  }

  Future<void> _cancelOperation() async {
    if (_operationId == null) return;
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إلغاء الطلب المعلّق'),
        content: const Text(
          'لن تُحفظ نتيجة متأخرة لهذا الطلب. تبقى المدخلات لإعداد معاينة ومحاولة جديدتين بقرارك.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('رجوع'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('تأكيد إلغاء الطلب'),
          ),
        ],
      ),
    );
    if (answer != true) return;
    await _api.json(
      'POST',
      '/v1/activities/operations/$_operationId/cancel',
      data: {'confirmed': true},
    );
    _preview = null;
    _operationId = null;
    _confirmed = false;
    await _save();
  }

  Future<void> _reloadTools() async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تحميل ملف الأدوات من الخادم'),
        content: const Text(
          'سيستبدل هذا مسودة الأدوات المحلية غير المحفوظة بالنسخة التي تمت مزامنتها. بقية المدخلات تبقى محفوظة.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('الاحتفاظ بمسودتي'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('تحميل نسخة الخادم'),
          ),
        ],
      ),
    );
    if (answer != true) return;
    _toolsDirty = false;
    _preview = null;
    _confirmed = false;
    await _refresh();
  }

  Future<void> _addTool() async {
    final controller = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('أداة متاحة إضافية'),
        content: TextField(
          controller: controller,
          maxLength: 80,
          decoration: const InputDecoration(
            labelText: 'اسم الأداة فقط، دون بيانات طالب',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('إضافة'),
          ),
        ],
      ),
    );
    if (accepted == true && controller.text.trim().isNotEmpty) {
      final tool = {
        'id': 'custom.${const Uuid().v4()}',
        'label': controller.text.trim(),
      };
      _edit(() {
        _tools.add(tool);
        _selectedTools.add(tool['id']!);
        _configured = false;
        _toolsDirty = true;
      });
    }
    controller.dispose();
  }

  Future<void> _approve(Map<String, dynamic> record) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('اعتماد النشاط'),
        content: const Text(
          'راجعت خطوات النشاط وأمثلته وملاءمته للهدف والأدوات، وأوافق على اعتماده بقراري المهني.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('رجوع'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('أعتمد النشاط'),
          ),
        ],
      ),
    );
    if (approved != true) return;
    final response = await _api.json(
      'POST',
      '/v1/activities/${record['id']}/approve',
      data: {'revision': record['revision'], 'confirmed': true},
    );
    final updated = Map<String, dynamic>.from(response['record'] as Map);
    _activities = [
      for (final item in _activities)
        if (item['id'] == updated['id']) updated else item,
    ];
    await _save();
  }

  Widget _choice(
    String title,
    String value,
    Map<String, String> options,
    ValueChanged<String> change,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: DropdownButtonFormField<String>(
      key: ValueKey('$title-$value'),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: title),
      items: [
        for (final option in options.entries)
          DropdownMenuItem(value: option.key, child: Text(option.value)),
      ],
      onChanged: _busy
          ? null
          : (value) {
              if (value != null) _edit(() => change(value));
            },
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('الأنشطة العلاجية'),
      actions: [
        IconButton(
          tooltip: 'تحديث الأنشطة والأدوات',
          onPressed: _busy ? null : () => _run(_refresh),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const PrototypeNote(),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SectionHeading(
          'نشاط مرتبط بهدف معتمد',
          subtitle: 'المدخلات محفوظة محليًا؛ التوليد والطباعة يحتاجان الاتصال.',
        ),
        DropdownButtonFormField<String>(
          key: ValueKey('plan-$_planId-${_plans.length}'),
          initialValue: _plan?['id'] as String?,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'الخطة المعتمدة'),
          items: [
            for (final plan in _plans)
              DropdownMenuItem(
                value: plan['id'] as String,
                child: Text(
                  'خطة ${(plan['data'] as Map)['version']} · ${(plan['data'] as Map)['content']['generalGoal']}',
                ),
              ),
          ],
          onChanged: _busy
              ? null
              : (id) => _edit(() {
                  _planId = id;
                  _goalId = null;
                }),
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          key: ValueKey('goal-$_planId-$_goalId'),
          initialValue: _goals.any((g) => g['id'] == _goalId) ? _goalId : null,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'الهدف الإجرائي'),
          items: [
            for (final goal in _goals)
              DropdownMenuItem(
                value: goal['id'] as String,
                child: Text(goal['behavior'] as String),
              ),
          ],
          onChanged: _busy ? null : (id) => _edit(() => _goalId = id),
        ),
        const SizedBox(height: 14),
        _choice('المجال', _domain, _domains, (value) => _domain = value),
        _choice('نوع النشاط', _type, _types, (value) => _type = value),
        _choice(
          'الصعوبة',
          _difficulty,
          _difficultyLabels,
          (value) => _difficulty = value,
        ),
        _choice('نمط النشاط', _mode, const {
          'individual': 'فردي',
          'group': 'جماعي',
        }, (value) => _mode = value),
        TextFormField(
          controller: _minutesInput,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'زمن النشاط بالدقائق (1–180)',
          ),
          enabled: !_busy,
          onChanged: (value) =>
              _edit(() => _minutes = int.tryParse(value) ?? 0),
        ),
        const SizedBox(height: 14),
        const SectionHeading('ملف الأدوات المتاحة'),
        for (final tool in _tools)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tool['label'] as String),
            value: _selectedTools.contains(tool['id']),
            onChanged: _busy
                ? null
                : (value) => _edit(() {
                    _toolsDirty = true;
                    _configured = false;
                    if (value == true) {
                      _selectedTools.add(tool['id'] as String);
                    } else {
                      _selectedTools.remove(tool['id']);
                    }
                  }),
          ),
        Wrap(
          spacing: 12,
          runSpacing: 10,
          children: [
            OutlinedButton(
              onPressed: _busy ? null : _addTool,
              child: const Text('إضافة أداة متاحة'),
            ),
            OutlinedButton(
              onPressed: _busy ? null : () => _run(_saveTools),
              child: Text(
                _configured ? 'حفظ ملف الأدوات' : 'تأكيد وحفظ الأدوات المتاحة',
              ),
            ),
            if (_toolsDirty)
              TextButton(
                onPressed: _busy ? null : () => _run(_reloadTools),
                child: const Text('تحميل ملف الأدوات من الخادم'),
              ),
          ],
        ),
        CheckboxListTile(
          value: _reviewed,
          onChanged: _busy
              ? null
              : (value) => setState(() => _reviewed = value ?? false),
          title: const Text(
            'راجعت نص الهدف والأدوات وخلوّهما من الأسماء والتشخيص وبيانات التعريف.',
          ),
        ),
        CheckboxListTile(
          value: _synthetic,
          onChanged: _busy
              ? null
              : (value) => setState(() => _synthetic = value ?? false),
          title: const Text('أستخدم بيانات تجربة اصطناعية فقط.'),
        ),
        FilledButton(
          onPressed: _busy || !_storageReady ? null : () => _run(_makePreview),
          child: const Text('معاينة الحقول قبل الإرسال'),
        ),
        if (_preview != null) ...[
          const SizedBox(height: 16),
          const SectionHeading('الحمولة التي ستُرسل إلى المولّد'),
          SelectableText(
            const JsonEncoder.withIndent('  ').convert(_preview!['payload']),
            textDirection: TextDirection.rtl,
          ),
          CheckboxListTile(
            value: _confirmed,
            onChanged: _busy
                ? null
                : (value) => setState(() => _confirmed = value ?? false),
            title: const Text(
              'أوافق صراحةً على إرسال هذه الحقول المراجعة لتوليد مسودة نشاط.',
            ),
          ),
          FilledButton(
            onPressed: _busy || !_confirmed ? null : () => _run(_generate),
            child: const Text('توليد المسودة / استعادة نتيجة المحاولة'),
          ),
        ],
        if (_operationId != null)
          Wrap(
            spacing: 10,
            children: [
              OutlinedButton(
                onPressed: _busy ? null : () => _run(_operationStatus),
                child: const Text('استعلام واستعادة نتيجة الطلب'),
              ),
              TextButton(
                onPressed: _busy ? null : () => _run(_cancelOperation),
                child: const Text('إلغاء الطلب المعلّق'),
              ),
            ],
          ),
        const SizedBox(height: 24),
        const SectionHeading('الأنشطة المحفوظة'),
        for (final record in _activities) _activityCard(record),
      ],
    ),
  );

  Widget _activityCard(Map<String, dynamic> record) {
    final data = Map<String, dynamic>.from(record['data'] as Map);
    final content = Map<String, dynamic>.from(data['content'] as Map);
    final approved = data['status'] == 'approved';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${approved ? 'معتمد' : 'مقترح — مسودة'}: ${content['title']}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            for (final section in const {
              'preparation': 'إعداد الوسيلة',
              'steps': 'خطوات التنفيذ',
              'examples': 'أمثلة تطبيقية',
              'lowCostAlternatives': 'بدائل بسيطة',
            }.entries) ...[
              Text(
                section.value,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              for (final line in content[section.key] as List) Text('• $line'),
            ],
            Text('التغذية الراجعة: ${content['feedback']}'),
            Text('آلية القياس: ${content['measurement']}'),
            Text('الزمن: ${content['minutes']} دقيقة'),
            if ((content['teacherNotes'] as String).isNotEmpty)
              Text('ملاحظات المعلمة: ${content['teacherNotes']}'),
            if (!approved)
              FilledButton(
                onPressed: _busy ? null : () => _run(() => _approve(record)),
                child: const Text('مراجعة واعتماد النشاط'),
              ),
            if (approved) ...[
              const Text('العناصر الاختيارية للطباعة:'),
              Wrap(
                children: [
                  for (final section in const {
                    'title': 'العنوان',
                    'goal': 'الهدف',
                    'duration': 'المدة',
                    'alternatives': 'البدائل',
                    'teacherNotes': 'ملاحظات المعلمة',
                  }.entries)
                    FilterChip(
                      label: Text(section.value),
                      selected: _sections[section.key]!,
                      onSelected: _busy
                          ? null
                          : (value) =>
                                setState(() => _sections[section.key] = value),
                    ),
                ],
              ),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        final document = await _api.export(
                          '/v1/activities/${record['id']}/export',
                          {'optionalSections': _sections},
                        );
                        if (mounted) {
                          await shareExport(
                            context,
                            document,
                            auth: widget.auth,
                          );
                        }
                      }),
                child: const Text('تصدير النشاط PDF للطباعة'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
