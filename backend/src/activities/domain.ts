import { z } from 'zod';
import { schoolGrades } from '../schemas.js';
import { goalSchema } from '../planning/domain.js';

const text = z.string().trim().min(1).max(2000);
const toolId = z.string().regex(/^(board|pencils|cards|paper|colors|custom\.[a-f0-9-]{36})$/);
export const toolSchema = z.strictObject({ id: toolId, label: z.string().trim().min(1).max(80) });
export const toolProfileSchema = z.strictObject({
  tools: z.array(toolSchema).min(1).max(30).refine(items => new Set(items.map(item => item.id)).size === items.length, 'Duplicate tool'),
  privacyReviewed: z.literal(true),
});
export const defaultTools = [
  { id: 'board', label: 'السبورة' }, { id: 'pencils', label: 'الأقلام' },
  { id: 'cards', label: 'البطاقات' }, { id: 'paper', label: 'الأوراق' }, { id: 'colors', label: 'الألوان' },
];
export const activityPreviewSchema = z.strictObject({
  studentId: z.uuid(), planId: z.uuid(), goalId: z.uuid(),
  domain: z.enum(['reading', 'writing', 'math', 'foundations', 'attention', 'communication', 'lifeSkills', 'custom']),
  grade: z.enum(schoolGrades), difficulty: z.enum(['introductory', 'practice', 'generalization']),
  type: z.enum(['worksheet', 'cards', 'story', 'game', 'sensory']),
  toolIds: z.array(toolId).min(1).max(30).refine(ids => new Set(ids).size === ids.length, 'Duplicate tool'),
  minutes: z.int().min(1).max(180), mode: z.enum(['individual', 'group']),
  privacyReviewed: z.literal(true), syntheticDataConfirmed: z.literal(true),
});
export const activityPayloadSchema = z.strictObject({
  domain: activityPreviewSchema.shape.domain, grade: activityPreviewSchema.shape.grade,
  difficulty: activityPreviewSchema.shape.difficulty, type: activityPreviewSchema.shape.type,
  availableTools: z.array(toolSchema).min(1).max(30),
  minutes: activityPreviewSchema.shape.minutes, mode: activityPreviewSchema.shape.mode,
  goal: goalSchema.omit({ id: true, skillId: true }),
});
export type ActivityPayload = z.infer<typeof activityPayloadSchema>;
export const activityContentSchema = z.strictObject({
  title: z.string().trim().min(1).max(200), steps: z.array(text).min(1).max(20),
  examples: z.array(text).min(1).max(15), feedback: text, measurement: text,
  preparation: z.array(text).max(15), tools: z.array(toolId).min(1).max(30),
  minutes: z.int().min(1).max(180), lowCostAlternatives: z.array(text).max(15),
  teacherNotes: z.string().trim().max(2000),
});
export type ActivityContent = z.infer<typeof activityContentSchema>;
const prohibited = /(?:تشخيص|توحد|التوحد|ديسلكسيا|عسر القراءة|إعاقة|دواء|أدوية|كسول|فاشل|غبي|ضعيف|diagnos|autis|dyslex|medicat|stupid|lazy)/iu;
const identifying = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|(?:\+?\d[\s-]?){9,}|\b\d{4}[-/]\d{2}[-/]\d{2}\b/iu;
export function inspectActivityText(value: unknown): void {
  if (typeof value === 'string' && (prohibited.test(value) || identifying.test(value))) throw new Error('Unsafe educational text');
  if (Array.isArray(value)) value.forEach(inspectActivityText);
  else if (value && typeof value === 'object') Object.values(value).forEach(inspectActivityText);
}
export function validateActivityOutput(raw: unknown, payload: ActivityPayload): ActivityContent {
  const content = activityContentSchema.parse(raw);
  const { tools, ...prose } = content;
  inspectActivityText(prose);
  const available = new Set(payload.availableTools.map(tool => tool.id));
  if (tools.some(id => !available.has(id)) || new Set(tools).size !== tools.length || content.minutes !== payload.minutes) throw new Error('Unreviewed resources or duration');
  // Check known tools in prose as well as the structured resource references.
  const strings = JSON.stringify(prose);
  for (const tool of defaultTools) {
    if (!available.has(tool.id) && strings.includes(tool.label)) throw new Error('Unavailable tool in instructions');
  }
  return content;
}
