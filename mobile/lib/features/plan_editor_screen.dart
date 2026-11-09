import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/app_state.dart';
import '../core/form_draft.dart';
import '../core/plan_api.dart';
import '../models/initial_assessment.dart';
import '../models/intervention_session.dart';
import '../widgets/common.dart';

String? planContentIssue(Map<String, dynamic> content) {
  final strings = [
    'needsSummary',
    'strengthsSummary',
    'generalGoal',
    'baseline',
  ];
  if (strings.any((key) => (content[key] as String? ?? '').trim().isEmpty)) {
    return 'أكملي ملخص الاحتياج والقوة والهدف العام ومستوى الأداء الحالي.';
  }
  final weeks = content['durationWeeks'];
  final sessions = content['sessionsPerWeek'];
  if (weeks is! int ||
      weeks < 1 ||
      weeks > 104 ||
      sessions is! int ||
      sessions < 1 ||
      sessions > 14) {
    return 'راجعي مدة الخطة وعدد الجلسات.';
  }
  final goals = content['goals'];
  if (goals is! List || goals.isEmpty || goals.length > 30) {
    return 'يلزم هدف إجرائي واحد على الأقل.';
  }
  final texts = [for (final key in strings) content[key] as String];
  for (final item in goals) {
    final goal = Map<String, dynamic>.from(item as Map);
    if ((goal['behavior'] as String? ?? '').trim().isEmpty ||
        (goal['condition'] as String? ?? '').trim().isEmpty) {
      return 'كل هدف يحتاج سلوكًا قابلًا للملاحظة وشرط أداء.';
    }
    final timeframe = goal['timeframeWeeks'];
    if (timeframe is! int || timeframe < 1 || timeframe > weeks) {
      return 'زمن الهدف موجب ولا يتجاوز مدة الخطة.';
    }
    final c = Map<String, dynamic>.from(goal['criterion'] as Map);
    switch (c['type']) {
      case 'percentage':
      case 'consistency':
        final target =
            c[c['type'] == 'percentage' ? 'target' : 'targetPercent'];
        if (target is! num || target < 0 || target > 100) {
          return 'نسبة معيار الإتقان بين صفر و100.';
        }
        if (c['type'] == 'consistency' &&
            (c['sessions'] is! int || (c['sessions'] as int) < 1)) {
          return 'حددي عدد جلسات الثبات الموجب.';
        }
      case 'trials':
        if (c['total'] is! int ||
            c['correct'] is! int ||
            (c['total'] as int) < 1 ||
            (c['correct'] as int) < 1 ||
            (c['correct'] as int) > (c['total'] as int)) {
          return 'معيار المحاولات يحتاج عددًا صحيحًا موجبًا لا يتجاوز الإجمالي.';
        }
      case 'independence':
        if (!supportLevels.containsKey(c['support'])) {
          return 'حددي مستوى الاستقلالية.';
        }
      default:
        return 'حددي معيارًا قابلًا للقياس لكل هدف.';
    }
    texts.addAll([goal['behavior'] as String, goal['condition'] as String]);
  }
  for (final key in [
    'tools',
    'measurementTools',
    'strategies',
    'recommendations',
  ]) {
    final values = content[key];
    if (values is! List ||
        values.length > 30 ||
        values.any((v) => v is! String || v.trim().isEmpty)) {
      return 'راجعي قائمة الوسائل والقياس والاستراتيجيات والتوصيات.';
    }
    if (['tools', 'measurementTools'].contains(key) && values.isEmpty) {
      return 'وسائل التعليم وأدوات القياس مكوّنات أساسية.';
    }
    texts.addAll(values.cast<String>());
  }
  final date = content['nextFollowUp'] as String? ?? '';
  final parsed = DateTime.tryParse(date);
  if (parsed == null ||
      date.length != 10 ||
      parsed.toIso8601String().substring(0, 10) != date) {
    return 'تاريخ المتابعة غير صالح.';
  }
  return educationalTextIssue(texts);
}

class PlanEditorScreen extends StatefulWidget {
  const PlanEditorScreen({
    super.key,
    required this.plan,
    required this.api,
    required this.state,
    required this.onSaved,
  });
  final PlanRecord plan;
  final PlanApi api;
  final AppState state;
  final Future<void> Function(PlanRecord) onSaved;
  @override
  State<PlanEditorScreen> createState() => _PlanEditorScreenState();
}

class _PlanEditorScreenState extends State<PlanEditorScreen> {
  late Map<String, dynamic> _content;
  final Map<String, bool> _options = {
    'showStrategies': true,
    'showRecommendations': true,
    'showSessionSchedule': true,
  };
  String? _operationId, _error;
  final Map<String, String> _numericInputs = {};
  bool _privacy = false, _busy = false;
  late final FormDraftController _formDraft;
  String get _draftKey => 'plan-edit:${widget.plan.id}';
  @override
  void initState() {
    super.initState();
    final saved = widget.state.draftFor(_draftKey);
    _content = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(saved?['content'] ?? widget.plan.content)) as Map,
    );
    if (saved != null) {
      _operationId = saved['operationId'] as String?;
      _options.addAll(Map<String, bool>.from(saved['templateOptions'] as Map));
      _numericInputs.addAll(
        Map<String, String>.from((saved['numericInputs'] as Map?) ?? {}),
      );
    } else {
      final options = widget.plan.data['templateOptions'];
      if (options is Map) _options.addAll(Map<String, bool>.from(options));
    }
    _formDraft = FormDraftController(
      state: widget.state,
      key: _draftKey,
      validate: (value) => educationalTextIssue([
        for (final field in [
          'needsSummary',
          'strengthsSummary',
          'generalGoal',
          'baseline',
        ])
          (value['content'] as Map)[field] as String,
        for (final raw in (value['content'] as Map)['goals'] as List) ...[
          (raw as Map)['behavior'] as String,
          raw['condition'] as String,
        ],
        for (final field in [
          'tools',
          'measurementTools',
          'strategies',
          'recommendations',
        ])
          ...((value['content'] as Map)[field] as List).cast<String>(),
        ...(value['numericInputs'] as Map).values.cast<String>(),
      ]),
    );
  }

  void _changed() {
    _operationId = null;
    _formDraft.update(_snapshot());
  }

  Map<String, dynamic> _snapshot() => {
    'content': _content,
    'templateOptions': _options,
    'operationId': _operationId,
    'numericInputs': _numericInputs,
  };

  Future<void> _retain() async {
    _formDraft.update(_snapshot());
    await _formDraft.flush();
  }

  @override
  void dispose() {
    _formDraft.dispose();
    super.dispose();
  }

  Future<void> _save({bool send = false}) async {
    final issue = planContentIssue(_content);
    if (issue != null || !_privacy) {
      setState(
        () => _error = issue ?? 'راجعي النصوص وأكدي خلوها من الهوية والتشخيص.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (send) _operationId ??= const Uuid().v4();
      await _retain();
      if (send) {
        final revised = await widget.api.revise(
          widget.plan,
          operationId: _operationId!,
          content: _content,
          templateOptions: _options,
          confirmed: true,
        );
        await widget.onSaved(revised);
        await _formDraft.clearAfterSave();
        if (mounted) Navigator.pop(context);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'حُفظت التعديلات مشفّرة على هذا الجهاز دون تغيير الخطة المعتمدة.',
            ),
          ),
        );
      }
    } catch (error) {
      _error = planErrorMessage(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _text(String key, String label, {int maxLines = 3}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: TextFormField(
      initialValue: _content[key] as String,
      maxLength: 2000,
      maxLines: maxLines,
      enabled: !_busy,
      decoration: InputDecoration(
        labelText: label,
        helperText: 'وصف تعليمي دون أسماء أو بيانات صحية',
      ),
      onChanged: (v) {
        _content[key] = v;
        _changed();
      },
    ),
  );
  Widget _number(
    String inputKey,
    String label,
    Object? value,
    ValueChanged<num?> change,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: TextFormField(
      key: ValueKey(inputKey),
      initialValue: _numericInputs[inputKey] ?? value?.toString() ?? '',
      enabled: !_busy,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label),
      onChanged: (v) {
        _numericInputs[inputKey] = v;
        final parsed = num.tryParse(v);
        change(parsed != null && parsed.isFinite ? parsed : null);
        _changed();
      },
    ),
  );
  @override
  Widget build(BuildContext context) => FormDraftGuard(
    controller: _formDraft,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('تعديل الخطة وحفظ إصدار'),
        actions: [
          DiscardFormDraftButton(controller: _formDraft, enabled: !_busy),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          const PrototypeNote(),
          FormDraftStatus(controller: _formDraft),
          const Text(
            'التعديل ينشئ مسودة جديدة مرتبطة بالمصدر، ويُبقي الخطة السابقة وتاريخها كما هما. المسودة الجديدة تحتاج مراجعة واعتمادًا صريحًا قبل تسجيل جلسات عليها.',
          ),
          if (_error != null)
            Text(
              _error!,
              key: const Key('plan-editor-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          for (final entry in const {
            'needsSummary': 'ملخص الاحتياج',
            'strengthsSummary': 'نقاط القوة',
            'generalGoal': 'الهدف العام',
            'baseline': 'مستوى الأداء الأولي',
          }.entries)
            _text(entry.key, entry.value),
          _number(
            'durationWeeks',
            'مدة الخطة بالأسابيع',
            _content['durationWeeks'],
            (v) => _content['durationWeeks'] = v,
          ),
          _number(
            'sessionsPerWeek',
            'الجلسات الأسبوعية',
            _content['sessionsPerWeek'],
            (v) => _content['sessionsPerWeek'] = v,
          ),
          const SectionHeading('الأهداف الإجرائية (مكوّن أساسي)'),
          for (final raw in _content['goals'] as List) _goal(raw as Map),
          for (final entry in const {
            'tools': 'الأدوات والوسائل التعليمية',
            'measurementTools': 'أدوات القياس',
            'strategies': 'الاستراتيجيات',
            'recommendations': 'توصيات المتابعة',
          }.entries)
            TextFormField(
              initialValue: (_content[entry.key] as List).join('\n'),
              enabled: !_busy,
              maxLines: 4,
              maxLength: 2000,
              decoration: InputDecoration(
                labelText: entry.value,
                helperText: 'عنصر واحد في كل سطر، دون بيانات تعريفية',
              ),
              onChanged: (v) {
                _content[entry.key] = v
                    .split('\n')
                    .map((s) => s.trim())
                    .where((s) => s.isNotEmpty)
                    .toList();
                _changed();
              },
            ),
          _text('nextFollowUp', 'تاريخ المتابعة YYYY-MM-DD', maxLines: 1),
          const SectionHeading('تخصيص عرض المكونات الاختيارية'),
          for (final entry in const {
            'showStrategies': 'عرض الأنشطة والاستراتيجيات',
            'showRecommendations': 'عرض التوصيات',
            'showSessionSchedule': 'عرض مدة وآلية الجلسات',
          }.entries)
            SwitchListTile(
              value: _options[entry.key]!,
              title: Text(entry.value),
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                      _options[entry.key] = v;
                      _changed();
                    }),
            ),
          const Text(
            'الأهداف ومستوى الأداء والوسائل وأدوات القياس تبقى ظاهرة. قالب المؤسسة النهائي يحتاج اعتمادها.',
          ),
          CheckboxListTile(
            value: _privacy,
            title: const Text(
              'راجعت الملاءمة والخصوصية وأوافق على حفظ التعديلات',
            ),
            onChanged: _busy
                ? null
                : (v) => setState(() => _privacy = v ?? false),
          ),
          OutlinedButton(
            onPressed: _busy ? null : () => _save(),
            child: const Text('حفظ التعديلات على هذا الجهاز'),
          ),
          FilledButton(
            onPressed: _busy ? null : () => _save(send: true),
            child: const Text('حفظ إصدار جديد كمسودة على الخادم'),
          ),
        ],
      ),
    ),
  );
  Widget _goal(Map raw) {
    final criterion = Map<String, dynamic>.from(raw['criterion'] as Map);
    return Card(
      key: ValueKey(raw['id']),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('مصدر المهارة: ${raw['skillId']}'),
            for (final entry in const {
              'behavior': 'السلوك القابل للملاحظة',
              'condition': 'شرط الأداء',
            }.entries)
              TextFormField(
                initialValue: raw[entry.key] as String,
                enabled: !_busy,
                maxLength: 2000,
                maxLines: 2,
                decoration: InputDecoration(labelText: entry.value),
                onChanged: (v) {
                  raw[entry.key] = v;
                  _changed();
                },
              ),
            DropdownButtonFormField<String>(
              initialValue: criterion['type'] as String,
              decoration: const InputDecoration(labelText: 'نوع معيار الإتقان'),
              items: const [
                DropdownMenuItem(value: 'percentage', child: Text('نسبة دقة')),
                DropdownMenuItem(
                  value: 'trials',
                  child: Text('صحيح من إجمالي محاولات'),
                ),
                DropdownMenuItem(
                  value: 'consistency',
                  child: Text('ثبات عبر جلسات'),
                ),
                DropdownMenuItem(
                  value: 'independence',
                  child: Text('مستوى الاستقلالية'),
                ),
              ],
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                      _numericInputs.removeWhere(
                        (key, _) =>
                            key.startsWith('goal:${raw['id']}:criterion:'),
                      );
                      raw['criterion'] = switch (v) {
                        'trials' => {'type': v, 'correct': 4, 'total': 5},
                        'consistency' => {
                          'type': v,
                          'sessions': 3,
                          'targetPercent': 80,
                        },
                        'independence' => {'type': v, 'support': 'independent'},
                        _ => {'type': 'percentage', 'target': 80},
                      };
                      _changed();
                    }),
            ),
            if (criterion['type'] == 'percentage')
              _number(
                'goal:${raw['id']}:criterion:target',
                'نسبة الدقة المستهدفة',
                criterion['target'],
                (v) => (raw['criterion'] as Map)['target'] = v,
              ),
            if (criterion['type'] == 'trials') ...[
              _number(
                'goal:${raw['id']}:criterion:correct',
                'المحاولات الصحيحة المستهدفة',
                criterion['correct'],
                (v) => (raw['criterion'] as Map)['correct'] = v,
              ),
              _number(
                'goal:${raw['id']}:criterion:total',
                'إجمالي المحاولات',
                criterion['total'],
                (v) => (raw['criterion'] as Map)['total'] = v,
              ),
            ],
            if (criterion['type'] == 'consistency') ...[
              _number(
                'goal:${raw['id']}:criterion:sessions',
                'عدد الجلسات',
                criterion['sessions'],
                (v) => (raw['criterion'] as Map)['sessions'] = v,
              ),
              _number(
                'goal:${raw['id']}:criterion:targetPercent',
                'نسبة الدقة عبر الجلسات',
                criterion['targetPercent'],
                (v) => (raw['criterion'] as Map)['targetPercent'] = v,
              ),
            ],
            if (criterion['type'] == 'independence')
              DropdownButtonFormField<String>(
                initialValue: criterion['support'] as String,
                decoration: const InputDecoration(labelText: 'الدعم المستهدف'),
                items: supportLevels.entries
                    .map(
                      (e) =>
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                    )
                    .toList(),
                onChanged: _busy
                    ? null
                    : (v) {
                        (raw['criterion'] as Map)['support'] = v;
                        _changed();
                      },
              ),
            _number(
              'goal:${raw['id']}:timeframeWeeks',
              'الإطار الزمني بالأسابيع',
              raw['timeframeWeeks'],
              (v) => raw['timeframeWeeks'] = v,
            ),
          ],
        ),
      ),
    );
  }
}
