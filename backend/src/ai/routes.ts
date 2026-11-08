import { createHash } from 'node:crypto';
import type { Prisma, PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { z } from 'zod';
import type { AuthService, Clock } from '../auth.js';
import { canonicalJson, tokenHash } from '../crypto.js';
import { ApiError, missing } from '../errors.js';
import { assessmentSchema, studentSchema } from '../schemas.js';
import { initialAssessmentSchema } from '../intake/schema.js';
import { skillsForInitialAssessment } from '../intake/catalog.js';
import { RecordStore, type Envelope } from '../records.js';
import { approvePlan, createDraft, prepareGeneration, type PlanVersion } from '../planning/domain.js';
import { validateGeneratedPlan, type PlanProvider } from '../planning/gateway.js';
import { skillsForAssessment, toolLabels } from './catalog.js';
import { generateRequestSchema, payloadFromRequest, previewRequestSchema, PreviewSigner, type PreviewClaims } from './preview.js';

export interface AiConfig { enabled: boolean; syntheticOnly: boolean; provider: PlanProvider; model: string }
export interface AiRouteOptions { prisma: PrismaClient; auth: AuthService; records: RecordStore; storageKey: Buffer; clock?: Clock; config?: AiConfig }
type Receipt = { namespace: 'ai-generate'; state: 'pending' | 'completed' | 'failed'; record?: Envelope; error?: { code: string; message: string } };
interface StoredPlan extends PlanVersion {
  history: PlanVersion[];
  generation: { model: string; assessmentId: string; assessmentRevision: number; payloadHash: string };
}

export function registerAiRoutes(app: FastifyInstance, options: AiRouteOptions) {
  const { prisma, auth, records, config } = options;
  const now = options.clock ?? (() => new Date());
  const signer = new PreviewSigner(options.storageKey);
  const receiptContext = (ownerId: string, operationId: string) => `operation:${ownerId}:${operationId}`;
  async function requireSpecialist(request: FastifyRequest) {
    const user = await auth.requireUser(request);
    if (user.role !== 'specialist') throw new ApiError(403, 'SPECIALIST_REQUIRED', 'يلزم حساب مختصة مخوّل لإعداد الخطة واعتمادها.');
    return user;
  }
  function requirePolicy(): AiConfig {
    if (!config?.enabled) throw new ApiError(503, 'AI_DISABLED', 'توليد الخطط غير مفعّل حاليًا.');
    if (!config.syntheticOnly) throw new ApiError(403, 'SYNTHETIC_ONLY', 'التوليد متاح لبيانات الاختبار الاصطناعية فقط حتى اعتماد سياسة البيانات.');
    return config;
  }
  async function source(ownerId: string, studentId: string, assessmentId: string, tx: Prisma.TransactionClient | PrismaClient = prisma) {
    const [studentRow, assessmentRow] = await Promise.all([
      tx.record.findUnique({ where: { ownerId_id: { ownerId, id: studentId } } }),
      tx.record.findUnique({ where: { ownerId_id: { ownerId, id: assessmentId } } }),
    ]);
    if (!studentRow || studentRow.kind !== 'student' || studentRow.deletedAt || !assessmentRow || !['assessment', 'initialAssessment'].includes(assessmentRow.kind) || assessmentRow.parentId !== studentId || assessmentRow.deletedAt) throw missing();
    const student = studentSchema.parse(records.toEnvelope(studentRow).data);
    if (assessmentRow.kind === 'initialAssessment') {
      const assessment = initialAssessmentSchema.parse(records.toEnvelope(assessmentRow).data);
      if (!student.consentConfirmed || assessment.status !== 'approved') throw new ApiError(409, 'SOURCE_NOT_READY', 'أكمل الموافقة واعتماد التقييم الأولي أولًا.');
      if (assessment.method === 'academicCards') {
        const reference = await tx.record.findUnique({ where: { ownerId_id: { ownerId, id: assessment.academicAssessmentId! } } });
        if (!reference || reference.deletedAt || reference.kind !== 'assessment' || reference.parentId !== studentId || assessmentSchema.parse(records.toEnvelope(reference).data).status !== 'approved') throw new ApiError(409, 'SOURCE_NOT_READY', 'مصدر التقييم الأكاديمي غير متاح.');
      }
      return { studentRow, assessmentRow, skills: skillsForInitialAssessment(assessment), evidence: assessment.method === 'academicCards' ? 'approvedAcademicAssessment' : 'approvedAlternativeAssessment' };
    }
    const assessment = assessmentSchema.parse(records.toEnvelope(assessmentRow).data);
    if (!student.consentConfirmed || assessment.status !== 'approved' || !assessment.strengths.trim() || !assessment.needs.trim() || !Object.values(assessment.results).some(result => result.execution === 'performed')) throw new ApiError(409, 'SOURCE_NOT_READY', 'أكمل الموافقة واعتماد التقييم ونقاط القوة والاحتياج أولًا.');
    return { studentRow, assessmentRow, skills: skillsForAssessment(assessment), evidence: 'approvedAcademicAssessment' };
  }
  function verifyHash(claims: PreviewClaims, confirmedHash: string) {
    const hash = createHash('sha256').update(JSON.stringify(claims.payload)).digest('hex');
    if (confirmedHash !== claims.hash || hash !== claims.hash) throw new ApiError(400, 'CONFIRMATION_REQUIRED', 'أكد المعاينة الحالية نفسها قبل الإرسال.');
  }
  async function checkCurrentSource(ownerId: string, claims: PreviewClaims, tx: Prisma.TransactionClient | PrismaClient = prisma) {
    const current = await source(ownerId, claims.studentId, claims.assessmentId, tx);
    if (current.studentRow.revision !== claims.studentRevision || current.assessmentRow.revision !== claims.assessmentRevision) throw new ApiError(409, 'SOURCE_CHANGED', 'تغير مصدر الخطة. راجع البيانات وأنشئ معاينة جديدة.');
    return current;
  }
  const limit = { config: { rateLimit: { max: 12, timeWindow: '1 minute' } } };

  app.get('/v1/ai/skills', async request => {
    const user = await requireSpecialist(request);
    requirePolicy();
    const { assessmentId } = z.strictObject({ assessmentId: z.uuid() }).parse(request.query);
    const row = await records.get(user.id, assessmentId);
    if (!['assessment', 'initialAssessment'].includes(row.kind) || !row.parentId || row.deletedAt) throw missing();
    const verified = await source(user.id, row.parentId, assessmentId);
    return { skills: verified.skills };
  });

  app.post('/v1/ai/preview', limit, async request => {
    const user = await requireSpecialist(request);
    requirePolicy();
    const input = previewRequestSchema.parse(request.body);
    const current = await source(user.id, input.studentId, input.assessmentId);
    const payload = payloadFromRequest(input);
    if (payload.skills.some(skill => skill.evidence !== current.evidence) || new Set(payload.skills.map(skill => skill.skillId)).size !== payload.skills.length) throw new ApiError(400, 'INVALID_SKILLS', 'اختر مهارات موثقة مختلفة من التقييم المعتمد.');
    if (current.assessmentRow.kind === 'initialAssessment') {
      const levels = new Map(current.skills.map(item => [item.skillId, 'level' in item ? item.level : null]));
      if (payload.skills.some(skill => levels.get(skill.skillId) !== skill.level)) throw new ApiError(400, 'INVALID_SKILLS', 'استخدم مستويات الأداء المراجعة في التقييم المعتمد.');
    }
    let preview;
    try { preview = prepareGeneration(payload, { consentConfirmed: true, assessmentApproved: true, hasReviewedStrengths: true, hasReviewedNeeds: true, hasBaseline: true }, new Set(current.skills.map(skill => skill.skillId))); }
    catch { throw new ApiError(400, 'INVALID_SKILLS', 'اختر مهارات التقييم وحدد احتياجًا واحدًا على الأقل.'); }
    const expiresAt = new Date(now().getTime() + 10 * 60 * 1000);
    const previewToken = signer.sign({ version: 1, ownerId: user.id, studentId: input.studentId, assessmentId: input.assessmentId,
      studentRevision: current.studentRow.revision, assessmentRevision: current.assessmentRow.revision,
      expiresAt: expiresAt.getTime(), payload: preview.payload, hash: preview.hash });
    return { ...preview, previewToken, expiresAt: expiresAt.toISOString() };
  });

  app.post('/v1/ai/generate', limit, async (request, reply) => {
    const user = await requireSpecialist(request);
    const policy = requirePolicy();
    const input = generateRequestSchema.parse(request.body);
    const claims = signer.verify(input.previewToken, user.id);
    verifyHash(claims, input.confirmedHash);
    const requestHash = tokenHash(canonicalJson({ namespace: 'ai-generate', ...input }));
    const context = receiptContext(user.id, input.operationId);
    const replay = await prisma.$transaction(async tx => {
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${user.id}))`;
      const prior = await tx.syncOperation.findUnique({ where: { ownerId_operationId: { ownerId: user.id, operationId: input.operationId } } });
      if (prior) {
        if (prior.requestHash !== requestHash) throw new ApiError(409, 'OPERATION_REUSED', 'معرف العملية مستخدم بطلب مختلف.');
        const receipt = records.cipher.decrypt<Receipt>(prior.encryptedResult, context);
        if (receipt.namespace !== 'ai-generate') throw new ApiError(409, 'OPERATION_REUSED', 'معرف العملية مستخدم بطلب مختلف.');
        if (receipt.state === 'completed' && receipt.record) {
          // A deletion revokes access even to a replayed generation response.
          const existing = await tx.record.findUnique({ where: { ownerId_id: { ownerId: user.id, id: receipt.record.id } } });
          if (!existing || existing.deletedAt) throw missing();
          return receipt.record;
        }
        if (receipt.state === 'failed') throw new ApiError(502, 'AI_PREVIOUS_FAILED', 'فشل هذا الطلب السابق ولم تُحفظ خطة. راجع المدخلات وأنشئ معاينة جديدة للمحاولة بإجراء صريح.');
        throw new ApiError(409, 'AI_IN_PROGRESS', 'طلب التوليد قيد التنفيذ أو لم تُعرف نتيجته بعد انقطاعه. حدّث قائمة الخطط وراجع حالته؛ لن يُرسل مرة أخرى تلقائيًا.');
      }
      if (claims.expiresAt <= now().getTime()) throw new ApiError(409, 'PREVIEW_EXPIRED', 'انتهت صلاحية المعاينة. أنشئ معاينة جديدة.');
      await checkCurrentSource(user.id, claims, tx);
      await tx.syncOperation.create({ data: { ownerId: user.id, operationId: input.operationId, requestHash, encryptedResult: records.cipher.encrypt({ namespace: 'ai-generate', state: 'pending' } satisfies Receipt, context) } });
      await tx.auditEvent.create({ data: { ownerId: user.id, action: 'ai.generation_requested', entityId: claims.assessmentId } });
      return null;
    }, { timeout: 15000 });
    if (replay) return { record: replay };

    try {
      // The durable claim is committed before calling the provider; a retry never repeats the external call.
      const raw = await policy.provider.generate(structuredClone(claims.payload));
      let draft: PlanVersion;
      try {
        const content = validateGeneratedPlan(raw, claims.payload);
        const allowedTools = claims.payload.availableTools.map(tool => toolLabels[tool]);
        if (content.tools.some(tool => !allowedTools.includes(tool as typeof allowedTools[number]))) throw new Error('Unapproved tool');
        // The provider receives levels, never measured baseline numbers.
        if (/[0-9٠-٩۰-۹%٪]/u.test(`${content.baseline} ${content.strengthsSummary} ${content.needsSummary}`)) throw new Error('Unprovided baseline measurement');
        const followUp = Date.parse(content.nextFollowUp);
        const today = Date.parse(now().toISOString().slice(0, 10));
        if (followUp <= today || followUp > today + content.durationWeeks * 7 * 86400000) throw new Error('Invalid follow-up date');
        draft = createDraft(content, claims.studentId, 'ai', now());
      }
      catch { throw new ApiError(502, 'AI_OUTPUT_INVALID', 'لم تجتز المسودة فحص الجودة؛ لم تُحفظ خطة. أنشئ معاينة جديدة للمحاولة.'); }
      const plan: StoredPlan = { ...draft, history: [], generation: { model: policy.model, assessmentId: claims.assessmentId, assessmentRevision: claims.assessmentRevision, payloadHash: claims.hash } };
      const record = await prisma.$transaction(async tx => {
        await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${user.id}))`;
        await checkCurrentSource(user.id, claims, tx);
        const row = await tx.record.create({ data: { id: plan.id, ownerId: user.id, kind: 'plan', parentId: claims.studentId,
          encryptedPayload: records.cipher.encrypt(plan, records.recordContext(user.id, plan.id)) } });
        const envelope = records.toEnvelope(row);
        await tx.syncOperation.update({ where: { ownerId_operationId: { ownerId: user.id, operationId: input.operationId } }, data: { encryptedResult: records.cipher.encrypt({ namespace: 'ai-generate', state: 'completed', record: envelope } satisfies Receipt, context) } });
        await tx.auditEvent.create({ data: { ownerId: user.id, action: 'ai.draft_created', entityId: row.id } });
        return envelope;
      }, { timeout: 15000 });
      return reply.code(201).send({ record });
    } catch (error) {
      const safe = error instanceof ApiError ? error : new ApiError(502, 'AI_PROVIDER_UNAVAILABLE', 'تعذر التوليد؛ لم تُحفظ خطة. أنشئ معاينة جديدة لإعادة المحاولة.');
      await prisma.syncOperation.updateMany({ where: { ownerId: user.id, operationId: input.operationId }, data: { encryptedResult: records.cipher.encrypt({ namespace: 'ai-generate', state: 'failed', error: { code: safe.code, message: safe.message } } satisfies Receipt, context) } });
      throw safe;
    }
  });

  app.post('/v1/plans/:id/approve', async request => {
    const user = await requireSpecialist(request);
    const { id } = z.strictObject({ id: z.uuid() }).parse(request.params);
    const { revision } = z.strictObject({ revision: z.int().positive(), confirmed: z.literal(true) }).parse(request.body);
    const record = await prisma.$transaction(async tx => {
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${user.id}))`;
      const row = await tx.record.findUnique({ where: { ownerId_id: { ownerId: user.id, id } } });
      if (!row || row.kind !== 'plan' || row.deletedAt) throw missing();
      if (row.revision !== revision) throw new ApiError(409, 'REVISION_CONFLICT', 'تغيرت نسخة الخطة. حدّثها وراجعها قبل الاعتماد.');
      const plan = records.toEnvelope(row).data as unknown as StoredPlan;
      if (plan.status !== 'draft') throw new ApiError(409, 'PLAN_ALREADY_APPROVED', 'الخطة معتمدة بالفعل.');
      const approved = approvePlan(plan, user.id, true, now());
      const snapshot: PlanVersion = { id: plan.id, studentId: plan.studentId, version: plan.version, status: plan.status, source: plan.source, suggested: plan.suggested, content: plan.content, createdAt: plan.createdAt, approvedAt: plan.approvedAt, approvedBy: plan.approvedBy, previousVersionId: plan.previousVersionId };
      const saved: StoredPlan = { ...approved, version: plan.version + 1, history: [...plan.history, snapshot], generation: plan.generation };
      const updated = await tx.record.update({ where: { ownerId_id: { ownerId: user.id, id } }, data: { revision: { increment: 1 }, encryptedPayload: records.cipher.encrypt(saved, records.recordContext(user.id, id)) } });
      await tx.auditEvent.create({ data: { ownerId: user.id, action: 'plan.approved', entityId: id } });
      return records.toEnvelope(updated);
    }, { timeout: 15000 });
    return { record };
  });
}
