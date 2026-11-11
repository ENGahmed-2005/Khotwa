import { randomBytes, randomUUID } from 'node:crypto';
import { describe, expect, it, vi } from 'vitest';
import { aiConfigFromEnvironment } from '../src/ai/config.js';
import { GeminiPlanProvider } from '../src/ai/gemini.js';
import { PreviewSigner } from '../src/ai/preview.js';
import { skillsForAssessment } from '../src/ai/catalog.js';
import { ApiError } from '../src/errors.js';
import { assessmentFixture } from './fixtures.js';
import { aiContent, aiInput } from './ai.fixtures.js';

describe('signed AI preview', () => {
  it('binds owner and revisions and rejects tamper', () => {
    const signer = new PreviewSigner(randomBytes(32));
    const claims = { version: 1 as const, ownerId: randomUUID(), studentId: randomUUID(), assessmentId: randomUUID(), studentRevision: 1, assessmentRevision: 3, expiresAt: Date.now() + 10000, hash: 'a'.repeat(64), payload: aiInput };
    const token = signer.sign(claims);
    expect(signer.verify(token, claims.ownerId)).toEqual(claims);
    expect(() => signer.verify(token, randomUUID())).toThrow();
    const [body, signature] = token.split('.');
    expect(() => signer.verify(`${body}x.${signature}`, claims.ownerId)).toThrow();
    expect(() => new PreviewSigner(randomBytes(32)).verify(token, claims.ownerId)).toThrow();
  });
  it('only exposes skills with performed evidence, no raw text', () => {
    const assessment = assessmentFixture(randomUUID());
    for (const result of Object.values(assessment.results)) result.execution = 'notDone';
    assessment.results['1a']!.execution = 'performed';
    assessment.results['1a']!.response = 'Synthetic text never sent';
    expect(skillsForAssessment(assessment)).toEqual([{ skillId: 'reading.sound_deletion', label: 'حذف الصوت الأول', evidence: 'approvedAcademicAssessment' }]);
  });
});

describe('server configuration and Gemini transport', () => {
  it('is opt-in and fails closed without synthetic policy or server key', () => {
    expect(aiConfigFromEnvironment({ GEMINI_API_KEY: 'synthetic-key' })).toBeUndefined();
    expect(() => aiConfigFromEnvironment({ AI_ENABLED: 'true', GEMINI_API_KEY: 'synthetic-key' })).toThrow();
    expect(() => aiConfigFromEnvironment({ AI_ENABLED: 'true', AI_SYNTHETIC_ONLY: 'true' })).toThrow();
    expect(aiConfigFromEnvironment({ AI_ENABLED: 'true', AI_SYNTHETIC_ONLY: 'true', GEMINI_API_KEY: 'synthetic-key' })?.model).toBe('gemini-flash-latest');
  });
  it('sends structured JSON with header-only key and controlled input', async () => {
    const content = aiContent();
    const transport = vi.fn<typeof fetch>().mockResolvedValue(Response.json({ candidates: [{ finishReason: 'STOP', content: { parts: [{ text: JSON.stringify(content) }] } }] }));
    const provider = new GeminiPlanProvider({ apiKey: 'test-only-key', model: 'gemini-flash-latest', fetchImpl: transport });
    const result = await provider.generate(aiInput) as ReturnType<typeof aiContent>;
    const [url, options] = transport.mock.calls[0]!;
    expect(String(url)).toBe('https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent');
    expect(options?.headers).toEqual({ 'Content-Type': 'application/json', 'x-goog-api-key': 'test-only-key' });
    const body = JSON.parse(String(options?.body));
    expect(JSON.parse(body.contents[0].parts[0].text)).toEqual(aiInput);
    expect(String(options?.body)).not.toContain('test-only-key');
    expect(body.generationConfig.responseMimeType).toBe('application/json');
    expect(body.generationConfig.responseJsonSchema.properties.tools.items.enum).toEqual(['البطاقات']);
    expect(result.goals[0]!.id).not.toBe(content.goals[0]!.id);
    expect(result.baseline).toBe(content.baseline);
  });
  it.each([
    [503, 503, 'AI_PROVIDER_BUSY'],
    [429, 503, 'AI_PROVIDER_LIMITED'],
    [400, 502, 'AI_REQUEST_REJECTED'],
    [401, 503, 'AI_PROVIDER_CONFIGURATION'],
    [403, 503, 'AI_PROVIDER_CONFIGURATION'],
    [404, 502, 'AI_PROVIDER_UNAVAILABLE'],
    [500, 502, 'AI_PROVIDER_UNAVAILABLE'],
  ] as const)('classifies provider HTTP %i as client HTTP %i (%s) without fallback or leaked details', async (status, statusCode, code) => {
    const response = Response.json({ error: { message: 'private-provider-detail test-only-key' } }, { status });
    const readJson = vi.spyOn(response, 'json');
    const readText = vi.spyOn(response, 'text');
    const transport = vi.fn<typeof fetch>().mockResolvedValue(response);
    const provider = new GeminiPlanProvider({ apiKey: 'test-only-key', model: 'gemini-flash-latest', fetchImpl: transport });
    const result = await provider.generate(aiInput).catch((error: unknown) => error);
    expect(result).toBeInstanceOf(ApiError);
    expect(result).toMatchObject({ statusCode, code, message: expect.stringMatching(/[\u0600-\u06FF]/u) });
    expect(String(result)).not.toContain('private-provider-detail');
    expect(String(result)).not.toContain('test-only-key');
    expect(transport).toHaveBeenCalledTimes(1);
    const [url, options] = transport.mock.calls[0]!;
    expect(String(url)).toBe('https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent');
    expect(String(url)).not.toContain('test-only-key');
    expect(options?.headers).toEqual({ 'Content-Type': 'application/json', 'x-goog-api-key': 'test-only-key' });
    expect(String(options?.body)).not.toContain('test-only-key');
    expect(readJson).not.toHaveBeenCalled();
    expect(readText).not.toHaveBeenCalled();
  });
  it.each(['network', 'timeout', 'invalid', 'truncated'])('returns safe error on %s without fallback or retry', async mode => {
    const transport = vi.fn<typeof fetch>();
    if (mode === 'network') transport.mockRejectedValue(new Error('test-only-key'));
    else if (mode === 'timeout') transport.mockRejectedValue(new DOMException('test-only-key', 'TimeoutError'));
    else transport.mockResolvedValue(Response.json({ candidates: [{ finishReason: mode === 'truncated' ? 'MAX_TOKENS' : 'STOP', content: { parts: [{ text: 'bad-json' }] } }] }));
    const provider = new GeminiPlanProvider({ apiKey: 'test-only-key', model: 'gemini-flash-latest', fetchImpl: transport });
    const result = await provider.generate(aiInput).catch((error: unknown) => error);
    expect(result).toBeInstanceOf(ApiError);
    expect(result).toMatchObject({ statusCode: 502, code: mode === 'network' || mode === 'timeout' ? 'AI_PROVIDER_UNAVAILABLE' : 'AI_OUTPUT_INVALID' });
    expect(String(result)).not.toContain('test-only-key');
    expect(transport).toHaveBeenCalledTimes(1);
  });
  it.each(['caller', 'timeout'] as const)('aborts the transport on %s cancellation and exposes no cancellation details', async mode => {
    const controller = new AbortController();
    const transport = vi.fn<typeof fetch>().mockImplementation(async (_url, options) => {
      const signal = options?.signal;
      expect(signal).toBeInstanceOf(AbortSignal);
      return new Promise<Response>((_resolve, reject) => {
        const abort = () => reject(signal?.reason);
        if (signal?.aborted) abort();
        else signal?.addEventListener('abort', abort, { once: true });
      });
    });
    const provider = new GeminiPlanProvider({
      apiKey: 'test-only-key', model: 'gemini-flash-latest', fetchImpl: transport,
      timeoutMs: mode === 'timeout' ? 10 : 1000,
    });
    const pending = provider.generate(aiInput, controller.signal).catch((error: unknown) => error);
    if (mode === 'caller') controller.abort(new Error('private-cancellation-detail test-only-key'));
    const result = await pending;
    expect(result).toBeInstanceOf(ApiError);
    expect(result).toMatchObject({ statusCode: 502, code: 'AI_PROVIDER_UNAVAILABLE' });
    expect(String(result)).not.toContain('private-cancellation-detail');
    expect(String(result)).not.toContain('test-only-key');
    expect(transport).toHaveBeenCalledTimes(1);
    expect(transport.mock.calls[0]![1]?.signal?.aborted).toBe(true);
  });
});
