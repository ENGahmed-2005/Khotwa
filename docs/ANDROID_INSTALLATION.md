# تثبيت نسخة خطوة على Android

هذه نسخة اختبار ببيانات اصطناعية فقط، بمعرّف التطبيق `org.khotwa.khotwa`. نسخة `arm64-v8a` مخصصة لهواتف Android التي يدعم نظامها معمارية ARM64، ونسخة `armeabi-v7a` لأجهزة ARM ذات النظام32بت، ونسخة `x86_64` للمحاكي المناسب. يمكن معرفة المعمارية عبر `adb shell getprop ro.product.cpu.abi`. الإصدار وSHA ونتيجة البناء الفعلية موجودة في `BUILD_METADATA.json` و`PROJECT_STATUS.md`؛ الوصف هنا لا يعني اكتمال قبول MVP أو الاختبار على هاتف.

## نسخة HTTPS المستقلة

مسار `.github/workflows/installers.yml` يبني Release موقّعًا بهوية توزيع محفوظة خارج Git، مع عنوان `https://khotwa-api-staging-p4le.onrender.com`. يشغّل التبعيات المقفلة والتنسيق والتحليل واختبارات Flutter، ويفحص التوقيع باستخدام `apksigner` ومحتويات APK. لكل معمارية مرفق مستقل لتقليل التنزيل، يشمل APK وتقرير التوقيع وبيانات البناء وبصمات SHA-256.

بعد التحقق من البصمة انقل `Khotwa-arm64-v8a.apk` أو الملف الموافق للهاتف وافتحه، أو استخدم `adb install -r` مع مساره. لا يحتاج هذا الإصدار ربط USB بالكمبيوتر. أول تسجيل دخول يحتاج اتصالًا بالخادم؛ حفظ الملفات بعده محلي ومشفّر بمفتاح Keystore، بينما التوليد والتصدير من الخادم يحتاجان الإنترنت. إعدادات AI والبريد وSHA الخادم المنشور موثقة في الحالة؛ بناء APK لا يفعّلهما تلقائيًا. لا توجد مفاتيح AI أو قاعدة بيانات داخل التطبيق.

إذا منع Android تحديث نسخة Debug القديمة لاختلاف التوقيع، استخدم جهاز اختبار منفصل أو احفظ العمل المتزامن أولًا؛ إلغاء التثبيت يمحو العمل المحلي غير المتزامن. لا تُمسح بيانات المستخدم لحل اختلاف التوقيع تلقائيًا.

## إعادة البناء محليًا

يلزم Flutter3.47.9 وJava متوافق17 أو أحدث وAndroid API36 وBuild Tools36.0.0 وNDK28.2.13676358 وGradle9.3.1. حدّد `JAVA_HOME` و`ANDROID_HOME` لهذه العملية. تُمرّر هوية التوقيع عبر متغيرات البيئة المحمية `KHOTWA_ANDROID_KEYSTORE_PATH` و`KHOTWA_ANDROID_STORE_PASSWORD` و`KHOTWA_ANDROID_KEY_ALIAS` و`KHOTWA_ANDROID_KEY_PASSWORD`، ولا تُضاف إلى Git.

```powershell
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
flutter build apk --release --no-pub --split-per-abi --dart-define=API_BASE_URL=https://khotwa-api-staging-p4le.onrender.com
```

هوية التوقيع مطلوبة لحزمة قابلة للتثبيت وتحديثها بنفس التوقيع. فشل تنزيل الأدوات لا يُعالج بتغيير النسخ المثبتة أو تعطيل التحقق.

## نسخ Debug السابقة وربط الخادم المحلي

حزم `Khotwa-Android-*-preview.apk` من مسار جودة التطوير تستخدم `http://127.0.0.1:3000` وتوقيع Debug، وتحتاج الخادم المحلي على الكمبيوتر. تختلف عن حزم HTTPS أعلاه. يلزم Android Platform Tools وتفعيل تصحيح USB مؤقتًا والموافقة على الاتصال، ثم:

```powershell
adb devices
adb reverse tcp:3000 tcp:3000
```

شغّل PostgreSQL وخادم المشروع كما يوضح README، ثم افتح التطبيق وأنشئ حساب تجربة. يجب أن يعود `/health` بحالة قاعدة بيانات جاهزة قبل اختبار الحسابات والمزامنة. عند فصل USB يتوقف الاتصال بالخادم؛ العمل المحلي بعد أول دخول يبقى مشفّرًا على الجهاز. يلزم إعادة إعداد الربط عند الحاجة. نجاح هذا المسار على جهاز فعلي ما زال غير متحقق.

يقتصر HTTP في نسخة Debug على loopback؛ لا تضع عنوان خادم عام غير مشفر. خدمة HTTPS الحالية تجريبية للبيانات الاصطناعية، ولا تمثل اعتماد استضافة إنتاج لبيانات الطلاب.

## نطاق هذه النسخة

الحسابات وملفات الطلاب والبطاقات والتقييم الأولي والخطط والأنشطة والجلسات والتقارير والتخزين المشفّر موجودة في المصدر الحالي. الاختبار الميداني وتكافؤ المنصتين وتحديث الخادم والتوقيع على iPhone لها حالة مستقلة في `PROJECT_STATUS.md`. لا تستخدم بيانات طالب حقيقي.

## GameLoop على جهاز التطوير

تحقق تثبيت الإصدار0.1.0/code2001 ثم تحديثه إلى2002، وأخيرًا نسخة x86_64/code4002 المطابقة لمعالج GameLoop7.0.167.0 بنظام Android13، دون حذف البيانات وبنفس التوقيع. هذه أرقام ABI مختلفة لنفس مصدر9f38187، ولا تتضمن إصلاح التسجيل الأحدث حتى إعادة البناء. يظهر التطبيق من الاختصار «خطوة - GameLoop» على سطح المكتب. عند تثبيته من ADB قد يمنع المحاكي فتحه مباشرةً؛ مسار التشغيل الذي تحقق على هذا الجهاز هو:

```powershell
& 'C:\Program Files\Tencent\GameLoop\Application\GameLoopLauncher.exe' --from 4 --launch-proc-name GameLoopEmulator.exe --launch-pkg-name org.khotwa.khotwa
```

كشف المحاكي خطأ في Keystore أثناء التشغيل؛ توثيق إصلاح منع المسح التلقائي للمفاتيح وإعادة التحقق من النسخة الجديدة في ملف الحالة. تحقق التثبيت وبدء العملية منفصل عن اعتماد التخزين الآمن والاختبار الميداني.

## تأخر التسجيل ورسائل الدخول

تجهيز خدمة الاستضافة المجانية بعد الخمول قد يستغرق نحو دقيقة. ينتظر المصدر المحدّث جاهزية الاتصال حتى90ثانية بطلب GET بلا بريد أو كلمة مرور، ثم يرسل طلب الحساب مرة واحدة؛ لا يكرر POST تلقائيًا. إن انتهت مهلة التسجيل بعد الإرسال فقد يكون الحساب أُنشئ بالفعل، لذا يُطلب تسجيل الدخول بنفس البيانات. رسالة كلمة مرور غير صحيحة مستقلة عن انتهاء جلسة سابقة، ولا تُمسح بيانات التطبيق أو مفاتيحه لعلاج أي منهما. حالة وصول الإصلاح إلى الحزمة المثبتة مسجلة في PROJECT_STATUS.md.

## Compatibility and brand update — 2026-11-15

Updated 2026-11-15. Packages are synthetic-data pilot builds, not MVP acceptance.

## Choosing the package

- `Khotwa-universal.apk`: the default for direct sharing. Contains ARM32 (`armeabi-v7a`), ARM64 (`arm64-v8a`) and x86_64. Android selects the supported libraries. It is larger than a package for one architecture.
- `Khotwa-armeabi-v7a.apk`: smaller ARM32 package, including phones whose Android system exposes only 32-bit ARM ABIs.
- `Khotwa-arm64-v8a.apk`: smaller ARM64 package. A 64-bit CPU alone does not prove its installed Android system supports this ABI.
- `Khotwa-x86_64.apk`: smaller package for compatible emulators, including the verified GameLoop configuration.

The verified previous APKs require API24 (Android7.0) or newer. The installer workflow records the actual minimum SDK and architecture set of every new APK with `aapt` and ZIP inspection; do not infer it from a filename. Android12 satisfies API24, but does not identify the supported ABIs.

The user's screenshot showed Android rejecting `Khotwa-arm64-v8a.apk` before launch on a reported Samsung A13 with Android12. We verified that the inspected APK contains only `arm64-v8a`. Architecture mismatch is plausible, not confirmed by that generic message. The affected phone is not connected for an actual Package Manager error, ABI query or installation test. Do not claim successful installation on it.

## Safe updates

Keep package ID `org.khotwa.khotwa` and the existing protected distribution signing identity. CI checks certificate SHA256 `9235d22df8c6e12a3cbddc2e18aec1ab3e9c2b1abad8f54ee77c19194c03dd41` and verifies each signed APK. Installer builds use `10000 + github.run_number` and `force-version-code-ignoring-abi=true`, so all architecture packages in a build share one version above the old2001/2002/2004/4002/4004 packages. This also permits switching to the universal package without an architecture-specific downgrade.

Install as an update. **Do not uninstall or clear storage to troubleshoot compatibility**: unsynchronized student records and local encryption keys must be preserved. If a matching package is still rejected, obtain the exact Package Manager failure on an authorized connected phone before changing signing, SDK requirements or storage.

## Reproducible icon assets

The original generated book/path/spark artwork is `mobile/assets/branding/khotwa-icon-master.png`. Navy and amber match the specialist UI. `scripts/generate-app-icons.ps1` prepares the Android legacy/adaptive sizes, all existing iOS asset-catalog sizes, Flutter's brand image and browser favicon. Android adaptive foreground is inset for launcher masks; iOS outputs are opaque RGB PNGs. Flutter loads the same symbol from its bundled asset. This replaces the stock Flutter launcher icon without changing application ID or user data.

Generation prompt: one original professional Khotwa educational-specialist icon, an open book combined with a gentle ascending path/step and an amber spark; navy17375E/amberE3A343 on warm ivoryF8F5EF, clear small-size silhouette and generous mask-safe margins, no lettering, watermark, children, device mockup or medical symbolism. Original artwork was generated with the built-in image generator on2026-11-15; the master is kept unchanged and copied into this repository. Standard size conversion is reproducible with the script.

## Verification and limits

`.github/workflows/installers.yml` runs locked dependencies, formatting, analyzer and Flutter tests before both split and universal release builds. It checks signatures, package ID, exact architecture libraries, common increasing version, minimum SDK, ZIP CRC and SHA256, and uploads metadata with every artifact. No phone installation is implied by these checks. iOS signing and physical Android/iPhone acceptance remain separate requirements; see `PROJECT_STATUS.md`.
