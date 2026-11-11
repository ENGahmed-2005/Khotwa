# Khotwa execution status

Updated 2026-11-11 (Asia/Hebron). Integrated MVP implementation and verification IN_PROGRESS. This is not MVP acceptance or approval for real student data.

## Current source and operation

- Repository: https://github.com/ENGahmed-2005/Khotwa; draft review: https://github.com/ENGahmed-2005/Khotwa/pull/1. Work remains on feat/fnd-02-foundation; main was not merged.
- Reference: original docs/reference/Khotwa_SRS_v1.3.docx, 128 FRs and task DAG. Previous chronological execution notes are preserved in docs/history/PROJECT_STATUS_2026-11-08.md.
- Automation `automation` was deleted on 2026-11-06 and must remain stopped.

## Implemented

Accounts, opaque sessions, explicit owner/specialist isolation, account deletion and one-use reset; Arabic RTL Flutter navigation; anonymized student intake and consent; six versioned academic cards and structured writing/math observations; dated initial educational assessments and reviewed custom skills; controlled AI preview/confirmation, draft plans, immutable edited versions and explicit approval; reviewed tools/activities and approval; individual/batch/backdated sessions; descriptive charts/tables; three report audiences plus approved plan and activity exports; institution header/logo and batch matching list; encrypted native snapshots/outbox/drafts and safe conflict/tombstone handling.

Key integrated changes: activities/report UI 36e4a14, form autosave a571634/16539b5, assessment observations/date/grade/unfinished input 8a1812b, provider status classification 3926902, basic-input gating fb4212e, Gemini grammar fix 99dcd5f, HTTPS installer/signing configuration f174383. Raw observations remain outside AI input. Legacy assessments are preserved without invented date/grade. Undefined gender and missing referral may be saved but must be completed before AI.

## Executed verification

- 2026-11-11: `npm ci` PASS, 247 installed packages, zero reported vulnerabilities. Prisma6.19 client generation/migration, lint/typecheck/build PASS. Node22.23.2; Vitest5.1.0.
- Combined root backend: **234/234 PASS, 13 files**, separate PostgreSQL khotwa_test; command: Node --env-file=.env, set TEST_DATABASE_URL in-process, then vitest run --pool=threads. Actual log .local/backend-combined-2026-11-11.log. Windows fork runner stalled and was terminated; thread runner completed in114.20s. No tests disabled. Includes actual PostgreSQL, Chrome PDF/DOCX and loopback SMTP tests.
- `python scripts/validate_planning.py` PASS: source SRS,128 FRs,DAG,states. Flutter analyze PASS locally; earlier combined root96/96 tests PASS Nov9; isolated assessment implementation102/102 tests PASS Nov11. Final combined Flutter run after remaining cleanup integration is pending.
- Actual local Gemini smoke after99dcd5f: preview200, generation201, one persisted **draft**, then synthetic account/records deleted204. .local/live-ai-fixed-2026-11-11.log. Original full request400 was fixed by simplifying provider decoding grammar while retaining complete original Zod and safety validation; model remains gemini-flash-latest, no fallback plan.
- Current PDF/DOCX tests include separate audience templates, grayscale charts, repeated code/serial/page numbering and logo,9 Word fixtures including multipage. Linux Word visual CI uncovered a font/text-extraction failure; font repair and actual LibreOffice visual checks are still in progress. Do not claim Word acceptance.
- CI43003540335 and43003529773 at5178e90 passed backend/Flutter/planning and Android+iOS builds. iOS release unsigned package43003529775 also passed. These precede subsequent assessment/AI changes and require a final rebuild. Build success is not device acceptance.
- Flutter web build PASS105.7s at8a1812b; actual390px login screenshot reviewed .artifacts/preview/login-2026-11-11.png, connected Arabic/RTL visible. Local preview http://127.0.0.1:4173; open request queued in Codex side panel. This synthetic browser preview uses memory storage and does not prove native encryption/offline behavior.

## Live synthetic staging

User approved My Workspace and reviewed Free deployment plan on2026-11-11. Render Blueprint exs-dbq445lg1s2s73bvi6l0 created a separate Frankfurt API and PostgreSQL17, with private-only database ingress. Existing menuPilot resources were not changed. Automatic deployment and Blueprint autoSync are disabled.

API: https://khotwa-api-staging-p4le.onrender.com . Service srv-dbq45k56e07s73c3514g; deploy dep-dbq45kl6e07s73c35260 at5178e90 reached **live**. `/health` returned200 with database ready. Explicit `KHOTWA_LIVE_SMOKE=synthetic-only KHOTWA_API_URL=... node scripts/verify-staging.mjs` PASS: registration/login, encrypted-server record persistence, repeated-operation idempotency, new-session pull, two-owner isolation, forbidden-field rejection; both synthetic accounts deleted successfully. Evidence .local/staging-smoke-2026-11-11.log.

Gemini and SMTP remain disabled on this initial remote deployment; latest validated code and protected server-side AI environment still need deploying. Free Postgres expires30 days after creation, has no backup and is for disposable synthetic staging. No real-student hosting/retention/processing decision is approved by this deployment.

## Installation and remaining acceptance

Signed Android HTTPS release workflow is prepared in .github/workflows/installers.yml, with persistent protected PKCS12 identity stored outside Git and three encrypted GitHub Actions signing secrets configured; secret values were not printed. Installer candidate branch must be deliberately pushed only after remaining functional fixes and checks. Android release packaging/signature verification has not yet run for current source.

Actual arm64 iPhoneOS release build exists through macOS CI. Apple team/certificate/private key/provisioning profile are absent: **no installable signed iPhone package exists**. Unsigned IPA must not be called installable or MVP complete.

Remaining: finish export temporary-file/account-cleanup hardening and combined tests; repair Linux Arabic report font and inspect actual LibreOffice outputs; run full real-provider API flow and deploy current validated source/AI key; final native builds; Android+iOS lifecycle/offline/encryption/conflict/cross-device acceptance; configured real SMTP delivery; approved institution layout/consent/retention/provider location and specialist educational review. AT01..17 are not marked passed by unit tests or builds.

## Resume without duplicating work

Use ONLY C:/Users/Ahmed/tools/khotwa/project-link/mobile for root Flutter commands; Arabic-path LSP/mixed build stamps fail on this Windows SDK. Full Node path C:/Program Files/nodejs/node.exe. Root backend ASCII junction C:/Users/Ahmed/tools/khotwa/project-link/backend. Protected local backend/.env is ignored. Keep khotwa_test separate from synthetic dev database. PostgreSQL17 port55432 logs must be outside its data directory during recovery. Current parallel worktrees: khotwa-mvp-mobile owns privacy export/deletion hardening, khotwa-mvp-backend owns live-MVP smoke, khotwa-mvp-reports owns Linux font/Word verification. Root owns deployment/contracts/status/CI/integration. Do not buy credits, change model automatically, merge main, restore automation, or publish stores.
