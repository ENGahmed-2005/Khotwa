# Arabic report module

This module implements owner-scoped exports from an approved plan and recorded intervention sessions. Assessment answers, family/teacher observations, session notes, age and gender are not copied into exported documents. Grade is excluded by default because FR-22 and FR-89 conflict; the explicit `includeGrade` option records the user's choice. This provisional layout still needs the institution's review.

## Runtime

`docx` creates editable Word text/tables with native RTL properties, page fields, and chart images. `playwright-core` uses an installed Chrome to shape Arabic and print real PDF files. Chromium receives escaped HTML and embedded font/image data; outgoing browser requests are blocked. The licensed Noto Sans Arabic font is bundled here and copied into `dist/src/reports/assets` by `postbuild`.

Install Google Chrome on the backend host, or set `KHOTWA_CHROMIUM_EXECUTABLE` to an installed Chromium executable. No browser is downloaded at request time. Missing Chrome returns `503 REPORT_RENDERER_UNAVAILABLE`; no substitute file or fabricated content is returned. `KHOTWA_REPORT_FONT` may point to the same licensed font when a deployment packages assets differently. These settings are server-only and contain no user credentials.

## Integration and contract

Call `registerReportRoutes(app, { auth, records, prisma, clock? })` during application registration. All routes require the authenticated owning specialist.

- `GET /v1/reports/settings` -> `{settings:{institutionTitle,logo,privacyReviewed:true},revision}`. Unconfigured settings are empty with revision `0`.
- `PUT /v1/reports/settings` accepts `{revision,institutionTitle,logo:null|{mime:'image/png'|'image/jpeg',base64},privacyReviewed:true}`. The maximum source size is 300,000 bytes and 1,500,000 pixels, with neither dimension above 1600. Pixels are decoded and re-encoded as PNG without EXIF or appended data, resized to at most 512 on either side. A stale revision returns 409.
- `POST /v1/reports/export` accepts `{studentId,planId,type:'progress'|'parent'|'administration'|'plan',periodStart:'YYYY-MM-DD',periodEnd:'YYYY-MM-DD',format:'pdf'|'docx',includeGrade?:false}`. Response is binary with `Content-Disposition` and `X-Khotwa-Report-Serial`.
- `POST /v1/reports/batch` accepts `{reports:[{studentId,planId,type,periodStart,periodEnd,includeGrade?}],format:'pdf'|'docx'}` (maximum 10). It returns a ZIP with a separate report per selection and `MATCHING.json`/`MATCHING.csv` containing codes, serials and filenames. Every selection is authorized before rendering; export logs are saved atomically after success.
- `GET /v1/reports/exports` -> `{exports:[{id,serial,studentCode,type,format,exportedAt,periodStart,periodEnd,includeGrade}]}`. Settings and logs are AES-GCM encrypted records (`institutionProfile`, `reportExport`), with payload-free audit events. The generic sync endpoint must reject writes of these kinds.
- `POST /v1/activities/:id/export` accepts `{optionalSections?:{title?,goal?,duration?,alternatives?,teacherNotes?}}`, all booleans. It prints an approved activity attached to the owner's approved plan and goal, with its own serial/log. Historic `toolSnapshot` labels take precedence over the current tool profile; a missing custom-tool label prevents output.

The module also exports `renderActivityPdf` and `renderArabicPdf` for server integrations. `renderArabicPdf.bodyHtml` is a trusted internal argument; HTTP inputs never pass through as raw HTML.

## Data and calculation rules

The report selects sessions by student, exact approved plan version, goal and inclusive date period. It rejects a period containing more than 300 sessions. Completed sessions show `(correct / total) * 100`; absence and cancellation have no accuracy. Cancelled sessions are excluded from the attendance denominator under the project's documented provisional technical policy. No automatic mastery/stagnation classification is generated. A criterion percentage/trials/consistency is shown as a dashed target line; a support-based criterion is described in text, without inventing a percentage.

Charts contain at most twelve data points per panel, include dates, numeric values and status symbols, and remain understandable in monochrome. The body contains editable session tables as well as the chart. Required goals and measurement data remain visible when optional plan sections are hidden.

## Executed verification and visual gate

`reports.model.test.ts` runs all four templates through actual Chrome PDF and DOCX generation, with a longer multi-page PDF and activity printing. `reports.integration.test.ts` uses a real isolated PostgreSQL database and two accounts, checks forbidden cross-owner selections, binary output, encrypted logs, independent batch files, logo normalization, stale settings, role checks and activity approval.

The tests write synthetic QA files to `.artifacts/reports/`. Local PDF extraction and Poppler review are separate evidence from a successful build. For Word visual review, install LibreOffice Writer, Poppler and the Python `pypdf` package, then run `python backend/test/reports.visual.py --directory .artifacts/reports`. This converts every Word fixture, verifies code/serial on every resulting page and renders PNGs for visual inspection. Missing tools fail this command; they do not establish Word visual acceptance. Field tests on Android/iOS and specialist template approval are separate acceptance requirements.
