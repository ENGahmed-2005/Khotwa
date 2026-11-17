import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/khotwa_theme.dart';
import 'common.dart';
import 'khotwa_backdrop.dart';

class SpecialistDashboard extends StatefulWidget {
  const SpecialistDashboard({
    super.key,
    required this.state,
    required this.onStudents,
    required this.onAddStudent,
    required this.onPlans,
    required this.onSessions,
    required this.onProgress,
    this.onActivities,
    this.onReports,
  });
  final AppState state;
  final VoidCallback onStudents, onAddStudent, onPlans, onSessions, onProgress;
  final VoidCallback? onActivities, onReports;
  @override
  State<SpecialistDashboard> createState() => _SpecialistDashboardState();
}

class _SpecialistDashboardState extends State<SpecialistDashboard> {
  int _guideStep = 0;
  @override
  Widget build(BuildContext context) => ListView(
    key: const PageStorageKey('specialist-dashboard'),
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
    children: [
      const PrototypeNote(),
      _welcome(),
      if (!widget.state.guideSeen) ...[const SizedBox(height: 18), _guide()],
      const SectionHeading(
        'خطوتكِ التالية',
        subtitle: 'ابدئي بملف طالب، ثم تابعي التقييم والخطة',
      ),
      FilledButton.icon(
        key: const ValueKey('home-add-student'),
        onPressed: widget.onAddStudent,
        icon: const Icon(Icons.person_add_alt_1_rounded, size: 22),
        label: Text(
          widget.state.students.isEmpty
              ? 'إضافة أول ملف طالب'
              : 'إضافة ملف طالب',
        ),
      ),
      const SizedBox(height: 10),
      OutlinedButton.icon(
        key: const ValueKey('home-quick-session'),
        onPressed: widget.onSessions,
        icon: const Icon(Icons.edit_calendar_outlined, size: 22),
        label: const Text('تسجيل جلسة متابعة'),
      ),
      const SectionHeading(
        'نظرة على عملكِ',
        subtitle: 'كل ما تحتاجينه لمتابعة طلابكِ',
      ),
      Container(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 10),
        decoration: _cardDecoration(),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _metric(
              'ملفات الطلبة',
              widget.state.students.length,
              Icons.groups_2_outlined,
            ),
            _metric(
              'خطط معتمدة',
              widget.state.plans.where((p) => p.approved).length,
              Icons.assignment_turned_in_outlined,
            ),
            _metric(
              'جلسات مسجّلة',
              widget.state.sessions.length,
              Icons.event_available_outlined,
            ),
          ],
        ),
      ),
      const SectionHeading('أدوات المختصة'),
      _tool(
        'ملفات الطلبة والتقييم',
        'ملف منظم وبطاقات لتوصيف الأداء',
        Icons.folder_shared_outlined,
        widget.onStudents,
        KhotwaPalette.paleBlue,
        key: const ValueKey('home-students'),
      ),
      _tool(
        'الخطط العلاجية',
        'راجعي المسودة واعتمدي أهداف الخطة',
        Icons.auto_awesome_outlined,
        widget.onPlans,
        KhotwaPalette.paleAmber,
        key: const ValueKey('home-plans'),
      ),
      _tool(
        'الأنشطة العلاجية',
        'أنشطة مرتبطة بالأهداف والأدوات المتاحة',
        Icons.extension_outlined,
        widget.onActivities,
        const Color(0xFFEAF3ED),
        key: const ValueKey('home-activities'),
      ),
      _tool(
        'الجلسات والتقدّم',
        'سجّلي الأداء وتابعي رحلة كل طالب',
        Icons.insights_rounded,
        widget.onSessions,
        KhotwaPalette.paleBlue,
        key: const ValueKey('home-sessions'),
      ),
      _tool(
        'التقارير',
        'تقارير للأهل والمدرسة والمختصة',
        Icons.description_outlined,
        widget.onReports,
        KhotwaPalette.paleAmber,
        key: const ValueKey('home-reports'),
      ),
      const SizedBox(height: 8),
      TextButton.icon(
        onPressed: widget.onProgress,
        icon: const Icon(Icons.show_chart_rounded),
        label: const Text('عرض رسوم التقدّم'),
      ),
      const SizedBox(height: 14),
      const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.shield_outlined, size: 17, color: KhotwaPalette.muted),
          SizedBox(width: 7),
          Flexible(
            child: Text(
              'ملفات الطلبة تظهر برموز مجهّلة',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: KhotwaPalette.muted),
            ),
          ),
        ],
      ),
    ],
  );

  BoxDecoration _cardDecoration() => BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(24),
    border: Border.all(color: KhotwaPalette.line),
    boxShadow: [
      BoxShadow(
        color: KhotwaPalette.navy.withValues(alpha: .04),
        blurRadius: 20,
        offset: const Offset(0, 7),
      ),
    ],
  );

  Widget _welcome() => KhotwaPhotoPanel(
    child: LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'مساحة المختصّة',
                    style: TextStyle(fontSize: 11, color: Color(0xFFF9E1B8)),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'أهلاً بكِ في خطوة',
                  style: TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'كل خطوة صغيرة، فرصة لتقدّم أكبر.',
                  style: TextStyle(
                    fontSize: 13,
                    color: Color(0xFFEDF2F8),
                    height: 1.8,
                  ),
                ),
              ],
            ),
          ),
          if (constraints.maxWidth >= 280 &&
              MediaQuery.textScalerOf(context).scale(14) <= 19)
            SizedBox(width: (constraints.maxWidth * .25).clamp(72.0, 180.0)),
        ],
      ),
    ),
  );

  Widget _metric(String title, int value, IconData icon) => Expanded(
    child: Semantics(
      label: '$title: $value',
      container: true,
      excludeSemantics: true,
      child: Column(
        children: [
          Icon(icon, size: 27, color: KhotwaPalette.navy),
          const SizedBox(height: 10),
          Text(
            '$value',
            textDirection: TextDirection.ltr,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: KhotwaPalette.navy,
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 11,
                color: KhotwaPalette.muted,
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _tool(
    String title,
    String subtitle,
    IconData icon,
    VoidCallback? onTap,
    Color tint, {
    Key? key,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Material(
      key: key,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: KhotwaPalette.line),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: tint,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(icon, color: KhotwaPalette.navy, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 5),
              Icon(
                Icons.chevron_right_rounded,
                size: 24,
                color: onTap == null ? KhotwaPalette.line : KhotwaPalette.navy,
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _guide() {
    const steps = [
      'أضيفي ملفًا برمز مجهّل وأكدي الموافقة. احفظي مطابقة الاسم على الورق خارج التطبيق.',
      'سجّلي شواهد الأداء، وراجعي الحقول المُرسلة للذكاء الاصطناعي، ثم راجعي المسودة واعتمديها.',
      'سجّلي الجلسات وصدّري التقرير. زامني قبل الانتقال إلى جهاز آخر.',
    ];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: KhotwaPalette.paleAmber,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(
                  Icons.lightbulb_outline_rounded,
                  color: KhotwaPalette.navy,
                  size: 21,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  'دليل البداية',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(
                '${_guideStep + 1} من 3',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            steps[_guideStep],
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: KhotwaPalette.muted,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              if (_guideStep > 0)
                TextButton(
                  onPressed: () => setState(() => _guideStep--),
                  child: const Text('السابق'),
                ),
              FilledButton.icon(
                onPressed: () async {
                  if (_guideStep < 2) {
                    setState(() => _guideStep++);
                    return;
                  }
                  try {
                    await widget.state.markGuideSeen();
                  } catch (error) {
                    if (mounted) showError(context, error);
                  }
                },
                icon: Icon(
                  _guideStep < 2
                      ? Icons.chevron_right_rounded
                      : Icons.check_rounded,
                  size: 18,
                ),
                iconAlignment: IconAlignment.end,
                label: Text(_guideStep < 2 ? 'التالي' : 'فهمت، أبدأ العمل'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
