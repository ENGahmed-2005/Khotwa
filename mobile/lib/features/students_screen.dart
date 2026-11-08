import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../data/assessment_templates.dart';
import '../models/assessment.dart';
import '../models/student.dart';
import '../widgets/common.dart';
import 'assessment_screen.dart';
import 'initial_assessment_screen.dart';

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
  const StudentFormScreen({super.key, required this.state, this.studentId});
  final AppState state;
  final String? studentId;

  @override
  State<StudentFormScreen> createState() => _StudentFormScreenState();
}

class _StudentFormScreenState extends State<StudentFormScreen> {
  String _grade = 'الثاني الأساسي';
  int _years = 7;
  int _months = 0;
  bool _consent = false;
  bool _saving = false;
  bool _privacy = false;
  String _gender = 'unspecified';
  int _weeks = 8, _sessions = 2, _minutes = 30;
  final _referral = TextEditingController(),
      _observation = TextEditingController(),
      _difficulties = TextEditingController(),
      _family = TextEditingController(),
      _teacher = TextEditingController();
  @override
  void initState() {
    super.initState();
    if (widget.studentId != null) {
      final old = widget.state.studentById(widget.studentId!);
      _grade = old.grade;
      _years = old.ageYears;
      _months = old.ageMonths;
      _consent = old.consentConfirmed;
      _gender = old.gender;
      _weeks = old.proposedDurationWeeks;
      _sessions = old.sessionsPerWeek;
      _minutes = old.sessionMinutes;
      _referral.text = old.referralReason;
      _observation.text = old.classroomObservation;
      _difficulties.text = old.difficulties;
      _family.text = old.familyNotes;
      _teacher.text = old.teacherNotes;
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _referral,
      _observation,
      _difficulties,
      _family,
      _teacher,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) {
      return;
    }
    setState(() => _saving = true);
    try {
      if (widget.studentId == null) {
        await widget.state.createStudent(
          grade: _grade,
          ageYears: _years,
          ageMonths: _months,
          consentConfirmed: _consent,
          gender: _gender,
          referralReason: _referral.text,
          classroomObservation: _observation.text,
          difficulties: _difficulties.text,
          familyNotes: _family.text,
          teacherNotes: _teacher.text,
          proposedDurationWeeks: _weeks,
          sessionsPerWeek: _sessions,
          sessionMinutes: _minutes,
          privacyReviewed: _privacy,
        );
      } else {
        final old = widget.state.studentById(widget.studentId!);
        await widget.state.updateStudentIntake(
          StudentRecord(
            id: old.id,
            code: old.code,
            grade: _grade,
            ageYears: _years,
            ageMonths: _months,
            consentConfirmed: _consent,
            consentDate: old.consentDate,
            createdAt: old.createdAt,
            gender: _gender,
            referralReason: _referral.text,
            classroomObservation: _observation.text,
            difficulties: _difficulties.text,
            familyNotes: _family.text,
            teacherNotes: _teacher.text,
            proposedDurationWeeks: _weeks,
            sessionsPerWeek: _sessions,
            sessionMinutes: _minutes,
          ),
          privacyReviewed: _privacy,
        );
      }
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
    appBar: AppBar(
      title: Text(
        widget.studentId == null ? 'ملف طالب جديد' : 'تحديث البيانات المجهّلة',
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const PrototypeNote(),
        const SectionHeading('١. البيانات الأساسية المجهّلة'),
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
        DropdownButtonFormField<String>(
          initialValue: _gender,
          decoration: const InputDecoration(
            labelText: 'الجنس لصياغة الطالب / الطالبة فقط',
          ),
          items: const [
            DropdownMenuItem(value: 'unspecified', child: Text('غير محدد')),
            DropdownMenuItem(value: 'male', child: Text('طالب')),
            DropdownMenuItem(value: 'female', child: Text('طالبة')),
          ],
          onChanged: (v) => setState(() => _gender = v!),
        ),
        const SectionHeading('٢. ملاحظة الأداء الصفي والصعوبات'),
        const Text(
          'اكتبي وصفًا تربويًا بلا اسم أو تاريخ ميلاد أو بيانات اتصال أو تشخيص. معلومات التشخيص تبقى خارج التطبيق لدى المختصين.',
        ),
        _intakeText(_referral, 'سبب الإحالة'),
        _intakeText(_observation, 'ملاحظة الأداء داخل الصف'),
        _intakeText(_difficulties, 'الصعوبات التعليمية الملحوظة'),
        const SectionHeading('٣. ملاحظات الأسرة والمعلمين (مستحسنة)'),
        _intakeText(_family, 'ملاحظات الأسرة دون أسمائهم'),
        _intakeText(_teacher, 'ملاحظات المعلمين دون أسمائهم'),
        const SectionHeading('٤. المدة المقترحة والقابلة للتعديل'),
        _numberChoice(
          'مدة الخطة بالأسابيع',
          _weeks,
          104,
          (v) => setState(() => _weeks = v),
        ),
        _numberChoice(
          'الجلسات الأسبوعية',
          _sessions,
          14,
          (v) => setState(() => _sessions = v),
        ),
        _numberChoice(
          'زمن الجلسة بالدقائق',
          _minutes,
          240,
          (v) => setState(() => _minutes = v),
        ),
        const Text(
          'القيم المقترحة قابلة للتعديل وفق تقييمك، ولا تعني قرارًا علاجيًا آليًا.',
        ),
        const SectionHeading('٥. الموافقة والخصوصية'),
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
        CheckboxListTile(
          value: _privacy,
          onChanged: _saving
              ? null
              : (v) => setState(() => _privacy = v ?? false),
          title: const Text(
            'راجعت الحقول الحرة وأؤكد خلوها من الهوية والمعلومات الصحية',
          ),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(_saving ? 'جارٍ الحفظ…' : 'حفظ الملف محليًا'),
          ),
        ),
        const Text(
          'بعد حفظ الملف: سجّلي التقييم الأولي وحددي القوة والاحتياج، ثم راجعي المصدر واعتمديه قبل توليد خطة.',
        ),
      ],
    ),
  );
  Widget _intakeText(TextEditingController controller, String label) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: TextField(
      controller: controller,
      maxLines: 3,
      maxLength: 2000,
      decoration: InputDecoration(
        labelText: label,
        helperText:
            'وصف أداء فقط؛ لا تُرسل هذه النصوص تلقائيًا للذكاء الاصطناعي',
        border: const OutlineInputBorder(),
      ),
    ),
  );
  Widget _numberChoice(
    String label,
    int selected,
    int limit,
    ValueChanged<int> changed,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: DropdownButtonFormField<int>(
      initialValue: selected,
      decoration: InputDecoration(labelText: label),
      items: [
        for (var i = 1; i <= limit; i++)
          DropdownMenuItem(value: i, child: Text('$i')),
      ],
      onChanged: (v) => changed(v!),
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
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
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
            OutlinedButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      StudentFormScreen(state: state, studentId: studentId),
                ),
              ),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('مراجعة الملاحظات والبيانات الأساسية'),
            ),
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
                'العمر خارج نطاق البطاقات 6–12 سنة؛ استخدمي التقييم التربوي الحر أدناه.',
              ),
            const SectionHeading('التقييم الأولي الحر والقوة والاحتياج'),
            OutlinedButton.icon(
              onPressed: () async {
                try {
                  final value = await state.createInitialAssessment(studentId);
                  if (context.mounted) {
                    await Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => InitialAssessmentScreen(
                          state: state,
                          assessmentId: value.id,
                        ),
                      ),
                    );
                  }
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
              icon: const Icon(Icons.checklist_outlined),
              label: const Text('بدء تقييم تربوي أولي'),
            ),
            for (final initial in state.initialAssessmentsFor(studentId))
              Card(
                child: ListTile(
                  title: Text(
                    'تقييم ${initial.assessedOn} · ${initial.approved ? 'معتمد' : 'مسودة'}',
                  ),
                  subtitle: Text(syncStatusLabel(state.stateFor(initial.id))),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => InitialAssessmentScreen(
                        state: state,
                        assessmentId: initial.id,
                      ),
                    ),
                  ),
                ),
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
