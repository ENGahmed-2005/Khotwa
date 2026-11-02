# خطوة — Khotwa

تطبيق Flutter عربي Android/iOS لإعداد الخطط التربوية الفردية وتوثيق التقييم والأداء. المرجع: SRS v1.3 في `docs/reference/Khotwa_SRS_v1.3.docx`.

**الحالة: تطوير أول مسار قابل للتشغيل، وليس MVP مكتملًا أو معتمدًا للاستخدام مع بيانات حقيقية.** راجع `docs/PROJECT_STATUS.md` للأوامر المنفّذة ونتائجها.

## البنية

- `mobile/`: Flutter عربية RTL، حسابات، ملفات مجهلة، تقييم أكاديمي، تخزين مشفر ومزامنة.
- `backend/`: Node 22 + TypeScript + Fastify + Zod + Prisma + PostgreSQL.
- `packages/contracts/API.md`: عقد API والمزامنة وإصدارات القوالب.
- `docs/requirements_map.json`: فهرس 128 متطلبًا؛ `TASKS.md`: التبعيات والحالة.
- `docs/OPEN_DECISIONS.md`: القرارات التي تحتاج اعتمادًا.

## تشغيل الخادم

يتطلب Node 22+ وقاعدة PostgreSQL 17. لقاعدة محلية انسخ `backend/.env.example` إلى `backend/.env` واضبط الرابط ومفتاح AES من 32 بايت عشوائي. لا تشارك الملف. أو استخدم Docker: شغّل `powershell -File scripts/configure-dev.ps1` ثم `docker compose up -d`.

```powershell
cd backend
npm ci
npm run db:generate
npm run db:migrate:ci
npm run dev
```

الخادم الافتراضي على `http://127.0.0.1:3000`. الاختبار المحلي اصطناعي فقط. الإنتاج يتطلب HTTPS واعتماد سياسة الاستضافة والموافقات.

## تشغيل Flutter

```powershell
cd mobile
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:3000
```

`10.0.2.2` لمحاكي Android؛ لمحاكي iOS استخدم `http://127.0.0.1:3000` في إعداد التطوير. الجهاز الفعلي يحتاج HTTPS قابلًا للوصول. لا مفاتيح خادم أو AI داخل التطبيق.

أنشئ حساب تطوير ثم ملف طالب برمز عشوائي وإقرار الموافقة. لا تدخل اسم طالب أو تاريخ ميلاد كامل أو تشخيص. احفظ التقييم محليًا ثم زامن وراقب حالة الانتظار والتعارض. أسماء الأشخاص داخل نصوص بطاقات SRS أمثلة ثابتة وليست بيانات الطالب.

## الاختبارات والبناء

```powershell
python scripts/validate_planning.py
cd backend
npm run lint
npm run typecheck
# اضبط TEST_DATABASE_URL لقاعدة PostgreSQL اختبار منفصلة أولًا
npm run test:ci
npm run build
cd ../mobile
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --debug
# على macOS مع Xcode فقط:
flutter build ios --debug --no-codesign
```

CI في `.github/workflows/ci.yml` يشغّل PostgreSQL واختبارات الخادم وFlutter وبناء Android وiOS على macOS. البناء لا يثبت اختبارات الأجهزة والتشفير والمزامنة الميدانية. بناء iOS بلا توقيع ليس TestFlight.

## حدود التنفيذ

التوليد الخارجي بالذكاء الاصطناعي معطل لحين اختيار المزوّد واعتماد سياسة المعالجة. وحدات قواعد الخطط والجلسات قابلة للاختبار، وارتباطها بالواجهة والخادم موثق في ملف الحالة. التقارير العربية والاختبار الميداني والتوقيع والنشر تحتاج التنفيذ والتحقق وفق التبعيات.

ملفات `_AR` تصف حزمة البداية؛ `ARCHITECTURE.md` و`PROJECT_STATUS.md` مرجع التنفيذ الحالي. README الأصلي محفوظ في `docs/reference/IMPORTED_README.md` والنسخة المضغوطة الأصلية لم تتغير.

العمل عبر فروع وPull Requests إلى [المستودع الخاص](https://github.com/ENGahmed-2005/Khotwa)، دون دمج تلقائي إلى main.
