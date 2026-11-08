import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import type { AuthService, Clock } from '../auth.js';
import { canonicalJson, tokenHash } from '../crypto.js';
import { ApiError, missing } from '../errors.js';
import { RecordStore, type Envelope } from '../records.js';
import { planContentSchema, revisePlan, type PlanVersion } from './domain.js';
import { validateEducationalPlan } from './gateway.js';
import { assessmentSchema } from '../schemas.js';
import { initialAssessmentSchema } from '../intake/schema.js';
import { skillsForAssessment } from '../ai/catalog.js';

export const templateOptionsSchema = z.strictObject({
  showStrategies: z.boolean().default(true), showRecommendations: z.boolean().default(true), showSessionSchedule: z.boolean().default(true),
});
interface StoredPlan extends PlanVersion {
  history: PlanVersion[];
  generation: { model: string; assessmentId: string; assessmentRevision: number; payloadHash: string };
  templateOptions?: z.infer<typeof templateOptionsSchema>;
  provenance?: Record<string, 'ai' | 'specialist'>;
  revisionDetails?: { actorId: string; occurredAt: string; changedFields: string[] };
}
type Receipt = { namespace: 'plan-version'; record: Envelope };

function snapshot(plan: PlanVersion): PlanVersion {
  return { id: plan.id, studentId: plan.studentId, version: plan.version, status: plan.status, source: plan.source,
    suggested: plan.suggested, content: structuredClone(plan.content), createdAt: plan.createdAt,
    approvedAt: plan.approvedAt, approvedBy: plan.approvedBy, previousVersionId: plan.previousVersionId };
}

function contentFields(content: PlanVersion['content']): Record<string, unknown> {
  const result: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(content)) if (key !== 'goals') result[key] = value;
  for (const goal of content.goals) {
    for (const [key, value] of Object.entries(goal)) if (key !== 'id') result[`goals.${goal.id}.${key}`] = value;
  }
  return result;
}

export function registerPlanVersionRoutes(app: FastifyInstance, options: { prisma: PrismaClient; auth: AuthService; records: RecordStore; clock?: Clock }) {
  const { prisma, auth, records } = options;
  const now = options.clock ?? (() => new Date());
  async function specialist(request: FastifyRequest) {
    const user = await auth.requireUser(request);
    if (user.role !== 'specialist') throw new ApiError(403, 'SPECIALIST_REQUIRED', 'يلزم حساب مختصة مخوّل.');
    return user;
  }
  app.post('/v1/plans/:id/versions', async (request, reply) => {
    const user = await specialist(request);
    const { id } = z.strictObject({ id: z.uuid() }).parse(request.params);
    const input = z.strictObject({ revision: z.int().positive(), operationId: z.uuid(), confirmed: z.literal(true),
      content: planContentSchema, templateOptions: templateOptionsSchema.optional() }).parse(request.body);
    const requestHash = tokenHash(canonicalJson({ namespace: 'plan-version', id, ...input }));
    const context = `operation:${user.id}:${input.operationId}`;
    const record = await prisma.$transaction(async tx => {
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${user.id}))`;
      const prior = await tx.syncOperation.findUnique({ where: { ownerId_operationId: { ownerId: user.id, operationId: input.operationId } } });
      if (prior) {
        if (prior.requestHash !== requestHash) throw new ApiError(409, 'OPERATION_REUSED', 'معرف العملية مستخدم بمحتوى مختلف.');
        const receipt = records.cipher.decrypt<Receipt>(prior.encryptedResult, context);
        if (receipt.namespace !== 'plan-version') throw new ApiError(409, 'OPERATION_REUSED', 'معرف العملية مستخدم بطلب مختلف.');
        const current = await tx.record.findUnique({ where: { ownerId_id: { ownerId: user.id, id: receipt.record.id } } });
        if (!current || current.deletedAt) throw missing();
        return receipt.record;
      }
      const row = await tx.record.findUnique({ where: { ownerId_id: { ownerId: user.id, id } } });
      if (!row || row.kind !== 'plan' || row.deletedAt) throw missing();
      if (row.revision !== input.revision) throw new ApiError(409, 'REVISION_CONFLICT', 'تغيرت الخطة؛ حدّثها قبل حفظ إصدار جديد.');
      const previous = records.toEnvelope(row).data as unknown as StoredPlan;
      const student = await tx.record.findUnique({ where: { ownerId_id: { ownerId: user.id, id: previous.studentId } } });
      const assessment = await tx.record.findUnique({ where: { ownerId_id: { ownerId: user.id, id: previous.generation.assessmentId } } });
      if (!student || student.deletedAt || !assessment || assessment.deletedAt || assessment.parentId !== previous.studentId) throw missing();
      let allowed: Set<string>;
      if (assessment.kind === 'assessment') {
        const data = assessmentSchema.parse(records.toEnvelope(assessment).data);
        if (data.status !== 'approved') throw new ApiError(409, 'SOURCE_NOT_READY', 'مصدر الخطة غير معتمد.');
        allowed = new Set(skillsForAssessment(data).map(skill => skill.skillId));
      } else if (assessment.kind === 'initialAssessment') {
        const data = initialAssessmentSchema.parse(records.toEnvelope(assessment).data);
        if (data.status !== 'approved') throw new ApiError(409, 'SOURCE_NOT_READY', 'مصدر الخطة غير معتمد.');
        allowed = new Set(data.domains.flatMap(domain => domain.skills.map(skill => skill.id)));
      } else throw missing();
      let content: PlanVersion['content'];
      try { content = validateEducationalPlan(input.content); }
      catch { throw new ApiError(400, 'PLAN_REVIEW_REQUIRED', 'راجع صياغة الخطة التربوية وخصوصية النصوص.'); }
      if (content.goals.some(goal => !allowed.has(goal.skillId))) throw new ApiError(400, 'INVALID_SKILLS', 'اربط الأهداف بمهارات التقييم المعتمد فقط.');
      const before = contentFields(previous.content);
      const after = contentFields(content);
      const changedFields = Object.keys(after).filter(key => canonicalJson(after[key]) !== canonicalJson(before[key] ?? null));
      const provenance: Record<string, 'ai' | 'specialist'> = {};
      for (const key of Object.keys(after)) provenance[key] = changedFields.includes(key) ? 'specialist' : (previous.provenance?.[key] ?? previous.source);
      const revised = revisePlan(previous, content, now());
      const saved: StoredPlan = { ...revised, id: randomUUID(), suggested: Object.values(provenance).includes('ai'),
        history: [...previous.history, snapshot(previous)], generation: previous.generation,
        templateOptions: input.templateOptions ?? previous.templateOptions ?? templateOptionsSchema.parse({}), provenance,
        revisionDetails: { actorId: user.id, occurredAt: now().toISOString(), changedFields } };
      const result = await tx.record.create({ data: { id: saved.id, ownerId: user.id, kind: 'plan', parentId: saved.studentId,
        encryptedPayload: records.cipher.encrypt(saved, records.recordContext(user.id, saved.id)) } });
      const envelope = records.toEnvelope(result);
      await tx.syncOperation.create({ data: { ownerId: user.id, operationId: input.operationId, requestHash,
        encryptedResult: records.cipher.encrypt({ namespace: 'plan-version', record: envelope } satisfies Receipt, context) } });
      await tx.auditEvent.create({ data: { ownerId: user.id, action: 'plan.version_created', entityId: saved.id } });
      return envelope;
    }, { timeout: 15000 });
    return reply.code(201).send({ record });
  });
  app.get('/v1/plans/:id/history', async request => {
    const user = await specialist(request);
    const { id } = z.strictObject({ id: z.uuid() }).parse(request.params);
    const record = await records.get(user.id, id);
    if (record.kind !== 'plan' || record.deletedAt) throw missing();
    const plan = record.data as unknown as StoredPlan;
    // Every snapshot was encrypted inside the owned record; none is fetched from another owner.
    return { history: plan.history, current: record };
  });
}
