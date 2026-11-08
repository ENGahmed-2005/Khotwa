import { isIP } from 'node:net';
import nodemailer, { type Transporter } from 'nodemailer';
import type SMTPTransport from 'nodemailer/lib/smtp-transport/index.js';
import { z } from 'zod';
import type { ResetDelivery } from '../auth.js';

/** Only server environment may configure SMTP; callers cannot select a host or sender. */
export function smtpOptionsFromEnvironment(env: NodeJS.ProcessEnv): { options: SMTPTransport.Options; from: string } | undefined {
  if (env.SMTP_ENABLED !== 'true') return undefined;
  const host = z.string().trim().min(1).max(253).regex(/^[a-z0-9.:-]+$/iu).parse(env.SMTP_HOST);
  const mode = z.enum(['implicit', 'starttls', 'plain-loopback']).parse(env.SMTP_TLS_MODE ?? 'starttls');
  const port = z.coerce.number().int().min(1).max(65535).parse(env.SMTP_PORT ?? (mode === 'implicit' ? 465 : 587));
  const from = z.email().max(254).parse(env.SMTP_FROM);
  const loopback = host === '127.0.0.1' || host === '::1';
  const plain = mode === 'plain-loopback';
  if (plain && (!loopback || env.SMTP_ALLOW_INSECURE_LOOPBACK !== 'true' || env.NODE_ENV === 'production')) throw new Error('Plain SMTP is restricted to explicitly enabled loopback development');
  const user = env.SMTP_USER?.trim();
  const pass = env.SMTP_PASSWORD;
  if (Boolean(user) !== Boolean(pass) || (!plain && (!user || !pass))) throw new Error('SMTP authentication must be configured for TLS delivery');
  const servername = env.SMTP_TLS_SERVERNAME?.trim() ?? (isIP(host) ? undefined : host);
  if (!plain && isIP(host) && !servername) throw new Error('SMTP_TLS_SERVERNAME is required for certificate verification with an IP host');
  if (servername && !/^[a-z0-9.-]+$/iu.test(servername)) throw new Error('Invalid SMTP TLS server name');
  return { from, options: {
    host, port, secure: mode === 'implicit', requireTLS: mode === 'starttls', ignoreTLS: plain,
    opportunisticTLS: false, ...(user && pass ? { auth: { user, pass } } : {}),
    tls: { minVersion: 'TLSv1.2', rejectUnauthorized: true, ...(servername ? { servername } : {}) },
    name: 'khotwa.local', connectionTimeout: 10000, greetingTimeout: 10000, socketTimeout: 20000,
    pool: false, logger: false, debug: false, disableFileAccess: true, disableUrlAccess: true,
  } };
}

class SmtpResetDelivery implements ResetDelivery {
  constructor(private readonly transport: Transporter<SMTPTransport.SentMessageInfo>, private readonly from: string) {}
  async verifyAvailability(): Promise<void> { await this.transport.verify(); }
  async sendPasswordReset(message: { email: string; token: string; expiresAt: Date }): Promise<void> {
    const email = z.email().max(254).parse(message.email);
    const token = z.string().regex(/^[A-Za-z0-9_-]{43}$/).parse(message.token);
    if (!Number.isFinite(message.expiresAt.getTime())) throw new Error('Invalid reset expiration');
    const info = await this.transport.sendMail({ from: this.from, to: email,
      subject: 'خطوة — استعادة كلمة المرور',
      text: `طلبتِ استعادة كلمة المرور في تطبيق خطوة.\n\nانسخي رمز الاستعادة إلى شاشة استعادة الحساب في التطبيق:\n${token}\n\nتنتهي صلاحية الرمز في ${message.expiresAt.toISOString()} ويُستخدم مرة واحدة.\nإن لم تطلبي الاستعادة، تجاهلي هذه الرسالة ولا تشاركي الرمز مع أي شخص.`,
      headers: { 'X-Auto-Response-Suppress': 'All' },
    });
    if (info.accepted.length !== 1 || info.rejected.length !== 0) throw new Error('Reset message was not accepted by SMTP');
  }
}

/** Hook for buildApp({ resetDelivery: resetDeliveryFromEnvironment(process.env) }). */
export function resetDeliveryFromEnvironment(env: NodeJS.ProcessEnv): ResetDelivery | undefined {
  const settings = smtpOptionsFromEnvironment(env);
  return settings ? new SmtpResetDelivery(nodemailer.createTransport(settings.options), settings.from) : undefined;
}
