import { Prisma, type PrismaClient, type Record as DatabaseRecord } from '@prisma/client';
import { z } from 'zod';
import { canonicalJson, PayloadCipher, tokenHash } from './crypto.js';
import { ApiError, missing } from './errors.js';
import { assessmentSchema, interventionRecordSchema, recommendedAgeGroup, studentSchema, type Operation, type StudentData, type AssessmentData } from './schemas.js';
import { initialAssessmentSchema, type InitialAssessment } from './intake/schema.js';
import { skillsForAssessment } from './ai/catalog.js';
import { validateSession, type PlanVersion } from './planning/domain.js';
import type { Clock } from './auth.js';

export interface Envelope {
  id: string; kind: string; parentId: string | null; revision: number; deletedAt: string | null;
  createdAt: string; updatedAt: string; data: Record<string, unknown>;
}
export interface SyncResult {
  operationId: string; status: 'applied' | 'conflict' | 'rejected'; record?: Envelope; error?: { code: string; message: string };
}
type Transaction = Prisma.TransactionClient;

export class RecordStore {
  constructor(public readonly prisma: PrismaClient, public readonly cipher: PayloadCipher, private readonly clock: Clock = () => new Date()) {}

  toEnvelope(row: DatabaseRecord): Envelope {
    return { id: row.id, kind: row.kind, parentId: row.parentId, revision: row.revision,
      deletedAt: row.deletedAt?.toISOString() ?? null, createdAt: row.createdAt.toISOString(), updatedAt: row.updatedAt.toISOString(),
      data: this.cipher.decrypt<Record<string, unknown>>(row.encryptedPayload, this.recordContext(row.ownerId, row.id)),
    };
  }
  recordContext(ownerId: string, id: string) { return `record:${ownerId}:${id}`; }

  async list(ownerId: string, kind?: string, includeDeleted = false): Promise<Envelope[]> {
    const rows = await this.prisma.record.findMany({ where: { ownerId, ...(kind ? { kind } : {}), ...(includeDeleted ? {} : { deletedAt: null }) }, orderBy: [{ createdAt: 'asc' }, { id: 'asc' }] });
    return rows.map(row => this.toEnvelope(row));
  }

  async get(ownerId: string, id: string): Promise<Envelope> {
    const row = await this.prisma.record.findUnique({ where: { ownerId_id: { ownerId, id } } });
    if (!row) throw missing();
    return this.toEnvelope(row);
  }

  /** One owner transaction serializes parent validation, cascades and operation receipts. */
  async applyOperation(ownerId: string, operation: Operation): Promise<SyncResult> {
    for (let attempt = 0; attempt < 5; attempt++) {
      try {
        return await this.prisma.$transaction(async tx => {
          await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${ownerId}))`;
          return this.applyWithinTransaction(tx, ownerId, operation);
        }, { isolationLevel: Prisma.TransactionIsolationLevel.Serializable, timeout: 15000 });
      } catch (error) {
        if (error instanceof Prisma.PrismaClientKnownRequestError && (error.code === 'P2034' || error.code === 'P2002') && attempt < 4) continue;
        throw error;
      }
    }
    throw new ApiError(503, 'SYNC_RETRY', 'المزامنة مشغولة؛ أعد المحاولة.');
  }

  private async applyWithinTransaction(tx: Transaction, ownerId: string, operation: Operation): Promise<SyncResult> {
    const requestHash = tokenHash(canonicalJson(operation));
    const context = `operation:${ownerId}:${operation.operationId}`;
    const prior = await tx.syncOperation.findUnique({ where: { ownerId_operationId: { ownerId, operationId: operation.operationId } } });
    if (prior) {
      if (prior.requestHash !== requestHash) return this.rejected(operation, 'OPERATION_REUSED', 'لا يمكن إعادة استخدام معرف عملية بمحتوى مختلف.');
      return this.cipher.decrypt<{ result: SyncResult }>(prior.encryptedResult, context).result;
    }
    let result: SyncResult;
    try { result = await this.applyRecord(tx, ownerId, operation); }
    catch (error) {
      if (error instanceof z.ZodError) result = this.rejected(operation, 'INVALID_INPUT', 'راجع بيانات السجل والحقول المطلوبة.');
      else if (error instanceof ApiError) result = this.rejected(operation, error.code, error.message);
      else throw error;
    }
    // Retain valid conflicting variants, but never persist rejected/unvalidated input.
    const receipt = result.status === 'conflict' ? { result, operation } : { result };
    await tx.syncOperation.create({ data: { ownerId, operationId: operation.operationId, requestHash, encryptedResult: this.cipher.encrypt(receipt, context) } });
    if (result.status === 'conflict') {
      await tx.auditEvent.create({ data: { ownerId, action: 'sync.conflict', entityId: operation.entityId } });
    }
    return result;
  }

  private rejected(operation: Operation, code: string, message: string): SyncResult { return { operationId: operation.operationId, status: 'rejected', error: { code, message } }; }

  private async applyRecord(tx: Transaction, ownerId: string, operation: Operation): Promise<SyncResult> {
    // Validate before conflict retention: forbidden fields must never enter any encrypted receipt.
    if (operation.action === 'upsert') {
      if (operation.kind === 'student') studentSchema.parse(operation.data);
      else if (operation.kind === 'assessment') assessmentSchema.parse(operation.data);
      else if (operation.kind === 'initialAssessment') initialAssessmentSchema.parse(operation.data);
      else if (operation.kind === 'session') interventionRecordSchema.parse(operation.data);
      else throw new ApiError(400, 'KIND_NOT_AVAILABLE', 'هذا النوع ينتظر تفعيل عقد بياناته.');
    } else if (Object.keys(operation.data).length) throw new ApiError(400, 'INVALID_INPUT', 'عملية الحذف لا تقبل بيانات إضافية.');
    const existing = await tx.record.findUnique({ where: { ownerId_id: { ownerId, id: operation.entityId } } });
    if (operation.baseRevision !== (existing?.revision ?? 0)) {
      if (!existing) return this.rejected(operation, 'NOT_FOUND', 'السجل غير متاح.');
      return { operationId: operation.operationId, status: 'conflict', record: this.toEnvelope(existing) };
    }
    if (existing && (existing.kind !== operation.kind || existing.parentId !== operation.parentId)) throw new ApiError(400, 'IMMUTABLE_RELATION', 'نوع السجل وارتباطه لا يتغيران.');
    if (existing?.deletedAt) throw new ApiError(409, 'RECORD_DELETED', 'هذا السجل محذوف؛ احتفظ بنسختك للمراجعة.');
    if (operation.action === 'delete') {
      if (!existing) throw missing();
      const now = this.clock();
      const deleted = await tx.record.update({ where: { ownerId_id: { ownerId, id: operation.entityId } }, data: { deletedAt: now, revision: { increment: 1 } } });
      const pending = [deleted.id];
      while (pending.length) {
        const descendants = await tx.record.findMany({ where: { ownerId, parentId: { in: pending.splice(0) }, deletedAt: null } });
        for (const child of descendants) {
          await tx.record.update({ where: { ownerId_id: { ownerId, id: child.id } }, data: { deletedAt: now, revision: { increment: 1 } } });
          pending.push(child.id);
        }
      }
      await tx.auditEvent.create({ data: { ownerId, action: 'record.deleted', entityId: operation.entityId } });
      return { operationId: operation.operationId, status: 'applied', record: this.toEnvelope(deleted) };
    }
    const data = await this.validatePayload(tx, ownerId, operation, existing);
    const encryptedPayload = this.cipher.encrypt(data, this.recordContext(ownerId, operation.entityId));
    const row = existing
      ? await tx.record.update({ where: { ownerId_id: { ownerId, id: operation.entityId } }, data: { encryptedPayload, revision: { increment: 1 } } })
      : await tx.record.create({ data: { id: operation.entityId, ownerId, kind: operation.kind, parentId: operation.parentId, encryptedPayload } });
    await tx.auditEvent.create({ data: { ownerId, entityId: row.id, action: ['assessment', 'initialAssessment'].includes(operation.kind) && data.status === 'approved' ? `${operation.kind}.approved` : 'record.saved' } });
    return { operationId: operation.operationId, status: 'applied', record: this.toEnvelope(row) };
  }

  private async validatePayload(tx: Transaction, ownerId: string, operation: Operation, existing: DatabaseRecord | null): Promise<Record<string, unknown>> {
    if (operation.kind === 'student') {
      const data = studentSchema.parse(operation.data);
      if (data.id !== operation.entityId || operation.parentId !== null) throw new ApiError(400, 'INVALID_RELATION', 'ارتباط ملف الطالب غير صالح.');
      if (existing) {
        const previous = this.toEnvelope(existing).data as StudentData;
        if (previous.code !== data.code || previous.createdAt !== data.createdAt) throw new ApiError(400, 'IMMUTABLE_IDENTITY', 'رمز الطالب وتاريخ الإنشاء ثابتان.');
      }
      const otherStudents = await tx.record.findMany({ where: { ownerId, kind: 'student', id: { not: data.id }, deletedAt: null } });
      if (otherStudents.some(row => this.toEnvelope(row).data.code === data.code)) throw new ApiError(409, 'DUPLICATE_CODE', 'رمز الطالب مستخدم في ملف آخر.');
      return data;
    }
    if (operation.kind === 'assessment') {
      const data = assessmentSchema.parse(operation.data);
      if (data.id !== operation.entityId || data.studentId !== operation.parentId) throw new ApiError(400, 'INVALID_RELATION', 'ارتباط التقييم غير صالح.');
      const student = await tx.record.findUnique({ where: { ownerId_id: { ownerId, id: data.studentId } } });
      if (!student || student.kind !== 'student' || student.deletedAt) throw missing();
      const studentData = studentSchema.parse(this.toEnvelope(student).data);
      const recommended = recommendedAgeGroup(studentData);
      if (recommended === null) throw new ApiError(400, 'MANUAL_ASSESSMENT_REQUIRED', 'استخدم التقييم التربوي اليدوي لهذا العمر.');
      if (data.ageGroup !== recommended && !data.ageOverrideReason.trim()) throw new ApiError(400, 'AGE_OVERRIDE_REQUIRED', 'يلزم مبرر تربوي لاختيار فئة عمرية أخرى.');
      if (existing) {
        const previous = this.toEnvelope(existing).data as AssessmentData;
        if (previous.status === 'approved') throw new ApiError(409, 'ASSESSMENT_IMMUTABLE', 'التقييم المعتمد محفوظ؛ أنشئ إعادة تقييم جديدة.');
        if (previous.templateVersion !== data.templateVersion || previous.ageGroup !== data.ageGroup || previous.createdAt !== data.createdAt) throw new ApiError(400, 'TEMPLATE_IMMUTABLE', 'إصدار التقييم وفئته وتاريخ إنشائه ثابتة.');
        if (previous.assessedOn !== data.assessedOn || previous.gradeAtAssessment !== data.gradeAtAssessment) throw new ApiError(400, 'ASSESSMENT_METADATA_IMMUTABLE', 'تاريخ التقييم والصف وقت إنشائه ثابتان؛ لا تُضاف بيانات تاريخية إلى سجل قديم.');
      }
      return data;
    }
    if (operation.kind === 'initialAssessment') {
      const data = initialAssessmentSchema.parse(operation.data);
      if (data.id !== operation.entityId || data.studentId !== operation.parentId) throw new ApiError(400, 'INVALID_RELATION', 'ارتباط التقييم الأولي غير صالح.');
      const student = await tx.record.findUnique({ where: { ownerId_id: { ownerId, id: data.studentId } } });
      if (!student || student.kind !== 'student' || student.deletedAt) throw missing();
      if (data.assessedOn > this.clock().toISOString().slice(0, 10)) throw new ApiError(400, 'FUTURE_ASSESSMENT', 'لا تسجّل أداءً في تاريخ مستقبلي.');
      if (existing) {
        const previous = this.toEnvelope(existing).data as unknown as InitialAssessment;
        if (previous.status === 'approved') throw new ApiError(409, 'ASSESSMENT_IMMUTABLE', 'التقييم المعتمد محفوظ؛ أنشئ إعادة تقييم جديدة.');
        if (previous.createdAt !== data.createdAt) throw new ApiError(400, 'IMMUTABLE_IDENTITY', 'تاريخ الإنشاء ثابت.');
      }
      if (data.status === 'approved' && data.method === 'academicCards') {
        const row = await tx.record.findUnique({ where: { ownerId_id: { ownerId, id: data.academicAssessmentId! } } });
        if (!row || row.deletedAt || row.kind !== 'assessment' || row.parentId !== data.studentId) throw missing();
        const academic = assessmentSchema.parse(this.toEnvelope(row).data);
        if (academic.status !== 'approved') throw new ApiError(409, 'SOURCE_NOT_READY', 'اعتمد ملخص البطاقة المرتبطة أولًا.');
        const allowed = new Set<string>(skillsForAssessment(academic).map(skill => skill.skillId));
        if (data.domains.some(domain => domain.skills.some(skill => !allowed.has(skill.id)))) throw new ApiError(400, 'INVALID_SKILLS', 'لا تنسب إلى البطاقة مهارة لم تُجرَ؛ استخدم تقييمًا بديلًا موثقًا عند الحاجة.');
      }
      return data;
    }
    if (operation.kind === 'session') {
      const data = interventionRecordSchema.parse(operation.data);
      if (data.id !== operation.entityId || data.studentId !== operation.parentId) throw new ApiError(400, 'INVALID_RELATION', 'ارتباط الجلسة غير صالح.');
      const [student, plan] = await Promise.all([
        tx.record.findUnique({ where: { ownerId_id: { ownerId, id: data.studentId } } }),
        tx.record.findUnique({ where: { ownerId_id: { ownerId, id: data.planVersionId } } }),
      ]);
      if (!student || student.deletedAt || student.kind !== 'student' || !plan || plan.deletedAt || plan.kind !== 'plan' || plan.parentId !== data.studentId) throw missing();
      try { validateSession(data, this.toEnvelope(plan).data as unknown as PlanVersion, this.clock().toISOString().slice(0, 10)); }
      catch { throw new ApiError(400, 'INVALID_SESSION', 'راجع تاريخ الجلسة والهدف المعتمد والمحاولات والأداء.'); }
      if (existing) {
        const previous = this.toEnvelope(existing).data;
        if (previous.createdAt !== data.createdAt || previous.planVersionId !== data.planVersionId || previous.goalId !== data.goalId) throw new ApiError(400, 'IMMUTABLE_RELATION', 'ارتباط الجلسة بالخطة والهدف وتاريخ الإنشاء ثابت.');
      }
      if (data.activityId) {
        const activity = await tx.record.findUnique({ where: { ownerId_id: { ownerId, id: data.activityId } } });
        if (!activity || activity.deletedAt || activity.kind !== 'activity' || activity.parentId !== data.studentId) throw missing();
        const content = this.toEnvelope(activity).data;
        if (content.planId !== data.planVersionId || content.goalId !== data.goalId) throw new ApiError(400, 'INVALID_RELATION', 'النشاط يجب أن يرتبط بهدف الجلسة وخطتها.');
      }
      return data;
    }
    throw new ApiError(400, 'KIND_NOT_AVAILABLE', 'هذا النوع ينتظر تفعيل عقد بياناته.');
  }
}
