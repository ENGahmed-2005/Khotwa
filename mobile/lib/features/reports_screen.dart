import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/auth_state.dart';
import '../core/feature_api.dart';
import '../core/share_export.dart';
import '../widgets/common.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({
    super.key,
    required this.auth,
    this.api,
    this.draftStore,
  });
  final AuthState auth;
  final FeatureApi? api;
  final FeatureDraftStore? draftStore;
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  static const _types = {
    'progress': 'تقرير تقدم دوري',
    'parent': 'تقرير لولي الأمر',
    'administration': 'تقرير للإدارة',
    'plan': 'طباعة الخطة المعتمدة',
  };
  late final FeatureApi _api;
  late final FeatureDraftStore _store;
  final _institution = TextEditingController();
  List<Map<String, dynamic>> _plans = [], _exports = [];
  final _selected = <String>{};
  Map<String, dynamic>? _logo;
  String _type = 'progress', _format = 'pdf';
  late String _start, _end;
  String? _error, _lastSerial;
  int _revision = 0;
  bool _headerDirty = false;
  bool _busy = true,
      _storageReady = false,
      _privacyReviewed = false,
      _includeGrade = false;
  static String _date(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? FeatureApi(widget.auth);
    _store =
        widget.draftStore ?? FeatureDraftStore(widget.auth, 'report-inputs');
    _end = _date(DateTime.now());
    _start = _date(DateTime.now().subtract(const Duration(days: 30)));
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _institution.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final data = await _store.read();
      _plans = [
        for (final value in data['plans'] as List? ?? [])
          Map<String, dynamic>.from(value as Map),
      ];
      _exports = [
        for (final value in data['exports'] as List? ?? [])
          Map<String, dynamic>.from(value as Map),
      ];
      _institution.text = data['institutionTitle'] as String? ?? '';
      _logo = data['logo'] == null
          ? null
          : Map<String, dynamic>.from(data['logo'] as Map);
      _revision = data['revision'] as int? ?? 0;
      _headerDirty = data['headerDirty'] == true;
      _type = data['type'] as String? ?? 'progress';
      _format = data['format'] as String? ?? 'pdf';
      _start = data['periodStart'] as String? ?? _start;
      _end = data['periodEnd'] as String? ?? _end;
      _includeGrade = data['includeGrade'] == true;
      _selected.addAll(List<String>.from(data['selected'] as List? ?? []));
      if (!_types.containsKey(_type) ||
          !['pdf', 'docx'].contains(_format) ||
          DateTime.tryParse(_start) == null ||
          DateTime.tryParse(_end) == null) {
        throw StateError('اختيارات التقرير المحفوظة غير صالحة.');
      }
      _storageReady = true;
      await _refresh();
    } catch (_) {
      _error = _storageReady
          ? 'تعذّر تحديث بيانات التقارير. الاختيارات المحفوظة باقية؛ يحتاج التصدير الاتصال بالخادم.'
          : 'تعذّر فتح إعدادات التقارير بأمان، ولم تُستبدل البيانات المحلية.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() => _store.write({
    'plans': _plans,
    'exports': _exports,
    'institutionTitle': _institution.text,
    'logo': _logo,
    'revision': _revision,
    'type': _type,
    'format': _format,
    'periodStart': _start,
    'periodEnd': _end,
    'includeGrade': _includeGrade,
    'selected': _selected.toList(),
    'headerDirty': _headerDirty,
  });

  void _edit(VoidCallback action) {
    setState(action);
    unawaited(
      _save().catchError((Object _) {
        if (mounted) {
          setState(
            () => _error =
                'تعذّر حفظ الاختيارات محليًا. أعيدي الحفظ قبل التصدير.',
          );
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
      _api.json('GET', '/v1/reports/settings'),
      _api.json('GET', '/v1/reports/exports'),
    ]);
    _plans = [
      for (final item in responses[0]['records'] as List)
        if ((item as Map)['deletedAt'] == null &&
            (item['data'] as Map)['status'] == 'approved')
          Map<String, dynamic>.from(item),
    ];
    final settings = Map<String, dynamic>.from(responses[1]['settings'] as Map);
    if (!_headerDirty) {
      _institution.text = settings['institutionTitle'] as String;
      _logo = settings['logo'] == null
          ? null
          : Map<String, dynamic>.from(settings['logo'] as Map);
      _revision = responses[1]['revision'] as int;
    }
    _exports = [
      for (final item in responses[2]['exports'] as List)
        Map<String, dynamic>.from(item as Map),
    ];
    _selected.removeWhere((id) => !_plans.any((plan) => plan['id'] == id));
    await _save();
  }

  Future<void> _chooseLogo() async {
    const images = XTypeGroup(
      label: 'شعار مؤسسة PNG أو JPEG',
      extensions: ['png', 'jpg', 'jpeg'],
      mimeTypes: ['image/png', 'image/jpeg'],
      uniformTypeIdentifiers: ['public.png', 'public.jpeg'],
    );
    final file = await openFile(acceptedTypeGroups: [images]);
    if (file == null) return;
    if (await file.length() > 290000) {
      throw StateError('اختاري شعارًا بحجم أقل من 290 كيلوبايت.');
    }
    final bytes = await file.readAsBytes();
    final png =
        bytes.length > 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47;
    final jpeg =
        bytes.length > 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff;
    if (!png && !jpeg) {
      throw StateError('صيغة الشعار غير صالحة. اختاري PNG أو JPEG.');
    }
    _logo = {
      'mime': png ? 'image/png' : 'image/jpeg',
      'base64': base64Encode(bytes),
    };
    _headerDirty = true;
    await _save();
  }

  Future<void> _reloadHeader() async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تحميل ترويسة الخادم'),
        content: const Text(
          'سيستبدل هذا مسودة الترويسة والشعار المحلية بالنسخة التي تمت مزامنتها.',
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
    _headerDirty = false;
    await _refresh();
  }

  Future<void> _saveHeader() async {
    if (!_privacyReviewed) {
      throw StateError('راجعي الخصوصية وأكّدي أن المرفق شعار المؤسسة فقط.');
    }
    await _save();
    final response = await _api.json(
      'PUT',
      '/v1/reports/settings',
      data: {
        'revision': _revision,
        'institutionTitle': _institution.text.trim(),
        'logo': _logo == null
            ? null
            : {'mime': _logo!['mime'], 'base64': _logo!['base64']},
        'privacyReviewed': true,
      },
    );
    _revision = response['revision'] as int;
    _headerDirty = false;
    _logo = (response['settings'] as Map)['logo'] == null
        ? null
        : Map<String, dynamic>.from(
            (response['settings'] as Map)['logo'] as Map,
          );
    await _save();
  }

  Map<String, dynamic> _selection(Map<String, dynamic> plan) => {
    'studentId': (plan['data'] as Map)['studentId'],
    'planId': plan['id'],
    'type': _type,
    'periodStart': _start,
    'periodEnd': _end,
    'includeGrade': _includeGrade,
  };

  Future<void> _export() async {
    if (!_privacyReviewed || _selected.isEmpty || _selected.length > 10) {
      throw StateError('راجعي الخصوصية واختاري من خطة إلى عشر خطط معتمدة.');
    }
    if (_start.compareTo(_end) > 0) {
      throw StateError('بداية الفترة يجب أن تسبق نهايتها.');
    }
    final plans = _plans
        .where((plan) => _selected.contains(plan['id']))
        .toList();
    final students = plans
        .map((plan) => (plan['data'] as Map)['studentId'])
        .toSet();
    if (students.length != plans.length) {
      throw StateError(
        'اختاري خطة واحدة لكل طالب في الدفعة لمنع الخلط بين الإصدارات.',
      );
    }
    await _save();
    final document = plans.length == 1
        ? await _api.export('/v1/reports/export', {
            ..._selection(plans.single),
            'format': _format,
          })
        : await _api.export('/v1/reports/batch', {
            'reports': plans.map(_selection).toList(),
            'format': _format,
          });
    _lastSerial = document.serial;
    if (mounted) await shareExport(context, document, auth: widget.auth);
    final history = await _api.json('GET', '/v1/reports/exports');
    _exports = [
      for (final item in history['exports'] as List)
        Map<String, dynamic>.from(item as Map),
    ];
    await _save();
  }

  Future<void> _chooseDate(bool start) async {
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime.parse(start ? _start : _end),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date != null) {
      _edit(() {
        if (start) {
          _start = _date(date);
        } else {
          _end = _date(date);
        }
      });
    }
  }

  String _codeFor(Map<String, dynamic> plan) {
    final id = (plan['data'] as Map)['studentId'];
    return widget.auth.records?.students
            .where((student) => student.id == id)
            .firstOrNull
            ?.code ??
        'ملف مجهّل — زامني رمز الطالب';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('التقارير والطباعة'),
      actions: [
        IconButton(
          tooltip: 'تحديث التقارير',
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
          'ترويسة المؤسسة',
          subtitle:
              'اسم المؤسسة وشعارها فقط. لا تُرفقي صور الأطفال أو أوراقهم أو بياناتهم.',
        ),
        TextField(
          controller: _institution,
          enabled: !_busy,
          maxLength: 160,
          decoration: const InputDecoration(
            labelText: 'عنوان المؤسسة (اختياري)',
          ),
          onChanged: (_) => _edit(() => _headerDirty = true),
        ),
        if (_logo != null)
          Image.memory(
            base64Decode(_logo!['base64'] as String),
            height: 90,
            fit: BoxFit.contain,
            semanticLabel: 'معاينة شعار المؤسسة',
          ),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            OutlinedButton(
              onPressed: _busy ? null : () => _run(_chooseLogo),
              child: const Text('اختيار شعار المؤسسة'),
            ),
            if (_logo != null)
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _edit(() {
                        _logo = null;
                        _headerDirty = true;
                      }),
                child: const Text('إزالة الشعار'),
              ),
            OutlinedButton(
              onPressed: _busy ? null : () => _run(_saveHeader),
              child: const Text('حفظ الترويسة'),
            ),
            if (_headerDirty)
              TextButton(
                onPressed: _busy ? null : () => _run(_reloadHeader),
                child: const Text('تحميل ترويسة الخادم'),
              ),
          ],
        ),
        const SizedBox(height: 22),
        const SectionHeading('نوع التقرير وفترته'),
        DropdownButtonFormField<String>(
          key: ValueKey('report-type-$_type'),
          initialValue: _type,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'قالب التقرير'),
          items: [
            for (final item in _types.entries)
              DropdownMenuItem(value: item.key, child: Text(item.value)),
          ],
          onChanged: _busy
              ? null
              : (value) {
                  if (value != null) _edit(() => _type = value);
                },
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          key: ValueKey('format-$_format'),
          initialValue: _format,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'صيغة الملف'),
          items: const [
            DropdownMenuItem(value: 'pdf', child: Text('PDF للطباعة')),
            DropdownMenuItem(value: 'docx', child: Text('Word قابل للتعديل')),
          ],
          onChanged: _busy
              ? null
              : (value) {
                  if (value != null) _edit(() => _format = value);
                },
        ),
        Wrap(
          spacing: 12,
          children: [
            TextButton(
              onPressed: _busy ? null : () => _chooseDate(true),
              child: Text('من: $_start'),
            ),
            TextButton(
              onPressed: _busy ? null : () => _chooseDate(false),
              child: Text('إلى: $_end'),
            ),
          ],
        ),
        SwitchListTile(
          value: _includeGrade,
          onChanged: _busy
              ? null
              : (value) => _edit(() => _includeGrade = value),
          title: const Text('إدراج الصف في هذا التصدير'),
          subtitle: const Text(
            'مستبعد افتراضيًا لحماية البيانات شبه التعريفية.',
          ),
        ),
        const SectionHeading(
          'اختيار الملفات',
          subtitle:
              'خطة معتمدة واحدة لكل طالب؛ الدفعة تنتج ملفًا مستقلًا لكل رمز وقائمة مطابقة.',
        ),
        if (_plans.isEmpty)
          const Text(
            'لا توجد خطط معتمدة محفوظة. اعتمدي الخطة ثم زامنيها وحدّثي هذه الشاشة.',
          ),
        for (final plan in _plans)
          CheckboxListTile(
            value: _selected.contains(plan['id']),
            title: Text(_codeFor(plan)),
            subtitle: Text(
              'الإصدار ${(plan['data'] as Map)['version']} · ${(plan['data'] as Map)['content']['generalGoal']}',
            ),
            onChanged: _busy
                ? null
                : (value) => _edit(() {
                    if (value == true) {
                      _selected.add(plan['id'] as String);
                    } else {
                      _selected.remove(plan['id']);
                    }
                  }),
          ),
        CheckboxListTile(
          value: _privacyReviewed,
          onChanged: _busy
              ? null
              : (value) => setState(() => _privacyReviewed = value ?? false),
          title: const Text(
            'راجعت خلو الترويسة والشعار من بيانات أي طالب، وأوافق على تصدير ملف خارج التخزين المشفّر للتطبيق.',
          ),
        ),
        FilledButton.icon(
          onPressed: _busy || !_storageReady ? null : () => _run(_export),
          icon: const Icon(Icons.file_download_outlined),
          label: Text(
            _selected.length > 1
                ? 'تصدير ملفات مستقلة في ZIP'
                : 'تصدير وحفظ التقرير',
          ),
        ),
        if (_lastSerial != null)
          SelectableText('الرقم التسلسلي للتقرير: $_lastSerial'),
        const SizedBox(height: 24),
        const SectionHeading('سجل التصدير'),
        for (final export in _exports)
          Card(
            child: ListTile(
              title: Text(
                '${export['studentCode']} · ${_types[export['type']] ?? 'نشاط علاجي'}',
              ),
              subtitle: Text(
                '${export['serial']}\n${export['exportedAt']} · ${export['format']}',
              ),
            ),
          ),
      ],
    ),
  );
}
