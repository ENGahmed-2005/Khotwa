import { GeminiPlanProvider } from './gemini.js';
import type { AiConfig } from './routes.js';

/** Fail closed: merely supplying a key never enables external processing. */
export function aiConfigFromEnvironment(env: NodeJS.ProcessEnv): AiConfig | undefined {
  if (env.AI_ENABLED !== 'true') return undefined;
  if (env.AI_SYNTHETIC_ONLY !== 'true') throw new Error('AI_SYNTHETIC_ONLY=true is required until processing policy is approved');
  if (!env.GEMINI_API_KEY?.trim()) throw new Error('GEMINI_API_KEY must be configured on the server');
  const model = env.GEMINI_MODEL ?? 'gemini-flash-latest';
  return { enabled: true, syntheticOnly: true, model, provider: new GeminiPlanProvider({ apiKey: env.GEMINI_API_KEY, model }) };
}
