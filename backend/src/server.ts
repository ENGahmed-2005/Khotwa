import 'dotenv/config';
import { PrismaClient } from '@prisma/client';
import { buildApp } from './app.js';
import { parseStorageKey } from './crypto.js';
import { aiConfigFromEnvironment } from './ai/config.js';

if (!process.env.DATABASE_URL || !process.env.STORAGE_KEY) throw new Error('DATABASE_URL and STORAGE_KEY must be configured');
const prisma = new PrismaClient({ log: [] });
const app = await buildApp({ prisma, storageKey: parseStorageKey(process.env.STORAGE_KEY), ai: aiConfigFromEnvironment(process.env) });
const port = Number(process.env.PORT ?? 3000);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT is invalid');
for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.once(signal, () => { void app.close().then(() => prisma.$disconnect()); });
}
await app.listen({ host: process.env.HOST ?? '127.0.0.1', port });
console.info(`Khotwa API listening on port ${port}; synthetic development data only.`);

