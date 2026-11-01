# Khotwa protocol v1 (2026-11-01 foundation)

Authoritative consumer contract for the first executable slice. JSON camelCase. All `/v1` routes except register/login/password-reset require `Authorization: Bearer <opaque token>`. Strict request allowlists reject unknown fields. IDs are UUID v4. No student names, full birth dates, health/diagnosis, image or audio uploads. Free text requires an explicit privacy-review checkbox and never enters AI automatically. Synthetic development only pending policy decisions.

## Auth
- `POST /v1/auth/register`, `POST /v1/auth/login`: `{email,password}` -> `{token,expiresAt,user:{id,email,role}}`. Password 12..128 chars. Email belongs to adult account only.
- `GET /v1/auth/me` -> `{user:{id,email,role}}`.
- `POST /v1/auth/logout` -> 204, revokes current token.
- `POST /v1/auth/password-reset/request`: `{email}` -> 202 generic `{message}`. Delivery adapter must be configured, no token in HTTP/logs. Tests inject a capture adapter.
- `POST /v1/auth/password-reset/confirm`: `{token,password}` -> 204; one-use, expiring, revoke sessions.
- `DELETE /v1/auth/account`: `{password,confirmed:true}` -> 204 cascade, local erase after acknowledgement. Retention policy remains open; destructive action explicit.

## Owner-scoped records and offline operations
- `GET /v1/records?kind=student|assessment|initialAssessment|plan|session` -> `{records:[Envelope]}`.
- `GET /v1/records/:id` -> `{record:Envelope}`, unowned id is 404.
- `POST /v1/sync/push` -> `{results:[Result]}` from `{operations:[Operation]}` (1..50).
- `GET /v1/sync/pull` -> `{records:[Envelope],fullSnapshot:true}`. Full owner snapshot including tombstones in first release; never treat missing record as deletion. Cursor/pagination optimization deferred and documented.
- `Envelope={id,kind,parentId:null|string,revision,deletedAt:null|ISO,createdAt:ISO,updatedAt:ISO,data:object}`.
- `Operation={operationId,deviceId,entityId,kind,parentId:null|string,baseRevision:int>=0,occurredAt:ISO,action:'upsert'|'delete',data:object}`.
- `Result={operationId,status:'applied'|'conflict'|'rejected',record?:Envelope,error?:{code,message}}`.
- Idempotency scoped to owner. Same operation ID+same request returns original result. Reusing ID with changed content rejects. Revision conflict returns current server record; client retains its variant/outbox and asks user to resolve. Retry must not overwrite. Server-owned approval cannot be injected. Delete produces tombstone; student deletion cascades tombstones to descendants.

## Payloads (kind)
### student
`{id,code,grade,ageYears,ageMonths,consentConfirmed,consentDate,createdAt}`
id=entityId. code generated client-side `ST-` plus 8 random uppercase hex digits (user does not type names into code). grade one of mobile supportedSchoolGrades. Age 3..21, months 0..11. consentConfirmed must true; consentDate ISO. Device clock timestamps descriptive only; server audit time authoritative. Additional demographic/initial-intake fields deferred to explicit contract revision.

### assessment
`{id,studentId,ageGroup:'6-8'|'9-12',templateVersion:'1.1',createdAt,status:'draft'|'completed'|'approved',ageOverrideReason,results:{[itemId]:ItemResult},strengths,needs,approvedAt:null|ISO,privacyReviewed:true}`
ItemResult = `{execution:'notDone'|'performed'|'unable',judgment:null|'independentCorrect'|'supportedCorrect'|'incorrect'|'notScorable',support:'independent'|'verbal'|'partial'|'full',response,observation,readingSeconds:null|nonnegativeInt,readingErrors:null|nonnegativeInt}`. Optional `wordsRead,selfCorrections` nonnegative integers or null. Nonperformed judgments must null. Subjective items must notScorable. Independent judgment requires independent support. Never derive clinical/normative thresholds. Strengths/needs general free text with privacy review and no automatic AI use.
parentId=studentId. Original template/age group frozen after creation. Approval transition explicit operation with `status=approved`, `approvedAt` from user's action; server revalidates complete items, nonempty strengths+needs, at least one performed and all performed judged; server stamps reviewer/time in audit. Approved record immutable; create reassessment.
Template 1.1 fixes original imported 1.0 grouped words: 1d1,1d2,1d3,1d4 separate objective items; remaining IDs 1a,1b,1c,2a,2b,3a,3b,3c,3d,4a,4b,4c,4d,5a,5b,6a,6b,6c,6d. V1.0 legacy snapshots must be preserved, not silently upgraded.

### initialAssessment (next slice, schema details require integrator coordination)
Reserved, not accepted until a validated schema exists. Same for plan/session. No generic pass-through JSON writes.

## Error responses
`{error:{code,message}}` with safe Arabic-facing messages. 400 invalid, 401 unauthenticated, 404 missing/unowned, 409 duplicate/conflict, 429 throttled, 503 dependency unavailable. No stack, password, token, input payload or student text in logs.

## Client persistence
Per-account AES-256-GCM encrypted file containing records+outbox, encryption key in Keystore/Keychain (flutter_secure_storage for key only). Durable atomic commit before notifying UI or sending network request. Failed writes roll back memory. Local login session cached securely, offline use only after prior authentication; no offline registration. Logout removes active UI access and keeps unsynced encrypted work partitioned by owner unless user explicitly deletes it. Different accounts must never see each other's files. Encrypted file authentication failure fails closed without overwrite. Production APIs must HTTPS; debug loopback explicit.
