import { describe, expect, it, vi } from 'vitest';
import { activityContentSchema, activityPreviewSchema, defaultTools, validateActivityOutput, type ActivityPayload } from '../src/activities/domain.js';
import { activityConfigFromEnvironment, GeminiActivityProvider } from '../src/activities/gemini.js';

export const payload: ActivityPayload = { domain: 'reading', grade: 'الثاني الأساسي', difficulty: 'practice', type: 'cards',
  availableTools: structuredClone(defaultTools), minutes: 20, mode: 'individual',
  goal: { behavior: 'تمييز الحروف المعروضة', condition: 'عند عرض البطاقات', criterion: { type: 'trials', correct: 4, total: 5 }, timeframeWeeks: 2 } };
export const content = () => ({ title: 'بطاقات الحروف', steps: ['اعرض البطاقات واسأل عن الحرف'], examples: ['اختر حرف الباء'], feedback: 'شجع المحاولة وقدم نموذجًا عند الحاجة',
  measurement: 'سجل الإجابات الصحيحة من خمس محاولات', preparation: ['اكتب الحروف على البطاقات'], tools: ['cards', 'pencils'], minutes: 20, lowCostAlternatives: [], teacherNotes: '' });

describe('reviewed activity constraints', () => {
  it('accepts a real structured educational proposal without approving it', () => {
    expect(validateActivityOutput(content(), payload).steps).toHaveLength(1);
    expect(activityContentSchema.safeParse({ ...content(), status: 'approved' }).success).toBe(false);
  });
  it.each(['طالب كسول', 'تشخيص طبي', 'send to x@example.test', 'اتصل 0599999999'])('rejects prohibited or identifying prose %s', prose => {
    expect(() => validateActivityOutput({ ...content(), feedback: prose }, payload)).toThrow();
  });
  it('rejects an unavailable resource or altered duration', () => {
    const limited = { ...payload, availableTools: [{ id: 'paper', label: 'الأوراق' }] };
    expect(() => validateActivityOutput(content(), limited)).toThrow();
    expect(() => validateActivityOutput({ ...content(), minutes: 30 }, payload)).toThrow();
  });
  it('blocks hidden tools in instructions as well as resource IDs', () => {
    const limited = { ...payload, availableTools: [{ id: 'paper', label: 'الأوراق' }] };
    expect(() => validateActivityOutput({ ...content(), tools: ['paper'], steps: ['استخدم السبورة'] }, limited)).toThrow();
  });
  it('requires explicit synthetic and privacy confirmation in the preview request', () => {
    const request = { studentId: '2feb7b98-0663-4000-8000-123456789abc', planId: '3feb7b98-0663-4000-8000-123456789abc', goalId: '4feb7b98-0663-4000-8000-123456789abc',
      domain: payload.domain, grade: payload.grade, difficulty: payload.difficulty, type: payload.type, minutes: payload.minutes, mode: payload.mode,
      toolIds: ['cards'], privacyReviewed: true, syntheticDataConfirmed: true };
    expect(activityPreviewSchema.safeParse(request).success).toBe(true);
    expect(activityPreviewSchema.safeParse({ ...request, privacyReviewed: false }).success).toBe(false);
    expect(activityPreviewSchema.safeParse({ ...request, syntheticDataConfirmed: false }).success).toBe(false);
  });
  it('supplying a key alone does not enable activity AI', () => {
    expect(activityConfigFromEnvironment({ GEMINI_API_KEY: 'synthetic-test-key' })).toBeUndefined();
    expect(() => activityConfigFromEnvironment({ AI_ENABLED: 'true', GEMINI_API_KEY: 'synthetic-test-key' })).toThrow();
  });
});
describe('Gemini activity transport', () => {
  it('keeps key in header and transmits only the reviewed payload', async () => {
    const transport = vi.fn<typeof fetch>().mockResolvedValue(new Response(JSON.stringify({ candidates: [{ finishReason: 'STOP', content: { parts: [{ text: JSON.stringify(content()) }] } }] })));
    const provider = new GeminiActivityProvider({ apiKey: 'synthetic-test-key', model: 'gemini-flash-latest', fetchImpl: transport });
    expect(await provider.generate(payload)).toEqual(content());
    const [url, options] = transport.mock.calls[0]!;
    expect(url).not.toContain('synthetic-test-key');
    expect(options!.headers).toHaveProperty('x-goog-api-key', 'synthetic-test-key');
    const body = JSON.parse(options!.body as string) as { contents: { parts: { text: string }[] }[] };
    expect(JSON.parse(body.contents[0]!.parts[0]!.text)).toEqual(payload);
    expect(options!.body).not.toMatch(/studentId|ownerId|assessment|ST-/);
  });
  it('provider HTTP failure returns an error and no fallback content', async () => {
    const provider = new GeminiActivityProvider({ apiKey: 'synthetic-test-key', model: 'gemini-flash-latest', fetchImpl: vi.fn().mockResolvedValue(new Response('{}', { status: 503 })) });
    await expect(provider.generate(payload)).rejects.toMatchObject({ code: 'AI_PROVIDER_UNAVAILABLE' });
  });
  it('incomplete output is never accepted', async () => {
    const provider = new GeminiActivityProvider({ apiKey: 'synthetic-test-key', model: 'gemini-flash-latest', fetchImpl: vi.fn().mockResolvedValue(new Response(JSON.stringify({ candidates: [{ finishReason: 'MAX_TOKENS', content: { parts: [{ text: '{}' }] } }] }))) });
    await expect(provider.generate(payload)).rejects.toMatchObject({ code: 'AI_OUTPUT_INVALID' });
  });
});
