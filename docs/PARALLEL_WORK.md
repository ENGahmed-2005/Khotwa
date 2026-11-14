# خطة العمل المتوازي الآمن — Codex + Git Worktrees

## القاعدة الأساسية
يبدأ العمل بـ **موجة تأسيس تعاقدية واحدة** لتفادي تعديل المخططات وAPI عبر جلسات منفصلة في الوقت نفسه. بعد التأسيس، تتوزع المهام على worktrees بفروع منفصلة، ودمج متسلسل عبر PR وCI.

| الموجة | عامل/فرع | مجلدات مملوكة | ممنوع تعديلها بلا تنسيق | التبعيات |
|---|---|---|---|---|
| 0 | Integrator / `feat/foundation` | `AGENTS.md`, `TASKS.md`, `docs/`, `packages/contracts/`, `.github/` | لا تكتب وظائف متفرقة قبل تثبيت عقود البيانات | FND-01, FND-02, DB-01 |
| 1 | Backend / `feat/backend-core` | `backend/src/auth`, `backend/src/students`, `backend/src/db`, `backend/test` | `mobile/`, العقود المشتركة بعد تثبيتها | FND-02, DB-01 |
| 1 | Mobile UI / `feat/mobile-shell` | `mobile/lib/core`, `mobile/lib/features/auth`, `mobile/lib/features/students`, `mobile/test` | `backend/`, العقود المشتركة | FND-02 |
| 1 | Assessment / `feat/assessment` | `mobile/lib/features/assessments`, `backend/src/assessments`, `docs/assessment-fixtures/` | لا تغيير migrations دون PR تكاملي | DB-01, ASM-01 |
| 2 | AI & Activities / `feat/ai-plans` | `backend/src/ai`, `backend/src/plans`, `backend/src/activities` | بيانات تقييم خام؛ لا تمس `mobile/features/sync` | ASM-02 + AI-01 contracts |
| 2 | Sessions / `feat/progress` | `mobile/lib/features/sessions`, `mobile/lib/features/progress`, `backend/src/sessions` | عقود التقييم | STU-02 + DB-01 |
| 2 | Reports / `feat/reports` | `backend/src/reports`, `mobile/lib/features/reports` | عقود خطط لم تعتمد بعد | AI-02 + SES-01 |
| 3 | Offline & Sync / `feat/offline-sync` | `mobile/lib/core/sync`, `mobile/lib/core/storage`, `backend/src/sync` | لا تغيّر سلوك API بلا موافقة | عقود الكيانات النهائية |
| 3 | QA / `test/cross-platform` | `mobile/integration_test`, `backend/test/e2e`, `docs/TEST_PLAN.md` | لا تعديل وظيفي غير متفق عليه | تكامل الميزات |

**مهم:** الملفات المشتركة مثل `backend/prisma/schema.prisma`, `packages/contracts/**`, `TASKS.md`, `docs/PROJECT_STATUS.md`, `.github/workflows/**` يمتلكها المنسق. تغييراتها تمر باتفاق وPR منفصل. لا تدمج فروعًا متزامنة دون حل التعارضات واختبارات CI.

## إنشاء worktrees على Windows PowerShell

```powershell
# بعد إنشاء أول commit وفرع main
.\scripts\start_parallel.ps1
# ثم افتح كل مجلد مجاور في نافذة Codex منفصلة
```

## أوامر يدوية بديلة

```bash
git switch main
git pull --ff-only  # إذا ارتبط المستودع بـ GitHub
# أنشئ موجة عمل مستقلة:
git worktree add ../khotwa-backend -b feat/backend-core main
git worktree add ../khotwa-mobile -b feat/mobile-shell main
git worktree add ../khotwa-assessment -b feat/assessment main
# بعد إنجاز الفرع ومراجعته ودمجه:
git worktree list
git worktree remove ../khotwa-assessment
```

## استراتيجية PR
1. لكل PR: Task ID وFRs وأمر اختبار مع نتيجته وبيئة التشغيل وأثر الخصوصية.
2. لا تسمح لوكيل بتعديل ملفات مهمة أخرى من أجل إصلاح سريع دون إخطار منسق التكامل.
3. عند تغيير عقد API: PR صغير للعقد أولًا، ثم دمج وتحديث الفروع التابعة.
4. كل merge يعاد بعده اختبار التكامل؛ Android/iOS ليسا مجرد build موافق للـ CI.
5. لا force-push إلى main. لا يُعلن استلام MVP حتى تُغطى حالات قسم 2.5.

## تسريع حقيقي دون فوضى
- ازداد التوازي بعد تثبيت schema وقوالب التقييم والنماذج المجهّلة، لا قبله.
- قبل تشغيل أكثر من ثلاث جلسات، تأكد من قدرة الجهاز والاتصال والاعتماد على تشغيل الاختبارات دون تنازع على قاعدة تطوير مشتركة.
- كل جلسة لديها قاعدة اختبار مستقلة أو schema منفصل وقيم اصطناعية، ولا تعدل بيئة الإنتاج.
