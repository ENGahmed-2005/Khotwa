import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../models/intervention_session.dart';
import '../widgets/common.dart';

class ProgressScreen extends StatefulWidget {
  const ProgressScreen({super.key, required this.state});
  final AppState state;
  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  String? _planId, _goalId;
  bool _line = false;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.state,
    builder: (context, _) {
      final plans = widget.state.plans.where((p) => p.approved).toList();
      final plan = plans.where((p) => p.id == _planId).firstOrNull;
      final goals = ((plan?.content['goals'] as List?) ?? [])
          .map((g) => Map<String, dynamic>.from(g as Map))
          .toList();
      final goal = goals.where((g) => g['id'] == _goalId).firstOrNull;
      final sessions =
          widget.state.sessions
              .where((s) => s.planVersionId == _planId && s.goalId == _goalId)
              .toList()
            ..sort(
              (a, b) => a.occurredOn.compareTo(b.occurredOn) == 0
                  ? a.id.compareTo(b.id)
                  : a.occurredOn.compareTo(b.occurredOn),
            );
      final attendance = AttendanceSummary.fromSessions(sessions);
      final criterion = goal == null
          ? null
          : Map<String, dynamic>.from(goal['criterion'] as Map);
      return Scaffold(
        appBar: AppBar(title: const Text('رحلة التقدم')),
        body: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            const PrototypeNote(),
            const Text(
              'مؤشرات وصفية من الجلسات المسجلة فقط. لا تستنتج هذه الشاشة إتقانًا معياريًا أو تشخيصًا، ولا تخلط نتائج التقييم الأولي بدقة جلسات التدخل.',
            ),
            DropdownButtonFormField<String>(
              initialValue: _planId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'خطة الطالب المعتمدة',
              ),
              items: plans
                  .map(
                    (p) => DropdownMenuItem(
                      value: p.id,
                      child: Text(
                        '${widget.state.studentById(p.studentId).code} · نسخة ${p.data['version']}',
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() {
                _planId = v;
                _goalId = null;
              }),
            ),
            DropdownButtonFormField<String>(
              key: ValueKey('progress-goal-$_planId'),
              initialValue: _goalId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'الهدف العلاجي'),
              items: goals
                  .map(
                    (g) => DropdownMenuItem(
                      value: g['id'] as String,
                      child: Text(
                        g['behavior'] as String,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 3,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _goalId = v),
            ),
            if (goal != null) ...[
              SectionHeading(
                'معيار الهدف: ${criterionLabelForProgress(criterion!)}',
              ),
              Text(
                'الانتظام: ${attendance.completed} جلسة تمت من ${attendance.scheduled} مجدولة${attendance.percent == null ? '' : ' · ${attendance.percent!.toStringAsFixed(1)}٪'}. تُستبعد الملغاة من المقام، والغياب بلا درجة أداء.',
              ),
              SwitchListTile(
                title: const Text('عرض خطي بدل الأعمدة'),
                value: _line,
                onChanged: (v) => setState(() => _line = v),
              ),
              if (sessions.isEmpty)
                const Text('لم تُسجل جلسات لهذا الهدف بعد.')
              else
                ProgressChart(
                  sessions: sessions,
                  criterion: criterion,
                  line: _line,
                ),
              const SectionHeading('بيانات الرسم القابلة للقراءة'),
              for (final s in sessions)
                Card(
                  child: ListTile(
                    title: Text(
                      '${s.occurredOn} · ${sessionStatuses[s.status]}',
                    ),
                    subtitle: Text(
                      s.accuracy == null
                          ? 'لا توجد نتيجة أداء لهذه الجلسة'
                          : '${s.correct} صحيحة من ${s.total} · دقة ${s.accuracy!.toStringAsFixed(1)}٪ · دعم ${supportLevels[s.support]}',
                    ),
                  ),
                ),
            ],
          ],
        ),
      );
    },
  );
}

String criterionLabelForProgress(Map<String, dynamic> criterion) =>
    switch (criterion['type']) {
      'percentage' => 'دقة ${criterion['target']}٪',
      'trials' => '${criterion['correct']} من ${criterion['total']} محاولة',
      'consistency' =>
        'دقة ${criterion['targetPercent']}٪ عبر ${criterion['sessions']} جلسات',
      'independence' => 'دعم ${supportLevels[criterion['support']]}',
      _ => 'راجعي معيار الهدف',
    };
double? criterionPercent(Map<String, dynamic>? criterion) =>
    switch (criterion?['type']) {
      'percentage' => (criterion!['target'] as num).toDouble(),
      'trials' =>
        (criterion!['correct'] as num) / (criterion['total'] as num) * 100,
      'consistency' => (criterion!['targetPercent'] as num).toDouble(),
      _ => null,
    };

class ProgressChart extends StatelessWidget {
  const ProgressChart({
    super.key,
    required this.sessions,
    this.criterion,
    this.line = false,
  });
  final List<InterventionSession> sessions;
  final Map<String, dynamic>? criterion;
  final bool line;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('دقة الأداء (%) عبر الجلسات بالتسلسل الزمني'),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: (sessions.length * 64.0 + 60).clamp(300, 100000),
          height: 270,
          child: Semantics(
            label:
                'رسم ${line ? 'خطي' : 'أعمدة'} لدقة الأداء؛ القيم والتواريخ مكتوبة أسفله',
            child: CustomPaint(
              painter: _ProgressPainter(
                sessions,
                criterionPercent(criterion),
                line,
                Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ),
      ),
      if (criterionPercent(criterion) != null)
        Text(
          'الخط المتقطع: معيار الهدف ${criterionPercent(criterion)!.toStringAsFixed(1)}٪',
        ),
      const Text('الرمز × يعني غيابًا أو إلغاءً بلا نتيجة، وليس صفرًا.'),
    ],
  );
}

class _ProgressPainter extends CustomPainter {
  _ProgressPainter(this.sessions, this.target, this.line, this.color);
  final List<InterventionSession> sessions;
  final double? target;
  final bool line;
  final Color color;
  void _label(
    Canvas canvas,
    String text,
    Offset at, {
    Color color = Colors.black,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: 11, color: color),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at);
  }

  @override
  void paint(Canvas canvas, Size size) {
    const top = 20.0, left = 40.0, bottom = 225.0;
    final width = size.width - left - 12;
    final paint = Paint()
      ..color = Colors.black54
      ..strokeWidth = 1;
    for (var value = 0; value <= 100; value += 25) {
      final y = bottom - (bottom - top) * value / 100;
      canvas.drawLine(
        Offset(left, y),
        Offset(size.width - 8, y),
        paint..color = Colors.black12,
      );
      _label(canvas, '$value', Offset(6, y - 7));
    }
    canvas.drawLine(
      const Offset(left, top),
      const Offset(left, bottom),
      paint..color = Colors.black54,
    );
    canvas.drawLine(
      const Offset(left, bottom),
      Offset(size.width - 8, bottom),
      paint,
    );
    if (target != null) {
      final y = bottom - (bottom - top) * target! / 100;
      for (var x = left; x < size.width - 8; x += 10) {
        canvas.drawLine(
          Offset(x, y),
          Offset((x + 6).clamp(0, size.width - 8), y),
          paint
            ..color = Colors.black
            ..strokeWidth = 2,
        );
      }
      _label(
        canvas,
        '${target!.toStringAsFixed(0)}%',
        Offset(left + 3, y - 16),
      );
    }
    Offset? previous;
    for (var i = 0; i < sessions.length; i++) {
      final session = sessions[i],
          x = left + width * (i + .5) / sessions.length;
      _label(canvas, '${i + 1}', Offset(x - 4, bottom + 8));
      final accuracy = session.accuracy;
      if (accuracy == null) {
        _label(canvas, '×', Offset(x - 4, bottom - 22));
        previous = null;
        continue;
      }
      final y = bottom - (bottom - top) * accuracy / 100;
      paint
        ..color = color
        ..strokeWidth = 3;
      if (line) {
        final point = Offset(x, y);
        if (previous != null) canvas.drawLine(previous, point, paint);
        canvas.drawCircle(point, 4, paint);
        previous = point;
      } else {
        canvas.drawRect(Rect.fromLTRB(x - 12, y, x + 12, bottom), paint);
      }
      _label(canvas, accuracy.toStringAsFixed(0), Offset(x - 8, y - 16));
    }
  }

  @override
  bool shouldRepaint(covariant _ProgressPainter old) =>
      old.sessions != sessions ||
      old.target != target ||
      old.line != line ||
      old.color != color;
}
