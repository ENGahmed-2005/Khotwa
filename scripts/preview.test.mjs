import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname, resolve, basename } from 'node:path';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';

test('preview pins API destination and forwards only required credential headers', { timeout: 20000 }, async t => {
  const folder = await mkdtemp(join(tmpdir(), 'khotwa-preview-'));
  assert.equal(dirname(folder), resolve(tmpdir()));
  assert.ok(basename(folder).startsWith('khotwa-preview-'));
  t.after(() => rm(folder, { recursive: true, force: true }));
  await writeFile(join(folder, 'index.html'), 'synthetic preview');
  let received;
  const upstream = createServer(async (req, res) => {
    const chunks = [];
    for await (const part of req) chunks.push(part);
    received = { url: req.url, method: req.method, headers: req.headers, body: Buffer.concat(chunks).toString() };
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true }));
  });
  upstream.listen(0, '127.0.0.1');
  await once(upstream, 'listening');
  t.after(() => { upstream.closeAllConnections(); upstream.close(); });
  // Reserve a free local port without assuming any existing preview is ours.
  const reservation = createServer();
  reservation.listen(0, '127.0.0.1');
  await once(reservation, 'listening');
  const port = reservation.address().port;
  await new Promise(resolve => reservation.close(resolve));
  const child = spawn(process.execPath, [fileURLToPath(new URL('./preview.mjs', import.meta.url))], {
    env: { ...process.env, KHOTWA_PREVIEW_BUILD: folder, KHOTWA_PREVIEW_PORT: String(port),
      KHOTWA_API_URL: `http://127.0.0.1:${upstream.address().port}` },
    windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],
  });
  t.after(async () => { if (child.exitCode === null) { child.kill(); await once(child, 'exit'); } });
  await Promise.race([
    once(child.stdout, 'data'),
    once(child, 'exit').then(([code]) => { throw new Error(`Preview exited ${code}`); }),
    new Promise((_, reject) => child.on('error', reject)),
  ]);
  const base = `http://127.0.0.1:${port}`;
  const response = await fetch(`${base}/v1/synthetic?revision=2`, {
    method: 'POST', headers: { authorization: 'Bearer synthetic-test-only',
      'content-type': 'application/json', accept: 'application/json',
      cookie: 'unrelated_local_cookie=synthetic', origin: 'http://unrelated.test', referer: 'http://unrelated.test/' },
    body: JSON.stringify({ synthetic: true }), signal: AbortSignal.timeout(5000),
  });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });
  assert.equal(received.url, '/v1/synthetic?revision=2');
  assert.equal(received.method, 'POST');
  assert.equal(received.headers.authorization, 'Bearer synthetic-test-only');
  assert.equal(received.headers['content-type'], 'application/json');
  assert.equal(received.headers.host, `127.0.0.1:${upstream.address().port}`);
  assert.equal(received.headers.cookie, undefined);
  assert.equal(received.headers.origin, undefined);
  assert.equal(received.headers.referer, undefined);
  assert.deepEqual(JSON.parse(received.body), { synthetic: true });
  assert.equal(await (await fetch(base)).text(), 'synthetic preview');
  assert.equal((await fetch(`${base}/missing.wasm`)).status, 404);
});
