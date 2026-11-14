// Explicit synthetic-only live acceptance smoke. No credentials are logged.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

if (process.env.KHOTWA_LIVE_SMOKE !== 'synthetic-only') throw new Error('Explicit synthetic-only opt-in required');
const base = new URL(process.env.KHOTWA_API_URL ?? '');
if (base.protocol !== 'https:' || base.username || base.password || base.search || base.hash) throw new Error('A clean HTTPS API URL is required');
const accounts = [];
async function request(method, path, data, token) {
  const response = await fetch(new URL(path, base), { method, redirect: 'error', signal: AbortSignal.timeout(60000),
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    ...(data ? { body: JSON.stringify(data) } : {}) });
  return { status: response.status, body: response.status === 204 ? null : await response.json() };
}
try {
  const health = await request('GET', '/health');
  assert.equal(health.status, 200); assert.equal(health.body.database, 'ready');
  for (let i = 0; i < 2; i++) {
    const account = { email: `staging-synthetic-${randomUUID()}@example.test`, password: `Synthetic-${randomUUID()}` };
    const response = await request('POST', '/v1/auth/register', account);
    assert.equal(response.status, 201, 'Registration failed');
    account.token = response.body.token; accounts.push(account);
  }
  const [a, b] = accounts;
  const time = new Date().toISOString();
  const student = { id: randomUUID(), code: `ST-${randomUUID().slice(0, 8).toUpperCase()}`, grade: 'الثاني الأساسي', ageYears: 7, ageMonths: 2,
    gender: 'female', referralReason: 'مراجعة تربوية اصطناعية لا تخص طفلة', consentConfirmed: true, consentDate: time, createdAt: time };
  const operation = { operationId: randomUUID(), deviceId: randomUUID(), entityId: student.id, kind: 'student', parentId: null, baseRevision: 0, occurredAt: time, action: 'upsert', data: student };
  const first = await request('POST', '/v1/sync/push', { operations: [operation] }, a.token);
  assert.equal(first.status, 200); assert.equal(first.body.results[0].status, 'applied');
  const replay = await request('POST', '/v1/sync/push', { operations: [operation] }, a.token);
  assert.equal(replay.status, 200); assert.deepEqual(replay.body, first.body, 'Retry changed operation result');
  const login = await request('POST', '/v1/auth/login', { email: a.email, password: a.password });
  assert.equal(login.status, 200);
  const freshDevice = await request('GET', '/v1/sync/pull', undefined, login.body.token);
  assert.equal(freshDevice.status, 200); assert.equal(freshDevice.body.records.filter(record => record.id === student.id).length, 1);
  const denied = await request('GET', `/v1/records/${student.id}`, undefined, b.token);
  assert.equal(denied.status, 404, 'Foreign record was exposed');
  const other = await request('GET', '/v1/records?kind=student', undefined, b.token);
  assert.equal(other.status, 200); assert.equal(other.body.records.length, 0);
  const malformed = await request('POST', '/v1/sync/push', { operations: [{ ...operation, operationId: randomUUID(), entityId: randomUUID(), data: { ...student, real_name: 'SYNTHETIC-REJECTED' } }] }, a.token);
  assert.equal(malformed.status, 200);
  assert.equal(malformed.body.results[0].status, 'rejected', 'Forbidden identity field accepted');
  const afterRejected = await request('GET', '/v1/records?kind=student', undefined, a.token);
  assert.equal(afterRejected.body.records.length, 1, 'Rejected record was persisted');
  console.log(JSON.stringify({ https: 'PASS', postgres: 'PASS', registration: 'PASS', login: 'PASS', durableSync: 'PASS', idempotentRetry: 'PASS', freshDevicePull: 'PASS', ownerIsolation: 'PASS', forbiddenField: 'PASS', syntheticOnly: true }));
} finally {
  let failed = false;
  for (const account of accounts) {
    try { const removed = await request('DELETE', '/v1/auth/account', { password: account.password, confirmed: true }, account.token); if (removed.status !== 204) failed = true; }
    catch { failed = true; }
  }
  console.log(JSON.stringify({ syntheticAccountsCleanup: failed ? 'FAILED' : 'PASS' }));
  if (failed) process.exitCode = 3;
}
