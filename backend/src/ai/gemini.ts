import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import type { PlanProvider } from '../planning/gateway.js';
import { planContentSchema, type GenerationInput } from '../planning/domain.js';
import { ApiError } from '../errors.js';
import { toolLabels } from './catalog.js';
import { providerHttpError } from './provider-errors.js';
import { geminiResponseSchema } from './provider-schema.js';

export interface GeminiOptions { apiKey: string; model: string; fetchImpl?: typeof fetch; timeoutMs?: number; clock?: () => Date }

/** Uses Gemini REST directly. The key is sent in a header, never in URL, logs or prompts. */
export class GeminiPlanProvider implements PlanProvider {
  readonly model: string;
  private readonly transport: typeof fetch;
  constructor(private readonly options: GeminiOptions) {
    if (!options.apiKey.trim()) throw new Error('Gemini server key is required');
    if (!/^gemini-[a-z0-9.-]+$/.test(options.model)) throw new Error('Gemini model identifier is invalid');
    this.model = options.model;
    this.transport = options.fetchImpl ?? fetch;
  }

  async generate(payload: GenerationInput, signal?: AbortSignal): Promise<unknown> {
    const schema = geminiResponseSchema(z.toJSONSchema(planContentSchema) as Record<string, unknown>);
    const properties = schema.properties as Record<string, Record<string, unknown>>;
    properties.tools = { type: 'array', items: { type: 'string', enum: payload.availableTools.map(tool => toolLabels[tool]) } };
    const timeout = AbortSignal.timeout(this.options.timeoutMs ?? 60000);
    const combined = signal ? AbortSignal.any([signal, timeout]) : timeout;
    const today = (this.options.clock?.() ?? new Date()).toISOString().slice(0, 10);
    const instructions = `أنت مساعد لصياغة مسودة خطة تربوية باللغة العربية. البيانات اصطناعية للتطوير فقط. التاريخ الحالي ${today}.
اعتمد حصراً المهارات والمستويات المراجعة في المدخلات. لا تستنتج أسماء أو أعماراً أو تشخيصات أو أسباباً أو نتائج تقييم لم تُرسل. لا تستخدم أوصافاً سلبية أو أدوية أو تصنيفات طبية، حتى في عبارات نفي أو تنبيهات. لا تقارن الطالب بأقرانه.
للمهارة المخصصة لا تستخدم سوى reviewedLabel الذي راجعته المختصة وأكدت إرساله. لا تستنتج منه هوية أو معلومات إضافية. صغ الأوصاف والسلوك بعبارات تعليمية محايدة مثل «تمييز الحروف» و«أداء القراءة قيد التطور»؛ تُضاف إشارة الطالب أو الطالبة محليًا في عناوين العرض ولا تحتاج إلى استنتاج الجنس.
صغ كل هدف من سلوك قابل للملاحظة وشرط ومعيار قابل للقياس وإطار زمني ضمن مدة الخطة. معايير الأهداف مقترحات مستقبلية، وليست نتائج حققها الطالب. حافظ حرفياً على durationWeeks وsessionsPerWeek وعلى skillId من القائمة المرسلة. أعط كل هدف UUID صالحاً ومختلفاً.
اكتب baseline وstrengthsSummary وneedsSummary بصياغة تصف المستويات المرسلة فقط؛ دون أي أرقام أو نسب أو مدة قراءة أو نتائج مزعومة. إذا لم توجد مهارة متقنة فاكتب أن نقاط القوة التفصيلية لم تُضمّن في الحمولة المراجعة.
لا تستخدم أداة خارج availableTools. أعد أسماء الأدوات حصراً من enum في المخطط. اكتب الخطط والقياس والأنشطة بمواد بسيطة. لا تضف status أو approval أو معلومات تعريفية. nextFollowUp تاريخ مقترح مستقبلي داخل مدة الخطة. النتيجة JSON وفق المخطط، ولا تُعتمد الخطة من النموذج.`;
    let response: Response;
    try {
      response = await this.transport(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(this.model)}:generateContent`, {
        method: 'POST', headers: { 'Content-Type': 'application/json', 'x-goog-api-key': this.options.apiKey }, signal: combined,
        body: JSON.stringify({ systemInstruction: { parts: [{ text: instructions }] }, contents: [{ role: 'user', parts: [{ text: JSON.stringify(payload) }] }],
          generationConfig: { temperature: 0.3, maxOutputTokens: 8192, responseMimeType: 'application/json', responseJsonSchema: schema } }),
      });
    } catch { throw new ApiError(502, 'AI_PROVIDER_UNAVAILABLE', 'تعذر الاتصال بمولد الخطة؛ المدخلات محفوظة لإعادة المحاولة.'); }
    if (!response.ok) throw providerHttpError(response.status);
    try {
      const raw: unknown = await response.json();
      const envelope = z.object({ candidates: z.array(z.object({ finishReason: z.string(), content: z.object({ parts: z.array(z.object({ text: z.string().optional(), thought: z.boolean().optional() })) }) })).min(1) }).parse(raw);
      const candidate = envelope.candidates[0]!;
      if (candidate.finishReason !== 'STOP') throw new Error('Incomplete generation');
      const text = candidate.content.parts.filter(part => !part.thought).map(part => part.text ?? '').join('');
      if (!text || text.length > 150000) throw new Error('Invalid provider body size');
      const content = planContentSchema.parse(JSON.parse(text));
      // Stable application identities are server generated, never trusted to the model.
      return { ...content, goals: content.goals.map(goal => ({ ...goal, id: randomUUID() })) };
    } catch { throw new ApiError(502, 'AI_OUTPUT_INVALID', 'لم تجتز المسودة فحص الجودة؛ لم تُحفظ خطة. أعد المحاولة.'); }
  }
}
