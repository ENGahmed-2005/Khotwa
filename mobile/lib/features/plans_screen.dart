import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/auth_state.dart';
import '../core/plan_api.dart';
import '../core/secure_local_store.dart';
import '../models/assessment.dart';
import '../widgets/common.dart';

class PlansScreen extends StatefulWidget {
  const PlansScreen({
    super.key,
    required this.auth,
    this.planApi,
    this.draftStore,
  });
  final AuthState auth;
  final PlanApi? planApi;
  final LocalStore? draftStore;
  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends State<PlansScreen> {
  static const _tools = {
    'board': 'السبورة',
    'pencils': 'الأقلام',
    'cards': 'البطاقات',
    'paper': 'الأوراق',
    'colors': 'الألوان',
  };
  static const _levels = {
    'mastered': 'متقن',
    'developing': 'يحتاج إلى تطوير',
    'needsSupport': 'يحتاج إلى دعم إضافي',
  };
  late final PlanApi _api;
  late final String _ownerId;
  LocalStore? _store;
  Future<void> _writes = Future.value();
  bool _busy = true,
      _storageReady = false,
      _synthetic = false,
      _sendConfirmed = false;
  String? _error, _studentId, _assessmentId, _operationId;
  List<PlanRecord> _plans = [];
  List<PlanSkill> _skills = [];
  Map<String, String> _selectedLevels = {};
  Set<String> _availableTools = _tools.keys.toSet();
  int _weeks = 6, _sessions = 2;
  PlanPreview? _preview;

  @override
  void initState() {
    super.initState();
    _ownerId = widget.auth.ownerId ?? '';
    _api =
        widget.planApi ??
        PlanApi(
          api: widget.auth.api,
          tokenForRequest: () =>
              widget.auth.ownerId == _ownerId ? widget.auth.token : null,
        );
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final ownerId = widget.auth.ownerId;
      if (ownerId == null) {
        throw StateError('يلزم تسجيل الدخول.');
      }
      _store =
          widget.draftStore ??
          await widget.auth.storeForOwner('$ownerId-plan-inputs');
      final saved = await _store!.read();
      if (saved != null) {
        final data = jsonDecode(saved) as Map<String, dynamic>;
        if (data['version'] != 1 || data['ownerId'] != ownerId) {
          throw StateError('بيانات محلية غير مطابقة للحساب.');
        }
        final weeks = data['weeks'] as int;
        final sessions = data['sessions'] as int;
        final levels = Map<String, String>.from(data['levels'] as Map);
        final tools = Set<String>.from(data['tools'] as List);
        if (weeks < 1 ||
            weeks > 104 ||
            sessions < 1 ||
            sessions > 14 ||
            levels.values.any((value) => !_levels.containsKey(value)) ||
            tools.any((value) => !_tools.containsKey(value))) {
          throw StateError('مسودة المدخلات المحلية غير صالحة.');
        }
        _studentId = data['studentId'] as String?;
        _assessmentId = data['assessmentId'] as String?;
        _selectedLevels = levels;
        _weeks = weeks;
        _sessions = sessions;
        _availableTools = tools;
        _operationId = data['operationId'] as String?;
        if (data['preview'] != null) {
          _preview = PlanPreview.fromJson(
            Map<String, dynamic>.from(data['preview'] as Map),
          );
        }
        _plans = (data['plans'] as List)
            .map(
              (value) =>
                  PlanRecord.fromJson(Map<String, dynamic>.from(value as Map)),
            )
            .toList();
      }
      _storageReady = true;
      if (mounted) {
        setState(() {});
      }
      await _refresh();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = _storageReady
              ? planErrorMessage(error)
              : 'تعذّر فتح مسودة المدخلات بأمان. احتُفظ بالتخزين دون تغيير؛ التوليد مقفل.';
          _busy = false;
        });
      }
    }
  }

  Future<void> _persist() {
    if (!_storageReady || _store == null || widget.auth.ownerId != _ownerId) {
      return Future.error(StateError('التخزين الآمن غير متاح.'));
    }
    final snapshot = jsonEncode({
      'version': 1,
      'ownerId': _ownerId,
      'studentId': _studentId,
      'assessmentId': _assessmentId,
      'levels': _selectedLevels,
      'weeks': _weeks,
      'sessions': _sessions,
      'tools': _availableTools.toList(),
      'preview': _preview?.toJson(),
      'operationId': _operationId,
      'plans': _plans.map((p) => p.envelope).toList(),
    });
    final write = _writes.then((_) {
      if (widget.auth.ownerId != _ownerId) {
        throw StateError('انتهت جلسة هذا الحساب.');
      }
      return _store!.write(snapshot);
    });
    _writes = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return write;
  }

  void _change(VoidCallback change) {
    setState(() {
      change();
      _preview = null;
      _operationId = null;
      _sendConfirmed = false;
      _error = null;
    });
    unawaited(
      _persist().catchError((Object error) {
        if (mounted) {
          setState(
            () => _error =
                'لم تُحفظ آخر تغييرات المدخلات محليًا. أعيدي المحاولة قبل المغادرة.',
          );
        }
      }),
    );
  }

  Future<void> _refresh() async {
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      final plans = await _api.plans();
      if (_assessmentId != null) {
        _skills = await _api.skills(_assessmentId!);
      }
      _plans = plans;
      await _persist();
    } catch (error) {
      _error = planErrorMessage(error);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _chooseAssessment(String? id) async {
    _change(() {
      _assessmentId = id;
      _skills = [];
      _selectedLevels = {};
    });
    if (id == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      final values = await _api.skills(id);
      if (_assessmentId == id) {
        _skills = values;
      }
    } catch (error) {
      _error = planErrorMessage(error);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _prepare() async {
    if (_studentId == null || _assessmentId == null) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _persist();
      final preview = await _api.preview(
        studentId: _studentId!,
        assessmentId: _assessmentId!,
        skills: _skills
            .where((skill) => _selectedLevels.containsKey(skill.id))
            .map(
              (skill) => <String, dynamic>{
                'skillId': skill.id,
                'level': _selectedLevels[skill.id],
                'evidence': skill.evidence,
              },
            )
            .toList(),
        durationWeeks: _weeks,
        sessionsPerWeek: _sessions,
        availableTools: _availableTools.toList(),
        syntheticDataConfirmed: _synthetic,
      );
      _preview = preview;
      _operationId = const Uuid().v4();
      _sendConfirmed = false;
      await _persist();
    } catch (error) {
      _error = planErrorMessage(error);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _generate() async {
    final preview = _preview;
    final operationId = _operationId;
    if (preview == null || operationId == null) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Flush the retained operation ID before sending; retries use the same ID.
      await _persist();
      final plan = await _api.generate(
        preview: preview,
        operationId: operationId,
        confirmed: _sendConfirmed,
        syntheticDataConfirmed: _synthetic,
      );
      _plans = [plan, ..._plans.where((old) => old.id != plan.id)];
      _preview = null;
      _operationId = null;
      _sendConfirmed = false;
      await _persist();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('وصلت مسودة مقترحة؛ راجعي عناصرها قبل الاعتماد.'),
          ),
        );
      }
    } catch (error) {
      _error = planErrorMessage(error);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _approve(PlanRecord plan) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('اعتماد بقرار المختصة'),
        content: const Text(
          'أؤكد أنني راجعت الخطة كاملة: مصدر الأداء، ملاءمة كل هدف، السلوك، شرط الأداء، معيار الإتقان، المدة والأدوات. هذا اعتماد بشري صريح للمسودة المقترحة.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('العودة للمراجعة'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('أوافق وأعتمد الخطة'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final approved = await _api.approve(plan, confirmed: true);
      _plans = _plans
          .map((old) => old.id == approved.id ? approved : old)
          .toList();
      await _persist();
    } catch (error) {
      _error = planErrorMessage(error);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final students = widget.auth.records?.students ?? [];
    final assessments =
        widget.auth.records?.assessments
            .where(
              (a) =>
                  a.studentId == _studentId &&
                  a.status == AssessmentStatus.approved,
            )
            .toList() ??
        [];
    final validStudent = students.any((s) => s.id == _studentId)
        ? _studentId
        : null;
    final validAssessment = assessments.any((a) => a.id == _assessmentId)
        ? _assessmentId
        : null;
    final preview = _preview;
    return Scaffold(
      appBar: AppBar(
        title: const Text('الخطط الذكية'),
        actions: [
          IconButton(
            tooltip: 'تحديث الخطط',
            onPressed: _busy || !_storageReady ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          const PrototypeNote(),
          const SizedBox(height: 12),
          const Text(
            'توليد الخطط عبر Gemini متاح في هذه النسخة لبيانات التجربة المصطنعة فقط، عند تفعيل الخدمة على الخادم. يلزم الاتصال، وتبقى كل نتيجة مسودة مقترحة حتى مراجعتك واعتمادك.',
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(),
            ),
          if (_error != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!, key: const Key('plan-error')),
              ),
            ),
          const SectionHeading('١. مصدر الخطة'),
          DropdownButtonFormField<String>(
            key: ValueKey('student-$validStudent'),
            initialValue: validStudent,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'ملف الطالب المجهّل'),
            items: students
                .map((s) => DropdownMenuItem(value: s.id, child: Text(s.code)))
                .toList(),
            onChanged: _busy || !_storageReady
                ? null
                : (id) => _change(() {
                    _studentId = id;
                    _assessmentId = null;
                    _skills = [];
                    _selectedLevels = {};
                  }),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('assessment-$validAssessment'),
            initialValue: validAssessment,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'تقييم معتمد مصدرًا للأداء',
            ),
            items: assessments
                .map(
                  (a) => DropdownMenuItem(
                    value: a.id,
                    child: Text(
                      'بطاقات ${a.ageGroup} · ${a.createdAt.substring(0, 10)}',
                    ),
                  ),
                )
                .toList(),
            onChanged: _busy || !_storageReady ? null : _chooseAssessment,
          ),
          if (assessments.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'أنشئي تقييمًا، سجّلي الأداء وراجعي الملخص واعتمديه، ثم زامنيه قبل التوليد. لا يبدأ التوليد من تقييم غير معتمد.',
              ),
            ),
          const SectionHeading('٢. مهارات موثّقة ومستويات تختارينها'),
          const Text(
            'تظهر فقط مهارات مرتبطة ببنود نُفّذت في التقييم المعتمد. لا يُستنتج مستوى تلقائيًا. اختاري مستوى كل مهارة تريدين إرسالها.',
          ),
          for (final skill in _skills)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: DropdownButtonFormField<String>(
                key: ValueKey('${skill.id}-${_selectedLevels[skill.id]}'),
                initialValue: _selectedLevels[skill.id],
                isExpanded: true,
                decoration: InputDecoration(labelText: skill.label),
                items: [
                  const DropdownMenuItem(
                    value: 'omit',
                    child: Text('لا تُرسل هذه المهارة'),
                  ),
                  ..._levels.entries.map(
                    (level) => DropdownMenuItem(
                      value: level.key,
                      child: Text(level.value),
                    ),
                  ),
                ],
                onChanged: _busy || !_storageReady
                    ? null
                    : (value) => _change(() {
                        if (value == null || value == 'omit') {
                          _selectedLevels.remove(skill.id);
                        } else {
                          _selectedLevels[skill.id] = value;
                        }
                      }),
              ),
            ),
          const SectionHeading('٣. مدة الخطة والأدوات المتاحة'),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  key: ValueKey('plan-weeks-$_weeks'),
                  initialValue: _weeks,
                  decoration: const InputDecoration(labelText: 'الأسابيع'),
                  items: [
                    for (var i = 1; i <= 104; i++)
                      DropdownMenuItem(value: i, child: Text('$i')),
                  ],
                  onChanged: _busy || !_storageReady
                      ? null
                      : (v) => _change(() => _weeks = v ?? _weeks),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<int>(
                  key: ValueKey('plan-sessions-$_sessions'),
                  initialValue: _sessions,
                  decoration: const InputDecoration(
                    labelText: 'الجلسات أسبوعيًا',
                  ),
                  items: [
                    for (var i = 1; i <= 14; i++)
                      DropdownMenuItem(value: i, child: Text('$i')),
                  ],
                  onChanged: _busy || !_storageReady
                      ? null
                      : (v) => _change(() => _sessions = v ?? _sessions),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: _tools.entries
                .map(
                  (tool) => FilterChip(
                    label: Text(tool.value),
                    selected: _availableTools.contains(tool.key),
                    onSelected: _busy || !_storageReady
                        ? null
                        : (selected) => _change(() {
                            if (selected) {
                              _availableTools.add(tool.key);
                            } else {
                              _availableTools.remove(tool.key);
                            }
                          }),
                  ),
                )
                .toList(),
          ),
          CheckboxListTile(
            value: _synthetic,
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'أؤكد أن ملف التجربة وتقييمه بيانات مصطنعة بالكامل؛ لا تخص طفلًا حقيقيًا.',
            ),
            onChanged: _busy || !_storageReady
                ? null
                : (v) => setState(() {
                    _synthetic = v ?? false;
                    _sendConfirmed = false;
                  }),
          ),
          FilledButton.icon(
            onPressed:
                _busy ||
                    !_storageReady ||
                    validAssessment == null ||
                    !_synthetic
                ? null
                : _prepare,
            icon: const Icon(Icons.preview_outlined),
            label: const Text('معاينة الحقول قبل الإرسال'),
          ),
          if (preview != null) ...[
            const SectionHeading('٤. الحقول التي ستُرسل إلى Gemini'),
            const Text(
              'تُرسل المهارات المرمّزة ومستوياتها والمدة وعدد الجلسات والأدوات أدناه فقط. لا يُرسل رمز الطالب أو معرّف الحساب أو إجابات التقييم الخام أو النصوص الحرة.',
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: SelectableText(
                    const JsonEncoder.withIndent('  ').convert(preview.payload),
                    key: const Key('exact-ai-payload'),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
            Text('صلاحية المعاينة: ${preview.expiresAt.toLocal()}'),
            CheckboxListTile(
              key: const Key('confirm-ai-send'),
              value: _sendConfirmed,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'راجعت هذه الحقول تحديدًا وأوافق على إرسالها لتوليد مسودة مقترحة.',
              ),
              onChanged: _busy || !_storageReady
                  ? null
                  : (v) => setState(() => _sendConfirmed = v ?? false),
            ),
            FilledButton.icon(
              key: const Key('generate-plan'),
              onPressed: _busy || !_sendConfirmed || !_synthetic
                  ? null
                  : _generate,
              icon: const Icon(Icons.auto_awesome_outlined),
              label: const Text('إرسال وتوليد مسودة / إعادة محاولة الطلب نفسه'),
            ),
          ],
          const SectionHeading('الخطط المحفوظة'),
          if (_plans.isEmpty)
            const Text(
              'لا توجد خطط محفوظة بعد. لا تتكوّن أي خطة دون التوليد الفعلي ومراجعة استجابته.',
            ),
          for (final plan in _plans)
            _planCard(
              plan,
              students
                      .where((s) => s.id == plan.studentId)
                      .map((s) => s.code)
                      .firstOrNull ??
                  'ملف مجهّل',
            ),
        ],
      ),
    );
  }

  Widget _planCard(PlanRecord plan, String code) {
    final content = plan.content;
    final goals = (content['goals'] as List).map(
      (value) => Map<String, dynamic>.from(value as Map),
    );
    String title(String value) => plan.approved ? value : '$value · مقترح';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$code · ${plan.approved ? 'معتمدة بقرار المختصة' : 'مسودة مقترحة — غير معتمدة'}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text('إصدار ${plan.data['version']} · مصدر المحتوى: Gemini'),
            if (plan.data['approvedAt'] != null)
              Text('تاريخ الاعتماد: ${plan.data['approvedAt']}'),
            for (final field in const {
              'needsSummary': 'ملخص الاحتياج',
              'strengthsSummary': 'نقاط القوة',
              'generalGoal': 'الهدف العام',
              'baseline': 'مستوى الأداء الأولي',
            }.entries) ...[
              SectionHeading(title(field.value)),
              SelectableText(content[field.key] as String),
            ],
            for (final goal in goals)
              Card(
                color: const Color(0xFFF1F8F8),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title('هدف إجرائي'),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text('السلوك: ${goal['behavior']}'),
                      Text('شرط الأداء: ${goal['condition']}'),
                      Text(
                        'معيار الإتقان: ${criterionLabel(Map<String, dynamic>.from(goal['criterion'] as Map))}',
                      ),
                      Text('الإطار الزمني: ${goal['timeframeWeeks']} أسابيع'),
                    ],
                  ),
                ),
              ),
            SectionHeading(title('المدة وآلية الجلسات')),
            Text(
              '${content['durationWeeks']} أسابيع · ${content['sessionsPerWeek']} جلسات أسبوعيًا',
            ),
            for (final field in const {
              'tools': 'الأدوات',
              'measurementTools': 'أدوات القياس',
              'strategies': 'الاستراتيجيات',
              'recommendations': 'توصيات المتابعة',
            }.entries) ...[
              SectionHeading(title(field.value)),
              for (final item in content[field.key] as List) Text('• $item'),
            ],
            SectionHeading(title('المتابعة القادمة')),
            Text(content['nextFollowUp'] as String),
            if (!plan.approved) ...[
              const SizedBox(height: 16),
              const Text(
                'راجعي ملاءمة المسودة قبل الاعتماد. تعديل عناصر الخطة وإصداراتها من الواجهة ما زال قيد التنفيذ؛ يمكن الرجوع للمدخلات وتوليد مسودة جديدة.',
              ),
              FilledButton.icon(
                onPressed: _busy ? null : () => _approve(plan),
                icon: const Icon(Icons.verified_outlined),
                label: const Text('مراجعة واعتماد هذه المسودة'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String criterionLabel(Map<String, dynamic> criterion) =>
    switch (criterion['type']) {
      'percentage' => 'دقة ${criterion['target']}٪',
      'trials' =>
        '${criterion['correct']} محاولات صحيحة من ${criterion['total']}',
      'consistency' =>
        'دقة ${criterion['targetPercent']}٪ عبر ${criterion['sessions']} جلسات',
      'independence' =>
        'مستوى المساعدة: ${switch (criterion['support']) {
          'independent' => 'مستقل',
          'verbal' => 'لفظي',
          'partial' => 'جزئي',
          'full' => 'كلي',
          _ => 'غير محدد',
        }}',
      _ => 'معيار غير معروف؛ يلزم التحقق قبل الاعتماد',
    };
