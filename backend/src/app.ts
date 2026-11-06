import Fastify, { type FastifyInstance, type FastifyRequest } from 'fastify';
import helmet from '@fastify/helmet';
import rateLimit from '@fastify/rate-limit';
import type { PrismaClient } from '@prisma/client';
import { z } from 'zod';
import { AuthService, type Clock, type ResetDelivery } from './auth.js';
import { PayloadCipher } from './crypto.js';
import { ApiError } from './errors.js';
import { RecordStore } from './records.js';
import { pushSchema, recordKind, uuid } from './schemas.js';
import { registerAiRoutes, type AiConfig } from './ai/routes.js';

export interface ApplicationServices {
  auth: AuthService;
  records: RecordStore;
  authenticate: AuthService['requireUser'];
}
export interface AppOptions {
  prisma: PrismaClient;
  storageKey: Buffer;
  resetDelivery?: ResetDelivery;
  clock?: Clock;
  authRateLimit?: number;
  globalRateLimit?: number;
  ai?: AiConfig;
  /** Additional routes share the same owner-scoped authentication and ciphertext helpers. */
  extend?: (app: FastifyInstance, services: ApplicationServices) => void | Promise<void>;
}

export async function buildApp(options: AppOptions): Promise<FastifyInstance> {
  const app = Fastify({ logger: false, bodyLimit: 1024 * 1024, trustProxy: false });
  await app.register(helmet);
  await app.register(rateLimit, { max: options.globalRateLimit ?? 120, timeWindow: '1 minute',
    errorResponseBuilder: () => new ApiError(429, 'RATE_LIMITED', 'محاولات كثيرة؛ انتظر قليلًا ثم أعد المحاولة.'),
  });
  const auth = new AuthService(options.prisma, options.clock, options.resetDelivery);
  const records = new RecordStore(options.prisma, new PayloadCipher(options.storageKey), options.clock);
  auth.registerRoutes(app, options.authRateLimit);

  // Logging is intentionally payload-free; all operational responses use safe messages.
  app.setErrorHandler((error, _request, reply) => {
    if (error instanceof z.ZodError) return reply.code(400).send({ error: { code: 'INVALID_INPUT', message: 'راجع الحقول المطلوبة وصياغتها.' } });
    if (error instanceof ApiError) return reply.code(error.statusCode).send({ error: { code: error.code, message: error.message } });
    if ('statusCode' in (error as object)) {
      const code = (error as { statusCode?: number }).statusCode;
      if (code === 429) return reply.code(429).send({ error: { code: 'RATE_LIMITED', message: 'محاولات كثيرة؛ انتظر قليلًا ثم أعد المحاولة.' } });
      if (code === 400 || code === 413 || code === 415) return reply.code(code).send({ error: { code: 'INVALID_REQUEST', message: 'صيغة الطلب غير صالحة.' } });
    }
    return reply.code(503).send({ error: { code: 'SERVICE_UNAVAILABLE', message: 'الخدمة غير متاحة مؤقتًا؛ احتفظ ببياناتك وحاول لاحقًا.' } });
  });
  app.setNotFoundHandler((_request, reply) => reply.code(404).send({ error: { code: 'NOT_FOUND', message: 'المسار غير متاح.' } }));
  app.addHook('onSend', async (request, reply) => {
    if (request.url.startsWith('/v1')) reply.header('Cache-Control', 'no-store');
  });
  app.get('/health', async (_request, reply) => {
    try {
      await options.prisma.$queryRaw`SELECT 1`;
      return { status: 'ok', database: 'ready' };
    } catch { return reply.code(503).send({ status: 'unavailable', database: 'unavailable' }); }
  });
  app.get('/v1/records', async request => {
    const user = await auth.requireUser(request);
    const { kind } = z.strictObject({ kind: recordKind.optional() }).parse(request.query);
    return { records: await records.list(user.id, kind) };
  });
  app.get('/v1/records/:id', async request => {
    const user = await auth.requireUser(request);
    const { id } = z.strictObject({ id: uuid }).parse(request.params);
    return { record: await records.get(user.id, id) };
  });
  app.post('/v1/sync/push', async request => {
    const user = await auth.requireUser(request);
    const { operations } = pushSchema.parse(request.body);
    const results = [];
    // Apply in client order so parents exist before children. Receipts permit safe retry after partial transport failure.
    for (const operation of operations) results.push(await records.applyOperation(user.id, operation));
    return { results };
  });
  app.get('/v1/sync/pull', async request => {
    const user = await auth.requireUser(request);
    z.strictObject({}).parse(request.query);
    return { records: await records.list(user.id, undefined, true), fullSnapshot: true };
  });
  registerAiRoutes(app, { prisma: options.prisma, auth, records, storageKey: options.storageKey, clock: options.clock, config: options.ai });
  if (options.extend) await options.extend(app, { auth, records, authenticate: (request: FastifyRequest) => auth.requireUser(request) });
  return app;
}

