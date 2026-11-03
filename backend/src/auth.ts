import { Prisma, type PrismaClient, type User } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { z } from 'zod';
import { ApiError, unauthorized } from './errors.js';
import { hashPassword, newToken, tokenHash, verifyPassword } from './crypto.js';
import { credentialsSchema, emailSchema, passwordSchema } from './schemas.js';

export interface ResetDelivery {
  /** Adapter must deliver privately. Never log or return this token in an API response. */
  sendPasswordReset(message: { email: string; token: string; expiresAt: Date }): Promise<void>;
}
export type Clock = () => Date;
export function publicUser(user: Pick<User, 'id' | 'email' | 'role'>) { return { id: user.id, email: user.email, role: user.role }; }

export class AuthService {
  constructor(private readonly prisma: PrismaClient, private readonly clock: Clock = () => new Date(), private readonly resetDelivery?: ResetDelivery) {}

  async requireUser(request: FastifyRequest): Promise<User> {
    const token = this.bearerToken(request);
    const session = await this.prisma.authSession.findUnique({ where: { tokenHash: tokenHash(token) }, include: { user: true } });
    if (!session || session.expiresAt <= this.clock()) throw unauthorized();
    return session.user;
  }

  bearerToken(request: FastifyRequest): string {
    const header = request.headers.authorization;
    if (!header || !/^Bearer [A-Za-z0-9_-]{43}$/.test(header)) throw unauthorized();
    return header.slice(7);
  }

  private async createSession(user: User) {
    const token = newToken();
    const expiresAt = new Date(this.clock().getTime() + 7 * 24 * 60 * 60 * 1000);
    await this.prisma.authSession.create({ data: { userId: user.id, tokenHash: tokenHash(token), expiresAt } });
    return { token, expiresAt: expiresAt.toISOString(), user: publicUser(user) };
  }

  registerRoutes(app: FastifyInstance, authRateLimit = 15) {
    const limited = { config: { rateLimit: { max: authRateLimit, timeWindow: '1 minute' } } };
    app.post('/v1/auth/register', limited, async (request, reply) => {
      const { email, password } = credentialsSchema.parse(request.body);
      const passwordHash = await hashPassword(password);
      try {
        const user = await this.prisma.user.create({ data: { email, passwordHash } });
        return reply.code(201).send(await this.createSession(user));
      } catch (error) {
        if (error instanceof Prisma.PrismaClientKnownRequestError && error.code === 'P2002') throw new ApiError(409, 'ACCOUNT_UNAVAILABLE', 'تعذر إنشاء الحساب بهذه البيانات.');
        throw error;
      }
    });

    // A valid scrypt hash makes a missing account follow the same password-verification path.
    const dummyHash = hashPassword(newToken());
    app.post('/v1/auth/login', limited, async (request) => {
      const { email, password } = credentialsSchema.parse(request.body);
      const user = await this.prisma.user.findUnique({ where: { email } });
      const valid = await verifyPassword(password, user?.passwordHash ?? await dummyHash);
      if (!user || !valid) throw new ApiError(401, 'INVALID_CREDENTIALS', 'البريد أو كلمة المرور غير صحيحة.');
      return this.createSession(user);
    });

    app.get('/v1/auth/me', async request => ({ user: publicUser(await this.requireUser(request)) }));
    app.post('/v1/auth/logout', async (request, reply) => {
      await this.requireUser(request);
      await this.prisma.authSession.deleteMany({ where: { tokenHash: tokenHash(this.bearerToken(request)) } });
      return reply.code(204).send();
    });

    app.post('/v1/auth/password-reset/request', limited, async (request, reply) => {
      const { email } = z.strictObject({ email: emailSchema }).parse(request.body);
      // Fail consistently, including unknown addresses, when no mail integration exists.
      if (!this.resetDelivery) throw new ApiError(503, 'RESET_DELIVERY_UNAVAILABLE', 'خدمة استعادة الحساب غير مهيأة حاليًا.');
      const user = await this.prisma.user.findUnique({ where: { email } });
      if (user) {
        const token = newToken();
        const expiresAt = new Date(this.clock().getTime() + 30 * 60 * 1000);
        const reset = await this.prisma.passwordReset.create({ data: { userId: user.id, tokenHash: tokenHash(token), expiresAt } });
        try { await this.resetDelivery.sendPasswordReset({ email, token, expiresAt }); }
        catch {
          await this.prisma.passwordReset.deleteMany({ where: { id: reset.id } });
          throw new ApiError(503, 'RESET_DELIVERY_UNAVAILABLE', 'تعذر توصيل رسالة الاستعادة. حاول لاحقًا.');
        }
      }
      return reply.code(202).send({ message: 'إن كان الحساب مسجلاً، ستصلك تعليمات الاستعادة.' });
    });

    app.post('/v1/auth/password-reset/confirm', limited, async (request, reply) => {
      const input = z.strictObject({ token: z.string().regex(/^[A-Za-z0-9_-]{43}$/), password: passwordSchema }).parse(request.body);
      const passwordHash = await hashPassword(input.password);
      const now = this.clock();
      await this.prisma.$transaction(async tx => {
        const reset = await tx.passwordReset.findUnique({ where: { tokenHash: tokenHash(input.token) } });
        if (!reset || reset.usedAt || reset.expiresAt <= now) throw new ApiError(400, 'RESET_INVALID', 'رابط الاستعادة غير صالح أو انتهت مدته.');
        const consumed = await tx.passwordReset.updateMany({ where: { id: reset.id, usedAt: null, expiresAt: { gt: now } }, data: { usedAt: now } });
        if (consumed.count !== 1) throw new ApiError(400, 'RESET_INVALID', 'رابط الاستعادة غير صالح أو انتهت مدته.');
        await tx.user.update({ where: { id: reset.userId }, data: { passwordHash } });
        await tx.authSession.deleteMany({ where: { userId: reset.userId } });
        await tx.passwordReset.updateMany({ where: { userId: reset.userId, usedAt: null }, data: { usedAt: now } });
        await tx.auditEvent.create({ data: { ownerId: reset.userId, action: 'account.password_reset' } });
      });
      return reply.code(204).send();
    });

    app.delete('/v1/auth/account', limited, async (request, reply) => {
      const user = await this.requireUser(request);
      const { password } = z.strictObject({ password: passwordSchema, confirmed: z.literal(true) }).parse(request.body);
      if (!await verifyPassword(password, user.passwordHash)) throw new ApiError(401, 'INVALID_CREDENTIALS', 'كلمة المرور غير صحيحة.');
      await this.prisma.user.delete({ where: { id: user.id } });
      return reply.code(204).send();
    });
  }
}

