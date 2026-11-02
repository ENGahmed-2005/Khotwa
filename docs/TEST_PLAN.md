# Executable verification and remaining acceptance gates

SRS v1.3 section 2.5 remains authoritative. Tests use synthetic random codes only.

## Automated first slice

- Planning: `python scripts/validate_planning.py` checks exact FR inventory, dependency DAG and status evidence.
- API: `npm ci`, `npm run db:generate`, `npm run db:migrate:ci` twice, `npm run lint`, `npm run typecheck`, `npm run test:ci`, `npm run build`.
- Database integration must use isolated PostgreSQL. Test env is required, never silently treat skipped database tests as passing.
- Account: successful and failed login, short passwords, duplicate accounts, expiration, logout revocation, one-use reset and revocation, owner data cleanup.
- Privacy: reject unknown personal-data fields; encrypted ciphertext must not contain input plaintext; AEAD tampering fails; logs/errors omit credentials and student text.
- IDOR: two owners across list/detail/push/pull/delete/assessment parent and audit paths.
- Sync: same operation three retries; changed body same id rejected; stale revision retained; student/child tombstones; all-or-nothing per operation; concurrent updates.
- Assessment: age boundaries 5y11m/6y/8y11m/9y/12y11m/13y; version frozen; every reading word separate; subjective tasks excluded; notDone/unable not incorrect; assisted responses not independent; explicit complete review required.
- Flutter: `flutter pub get --enforce-lockfile`, `dart format --output=none --set-exit-if-changed lib test`, `flutter analyze`, `flutter test`.
- Mobile persistence: ciphertext contains no plaintext, wrong key/corruption fail closed; failed commit rolls back memory; restart recovers outbox; account partitions; retained conflicts.
- Native: Android debug APK and macOS iOS no-codesign build through CI. Neither means field-device acceptance.

## SRS acceptance tracking

AT-01..AT-17 and the SEC/OFF/REP/ETH field scenarios are NOT claimed passed by this document. Their precise original text is preserved in docs/reference/SRS_v1.3.extracted.txt. Full checklist reconciliation and evidence run remain pending.

Required before MVP acceptance: Android and iPhone functional parity; physical secure-store/database verification; kill/background/network loss before and after save; repeat sends; two accounts; Android to iOS recovery of synchronized data; offline edits remain on original device until synchronized; actual Arabic PDF/DOCX export and two-student batch separation; human specialist review of card content and generated drafts.
