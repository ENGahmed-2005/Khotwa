# المعمارية المرجعية للعمل

## المخطط المنطقي النهائي المقصود

```text
Flutter Android / iOS
   ├── واجهات عربية RTL
   ├── تخزين مشفر محلي (مستقبلاً قاعدة بيانات معتمدة)
   ├── ملفات طلبة مجهّلة + تقييمات + مسودات جلسات
   └── طابور مزامنة + حل تعارضات (مستقبلاً)
            | TLS بعد المصادقة والتفويض
            v
Backend API (FastAPI / Node.js حسب القرار)
   ├── Auth / RBAC / consent / audit
   ├── Validation / sync / version history
   ├── Assessment summaries (مجهّلة ومعتمدة)
   ├── Plans: draft → edit → approve
   ├── Sessions / accuracy / progress
   ├── Reports Word/PDF
   └── AI gateway: minimal approved anonymized payloads
            |
            v
PostgreSQL في موقع استضافة معتمد + سياسات احتفاظ
```

## الموجود الآن في الشيفرة

- `mobile/lib/core/app_state.dart`: مصدر حالة محلي تجريبي، وقيود الموافقات وعدم تعديل الاعتماد.
- `mobile/lib/core/secure_local_store.dart`: نقطة استبدال التخزين التجريبي؛ تعمدنا عدم استخدام shared_preferences أو نص عادي للتخزين.
- `mobile/lib/models/student.dart`: ملف طالب لا يسمح بحقول أسماء أو ميلاد أو أمراض.
- `mobile/lib/models/assessment.dart`: حالات البنود والملاحظات ومعلومات المراجعة.
- `mobile/lib/data/assessment_templates.dart`: قوالب ست بطاقات مثبتة `1.0` بمحتوى مرجعي.
- `mobile/lib/features/*`: الواجهات العربية والإدخال والمراجعة.

## كيانات قاعدة البيانات الإنتاجية (SRS §2.4)

`users`, `roles_permissions`, `student_profiles`, `student_observations`, `initial_assessments`, `skills_library`, `previous_strategies`, `plans`, `plan_goals`, `available_resources`, `activities`, `sessions`, `plan_versions`, `library_items`, `reports`, `export_log`, `file_shares`.

للتقييم الأكاديمي: `assessment_templates`, `assessment_items`, `academic_assessments`, `assessment_item_results`, `assessment_observations`, `assessment_summaries`, `assessment_history`.

**قواعد تصميم لازمة:**

- ملف الطالب مرتبط برمز عشوائي/مشفر، لا باسم واقعي؛ الرمز الظاهر لا يكفي وحده لضمان عدم كشف الهوية.
- التقييم مؤرشف بحسب **إصدار القالب**؛ إعادة التقييم تنشئ سجلًا جديدًا، لا تعديلًا صامتًا للنسخة المعتمدة.
- `assessment_item_results` يحتوي `execution` مستقلًا عن `judgment`: «لم يُجرَ/تعذّر» لا يعادل «خطأ».
- `assessment_summaries` يحتفظ بشواهد وموافقة المختصة، ويتيح ربط الخطة بنتائج معتمدة فقط.
- بيانات الجلسة لها قياس مستقل: `(correct / attempts) × 100`، مع التحقق من `0 ≤ correct ≤ attempts`، و`attempts > 0` للجلسات المكتملة.
- كل تعديل أو مزامنة يجب أن يحمل `version`, `updatedAt`, `deviceId` وسياسة تعارضات لا تمحو السجلات السابقة.
- فصل سجلات المستخدمين بالـ tenant/owner و RBAC في الخادم، وليس فلاتر واجهة فقط.

## توليد الخطة (لاحقًا)

1. تحقق المصادقة + تفويض مالكة الملف + إقرار الموافقة.
2. تحقق مستوى الأداء ونقاط القوة والاحتياج والمهارات من تقييم معتمد.
3. عرض Preview للبيانات المجّهلة التي ستُرسل.
4. إزالة النصوص الحرة والأسماء والمعلومات الصحية/التعريفية قبل الاستدعاء.
5. استدعاء نموذج AI من الخادم فقط، مع عدم تدريب المزود على البيانات بما يوافق العقد والسياسة.
6. فحص مكونات الهدف (السلوك/الشرط/معيار الإتقان/الزمن) ومنع التشخيص والتعميم.
7. حفظ الخطة «مقترح»؛ الاعتماد بواسطة المختصة صراحة فقط.

**ملاحظة:** هذا المخطط يصف هدف MVP بحسب SRS، وليس خدمات قائمة الآن داخل الحزمة.
