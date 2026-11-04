import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../data/assessment_templates.dart';
import '../models/assessment.dart';
import '../models/student.dart';
import '../widgets/common.dart';
import 'assessment_screen.dart';

class StudentsScreen extends StatelessWidget {
  const StudentsScreen({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(18),
    children: [
      const PrototypeNote(),
      const SectionHeading(
        'ملفات الطلبة',
        subtitle: 'رموز مجّهلة فقط، بلا أسماء أو تواريخ ميلاد',
      ),
      FilledButton.icon(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => StudentFormScreen(state: state),
          ),
        ),
        icon: const Icon(Icons.add),
        label: const Text('إضافة ملف طالب'),
      ),
      const SizedBox(height: 14),
      if (state.students.isEmpty)
        const Card(
          child: Padding(
            padding: EdgeInsets.all(22),
            child: Text('لا توجد ملفات بعد. أنشئ رمزًا تجريبيًا للبدء.'),
          ),
        ),
      for (final student in state.students)
        Card(
          child: ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person_outline)),
            title: Text(
              'الطالب ${student.code}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              'الصف: ${student.grade} · ${student.ageLabel}\n${syncStatusLabel(state.stateFor(student.id))}',
            ),
            trailing: const Icon(Icons.chevron_left),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) =>
                    StudentDetailScreen(state: state, studentId: student.id),
              ),
            ),
          ),
        ),
    ],
  );
}

class StudentFormScreen extends StatefulWidget {
  const StudentFormScreen({super.key, required this.state});
  final AppState state;

  @override
  State<StudentFormScreen> createState() => _StudentFormScreenState();
}

class _StudentFormScreenState extends State<StudentFormScreen> {
  String _grade = 'الثاني الأساسي';
  int _years = 7;
  int _months = 0;
  bool _consent = false;
  bool _saving = false;

  Future<void> _submit() async {
    if (_saving) {
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.state.createStudent(
        grade: _grade,
        ageYears: _years,
        ageMonths: _months,
        consentConfirmed: _consent,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        showError(context, e);
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('ملف طالب جديد')),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const PrototypeNote(),
        const SectionHeading('البيانات الأساسية المجهّلة'),
        const Text(
          'يُنشأ رمز عشوائي تلقائيًا مثل ST-XXXXXXXX. احتفظي بربط الرمز بالاسم على الورق خارج التطبيق.',
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: _grade,
          decoration: const InputDecoration(labelText: 'الصف الدراسي'),
          isExpanded: true,
          items: [
            for (final grade in supportedSchoolGrades)
              DropdownMenuItem(value: grade, child: Text(grade)),
          ],
          onChanged: (value) => setState(() => _grade = value ?? _grade),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: _years,
                decoration: const InputDecoration(labelText: 'العمر - سنوات'),
                items: [
                  for (var i = 3; i <= 21; i++)
                    DropdownMenuItem(value: i, child: Text('$i')),
                ],
                onChanged: (value) => setState(() => _years = value ?? _years),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: _months,
                decoration: const InputDecoration(labelText: 'الأشهر'),
                items: [
                  for (var i = 0; i < 12; i++)
                    DropdownMenuItem(value: i, child: Text('$i')),
                ],
                onChanged: (value) =>
                    setState(() => _months = value ?? _months),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        CheckboxListTile(
          value: _consent,
          onChanged: (value) => setState(() => _consent = value ?? false),
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'أؤكد الحصول على الموافقة المطلوبة وفق سياسة المؤسسة',
          ),
          subtitle: const Text(
            'يُسجّل الإقرار وتاريخه فقط، ولا يُخزّن اسم ولي الأمر.',
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(_saving ? 'جارٍ الحفظ…' : 'حفظ الملف محليًا'),
          ),
        ),
      ],
    ),
  );
}

class StudentDetailScreen extends StatelessWidget {
  const StudentDetailScreen({
    super.key,
    required this.state,
    required this.studentId,
  });
  final AppState state;
  final String studentId;

  Future<void> _startAssessment(
    BuildContext context,
    StudentRecord student,
  ) async {
    final recommended = recommendedAgeGroup(student);
    final choice = await showDialog<({String group, String reason})>(
      context: context,
      builder: (ctx) => _AssessmentStartDialog(recommended: recommended),
    );
    if (choice == null || !context.mounted) {
      return;
    }
    try {
      final assessment = await state.createAssessment(
        studentId: student.id,
        overrideGroup: choice.group,
        overrideReason: choice.reason,
        privacyReviewed: true,
      );
      if (context.mounted) {
        Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) =>
                AssessmentScreen(state: state, assessmentId: assessment.id),
          ),
        );
      }
    } catch (error) {
      if (context.mounted) {
        showError(context, error);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state,
    builder: (context, _) {
      final student = state.studentById(studentId);
      final assessments = state.assessmentsFor(studentId);
      return Scaffold(
        appBar: AppBar(title: Text('ملف ${student.code}')),
        body: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            const PrototypeNote(),
            const SizedBox(height: 15),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'رمز الملف: ${student.code}',
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text('الصف: ${student.grade} · العمر: ${student.ageLabel}'),
                    const SizedBox(height: 5),
                    Text(
                      'إقرار الموافقة: ${student.consentConfirmed ? 'موثق' : 'غير موثق'}',
                    ),
                  ],
                ),
              ),
            ),
            const SectionHeading('التقييم الأكاديمي الأولي'),
            FilledButton.icon(
              onPressed: recommendedAgeGroup(student) == null
                  ? null
                  : () => _startAssessment(context, student),
              icon: const Icon(Icons.note_add_outlined),
              label: const Text('بدء تقييم جديد'),
            ),
            const SizedBox(height: 12),
            if (recommendedAgeGroup(student) == null)
              const Text(
                'العمر خارج نطاق البطاقات 6–12 سنة؛ مسار التقييم التربوي الحر لم يُنفذ بعد.',
              ),
            if (assessments.isEmpty)
              const Text('لم يتم تسجيل أي تقييم لهذا الملف بعد.'),
            for (final assessment in assessments)
              Card(
                child: ListTile(
                  title: Text(
                    'بطاقات ${assessment.ageGroup} سنة - ${_statusLabel(assessment.status)}',
                  ),
                  subtitle: Text(
                    'قالب ${assessment.templateVersion} · ${assessment.createdAt.substring(0, 10)}\n${syncStatusLabel(state.stateFor(assessment.id))}',
                  ),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => AssessmentScreen(
                        state: state,
                        assessmentId: assessment.id,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

String _statusLabel(AssessmentStatus value) => switch (value) {
  AssessmentStatus.draft => 'مسودة',
  AssessmentStatus.completed => 'مكتمل للمراجعة',
  AssessmentStatus.approved => 'معتمد',
};

class _AssessmentStartDialog extends StatefulWidget {
  const _AssessmentStartDialog({required this.recommended});
  final String? recommended;

  @override
  State<_AssessmentStartDialog> createState() => _AssessmentStartDialogState();
}

class _AssessmentStartDialogState extends State<_AssessmentStartDialog> {
  String _group = '6-8';
  bool _privacyReviewed = false;
  final _reason = TextEditingController();

  @override
  void initState() {
    super.initState();
    _group = widget.recommended ?? '6-8';
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('اختيار بطاقة التقييم'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.recommended == null
                ? 'العمر خارج نطاق البطاقات الجاهزة؛ لا تبدأ إلا بعد مراجعة تربوية.'
                : 'الفئة المناسبة للعمر المسجل: ${widget.recommended} سنة.',
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _group,
            decoration: const InputDecoration(labelText: 'الفئة العمرية'),
            items: const [
              DropdownMenuItem(value: '6-8', child: Text('6 إلى 8 سنوات')),
              DropdownMenuItem(value: '9-12', child: Text('9 إلى 12 سنة')),
            ],
            onChanged: (value) => setState(() => _group = value ?? _group),
          ),
          if (_group != widget.recommended) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _reason,
              maxLines: 2,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'المسوّغ التربوي لاختيار فئة مختلفة',
              ),
            ),
          ],
          CheckboxListTile(
            value: _privacyReviewed,
            onChanged: (v) => setState(() => _privacyReviewed = v ?? false),
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'أؤكد خلو المسوّغ والمدخلات من الأسماء وبيانات التعريف والتشخيص؛ سأراجع النصوص قبل حفظها ومزامنتها.',
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('إلغاء'),
      ),
      FilledButton(
        onPressed:
            (!_privacyReviewed ||
                widget.recommended == null ||
                (_group != widget.recommended && _reason.text.trim().isEmpty))
            ? null
            : () =>
                  Navigator.pop(context, (group: _group, reason: _reason.text)),
        child: const Text('بدء'),
      ),
    ],
  );
}
