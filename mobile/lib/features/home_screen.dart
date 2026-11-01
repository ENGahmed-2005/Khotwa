import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../models/assessment.dart';
import '../widgets/common.dart';
import 'students_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.state});
  final AppState state;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.state,
        builder: (context, _) => Scaffold(
          appBar: AppBar(
            title: const Text('خطوة', style: TextStyle(fontWeight: FontWeight.bold)),
            actions: [
              IconButton(
                tooltip: 'عن نسخة العمل',
                onPressed: () => showAboutDialog(
                  context: context,
                  applicationName: 'خطوة',
                  applicationVersion: '0.1.0 - مشروع تأسيسي',
                  children: [const Text('وثيقة المتطلبات المرجعية: SRS v1.3')],
                ),
                icon: const Icon(Icons.info_outline),
              )
            ],
          ),
          body: SafeArea(child: _tab == 0
              ? _dashboard()
              : _tab == 1
                  ? StudentsScreen(state: widget.state)
                  : _roadmap()),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (value) => setState(() => _tab = value),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.dashboard_outlined), label: 'الرئيسية'),
              NavigationDestination(icon: Icon(Icons.school_outlined), label: 'ملفات الطلبة'),
              NavigationDestination(icon: Icon(Icons.route_outlined), label: 'مراحل العمل'),
            ],
          ),
        ),
      );

  Widget _dashboard() {
    final approved = widget.state.assessments
        .where((item) => item.status == AssessmentStatus.approved)
        .length;
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const SizedBox(height: 8),
        Text('لكل طالب طريقته في التعلم،',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                )),
        Text('ولكل خطوة أثر في التقدم',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                )),
        const SizedBox(height: 20),
        const PrototypeNote(),
        const SectionHeading('نظرة سريعة'),
        Row(children: [
          Expanded(child: _stat('ملفات مجّهلة', widget.state.students.length.toString(), Icons.folder_shared_outlined)),
          const SizedBox(width: 10),
          Expanded(child: _stat('تقييمات معتمدة', approved.toString(), Icons.fact_check_outlined)),
        ]),
        const SectionHeading('ابدأ العمل', subtitle: 'المرحلة الحالية: ملفات الطلبة والتقييم الأكاديمي الأولي'),
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            leading: const CircleAvatar(child: Icon(Icons.assignment_outlined)),
            title: const Text('التقييم الأكاديمي الأولي'),
            subtitle: const Text('بطاقات العربية والرياضيات للأعمار 6–12 سنة'),
            trailing: const Icon(Icons.chevron_left),
            onTap: () => setState(() => _tab = 1),
          ),
        ),
        Card(
          child: const ListTile(
            contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            leading: CircleAvatar(child: Icon(Icons.auto_awesome_outlined)),
            title: Text('الخطط العلاجية والجلسات والتقارير'),
            subtitle: Text('ضمن مراحل التطوير اللاحقة؛ ليست متاحة بعد في النموذج الحالي'),
          ),
        ),
      ],
    );
  }

  Widget _stat(String title, String value, IconData icon) => Card(
        child: Padding(
          padding: const EdgeInsets.all(17),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 10),
            Text(value, style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                )),
            Text(title, style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      );

  Widget _roadmap() => ListView(
        padding: const EdgeInsets.all(18),
        children: [
          const PrototypeNote(),
          const SectionHeading('خطة التقدم الفعلية'),
          const ListTile(
            leading: Icon(Icons.check_circle_outline),
            title: Text('تأسيس Flutter والواجهة العربية'),
            subtitle: Text('الشاشات الأولية ونموذج البيانات وبطاقات التقييم'),
          ),
          const ListTile(
            leading: Icon(Icons.pending_outlined),
            title: Text('الأمان والحسابات والتزامن'),
            subtitle: Text('المصادقة والصلاحيات والخادم وقيود موقع البيانات'),
          ),
          const ListTile(
            leading: Icon(Icons.pending_outlined),
            title: Text('إنشاء الخطط بمراجعة بشرية'),
            subtitle: Text('الخطة المقترحة ثم التعديل والاعتماد والأنشطة'),
          ),
          const ListTile(
            leading: Icon(Icons.pending_outlined),
            title: Text('الجلسات والرسوم والتقارير'),
            subtitle: Text('حساب الدقة وتصدير Word/PDF بعد التحقق'),
          ),
          const ListTile(
            leading: Icon(Icons.pending_outlined),
            title: Text('اختبار Android وiPhone'),
            subtitle: Text('إصدار تجريبي على كل منصة قبل قبول MVP'),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () async {
              final accepted = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('مسح بيانات التجربة؟'),
                  content: const Text('سيتم مسح كل الملفات والتقييمات المحلية من هذا الجهاز. لا يمكن التراجع.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('مسح')), 
                  ],
                ),
              );
              if (accepted != true || !mounted) return;
              try {
                await widget.state.clearPrototypeData();
              } catch (e) {
                if (mounted) showError(context, e);
              }
            },
            icon: const Icon(Icons.delete_outline),
            label: const Text('مسح بيانات الاختبار المحلية'),
          ),
        ],
      );
}
