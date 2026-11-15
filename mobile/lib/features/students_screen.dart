import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/app_state.dart';
import '../core/form_draft.dart';
import '../core/khotwa_theme.dart';
import '../data/assessment_templates.dart';
import '../models/assessment.dart';
import '../models/student.dart';
import '../models/initial_assessment.dart';
import '../widgets/common.dart';
import '../widgets/khotwa_ui.dart';
import 'assessment_screen.dart';
import 'initial_assessment_screen.dart';

class StudentsScreen extends StatefulWidget {
  const StudentsScreen({super.key, required this.state});
  final AppState state;

  @override
  State<StudentsScreen> createState() => _StudentsScreenState();
}

class _StudentsScreenState extends State<StudentsScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _openStudent(StudentRecord student) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) =>
          StudentDetailScreen(state: widget.state, studentId: student.id),
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.state,
    builder: (context, _) {
      final students = widget.state.students.reversed.toList();
      final query = _search.text.trim().toLowerCase();
      final visible = students
          .where(
            (student) =>
                student.code.toLowerCase().contains(query) ||
                student.grade.contains(query),
          )
          .toList();
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(18),
            children: [
              const PrototypeNote(),
              const KhotwaPageIntro(
                title: 'ملفات الطلبة',
                description:
                    'ملف واحد يجمع الملاحظات والتقييمات. افتحي رمز الطالب لمتابعة الخطوة التالية.',
                icon: Icons.folder_shared_outlined,
              ),
              FilledButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => StudentFormScreen(state: widget.state),
                  ),
                ),
                icon: const Icon(Icons.person_add_alt_1_rounded),
                label: const Text('إضافة ملف طالب'),
              ),
              const SizedBox(height: 18),
              if (students.isEmpty)
                const KhotwaEmptyState(
                  title: 'ابدئي بأول ملف طالب',
                  message:
                      'اضغطي «إضافة ملف طالب». ينشئ خطوة رمزًا مجهّلًا، ثم يمكنك تسجيل الملاحظات والتقييم.',
                  icon: Icons.folder_open_rounded,
                )
              else ...[
                TextField(
                  key: const ValueKey('students-search'),
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'البحث',
                    helperText: 'رمز الطالب أو الصف الدراسي',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'مسح البحث',
                            onPressed: () => setState(_search.clear),
                            icon: const Icon(Icons.close_rounded),
                          ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'عرض ${visible.length} من ${students.length} ملف',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 6),
                if (visible.isEmpty)
                  const KhotwaEmptyState(
                    title: 'لم نجد ملفًا مطابقًا',
                    message:
                        'راجعي الرمز المكتوب أو ابحثي بالصف الدراسي. يمكنك مسح البحث لعرض جميع الملفات.',
                    icon: Icons.search_off_rounded,
                  ),
                for (final student in visible) _studentCard(context, student),
              ],
              const SizedBox(height: 18),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.shield_outlined,
                    size: 18,
                    color: KhotwaPalette.muted,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      'تُعرض رموز مجهّلة فقط. احتفظي بمطابقة الرمز مع الاسم خارج التطبيق.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _studentCard(BuildContext context, StudentRecord student) {
    final assessments =
        widget.state.assessmentsFor(student.id).length +
        widget.state.initialAssessmentsFor(student.id).length;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openStudent(student),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: KhotwaPalette.paleAmber,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.school_outlined,
                  color: KhotwaPalette.navy,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'الطالب ${student.code}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${student.grade} · ${student.ageLabel}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      assessments == 0
                          ? 'جاهز لبدء التقييم'
                          : '$assessments تقييمات محفوظة',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: KhotwaPalette.navy,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      syncStatusLabel(widget.state.stateFor(student.id)),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
  late final FormDraftController _formDraft;
  String _newId = const Uuid().v4();
  bool _restorationFailed = false;
  String? _draftError;
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
    _formDraft = FormDraftController(
      state: widget.state,
      key: 'student-form:${widget.studentId ?? 'new'}',
      validate: (value) => educationalTextIssue([
        for (final key in [
          'referralReason',
          'classroomObservation',
          'difficulties',
          'familyNotes',
          'teacherNotes',
        ])
          value[key] as String,
      ]),
    );
    final saved = _formDraft.restored;
    if (saved != null) {
      try {
        _newId = saved['entityId'] as String;
        _grade = saved['grade'] as String;
        _years = saved['ageYears'] as int;
        _months = saved['ageMonths'] as int;
        _gender = saved['gender'] as String;
        _weeks = saved['proposedDurationWeeks'] as int;
        _sessions = saved['sessionsPerWeek'] as int;
        _minutes = saved['sessionMinutes'] as int;
        _referral.text = saved['referralReason'] as String;
        _observation.text = saved['classroomObservation'] as String;
        _difficulties.text = saved['difficulties'] as String;
        _family.text = saved['familyNotes'] as String;
        _teacher.text = saved['teacherNotes'] as String;
        final existing = widget.state.students
            .where((s) => s.id == _newId)
            .firstOrNull;
        if (existing != null) _consent = existing.consentConfirmed;
      } catch (_) {
        _restorationFailed = true;
        _draftError =
            'تعذّر فتح مسودة الملف. بقيت محفوظة؛ يمكن إلغاؤها صراحةً.';
      }
    }
    for (final controller in [
      _referral,
      _observation,
      _difficulties,
      _family,
      _teacher,
    ]) {
      controller.addListener(_changed);
    }
  }

  void _changed() {
    if (_restorationFailed) return;
    _formDraft.update({
      'entityId': widget.studentId ?? _newId,
      'grade': _grade,
      'ageYears': _years,
      'ageMonths': _months,
      'gender': _gender,
      'referralReason': _referral.text,
      'classroomObservation': _observation.text,
      'difficulties': _difficulties.text,
      'familyNotes': _family.text,
      'teacherNotes': _teacher.text,
      'proposedDurationWeeks': _weeks,
      'sessionsPerWeek': _sessions,
      'sessionMinutes': _minutes,
    });
  }

  void _edit(VoidCallback action) {
    if (_saving) return;
    setState(action);
    _changed();
  }

  @override
  void dispose() {
    _formDraft.dispose();
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
    if (_saving || _restorationFailed) {
      return;
    }
    setState(() => _saving = true);
    try {
      await _formDraft.flush();
      final existingId =
          widget.studentId ??
          widget.state.students.where((s) => s.id == _newId).firstOrNull?.id;
      if (existingId == null) {
        await widget.state.createStudent(
          id: _newId,
          draftKey: _formDraft.key,
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
        final old = widget.state.studentById(existingId);
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
          draftKey: _formDraft.key,
        );
      }
      _formDraft.acknowledgeSaved();
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
  Widget build(BuildContext context) => FormDraftGuard(
    controller: _formDraft,
    child: Scaffold(
      appBar: AppBar(
        actions: [
          DiscardFormDraftButton(controller: _formDraft, enabled: !_saving),
        ],
        title: Text(
          widget.studentId == null
              ? 'ملف طالب جديد'
              : 'تحديث البيانات المجهّلة',
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(18),
            children: [
              const PrototypeNote(),
              KhotwaPageIntro(
                title: widget.studentId == null
                    ? 'لنبدأ بملف الطالب'
                    : 'تحديث ملف الطالب',
                description:
                    'سجّلي البيانات والملاحظات، ثم راجعي الموافقة واحفظي الملف. يمكنك العودة لإكمال المسودة.',
                icon: Icons.person_add_alt_1_outlined,
              ),
              FormDraftStatus(controller: _formDraft),
              if (_draftError != null) Text(_draftError!),
              KhotwaSectionCard(
                title: '١. البيانات الأساسية المجهّلة',
                icon: Icons.badge_outlined,
                subtitle:
                    'يُنشأ رمز عشوائي تلقائيًا. احتفظي بربط الرمز بالاسم على الورق خارج التطبيق.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: _grade,
                      decoration: const InputDecoration(
                        labelText: 'الصف الدراسي',
                      ),
                      isExpanded: true,
                      items: [
                        for (final grade in supportedSchoolGrades)
                          DropdownMenuItem(value: grade, child: Text(grade)),
                      ],
                      onChanged: _saving
                          ? null
                          : (value) => _edit(() => _grade = value ?? _grade),
                    ),
                    const SizedBox(height: 16),
                    _ageChoices(),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      initialValue: _gender,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'صياغة الطالب / الطالبة',
                        helperText: 'تُستخدم لصياغة النصوص فقط',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'unspecified',
                          child: Text('غير محدد'),
                        ),
                        DropdownMenuItem(value: 'male', child: Text('طالب')),
                        DropdownMenuItem(value: 'female', child: Text('طالبة')),
                      ],
                      onChanged: _saving
                          ? null
                          : (v) => _edit(() => _gender = v!),
                    ),
                  ],
                ),
              ),
              KhotwaSectionCard(
                title: '٢. ملاحظة الأداء الصفي والصعوبات',
                icon: Icons.edit_note_rounded,
                subtitle:
                    'وصف تربوي فقط، بلا أسماء أو تواريخ ميلاد أو بيانات اتصال أو تشخيص. لا تُرسل النصوص الحرة تلقائيًا للذكاء الاصطناعي.',
                child: Column(
                  children: [
                    _intakeText(_referral, 'سبب الإحالة'),
                    _intakeText(_observation, 'ملاحظة الأداء داخل الصف'),
                    _intakeText(_difficulties, 'الصعوبات التعليمية الملحوظة'),
                  ],
                ),
              ),
              KhotwaSectionCard(
                title: '٣. ملاحظات الأسرة والمعلمين (مستحسنة)',
                icon: Icons.forum_outlined,
                subtitle:
                    'معلومات تساعدك على فهم الأداء في مواقف مختلفة، دون تسجيل أسماء أصحاب الملاحظات.',
                child: Column(
                  children: [
                    _intakeText(_family, 'ملاحظات الأسرة دون أسمائهم'),
                    _intakeText(_teacher, 'ملاحظات المعلمين دون أسمائهم'),
                  ],
                ),
              ),
              KhotwaSectionCard(
                title: '٤. المدة المقترحة والقابلة للتعديل',
                icon: Icons.event_note_outlined,
                subtitle:
                    'عدّلي هذه القيم وفق تقييمك. لا تعني القيم المقترحة قرارًا علاجيًا آليًا.',
                child: Column(
                  children: [
                    _numberChoice(
                      'مدة الخطة بالأسابيع',
                      _weeks,
                      104,
                      (v) => _edit(() => _weeks = v),
                    ),
                    _numberChoice(
                      'الجلسات الأسبوعية',
                      _sessions,
                      14,
                      (v) => _edit(() => _sessions = v),
                    ),
                    _numberChoice(
                      'زمن الجلسة بالدقائق',
                      _minutes,
                      240,
                      (v) => _edit(() => _minutes = v),
                    ),
                  ],
                ),
              ),
              KhotwaSectionCard(
                title: '٥. الموافقة والخصوصية',
                icon: Icons.verified_user_outlined,
                child: Column(
                  children: [
                    CheckboxListTile(
                      value: _consent,
                      onChanged: _saving
                          ? null
                          : (value) =>
                                setState(() => _consent = value ?? false),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
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
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text(
                        'راجعت الحقول الحرة وأؤكد خلوها من الهوية والمعلومات الصحية',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _saving ? null : _submit,
                child: Text(_saving ? 'جارٍ الحفظ…' : 'حفظ الملف محليًا'),
              ),
              const SizedBox(height: 12),
              const Text(
                'بعد حفظ الملف: سجّلي التقييم الأولي وحددي القوة والاحتياج، ثم راجعي المصدر واعتمديه قبل توليد خطة.',
              ),
            ],
          ),
        ),
      ),
    ),
  );
  Widget _intakeText(TextEditingController controller, String label) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: TextField(
      enabled: !_saving,
      controller: controller,
      minLines: 2,
      maxLines: 3,
      maxLength: 2000,
      decoration: InputDecoration(labelText: label),
    ),
  );
  Widget _ageChoices() => LayoutBuilder(
    builder: (context, constraints) {
      final stacked =
          constraints.maxWidth < 380 ||
          MediaQuery.textScalerOf(context).scale(14) > 21;
      final width = stacked
          ? constraints.maxWidth
          : (constraints.maxWidth - 12) / 2;
      return Wrap(
        spacing: 12,
        runSpacing: 14,
        children: [
          SizedBox(
            width: width,
            child: DropdownButtonFormField<int>(
              initialValue: _years,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'العمر - سنوات'),
              items: [
                for (var i = 3; i <= 21; i++)
                  DropdownMenuItem(value: i, child: Text('$i')),
              ],
              onChanged: _saving
                  ? null
                  : (value) => _edit(() => _years = value ?? _years),
            ),
          ),
          SizedBox(
            width: width,
            child: DropdownButtonFormField<int>(
              initialValue: _months,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'الأشهر'),
              items: [
                for (var i = 0; i < 12; i++)
                  DropdownMenuItem(value: i, child: Text('$i')),
              ],
              onChanged: _saving
                  ? null
                  : (value) => _edit(() => _months = value ?? _months),
            ),
          ),
        ],
      );
    },
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
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        for (var i = 1; i <= limit; i++)
          DropdownMenuItem(value: i, child: Text('$i')),
      ],
      onChanged: _saving ? null : (v) => changed(v!),
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

  Future<void> _startInitial(BuildContext context) async {
    try {
      final value = await state.createInitialAssessment(studentId);
      if (context.mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) =>
                InitialAssessmentScreen(state: state, assessmentId: value.id),
          ),
        );
      }
    } catch (error) {
      if (context.mounted) showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state,
    builder: (context, _) {
      final student = state.studentById(studentId);
      final assessments = state.assessmentsFor(studentId);
      final initials = state.initialAssessmentsFor(studentId);
      return Scaffold(
        appBar: AppBar(title: Text('ملف ${student.code}')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(18),
              children: [
                const PrototypeNote(),
                const KhotwaPageIntro(
                  title: 'ملف الطالب',
                  description:
                      'راجعي البيانات، ثم اختاري طريقة التقييم. كل تقييم محفوظ يظهر في سجل هذا الملف.',
                  icon: Icons.folder_shared_outlined,
                ),
                Card(
                  color: KhotwaPalette.paleBlue,
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
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            Chip(
                              avatar: const Icon(
                                Icons.school_outlined,
                                size: 17,
                              ),
                              label: Text(student.grade),
                            ),
                            Chip(
                              avatar: const Icon(Icons.cake_outlined, size: 17),
                              label: Text(student.ageLabel),
                            ),
                            Chip(
                              avatar: Icon(
                                student.consentConfirmed
                                    ? Icons.verified_user_outlined
                                    : Icons.info_outline,
                                size: 17,
                              ),
                              label: Text(
                                'إقرار الموافقة: ${student.consentConfirmed ? 'موثق' : 'غير موثق'}',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          syncStatusLabel(state.stateFor(studentId)),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
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
                const SectionHeading(
                  'التقييم الأكاديمي الأولي',
                  subtitle:
                      'اختاري طريقة تسجيل الأداء المناسبة؛ اعتماد التقييم يتم بعد مراجعته.',
                ),
                KhotwaSectionCard(
                  title: 'بطاقات الأداء الأكاديمي',
                  subtitle:
                      'بطاقات القراءة والكتابة والرياضيات للفئتين 6–8 و9–12 سنة.',
                  icon: Icons.style_outlined,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
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
                    ],
                  ),
                ),
                KhotwaSectionCard(
                  title: 'التقييم الأولي الحر والقوة والاحتياج',
                  subtitle:
                      'سجّلي ملاحظاتك وأدلة الأداء والمجالات التي تحتاج إلى متابعة.',
                  icon: Icons.fact_check_outlined,
                  child: OutlinedButton.icon(
                    onPressed: () => _startInitial(context),
                    icon: const Icon(Icons.checklist_outlined),
                    label: const Text('بدء تقييم تربوي أولي'),
                  ),
                ),
                SectionHeading(
                  'التقييمات المحفوظة',
                  subtitle:
                      '${assessments.length + initials.length} تقييمات لهذا الملف',
                ),
                if (assessments.isEmpty && initials.isEmpty)
                  const KhotwaEmptyState(
                    title: 'لم يتم تسجيل أي تقييم لهذا الملف بعد.',
                    message:
                        'ابدئي بأحد الخيارين أعلاه. ستجدين التقييم هنا للمتابعة والمراجعة.',
                    icon: Icons.assignment_outlined,
                  ),
                for (final initial in initials.reversed)
                  _AssessmentHistoryCard(
                    title:
                        'تقييم ${initial.assessedOn} · ${initial.approved ? 'معتمد' : 'مسودة'}',
                    description:
                        'تقييم تربوي أولي · ${syncStatusLabel(state.stateFor(initial.id))}',
                    approved: initial.approved,
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
                for (final assessment in assessments.reversed)
                  _AssessmentHistoryCard(
                    title:
                        'بطاقات ${assessment.ageGroup} سنة - ${_statusLabel(assessment.status)}',
                    description:
                        '${assessment.createdAt.substring(0, 10)} · ${syncStatusLabel(state.stateFor(assessment.id))}',
                    approved: assessment.status == AssessmentStatus.approved,
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
                const SizedBox(height: 18),
                Text(
                  'بعد مراجعة التقييم واعتماده، انتقلي إلى الخطط من الصفحة الرئيسية.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _AssessmentHistoryCard extends StatelessWidget {
  const _AssessmentHistoryCard({
    required this.title,
    required this.description,
    required this.approved,
    required this.onTap,
  });
  final String title, description;
  final bool approved;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: Icon(
        approved ? Icons.task_alt_rounded : Icons.edit_note_rounded,
        color: approved ? KhotwaPalette.teal : KhotwaPalette.navy,
      ),
      title: Text(title),
      subtitle: Text(description),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    ),
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
