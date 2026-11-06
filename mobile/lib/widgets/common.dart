import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

class SectionHeading extends StatelessWidget {
  const SectionHeading(this.title, {super.key, this.subtitle});
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 20, 4, 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 3),
          Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    ),
  );
}

class PrototypeNote extends StatelessWidget {
  const PrototypeNote({super.key});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF6E5),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFFF4D9A6)),
    ),
    child: const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, color: Color(0xFF855611)),
        SizedBox(width: 12),
        Expanded(
          child: Text(
            kIsWeb
                ? 'معاينة متصفح ببيانات مصطنعة فقط. التخزين هنا مؤقت في الذاكرة ويُفقد عند إعادة التحميل؛ زامني بالخادم لحفظ عمل التجربة. هذه المعاينة لا تختبر تشفير Android أو iOS.'
                : 'نسخة تطوير ببيانات تجريبية مصطنعة فقط. يلزم اعتماد سياسة الاستضافة والموافقة والاحتفاظ ومراجعة المختصة والاختبارات الميدانية قبل بيانات الطلبة الحقيقية.',
            style: TextStyle(color: Color(0xFF654611)),
          ),
        ),
      ],
    ),
  );
}

void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(error.toString().replaceFirst('Bad state: ', ''))),
  );
}

String syncStatusLabel(String value) => switch (value) {
  'pending' => 'محفوظ محليًا · بانتظار المزامنة',
  'conflict' => 'تعارض · النسختان محفوظتان',
  'error' => 'تعذّر الإرسال · راجع المزامنة',
  _ => 'متزامن',
};
