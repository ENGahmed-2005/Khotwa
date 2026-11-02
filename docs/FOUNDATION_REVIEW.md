# Foundation review — draft PR 1

Review date: 2026-11-02. PR: https://github.com/ENGahmed-2005/Khotwa/pull/1

Reviewed central contract and Prisma schema before integrating consuming branches. The contract fixes owner scoping, encrypted payloads, stable UUIDs, idempotent operation identifiers, revision conflicts, tombstones, fixed assessment template 1.1, explicit review and no automatic AI send. Worktrees consume this contract independently; integrator owns amendments.

Technical review findings addressed:
- Legacy grouped reading words must become four independent items in a new version; old snapshots must not be silently upgraded.
- Subjective writing/reading observations are excluded from objective item scoring.
- Completion and approval have separate validations; API and UI must use the same states.
- Same operation identifier with changed payload must reject, not overwrite its receipt.
- Client and server encryption must bind ciphertext to owner/context and reject tampering.

Pending review gates: actual PostgreSQL integration/concurrent operations, device-side native encryption, end-to-end Android/iOS testing and human specialist review. Draft PR remains unmerged. No claim that this technical review substitutes for educational/legal approval.
