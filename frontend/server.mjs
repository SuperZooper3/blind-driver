import http from 'node:http';
import { createReadStream, existsSync, statSync, realpathSync } from 'node:fs';
import { extname, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createNavigator } from './ai_navigator.mjs';
import { VERSION } from '../server/protocol.mjs';

const defaultDirectory = fileURLToPath(new URL('../build/web/', import.meta.url));
const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.wasm': 'application/wasm', '.pck': 'application/octet-stream',
  '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.json': 'application/json' };

export function relayAddress(value) {
  const url = new URL(value);
  const local = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  if (!['https:', 'wss:', ...(local ? ['http:', 'ws:'] : [])].includes(url.protocol)
      || url.username || url.password || url.search || url.hash) {
    throw new Error('BLIND_DRIVER_RELAY_URL must be a public HTTPS/WSS URL (HTTP/WS is allowed only on localhost).');
  }
  return url.href.replace(/\/$/, '');
}

export function createFrontend({ directory = defaultDirectory,
  relay = process.env.BLIND_DRIVER_RELAY_URL || 'https://blind-driver-relay.onrender.com', ai = {} } = {}) {
  const navigate = createNavigator(ai);
  const root = resolve(directory);
  const relayUrl = relayAddress(relay);
  const ready = () => ['game.html', 'game.js', 'game.wasm', 'game.pck', 'launcher.js', 'style.css', 'favicon.svg',
    'media/bank-getaway.png', 'media/two-seats.png', 'media/field-map.png',
    'media/broken-glasses.png', 'media/police-pursuit.png']
    .every(file => existsSync(resolve(root, file)));
  return http.createServer((request, response) => {
    response.setHeader('X-Content-Type-Options', 'nosniff');
    response.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
    response.setHeader('X-Frame-Options', 'DENY');
    response.setHeader('Content-Security-Policy', "frame-ancestors 'none'; base-uri 'none'; object-src 'none'");
    response.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
    response.setHeader('Cache-Control', 'no-cache');
    if (request.url === '/api/ai/navigate') { void navigate(request, response); return; }
    if (!['GET', 'HEAD'].includes(request.method)) {
      response.writeHead(405, { Allow: 'GET, HEAD' }); response.end(); return;
    }
    let pathname;
    try { pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname); }
    catch { response.writeHead(400); response.end(); return; }
    const send = (code, type, text) => {
      response.writeHead(code, { 'Content-Type': type, 'Content-Length': Buffer.byteLength(text) });
      response.end(request.method === 'HEAD' ? undefined : text);
    };
    if (pathname === '/healthz') {
      const ok = ready();
      response.setHeader('Cache-Control', 'no-store');
      send(ok ? 200 : 503, 'application/json', JSON.stringify({ ok, service: 'blind-driver-frontend', protocol: VERSION }));
      return;
    }
    if (pathname === '/config.js') {
      response.setHeader('Cache-Control', 'no-store');
      send(200, types['.js'], `window.BLIND_DRIVER_CONFIG = Object.freeze(${JSON.stringify({ relayUrl, protocol: VERSION }).replace(/</g, '\\u003c')});\n`);
      return;
    }
    const path = resolve(root, pathname === '/' ? 'game.html' : `.${pathname}`);
    // Serve only public export file types, never source files or directory listings.
    const isPublicFile = candidate => {
      try { return realpathSync(candidate).startsWith(`${realpathSync(root)}${sep}`) && statSync(candidate).isFile(); }
      catch { return false; }
    };
    if (pathname.split('/').some(part => part.startsWith('.'))
        || !path.startsWith(`${root}${sep}`) || !types[extname(path)] || !isPublicFile(path)) {
      send(404, 'text/plain', 'Not found'); return;
    }
    const encodings = new Map((request.headers['accept-encoding'] || '').split(',').map(part => {
      const [name, quality] = part.trim().split(';');
      return [name, quality?.trim().startsWith('q=') ? Number(quality.trim().slice(2)) : 1];
    }));
    let servedPath = path;
    for (const [encoding, suffix] of [['br', '.br'], ['gzip', '.gz']]) {
      if ((encodings.get(encoding) ?? encodings.get('*') ?? 0) > 0 && isPublicFile(path + suffix)) {
        servedPath += suffix;
        response.setHeader('Content-Encoding', encoding);
        break;
      }
    }
    response.setHeader('Vary', 'Accept-Encoding');
    response.writeHead(200, { 'Content-Type': types[extname(path)], 'Content-Length': statSync(servedPath).size });
    if (request.method === 'HEAD') { response.end(); return; }
    const stream = createReadStream(servedPath);
    stream.on('error', () => response.destroy());
    response.on('close', () => stream.destroy());
    stream.pipe(response);
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const server = createFrontend();
  const port = Number(process.env.PORT || 8080);
  const host = process.env.HOST || (process.env.BLIND_DRIVER_AI_ENABLED === '1' ? '127.0.0.1' : '0.0.0.0');
  server.listen(port, host, () => console.log(`Blind Driver frontend listening on http://${host}:${port}`));
  for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => {
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 5000).unref();
  });
}
