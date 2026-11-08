import { z } from 'zod';
import { ApiError } from '../errors.js';
import { activityContentSchema, type ActivityPayload } from './domain.js';

export interface ActivityProvider { generate(payload: ActivityPayload): Promise<unknown> }
export interface ActivityConfig { enabled: boolean; syntheticOnly: boolean; model: string; provider: ActivityProvider }
export class GeminiActivityProvider implements ActivityProvider {
  constructor(private readonly options: { apiKey: string; model: string; fetchImpl?: typeof fetch; timeoutMs?: number }) {
    if (!options.apiKey.trim() || !/^gemini-[a-z0-9.-]+$/.test(options.model)) throw new Error('Invalid server activity configuration');
  }
  async generate(payload: ActivityPayload): Promise<unknown> {
    const schema = z.toJSONSchema(activityContentSchema);
    delete schema.$schema;
    const instructions = `أنت مساعد تربوي يصوغ مسودة نشاط بالعربية البسيطة الداعمة من المدخلات المراجعة فقط.
لا بيانات شخصية ولا تشخيص أو تصنيف أو حكم عام أو تنبؤ أو دواء. تجنب كل الألفاظ السلبية حتى عند النفي، وأي أمثلة مؤذية عن الحرب أو الفقد أو ظروف الطفل الصعبة.
النشاط مرتبط بالهدف المرفق، ويستعمل الأدوات المتاحة فقط. أعد tools كمعرّفات من availableTools حصراً وحافظ على minutes كما هي. لا تفترض أجهزة أو اتصالاً أو خامات أخرى.
اكتب خطوات تنفيذ وأمثلة تطبيقية وتغذية راجعة وآلية قياس قابلة للتنفيذ، وأدرج إعداد الوسيلة من الأدوات المتاحة وبدائل بسيطة. type يحدد ورقة عمل أو بطاقات أو قصة أو لعبة أو نشاطاً حسياً. mode يحدد فردي أو جماعي. لا تختلق نتائج طالب أو عدد إجابات حققها.
العناوين والمدة والبدائل وملاحظات المعلمة عناصر اختيارية عند الطباعة. أعد JSON حصراً وفق المخطط. جميع المخرجات اقتراحات للمراجعة البشرية.`;
    let response: Response;
    try {
      response = await (this.options.fetchImpl ?? fetch)(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(this.options.model)}:generateContent`, {
        method: 'POST', headers: { 'content-type': 'application/json', 'x-goog-api-key': this.options.apiKey },
        signal: AbortSignal.timeout(this.options.timeoutMs ?? 90000),
        body: JSON.stringify({ systemInstruction: { parts: [{ text: instructions }] }, contents: [{ role: 'user', parts: [{ text: JSON.stringify(payload) }] }],
          generationConfig: { temperature: 0.3, maxOutputTokens: 8192, responseMimeType: 'application/json', responseJsonSchema: schema } }),
      });
    } catch { throw new ApiError(502, 'AI_PROVIDER_UNAVAILABLE', 'تعذر الاتصال بمولّد الأنشطة. احتُفظ بالمدخلات.'); }
    if (!response.ok) throw new ApiError(502, 'AI_PROVIDER_UNAVAILABLE', 'مولّد الأنشطة غير متاح حاليًا. احتُفظ بالمدخلات.');
    try {
      const envelope = z.object({ candidates: z.array(z.object({ finishReason: z.literal('STOP'), content: z.object({ parts: z.array(z.object({ text: z.string().optional(), thought: z.boolean().optional() })) }) })).min(1) }).parse(await response.json());
      const text = envelope.candidates[0]!.content.parts.filter(part => !part.thought).map(part => part.text ?? '').join('');
      if (text.length > 150000) throw new Error('Oversized output');
      return activityContentSchema.parse(JSON.parse(text));
    } catch { throw new ApiError(502, 'AI_OUTPUT_INVALID', 'النشاط لم يجتز التحقق. لم تُحفظ نتيجة بديلة.'); }
  }
}
export function activityConfigFromEnvironment(env: NodeJS.ProcessEnv): ActivityConfig | undefined {
  if (env.AI_ENABLED !== 'true') return undefined;
  if (env.AI_SYNTHETIC_ONLY !== 'true' || !env.GEMINI_API_KEY?.trim()) throw new Error('Synthetic server-only Gemini configuration required');
  const model = env.GEMINI_MODEL ?? 'gemini-flash-latest';
  return { enabled: true, syntheticOnly: true, model, provider: new GeminiActivityProvider({ apiKey: env.GEMINI_API_KEY, model }) };
}
