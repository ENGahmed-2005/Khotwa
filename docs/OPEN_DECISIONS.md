# Open decisions (source SRS 1.3 section 2.7)

No educational/legal/hosting decision is silently resolved by implementation.

- Institution-approved plan layout and exact report headers: needs specialist sample/approval.
- Consent wording/evidence, data country/provider processing location, retention/deletion and backup policy: needs institution/project-owner approval before real data or production.
- User selected Gemini `gemini-flash-latest` and authorized their server-side key for synthetic development. Gateway integration is in progress. Cost budget and data-processing location/terms remain unresolved for real student data; this authorization does not approve production processing.
- Objective mastery/stagnation thresholds and extended writing rubric: not standardized or inferred; raw descriptive performance only.
- Supported minimum Android/iOS versions and field device matrix: technical provisional setup is not acceptance.
- Publishing accounts, signing and TestFlight: not configured.
- SRS FR-22 excludes grade from reports by default while FR-89 includes grade: report default requires clarification; use code only until resolved.
- See imported OPEN_DECISIONS_AR.md and full reference SRS section 2.7 for original additional decisions; tracked map is provisional until complete reconciliation.

Development is authorized with synthetic data; none of the above blocks foundation, account/owner boundaries, encrypted storage, or assessment infrastructure.

2026-11-11 operational authorization: owner confirmed My Workspace and the reviewed free Frankfurt Render staging plan (separate API+private PostgreSQL17,30-day disposable database). This approves synthetic staging only. It does not decide production data country/provider processing, consent or retention. No paid service was purchased. Gemini model remains the user-selected gemini-flash-latest; protected server-side synthetic access was explicitly authorized earlier.

Technical prototype policies (not educational approval): cancelled sessions are excluded from attendance denominator; absent sessions have no performance score. Engagement is an institution-entered label until its three-level scale is approved. Imported template v1.0 snapshots remain separate and preserved; no silent upgrade to v1.1. A supervised migration is still needed for any preexisting v1.0 data.
