import { createHash } from 'node:crypto';
import type { Prisma, PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { z } from 'zod';
import type { AuthService, Clock } from '../auth.js';
import { canonicalJson, tokenHash } from '../crypto.js';
import { ApiError, missing } from '../errors.js';
import { assessmentSchema, studentSchema, type StudentData } from '../schemas.js';
import { initialAssessmentSchema } from '../intake/schema.js';
import { skillsForInitialAssessment } from '../intake/catalog.js';
import { RecordStore, type Envelope } from '../records.js';
import { approvePlan, createDraft, customSkillId, prepareGeneration, reviewedSkillLabel, studentPresentation, type PlanVersion } from '../planning/domain.js';
import { validateGeneratedPlan, type PlanProvider } from '../planning/gateway.js';
import { skillsForAssessment, toolLabels } from './catalog.js';
import { generateRequestSchema, payloadFromRequest, previewRequestSchema, PreviewSigner, type PreviewClaims } from './preview.js';

export interface AiConfig { enabled: boolean; syntheticOnly: boolean; provider: PlanProvider; model: string }
export interface AiRouteOptions { prisma: PrismaClient; auth: AuthService; records: RecordStore; storageKey: Buffer; clock?: Clock; config?: AiConfig }
export const AI_OPERATION_LEASE_MS = 10 * 60 * 1000;
type Receipt = { namespace: 'ai-generate'; state: 'pending' | 'completed' | 'failed' | 'cancelled';
  startedAt?: string; leaseExpiresAt?: string; cancelledAt?: string;
  record?: Envelope; error?: { code: string; message: string } };
interface StoredPlan extends PlanVersion {
  history: PlanVersion[];
  generation: { model: string; assessmentId: string; assessmentRevision: number; payloadHash: string };
}

export function registerAiRoutes(app: FastifyInstance, options: AiRouteOptions) {
  const { prisma, auth, records, config } = options;
  const now = options.clock ?? (() => new Date());
  const signer = new PreviewSigner(options.storageKey);
  const receiptContext = (ownerId: string, operationId: string) => `operation:${ownerId}:${operationId}`;
  const active = new Map<string, AbortController>();
  function leaseExpiry(receipt: Receipt, createdAt: Date): Date {
    const stored = receipt.leaseExpiresAt ? Date.parse(receipt.leaseExpiresAt) : Number.NaN;
    return new Date(Number.isFinite(stored) ? stored : createdAt.getTime() + AI_OPERATION_LEASE_MS);
  }
  function isExpired(receipt: Receipt, createdAt: Date) { return receipt.state === 'pending' && leaseExpiry(receipt, createdAt) <= now(); }
  function cancelledError() { return new ApiError(409, 'AI_OPERATION_CANCELLED', 'أُلغي هذا الطلب؛ لن تُحفظ نتيجته. أنشئ معاينة جديدة وأكّد عملية جديدة للمحاولة.'); }
  function expiredError() { return new ApiError(409, 'AI_OPERATION_EXPIRED', 'انتهت مدة انتظار هذا الطلب ولن تُحفظ نتيجة متأخرة. يمكنك إلغاءه ثم مراجعة معاينة جديدة.'); }
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
    // Legacy/unfinished profiles remain valid records, but FR-22/32 require explicit basics before AI.
    if (!['male', 'female'].includes(student.gender ?? '') || !student.referralReason?.trim()) {
      throw new ApiError(409, 'STUDENT_INPUTS_INCOMPLETE', 'استكملي الجنس وسبب الإحالة في ملف الطالب، ثم راجعي معاينة جديدة قبل التوليد.');
    }
    if (assessmentRow.kind === 'initialAssessment') {
      const assessment = initialAssessmentSchema.parse(records.toEnvelope(assessmentRow).data);
      if (!student.consentConfirmed || assessment.status !== 'approved') throw new ApiError(409, 'SOURCE_NOT_READY', 'أكمل الموافقة واعتماد التقييم الأولي أولًا.');
      if (assessment.method === 'academicCards') {
        const reference = await tx.record.findUnique({ where: { ownerId_id: { ownerId, id: assessment.academicAssessmentId! } } });
        if (!reference || reference.deletedAt || reference.kind !== 'assessment' || reference.parentId !== studentId || assessmentSchema.parse(records.toEnvelope(reference).data).status !== 'approved') throw new ApiError(409, 'SOURCE_NOT_READY', 'مصدر التقييم الأكاديمي غير متاح.');
      }
      return { studentRow, student, assessmentRow, skills: skillsForInitialAssessment(assessment), evidence: assessment.method === 'academicCards' ? 'approvedAcademicAssessment' : 'approvedAlternativeAssessment' };
    }
    const assessment = assessmentSchema.parse(records.toEnvelope(assessmentRow).data);
    if (!student.consentConfirmed || assessment.status !== 'approved' || !assessment.strengths.trim() || !assessment.needs.trim() || !Object.values(assessment.results).some(result => result.execution === 'performed')) throw new ApiError(409, 'SOURCE_NOT_READY', 'أكمل الموافقة واعتماد التقييم ونقاط القوة والاحتياج أولًا.');
    return { studentRow, student, assessmentRow, skills: skillsForAssessment(assessment), evidence: 'approvedAcademicAssessment' };
  }
  function generationSourceHash(student: StudentData, skills: readonly { skillId: string; label: string; evidence: string; level?: unknown }[]) {
    const projection = skills.map(skill => ({ skillId: skill.skillId, label: skill.label, evidence: skill.evidence, level: skill.level ?? null }))
      .sort((a, b) => a.skillId.localeCompare(b.skillId));
    // Only this digest enters the signed preview; these basics are never added to the provider payload.
    return tokenHash(canonicalJson({ studentBasics: { grade: student.grade, ageYears: student.ageYears, ageMonths: student.ageMonths,
      gender: student.gender ?? null, referralReason: student.referralReason?.trim() ?? null }, skills: projection }));
  }
  function verifyHash(claims: PreviewClaims, confirmedHash: string) {
    const hash = createHash('sha256').update(JSON.stringify(claims.payload)).digest('hex');
    if (confirmedHash !== claims.hash || hash !== claims.hash) throw new ApiError(400, 'CONFIRMATION_REQUIRED', 'أكد المعاينة الحالية نفسها قبل الإرسال.');
  }
  async function checkCurrentSource(ownerId: string, claims: PreviewClaims, tx: Prisma.TransactionClient | PrismaClient = prisma) {
    const current = await source(ownerId, claims.studentId, claims.assessmentId, tx);
    if (current.studentRow.revision !== claims.studentRevision || current.assessmentRow.revision !== claims.assessmentRevision) throw new ApiError(409, 'SOURCE_CHANGED', 'تغير مصدر الخطة. راجع البيانات وأنشئ معاينة جديدة.');
    if (claims.sourceHash && claims.sourceHash !== generationSourceHash(current.student, current.skills)) throw new ApiError(409, 'SOURCE_CHANGED', 'تغيرت بيانات المصدر أو المهارات المراجعة. أنشئ معاينة جديدة.');
    return current;
  }
  const limit = { config: { rateLimit: { max: 12, timeWindow: '1 minute' } } };

  app.get('/v1/ai/operations/:operationId', async request => {
    const user = await requireSpecialist(request);
    const { operationId } = z.strictObject({ operationId: z.uuid() }).parse(request.params);
    const row = await prisma.syncOperation.findUnique({ where: { ownerId_operationId: { ownerId: user.id, operationId } } });
    if (!row) throw missing();
    const receipt = records.cipher.decrypt<Receipt>(row.encryptedResult, receiptContext(user.id, operationId));
    if (receipt.namespace !== 'ai-generate') throw missing();
    const state = isExpired(receipt, row.createdAt) ? 'expired' : receipt.state;
    return { operationId, state, startedAt: receipt.startedAt ?? row.createdAt.toISOString(),
      leaseExpiresAt: leaseExpiry(receipt, row.createdAt).toISOString(), canCancel: receipt.state === 'pending',
      ...(receipt.cancelledAt ? { cancelledAt: receipt.cancelledAt } : {}),
      ...(receipt.record ? { recordId: receipt.record.id } : {}),
      ...(receipt.error ? { error: receipt.error } : {}) };
  });

  app.post('/v1/ai/operations/:operationId/cancel', async request => {
    const user = await requireSpecialist(request);
    const { operationId } = z.strictObject({ operationId: z.uuid() }).parse(request.params);
    z.strictObject({ confirmed: z.literal(true) }).parse(request.body);
    const result = await prisma.$transaction(async tx => {
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${user.id}))`;
      const row = await tx.syncOperation.findUnique({ where: { ownerId_operationId: { ownerId: user.id, operationId } } });
      if (!row) throw missing();
      const context = receiptContext(user.id, operationId);
      const receipt = records.cipher.decrypt<Receipt>(row.encryptedResult, context);
      if (receipt.namespace !== 'ai-generate') throw missing();
      if (receipt.state === 'completed' || receipt.state === 'failed') throw new ApiError(409, 'AI_OPERATION_FINISHED', 'انتهى هذا الطلب بالفعل؛ راجع نتيجته قبل بدء عملية أخرى.');
      if (receipt.state === 'cancelled') return { operationId, state: 'cancelled', cancelledAt: receipt.cancelledAt, canCancel: false };
      const cancelledAt = now().toISOString();
      await tx.syncOperation.update({ where: { ownerId_operationId: { ownerId: user.id, operationId } },
        data: { encryptedResult: records.cipher.encrypt({ ...receipt, state: 'cancelled', cancelledAt } satisfies Receipt, context) } });
      await tx.auditEvent.create({ data: { ownerId: user.id, action: 'ai.generation_cancelled', entityId: operationId } });
      return { operationId, state: 'cancelled', cancelledAt, canCancel: false };
    }, { timeout: 15000 });
    active.get(`${user.id}:${operationId}`)?.abort();
    return result;
  });

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
    for (const skill of payload.skills) {
      if (!customSkillId.safeParse(skill.skillId).success) continue;
      if (input.customSkillsReviewed !== true) throw new ApiError(400, 'CUSTOM_LABEL_REVIEW_REQUIRED', 'راجعي التسميات التعليمية المخصصة وأكّدي خلوها من الهوية والبيانات الطبية قبل المعاينة.');
      const sourceSkill = current.skills.find(item => item.skillId === skill.skillId);
      const label = reviewedSkillLabel.safeParse(sourceSkill?.label);
      if (!label.success) throw new ApiError(400, 'CUSTOM_LABEL_REVIEW_REQUIRED', 'يلزم اسم تعليمي مراجع من سطر واحد، لا يتجاوز ثمانين محرفًا ودون هوية أو روابط.');
      skill.reviewedLabel = label.data;
    }
    let preview;
    try { preview = prepareGeneration(payload, { consentConfirmed: true, assessmentApproved: true, hasReviewedStrengths: true, hasReviewedNeeds: true, hasBaseline: true }, new Set(current.skills.map(skill => skill.skillId))); }
    catch { throw new ApiError(400, 'INVALID_SKILLS', 'اختر مهارات التقييم وحدد احتياجًا واحدًا على الأقل.'); }
    const expiresAt = new Date(now().getTime() + 10 * 60 * 1000);
    const previewToken = signer.sign({ version: 1, ownerId: user.id, studentId: input.studentId, assessmentId: input.assessmentId,
      studentRevision: current.studentRow.revision, assessmentRevision: current.assessmentRow.revision,
      expiresAt: expiresAt.getTime(), payload: preview.payload, hash: preview.hash, sourceHash: generationSourceHash(current.student, current.skills) });
    return { ...preview, previewToken, expiresAt: expiresAt.toISOString(), presentation: studentPresentation(current.student.gender),
      customLabelsRequireConfirmation: preview.payload.skills.some(skill => skill.reviewedLabel !== undefined) };
  });

  app.post('/v1/ai/generate', limit, async (request, reply) => {
    const user = await requireSpecialist(request);
    const policy = requirePolicy();
    const input = generateRequestSchema.parse(request.body);
    const claims = signer.verify(input.previewToken, user.id);
    verifyHash(claims, input.confirmedHash);
    if (claims.payload.skills.some(skill => skill.reviewedLabel !== undefined) && (!claims.sourceHash || input.customLabelsConfirmed !== true)) throw new ApiError(400, 'CUSTOM_LABEL_CONFIRMATION_REQUIRED', 'أكّدي إرسال التسميات التعليمية المخصصة الظاهرة في هذه المعاينة نفسها.');
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
        if (receipt.state === 'cancelled') throw cancelledError();
        if (isExpired(receipt, prior.createdAt)) throw expiredError();
        throw new ApiError(409, 'AI_IN_PROGRESS', 'طلب التوليد قيد التنفيذ أو لم تُعرف نتيجته بعد انقطاعه. حدّث قائمة الخطط وراجع حالته؛ لن يُرسل مرة أخرى تلقائيًا.');
      }
      if (claims.expiresAt <= now().getTime()) throw new ApiError(409, 'PREVIEW_EXPIRED', 'انتهت صلاحية المعاينة. أنشئ معاينة جديدة.');
      await checkCurrentSource(user.id, claims, tx);
      await tx.syncOperation.create({ data: { ownerId: user.id, operationId: input.operationId, requestHash,
        encryptedResult: records.cipher.encrypt({ namespace: 'ai-generate', state: 'pending', startedAt: now().toISOString(),
          leaseExpiresAt: new Date(now().getTime() + AI_OPERATION_LEASE_MS).toISOString() } satisfies Receipt, context) } });
      await tx.auditEvent.create({ data: { ownerId: user.id, action: 'ai.generation_requested', entityId: claims.assessmentId } });
      return null;
    }, { timeout: 15000 });
    if (replay) return { record: replay };

    const controller = new AbortController();
    const activeKey = `${user.id}:${input.operationId}`;
    active.set(activeKey, controller);
    const leaseTimer = setTimeout(() => controller.abort(), AI_OPERATION_LEASE_MS);
    leaseTimer.unref();
    try {
      const current = await prisma.syncOperation.findUnique({ where: { ownerId_operationId: { ownerId: user.id, operationId: input.operationId } } });
      if (!current) throw missing();
      const receipt = records.cipher.decrypt<Receipt>(current.encryptedResult, context);
      if (receipt.state === 'cancelled' || controller.signal.aborted) throw cancelledError();
      if (isExpired(receipt, current.createdAt)) throw expiredError();
      // The durable claim is committed before calling the provider; a retry never repeats the external call.
      const raw = await policy.provider.generate(structuredClone(claims.payload), controller.signal);
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
        const operation = await tx.syncOperation.findUnique({ where: { ownerId_operationId: { ownerId: user.id, operationId: input.operationId } } });
        if (!operation) throw missing();
        const receipt = records.cipher.decrypt<Receipt>(operation.encryptedResult, context);
        if (receipt.state === 'cancelled') throw cancelledError();
        if (isExpired(receipt, operation.createdAt)) throw expiredError();
        if (receipt.namespace !== 'ai-generate' || receipt.state !== 'pending' || operation.requestHash !== requestHash) throw new ApiError(409, 'AI_OPERATION_CHANGED', 'تغيرت حالة الطلب؛ راجع نتيجته قبل المحاولة.');
        const source = await checkCurrentSource(user.id, claims, tx);
        plan.presentation = studentPresentation(source.student.gender);
        const row = await tx.record.create({ data: { id: plan.id, ownerId: user.id, kind: 'plan', parentId: claims.studentId,
          encryptedPayload: records.cipher.encrypt(plan, records.recordContext(user.id, plan.id)) } });
        const envelope = records.toEnvelope(row);
        await tx.syncOperation.update({ where: { ownerId_operationId: { ownerId: user.id, operationId: input.operationId } }, data: { encryptedResult: records.cipher.encrypt({ ...receipt, state: 'completed', record: envelope } satisfies Receipt, context) } });
        await tx.auditEvent.create({ data: { ownerId: user.id, action: 'ai.draft_created', entityId: row.id } });
        return envelope;
      }, { timeout: 15000 });
      return reply.code(201).send({ record });
    } catch (error) {
      const safe = error instanceof ApiError ? error : new ApiError(502, 'AI_PROVIDER_UNAVAILABLE', 'تعذر التوليد؛ لم تُحفظ خطة. أنشئ معاينة جديدة لإعادة المحاولة.');
      const finalError = await prisma.$transaction(async tx => {
        await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${user.id}))`;
        const operation = await tx.syncOperation.findUnique({ where: { ownerId_operationId: { ownerId: user.id, operationId: input.operationId } } });
        if (!operation) return safe;
        const receipt = records.cipher.decrypt<Receipt>(operation.encryptedResult, context);
        if (receipt.state === 'cancelled') return cancelledError();
        if (isExpired(receipt, operation.createdAt)) return expiredError();
        // Cancellation/completion won the lock: never overwrite their durable result.
        if (receipt.namespace === 'ai-generate' && receipt.state === 'pending' && operation.requestHash === requestHash) {
          await tx.syncOperation.update({ where: { ownerId_operationId: { ownerId: user.id, operationId: input.operationId } },
            data: { encryptedResult: records.cipher.encrypt({ ...receipt, state: 'failed', error: { code: safe.code, message: safe.message } } satisfies Receipt, context) } });
        }
        return safe;
      }, { timeout: 15000 });
      throw finalError;
    } finally {
      clearTimeout(leaseTimer);
      if (active.get(activeKey) === controller) active.delete(activeKey);
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
      const snapshot: PlanVersion = { id: plan.id, studentId: plan.studentId, version: plan.version, status: plan.status, source: plan.source, suggested: plan.suggested, content: plan.content, createdAt: plan.createdAt, approvedAt: plan.approvedAt, approvedBy: plan.approvedBy, previousVersionId: plan.previousVersionId,
        ...(plan.presentation ? { presentation: plan.presentation } : {}) };
      const saved: StoredPlan = { ...approved, version: plan.version + 1, history: [...plan.history, snapshot], generation: plan.generation };
      const updated = await tx.record.update({ where: { ownerId_id: { ownerId: user.id, id } }, data: { revision: { increment: 1 }, encryptedPayload: records.cipher.encrypt(saved, records.recordContext(user.id, id)) } });
      await tx.auditEvent.create({ data: { ownerId: user.id, action: 'plan.approved', entityId: id } });
      return records.toEnvelope(updated);
    }, { timeout: 15000 });
    return { record };
  });
}
