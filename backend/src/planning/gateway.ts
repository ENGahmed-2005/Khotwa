import { createHash } from 'node:crypto';
import { createDraft, type GenerationInput, type PlanVersion, planContentSchema, generationInputSchema } from './domain.js';

/** Provider adapters run on server only. No default mock and no fallback content. */
export interface PlanProvider { generate(payload: GenerationInput, signal?: AbortSignal): Promise<unknown> }
export interface GenerationPolicy { enabled: boolean; processingApproved: boolean }

const prohibited = /(?:تشخيص|توحد|التوحد|ديسلكسيا|عسر القراءة|إعاقة|دواء|أدوية|كسول|فاشل|غبي|ضعيف|diagnos|autis|dyslex|medicat|stupid|lazy)/iu;
const identifying = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|(?:\+?\d[\s-]?){9,}|\b\d{4}[-/]\d{2}[-/]\d{2}\b/iu;

function inspectStrings(value: unknown): void {
  if (typeof value === 'string' && (prohibited.test(value) || identifying.test(value))) {
    throw new Error('Generated content requires correction for privacy or educational safety');
  }
  if (Array.isArray(value)) value.forEach(inspectStrings);
  else if (value && typeof value === 'object') Object.values(value).forEach(inspectStrings);
}

/** Lexical check is one layer, not a claim to detect every name or clinical inference. */
export function validateEducationalPlan(raw: unknown) {
  const content = planContentSchema.parse(raw);
  // Dates/UUIDs are system types, never scan them as free educational prose.
  inspectStrings({ needs: content.needsSummary, strengths: content.strengthsSummary,
    general: content.generalGoal, baseline: content.baseline, tools: content.tools,
    measurement: content.measurementTools, strategies: content.strategies,
    recommendations: content.recommendations,
    goals: content.goals.map(goal => ({ behavior: goal.behavior, condition: goal.condition })) });
  return content;
}

export function validateGeneratedPlan(raw: unknown, payload: GenerationInput) {
  const content = validateEducationalPlan(raw);
  const allowedSkills = new Set(payload.skills.map(skill => skill.skillId));
  if (content.goals.some(goal => !allowedSkills.has(goal.skillId))) throw new Error('Provider invented an unapproved skill');
  if (content.durationWeeks !== payload.durationWeeks || content.sessionsPerWeek !== payload.sessionsPerWeek) throw new Error('Provider changed reviewed schedule');
  return content;
}

export async function generateReviewedDraft(args: {
  provider: PlanProvider; policy: GenerationPolicy;
  preview: { payload: GenerationInput; hash: string };
  confirmedHash: string; confirmed: boolean; studentId: string; signal?: AbortSignal;
}): Promise<PlanVersion> {
  if (!args.policy.enabled || !args.policy.processingApproved) throw new Error('AI generation is disabled until processing policy is approved');
  const payload = generationInputSchema.parse(args.preview.payload);
  const currentHash = createHash('sha256').update(JSON.stringify(payload)).digest('hex');
  if (!args.confirmed || args.confirmedHash !== args.preview.hash || args.preview.hash !== currentHash) throw new Error('Confirm the exact current preview before sending');
  const raw = await args.provider.generate(structuredClone(payload), args.signal);
  return createDraft(validateGeneratedPlan(raw, payload), args.studentId, 'ai');
}
