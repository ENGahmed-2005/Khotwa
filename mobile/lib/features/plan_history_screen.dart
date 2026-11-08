import 'package:flutter/material.dart';
import '../core/app_state.dart';
import '../core/plan_api.dart';
import '../widgets/common.dart';
import 'progress_screen.dart';

class PlanHistoryScreen extends StatefulWidget {
  const PlanHistoryScreen({
    super.key,
    required this.plan,
    required this.api,
    required this.state,
  });
  final PlanRecord plan;
  final PlanApi api;
  final AppState state;
  @override
  State<PlanHistoryScreen> createState() => _PlanHistoryScreenState();
}

class _PlanHistoryScreenState extends State<PlanHistoryScreen> {
  List<Map<String, dynamic>> _history = [];
  String? _error;
  bool _busy = true;
  @override
  void initState() {
    super.initState();
    final cached = widget.state.draftFor('plan-history:${widget.plan.id}');
    _history =
        ((cached?['history'] ?? widget.plan.data['history']) as List? ?? [])
            .map((h) => Map<String, dynamic>.from(h as Map))
            .toList();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.api.history(widget.plan.id);
      _history = (data['history'] as List)
          .map((h) => Map<String, dynamic>.from(h as Map))
          .toList();
      await widget.state.saveDraft('plan-history:${widget.plan.id}', {
        'history': _history,
      });
    } catch (_) {
      _error = 'تعذّر تحديث السجل؛ تظهر النسخ المحفوظة على هذا الجهاز.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('سجل إصدارات الخطة')),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Text(_error!),
        const Text(
          'يحفظ السجل المصدر والتعديلات والاعتماد. لكل إصدار جلساته المرتبطة به؛ لا تعيد المراجعة كتابة خطة سابقة.',
        ),
        for (final version in [..._history, widget.plan.data])
          Card(
            child: ExpansionTile(
              title: Text(
                'الإصدار ${version['version']} · ${version['status'] == 'approved' ? 'معتمد' : 'مسودة مقترحة'}',
              ),
              subtitle: Text(
                '${version['source'] == 'ai' ? 'مصدر: اقتراح الذكاء الاصطناعي' : 'مصدر: تعديل المختصة'} · ${version['createdAt']}',
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (version['approvedAt'] != null)
                        Text('تاريخ الاعتماد: ${version['approvedAt']}'),
                      SectionHeading(
                        (version['content'] as Map)['generalGoal'] as String,
                      ),
                      for (final goal
                          in (version['content'] as Map)['goals'] as List)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          child: Text(
                            '${(goal as Map)['behavior']} · ${goal['condition']} · ${criterionLabelForProgress(Map<String, dynamic>.from(goal['criterion'] as Map))} · خلال ${goal['timeframeWeeks']} أسابيع',
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}
