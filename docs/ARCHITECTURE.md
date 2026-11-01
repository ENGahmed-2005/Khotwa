# Architecture decisions — 2026-11-01

ADR-001: Flutter Android/iOS and Node 22+ / TypeScript / Fastify / Zod / Prisma 6 / PostgreSQL. Adopt supplied AGENTS recommendation. Existing v0.1 source imported from the supplied local development archive, then upgraded without discarding prior work. Original archive remains in Downloads.

ADR-002: Aggregate `Record` with owner composite key, strict kind-specific validators and AES-256-GCM payload encryption. This allows atomic offline snapshots without schema drift between parallel agents. Owner lookup enforced server-side, never supplied by client. No generic unvalidated JSON persistence. Relational account/session/audit/idempotency models; migrations versioned. This is a technical implementation choice, not an educational requirement.

ADR-003: Opaque random session tokens stored as SHA-256 digests server-side; scrypt password hashing, expiry, throttling and explicit revocation. Refresh/production delivery policy requires further verification.

ADR-004: Per-account encrypted local snapshot and outbox, AEAD key stored in Keystore/Keychain. Atomic durable write + rollback. This is file encryption, not a claim that secure storage encrypts SQLite. Physical-device keystore and crash validation remain separate acceptance gates.

ADR-005: Full owner pull snapshot initially, explicit optimistic revisions and retained conflicts/tombstones. Optimize pagination later without altering correctness; scale testing pending.

ADR-006: All local execution uses synthetic data only; AI is disabled without approved provider/location policy and explicit request preview. No fabricated AI fallback. A successful build is not field acceptance.

API contract: ../packages/contracts/API.md. Prisma schema owned by integrator. New schemas need coordinated contract change before consumers.
