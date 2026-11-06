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

ربط Gemini متاح للاختبار ببيانات اصطناعية فقط. اضبط في `backend/.env` على الخادم: `AI_ENABLED=true` و`AI_SYNTHETIC_ONLY=true` و`GEMINI_MODEL=gemini-flash-latest` و`GEMINI_API_KEY`، ثم أعد تشغيل الخادم. لا تضف المفتاح إلى Flutter أو Git. تعرض الواجهة الحمولة المحدودة للمراجعة وتتطلب تأكيد الإرسال؛ تعود الخطة مسودة تحتاج اعتماد المختصة. فشل المزوّد لا ينشئ خطة بديلة. لم يُتحقق نجاح توليد حي بعد؛ راجع سجل الحالة لنتيجة الاتصال الفعلية.

التقييم التربوي الحر، تعديل الخطط وإصداراتها الكاملة، الأنشطة والجلسات والرسوم والتقارير العربية والاختبار الميداني والتوقيع والنشر ما زالت تحتاج التنفيذ والتحقق وفق التبعيات. استعادة كلمة المرور تحتاج ربط مزود بريد؛ لا تُرسل رسائل فعليًا في إعداد التطوير الحالي.

## معاينة التطوير المحلية

هذه معاينة للواجهة الفعلية مع الخادم وقاعدة PostgreSQL، مخصصة لبيانات اصطناعية. يخزن المتصفح بياناته مؤقتًا في الذاكرة؛ البيانات المتزامنة تستعاد من الخادم عند تسجيل الدخول. لا تثبت هذه المعاينة التشفير المحلي أو سلوك الأجهزة.

بعد تشغيل الخادم، نفّذ من `mobile/`:

```powershell
flutter build web --dart-define=API_BASE_URL=http://127.0.0.1:4173 --dart-define=ALLOW_SYNTHETIC_WEB_PREVIEW=true
cd ..
node scripts/preview.mjs
```

افتح `http://127.0.0.1:4173`، أنشئ حساب تجربة ثم ملفًا مجهّلًا. التقييم يجب أن يُعتمد ويُزامن قبل اختيار مهاراته في شاشة الخطط. لإنشاء محاولة جديدة بعد فشل توليد معروف، أنشئ معاينة جديدة وأكّد إرسالها؛ إعادة العملية نفسها تسترجع إيصالها وتمنع تكرار الطلب الخارجي.

اختبار Gemini الحي اختياري، ويتصل بالمزوّد الفعلي عبر الخادم المحلي. ينشئ حسابًا ومصدرًا اصطناعيين ويحذفهما بعد الاختبار، ولا يعتمد الخطة:

```powershell
cd backend
$env:KHOTWA_ALLOW_LIVE_AI_SMOKE='synthetic-only'
npx tsx test/live-ai.smoke.ts
```

ملفات `_AR` تصف حزمة البداية؛ `ARCHITECTURE.md` و`PROJECT_STATUS.md` مرجع التنفيذ الحالي. README الأصلي محفوظ في `docs/reference/IMPORTED_README.md` والنسخة المضغوطة الأصلية لم تتغير.

العمل عبر فروع وPull Requests إلى [المستودع الخاص](https://github.com/ENGahmed-2005/Khotwa)، دون دمج تلقائي إلى main.
