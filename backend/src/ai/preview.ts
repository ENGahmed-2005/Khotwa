import { createHmac, timingSafeEqual } from 'node:crypto';
import { z } from 'zod';
import { aiSkillReferenceSchema, generationInputSchema, type GenerationInput } from '../planning/domain.js';
import { ApiError } from '../errors.js';

const claimsSchema = z.strictObject({ version: z.literal(1), ownerId: z.uuid(), studentId: z.uuid(), assessmentId: z.uuid(),
  studentRevision: z.int().positive(), assessmentRevision: z.int().positive(), expiresAt: z.int().positive(),
  hash: z.string().regex(/^[a-f0-9]{64}$/), payload: generationInputSchema,
  sourceHash: z.string().regex(/^[a-f0-9]{64}$/).optional(),
});
export type PreviewClaims = z.infer<typeof claimsSchema>;

export class PreviewSigner {
  private readonly key: Buffer;
  constructor(storageKey: Buffer) {
    if (storageKey.length !== 32) throw new Error('A 256-bit server key is required');
    this.key = createHmac('sha256', storageKey).update('khotwa:ai-preview:v1').digest();
  }
  sign(claims: PreviewClaims): string {
    const encoded = Buffer.from(JSON.stringify(claimsSchema.parse(claims))).toString('base64url');
    return `${encoded}.${createHmac('sha256', this.key).update(encoded).digest('base64url')}`;
  }
  verify(token: string, ownerId: string): PreviewClaims {
    try {
      const [encoded, signature, extra] = token.split('.');
      if (!encoded || !signature || extra || token.length > 30000) throw new Error('Bad token');
      const expected = createHmac('sha256', this.key).update(encoded).digest();
      const actual = Buffer.from(signature, 'base64url');
      if (actual.length !== expected.length || !timingSafeEqual(expected, actual)) throw new Error('Bad signature');
      const claims = claimsSchema.parse(JSON.parse(Buffer.from(encoded, 'base64url').toString('utf8')));
      if (claims.ownerId !== ownerId) throw new Error('Wrong owner');
      return claims;
    } catch { throw new ApiError(400, 'PREVIEW_INVALID', 'المعاينة غير صالحة لهذا الحساب. أنشئ معاينة جديدة.'); }
  }
}

export const previewRequestSchema = z.strictObject({
  studentId: z.uuid(), assessmentId: z.uuid(), skills: z.array(aiSkillReferenceSchema).min(1).max(40),
  durationWeeks: generationInputSchema.shape.durationWeeks, sessionsPerWeek: generationInputSchema.shape.sessionsPerWeek,
  availableTools: generationInputSchema.shape.availableTools.max(5).refine(tools => new Set(tools).size === tools.length, 'Choose each tool once'), syntheticDataConfirmed: z.literal(true),
  customSkillsReviewed: z.boolean().optional(),
});
export const generateRequestSchema = z.strictObject({ previewToken: z.string().min(1).max(30000),
  confirmed: z.literal(true), confirmedHash: z.string().regex(/^[a-f0-9]{64}$/), syntheticDataConfirmed: z.literal(true), operationId: z.uuid(),
  customLabelsConfirmed: z.boolean().optional(),
});
export function payloadFromRequest(input: z.infer<typeof previewRequestSchema>): GenerationInput {
  return { skills: input.skills, durationWeeks: input.durationWeeks, sessionsPerWeek: input.sessionsPerWeek, availableTools: input.availableTools };
}
