// Local same-origin preview of the actual Flutter build and actual Fastify API.
// No fake data, no bundled credentials, no public binding.
import { createServer, request as proxyRequest } from 'node:http';
import { request as secureProxyRequest } from 'node:https';
import { createReadStream, existsSync, statSync } from 'node:fs';
import { resolve, extname, sep, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const workspace = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const root = resolve(process.env.KHOTWA_PREVIEW_BUILD ?? resolve(workspace, 'mobile/build/web'));
if (!existsSync(resolve(root, 'index.html'))) throw new Error('Build Flutter web preview first; mobile/build/web/index.html is missing.');
const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.json': 'application/json', '.css': 'text/css', '.wasm': 'application/wasm', '.png': 'image/png', '.webp': 'image/webp', '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.ttf': 'font/ttf' };
const port = Number(process.env.KHOTWA_PREVIEW_PORT ?? 4173);
const apiPort = Number(process.env.KHOTWA_API_PORT ?? 3000);
const api = new URL(process.env.KHOTWA_API_URL ?? `http://127.0.0.1:${apiPort}`);
const localApi = ['127.0.0.1', 'localhost', '[::1]'].includes(api.hostname);
if ((api.protocol !== 'https:' && !(localApi && api.protocol === 'http:')) ||
    api.username || api.password || api.search || api.hash || api.pathname !== '/') {
  throw new Error('Preview API must be HTTPS, or a local HTTP API, without credentials or a path');
}
const server = createServer((req, res) => {
  const incoming = new URL(req.url ?? '/', `http://127.0.0.1:${port}`);
  const pathname = incoming.pathname;
  if (pathname.startsWith('/v1/') || pathname === '/health') {
    const transport = api.protocol === 'https:' ? secureProxyRequest : proxyRequest;
    const headers = { host: api.host };
    for (const name of ['accept', 'authorization', 'content-type', 'content-length']) {
      if (req.headers[name] !== undefined) headers[name] = req.headers[name];
    }
    const upstream = transport({ hostname: api.hostname.replace(/^\[|\]$/g, ''), port: api.port || (api.protocol === 'https:' ? 443 : 80),
      path: incoming.pathname + incoming.search, method: req.method,
      headers }, response => {
      res.writeHead(response.statusCode ?? 502, { ...response.headers, 'cache-control': 'no-store' });
      response.pipe(res);
    });
    upstream.on('error', () => { if (!res.headersSent) res.writeHead(503, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }); res.end(JSON.stringify({ error: { code: 'API_UNAVAILABLE', message: 'الخادم المحلي غير متاح حاليًا.' } })); });
    req.on('aborted', () => upstream.destroy());
    res.on('close', () => { if (!res.writableEnded) upstream.destroy(); });
    upstream.setTimeout(180000, () => upstream.destroy());
    req.pipe(upstream);
    return;
  }
  if (req.method !== 'GET' && req.method !== 'HEAD') { res.writeHead(405); res.end(); return; }
  let path;
  try { path = resolve(root, '.' + decodeURIComponent(pathname)); }
  catch { res.writeHead(400); res.end(); return; }
  if (path !== root && !path.startsWith(root + sep)) { res.writeHead(403); res.end(); return; }
  if (!existsSync(path) || !statSync(path).isFile()) {
    // Only navigation requests receive the SPA entrypoint. A missing asset must
    // remain a 404 so the renderer does not try to parse HTML as JSON or WASM.
    if (extname(path) || pathname.startsWith('/assets/') || pathname.startsWith('/canvaskit/')) {
      res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' });
      res.end('Preview asset not found');
      return;
    }
    path = resolve(root, 'index.html');
  }
  res.writeHead(200, { 'content-type': types[extname(path)] ?? 'application/octet-stream', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' });
  if (req.method === 'HEAD') res.end(); else createReadStream(path).pipe(res);
});
server.listen(port, '127.0.0.1', () => console.info(`Khotwa Flutter preview: http://127.0.0.1:${port}`));
