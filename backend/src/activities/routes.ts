import { createHash, createHmac, randomUUID, timingSafeEqual } from 'node:crypto';
import { z } from 'zod';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import type { Prisma, PrismaClient } from '@prisma/client';
import type { AuthService, Clock } from '../auth.js';
import { canonicalJson, tokenHash } from '../crypto.js';
import { ApiError, missing } from '../errors.js';
import { planContentSchema } from '../planning/domain.js';
import type { Envelope, RecordStore } from '../records.js';
import { studentSchema } from '../schemas.js';
import { activityPayloadSchema, activityPreviewSchema, defaultTools, inspectActivityText, toolProfileSchema, validateActivityOutput, type ActivityPayload } from './domain.js';
import type { ActivityConfig } from './gemini.js';

export interface ActivityRouteOptions { prisma: PrismaClient; auth: AuthService; records: RecordStore; storageKey: Buffer; clock?: Clock; config?: ActivityConfig }
const claimsSchema = z.strictObject({
  namespace: z.literal('activity-preview-v1'), ownerId: z.uuid(), studentId: z.uuid(), planId: z.uuid(), goalId: z.uuid(),
  studentRevision: z.int().positive(), planRevision: z.int().positive(), toolsRevision: z.int().positive(),
  expiresAt: z.number(), hash: z.string().length(64), payload: activityPayloadSchema,
});
const generateSchema = z.strictObject({ previewToken: z.string().min(1).max(60000), confirmedHash: z.string().regex(/^[a-f0-9]{64}$/),
  operationId: z.uuid(), confirmed: z.literal(true), syntheticDataConfirmed: z.literal(true) });
type Claims = z.infer<typeof claimsSchema>;
interface Receipt { namespace: 'activity-generate'; state: 'pending' | 'completed' | 'failed' | 'cancelled'; startedAt?: string; leaseExpiresAt?: string; cancelledAt?: string; record?: Envelope; error?: { code: string; message: string } }
const leaseMs = 10 * 60 * 1000;
const hashPayload = (payload: ActivityPayload) => createHash('sha256').update(canonicalJson(payload)).digest('hex');

export function registerActivityRoutes(app: FastifyInstance, options: ActivityRouteOptions): void {
  const { prisma, auth, records } = options;
  const now = options.clock ?? (() => new Date());
  const ownerLock = async (tx: Prisma.TransactionClient, ownerId: string) => tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${ownerId}))`;
  const operationContext = (ownerId: string, id: string) => `operation:${ownerId}:${id}`;
  const expiry = (receipt: Receipt, createdAt: Date) => new Date(receipt.leaseExpiresAt ?? new Date(createdAt.getTime() + leaseMs).toISOString());
  const expired = (receipt: Receipt, createdAt: Date) => receipt.state === 'pending' && expiry(receipt, createdAt) <= now();
  const cancelledError = () => new ApiError(409, 'AI_OPERATION_CANCELLED', 'أُلغي طلب النشاط؛ لن تُحفظ نتيجة متأخرة. أنشئي معاينة جديدة لمحاولة جديدة.');
  async function specialist(request: FastifyRequest) {
    const user = await auth.requireUser(request);
    if (user.role !== 'specialist') throw new ApiError(403, 'SPECIALIST_REQUIRED', 'يلزم حساب مختصة مخوّل.');
    return user;
  }
  function policy(): ActivityConfig {
    if (!options.config?.enabled) throw new ApiError(503, 'AI_DISABLED', 'توليد الأنشطة غير مفعّل حاليًا.');
    if (!options.config.syntheticOnly) throw new ApiError(403, 'SYNTHETIC_ONLY', 'التوليد متاح ببيانات اصطناعية فقط حتى اعتماد السياسة.');
    return options.config;
  }
  async function toolsFor(ownerId: string, tx: Prisma.TransactionClient | PrismaClient = prisma) {
    const row = await tx.record.findFirst({ where: { ownerId, kind: 'activityTools', deletedAt: null } });
    return row ? { row, profile: toolProfileSchema.parse(records.toEnvelope(row).data) } : null;
  }
  async function source(ownerId: string, studentId: string, planId: string, goalId: string, tx: Prisma.TransactionClient | PrismaClient = prisma) {
    const [studentRow, planRow, tools] = await Promise.all([
      tx.record.findUnique({ where: { ownerId_id: { ownerId, id: studentId } } }),
      tx.record.findUnique({ where: { ownerId_id: { ownerId, id: planId } } }), toolsFor(ownerId, tx),
    ]);
    if (!studentRow || studentRow.kind !== 'student' || studentRow.deletedAt || !planRow || planRow.kind !== 'plan' || planRow.parentId !== studentId || planRow.deletedAt) throw missing();
    const student = studentSchema.parse(records.toEnvelope(studentRow).data);
    const plan = records.toEnvelope(planRow).data;
    if (!student.consentConfirmed || plan.status !== 'approved') throw new ApiError(409, 'SOURCE_NOT_READY', 'اعتمد الخطة وراجع موافقة ملف الطالب أولًا.');
    const content = planContentSchema.parse(plan.content);
    const goal = content.goals.find(goal => goal.id === goalId);
    if (!goal) throw missing();
    if (!tools) throw new ApiError(409, 'TOOLS_NOT_READY', 'احفظ ملف الأدوات المتاحة أولًا.');
    return { studentRow, planRow, student, goal, tools };
  }
  function sign(claims: Claims): string {
    const encoded = Buffer.from(JSON.stringify(claims)).toString('base64url');
    return `${encoded}.${createHmac('sha256', options.storageKey).update(`activity-preview:${encoded}`).digest('base64url')}`;
  }
  function verify(token: string, ownerId: string): Claims {
    try {
      const [encoded, signature, extra] = token.split('.');
      if (!encoded || !signature || extra) throw new Error('Token format');
      const expected = createHmac('sha256', options.storageKey).update(`activity-preview:${encoded}`).digest();
      const actual = Buffer.from(signature, 'base64url');
      if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) throw new Error('Token signature');
      const claims = claimsSchema.parse(JSON.parse(Buffer.from(encoded, 'base64url').toString('utf8')));
      if (claims.ownerId !== ownerId || claims.hash !== hashPayload(claims.payload)) throw new Error('Token owner or payload');
      return claims;
    } catch { throw new ApiError(400, 'PREVIEW_INVALID', 'المعاينة غير صالحة. أنشئ معاينة جديدة لهذا الحساب.'); }
  }
  async function currentSource(ownerId: string, claims: Claims, tx: Prisma.TransactionClient | PrismaClient = prisma) {
    const current = await source(ownerId, claims.studentId, claims.planId, claims.goalId, tx);
    if (current.studentRow.revision !== claims.studentRevision || current.planRow.revision !== claims.planRevision || current.tools.row.revision !== claims.toolsRevision) {
      throw new ApiError(409, 'SOURCE_CHANGED', 'تغيرت الخطة أو الأدوات. راجع معاينة جديدة.');
    }
    return current;
  }

  app.get('/v1/activities/tools', async request => {
    const user = await specialist(request);
    const stored = await toolsFor(user.id);
    return { revision: stored?.row.revision ?? 0, configured: !!stored, tools: stored?.profile.tools ?? defaultTools };
  });
  app.put('/v1/activities/tools', async request => {
    const user = await specialist(request);
    const { revision, ...input } = toolProfileSchema.extend({ revision: z.int().nonnegative() }).parse(request.body);
    try { inspectActivityText(input.tools.map(tool => tool.label)); }
    catch { throw new ApiError(400, 'PRIVACY_REVIEW_REQUIRED', 'راجع أسماء الأدوات لتخلو من بيانات التعريف والتشخيص.'); }
    for (const tool of input.tools) {
      const standard = defaultTools.find(item => item.id === tool.id);
      if (standard && standard.label !== tool.label) throw new ApiError(400, 'INVALID_TOOL', 'الأدوات الأساسية لها أسماء ثابتة. أضف أداة مخصصة عند الحاجة.');
    }
    return prisma.$transaction(async tx => {
      await ownerLock(tx, user.id);
      const stored = await toolsFor(user.id, tx);
      if ((stored?.row.revision ?? 0) !== revision) throw new ApiError(409, 'REVISION_CONFLICT', 'تغير ملف الأدوات. حدّثه قبل الحفظ.');
      const id = stored?.row.id ?? randomUUID();
      const encryptedPayload = records.cipher.encrypt(input, records.recordContext(user.id, id));
      const row = stored ? await tx.record.update({ where: { ownerId_id: { ownerId: user.id, id } }, data: { encryptedPayload, revision: { increment: 1 } } })
        : await tx.record.create({ data: { id, ownerId: user.id, kind: 'activityTools', parentId: null, encryptedPayload } });
      await tx.auditEvent.create({ data: { ownerId: user.id, action: 'activity.tools_saved', entityId: id } });
      return { revision: row.revision, configured: true, tools: input.tools };
    });
  });
  const limited = { config: { rateLimit: { max: 12, timeWindow: '1 minute' } } };
  app.get('/v1/activities/operations/:operationId', async request => {
    const user = await specialist(request);
    const { operationId } = z.strictObject({ operationId: z.uuid() }).parse(request.params);
    const row = await prisma.syncOperation.findUnique({ where: { ownerId_operationId: { ownerId: user.id, operationId } } });
    if (!row) throw missing();
    const receipt = records.cipher.decrypt<Receipt>(row.encryptedResult, operationContext(user.id, operationId));
    if (receipt.namespace !== 'activity-generate') throw missing();
    return { operationId, state: expired(receipt, row.createdAt) ? 'expired' : receipt.state,
      leaseExpiresAt: expiry(receipt, row.createdAt).toISOString(), canCancel: receipt.state === 'pending',
      ...(receipt.record ? { recordId: receipt.record.id } : {}) };
  });
  app.post('/v1/activities/operations/:operationId/cancel', async request => {
    const user = await specialist(request);
    const { operationId } = z.strictObject({ operationId: z.uuid() }).parse(request.params);
    z.strictObject({ confirmed: z.literal(true) }).parse(request.body);
    return prisma.$transaction(async tx => {
      await ownerLock(tx, user.id);
      const row = await tx.syncOperation.findUnique({ where: { ownerId_operationId: { ownerId: user.id, operationId } } });
      if (!row) throw missing();
      const context = operationContext(user.id, operationId);
      const receipt = records.cipher.decrypt<Receipt>(row.encryptedResult, context);
      if (receipt.namespace !== 'activity-generate') throw missing();
      if (receipt.state === 'completed' || receipt.state === 'failed') throw new ApiError(409, 'AI_OPERATION_FINISHED', 'انتهى الطلب. راجعي نتيجته قبل بدء محاولة أخرى.');
      if (receipt.state !== 'cancelled') {
        await tx.syncOperation.update({ where: { ownerId_operationId: { ownerId: user.id, operationId } }, data: {
          encryptedResult: records.cipher.encrypt({ ...receipt, state: 'cancelled', cancelledAt: now().toISOString() } satisfies Receipt, context),
        } });
        await tx.auditEvent.create({ data: { ownerId: user.id, action: 'activity.generation_cancelled', entityId: operationId } });
      }
      return { operationId, state: 'cancelled', canCancel: false };
    });
  });
  app.post('/v1/activities/preview', limited, async request => {
    const user = await specialist(request);
    policy();
    const input = activityPreviewSchema.parse(request.body);
    const current = await source(user.id, input.studentId, input.planId, input.goalId);
    if (input.grade !== current.student.grade) throw new ApiError(400, 'INVALID_GRADE', 'اختر الصف المسجل في ملف الطالب.');
    const selected = current.tools.profile.tools.filter(tool => input.toolIds.includes(tool.id));
    if (selected.length !== input.toolIds.length) throw new ApiError(400, 'INVALID_TOOL', 'استخدم الأدوات المحفوظة والمتاحة فقط.');
    const { behavior, condition, criterion, timeframeWeeks } = current.goal;
    const payload = activityPayloadSchema.parse({ domain: input.domain, grade: input.grade, difficulty: input.difficulty, type: input.type,
      availableTools: selected, minutes: input.minutes, mode: input.mode, goal: { behavior, condition, criterion, timeframeWeeks } });
    try { inspectActivityText({ goal: { behavior, condition }, tools: selected.map(tool => tool.label) }); }
    catch { throw new ApiError(400, 'PRIVACY_REVIEW_REQUIRED', 'صحّح نص الهدف أو الأدوات قبل معاينة الإرسال.'); }
    const hash = hashPayload(payload);
    const expiresAt = new Date(now().getTime() + 10 * 60 * 1000);
    const previewToken = sign({ namespace: 'activity-preview-v1', ownerId: user.id, studentId: input.studentId, planId: input.planId, goalId: input.goalId,
      studentRevision: current.studentRow.revision, planRevision: current.planRow.revision, toolsRevision: current.tools.row.revision,
      expiresAt: expiresAt.getTime(), payload, hash });
    return { payload, hash, previewToken, expiresAt: expiresAt.toISOString() };
  });
  app.post('/v1/activities/generate', limited, async (request, reply) => {
    const user = await specialist(request);
    const config = policy();
    const input = generateSchema.parse(request.body);
    const claims = verify(input.previewToken, user.id);
    if (claims.hash !== input.confirmedHash) throw new ApiError(400, 'CONFIRMATION_REQUIRED', 'أكد الحمولة المعروضة نفسها.');
    const requestHash = tokenHash(canonicalJson({ namespace: 'activity-generate', ...input }));
    const context = `operation:${user.id}:${input.operationId}`;
    const prior = await prisma.$transaction(async tx => {
      await ownerLock(tx, user.id);
      const receipt = await tx.syncOperation.findUnique({ where: { ownerId_operationId: { ownerId: user.id, operationId: input.operationId } } });
      if (receipt) {
        if (receipt.requestHash !== requestHash) throw new ApiError(409, 'OPERATION_REUSED', 'لا تُعد استخدام العملية بطلب مختلف.');
        const stored = records.cipher.decrypt<Receipt>(receipt.encryptedResult, context);
        if (stored.state === 'completed' && stored.record) {
          const row = await tx.record.findUnique({ where: { ownerId_id: { ownerId: user.id, id: stored.record.id } } });
          const student = await tx.record.findUnique({ where: { ownerId_id: { ownerId: user.id, id: claims.studentId } } });
          if (!row || row.deletedAt || !student || student.deletedAt) throw missing();
          return records.toEnvelope(row);
        }
        if (stored.state === 'failed') throw new ApiError(409, 'AI_PREVIOUS_FAILED', 'فشلت المحاولة السابقة. أنشئ معاينة جديدة وأكّد محاولة جديدة.');
        if (stored.state === 'cancelled') throw cancelledError();
        if (expired(stored, receipt.createdAt)) throw new ApiError(409, 'AI_OPERATION_EXPIRED', 'انتهت مدة انتظار الطلب. ألغيه صراحةً ثم أنشئي معاينة جديدة.');
        throw new ApiError(409, 'AI_OPERATION_PENDING', 'الطلب السابق قيد المعالجة أو يحتاج مراجعة. لم يُرسل طلب مكرر.');
      }
      if (claims.expiresAt <= now().getTime()) throw new ApiError(409, 'PREVIEW_EXPIRED', 'انتهت المعاينة. راجع الحقول مجددًا.');
      await currentSource(user.id, claims, tx);
      await tx.syncOperation.create({ data: { ownerId: user.id, operationId: input.operationId, requestHash,
        encryptedResult: records.cipher.encrypt({ namespace: 'activity-generate', state: 'pending', startedAt: now().toISOString(), leaseExpiresAt: new Date(now().getTime() + leaseMs).toISOString() } satisfies Receipt, context) } });
      return null;
    }, { timeout: 15000 });
    if (prior) return { record: prior };
    try {
      const raw = await config.provider.generate(structuredClone(claims.payload));
      let content;
      try { content = validateActivityOutput(raw, claims.payload); }
      catch { throw new ApiError(502, 'AI_OUTPUT_INVALID', 'النشاط لم يجتز فحص الجودة. لم تُحفظ نتيجة.'); }
      const record = await prisma.$transaction(async tx => {
        await ownerLock(tx, user.id);
        const pending = await tx.syncOperation.findUnique({ where: { ownerId_operationId: { ownerId: user.id, operationId: input.operationId } } });
        if (!pending) throw missing();
        const receipt = records.cipher.decrypt<Receipt>(pending.encryptedResult, context);
        if (receipt.state === 'cancelled') throw cancelledError();
        if (expired(receipt, pending.createdAt)) throw new ApiError(409, 'AI_OPERATION_EXPIRED', 'لن يُحفظ نشاط وصل بعد انتهاء المهلة.');
        if (receipt.state !== 'pending') throw new ApiError(409, 'AI_OPERATION_FINISHED', 'الطلب انتهى بالفعل.');
        await currentSource(user.id, claims, tx);
        const id = randomUUID();
        const data = { id, studentId: claims.studentId, planId: claims.planId, goalId: claims.goalId, status: 'draft', source: 'ai', suggested: true,
          createdAt: now().toISOString(), approvedAt: null, approvedBy: null, content,
          toolSnapshot: claims.payload.availableTools,
          generation: { model: config.model, payloadHash: claims.hash, planRevision: claims.planRevision } };
        const row = await tx.record.create({ data: { id, ownerId: user.id, kind: 'activity', parentId: claims.studentId,
          encryptedPayload: records.cipher.encrypt(data, records.recordContext(user.id, id)) } });
        const envelope = records.toEnvelope(row);
        await tx.syncOperation.update({ where: { ownerId_operationId: { ownerId: user.id, operationId: input.operationId } },
          data: { encryptedResult: records.cipher.encrypt({ namespace: 'activity-generate', state: 'completed', record: envelope } satisfies Receipt, context) } });
        await tx.auditEvent.create({ data: { ownerId: user.id, action: 'activity.draft_created', entityId: id } });
        return envelope;
      }, { timeout: 15000 });
      return reply.code(201).send({ record });
    } catch (error) {
      const safe = error instanceof ApiError ? error : new ApiError(502, 'AI_PROVIDER_UNAVAILABLE', 'تعذر توليد النشاط. المدخلات محفوظة.');
      await prisma.$transaction(async tx => {
        await ownerLock(tx, user.id);
        const row = await tx.syncOperation.findUnique({ where: { ownerId_operationId: { ownerId: user.id, operationId: input.operationId } } });
        if (!row) return;
        const receipt = records.cipher.decrypt<Receipt>(row.encryptedResult, context);
        if (receipt.state !== 'pending' || expired(receipt, row.createdAt)) return;
        await tx.syncOperation.update({ where: { ownerId_operationId: { ownerId: user.id, operationId: input.operationId } },
          data: { encryptedResult: records.cipher.encrypt({ ...receipt, state: 'failed', error: { code: safe.code, message: safe.message } } satisfies Receipt, context) } });
      });
      throw safe;
    }
  });
  app.post('/v1/activities/:id/approve', async request => {
    const user = await specialist(request);
    const { id } = z.strictObject({ id: z.uuid() }).parse(request.params);
    const { revision } = z.strictObject({ revision: z.int().positive(), confirmed: z.literal(true) }).parse(request.body);
    return prisma.$transaction(async tx => {
      await ownerLock(tx, user.id);
      const row = await tx.record.findUnique({ where: { ownerId_id: { ownerId: user.id, id } } });
      if (!row || row.kind !== 'activity' || row.deletedAt) throw missing();
      if (row.revision !== revision) throw new ApiError(409, 'REVISION_CONFLICT', 'تغير النشاط. راجعه مجددًا.');
      const data = records.toEnvelope(row).data;
      if (data.status !== 'draft') throw new ApiError(409, 'ALREADY_APPROVED', 'النشاط معتمد بالفعل.');
      await source(user.id, data.studentId as string, data.planId as string, data.goalId as string, tx);
      const updated = { ...data, status: 'approved', suggested: false, approvedAt: now().toISOString(), approvedBy: user.id };
      const saved = await tx.record.update({ where: { ownerId_id: { ownerId: user.id, id } },
        data: { revision: { increment: 1 }, encryptedPayload: records.cipher.encrypt(updated, records.recordContext(user.id, id)) } });
      await tx.auditEvent.create({ data: { ownerId: user.id, action: 'activity.approved', entityId: id } });
      return { record: records.toEnvelope(saved) };
    });
  });
}
