import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync, mkdirSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import http from 'node:http';
import { gzipSync } from 'node:zlib';
import { createFrontend, relayAddress } from './server.mjs';
import { VERSION } from '../server/protocol.mjs';

test('relay configuration accepts secure endpoints and rejects unsafe or private browser addresses', () => {
  assert.equal(relayAddress('https://relay.example/'), 'https://relay.example');
  assert.equal(relayAddress('wss://relay.example/ws'), 'wss://relay.example/ws');
  assert.equal(relayAddress('http://127.0.0.1:10000'), 'http://127.0.0.1:10000');
  for (const bad of ['http://public.example', 'http://relay.railway.internal', 'javascript:alert(1)',
    'https://user:password@example.com', 'https://example.com?token=secret', 'https://example.com/#room']) {
    assert.throws(() => relayAddress(bad));
  }
});

test('frontend serves playable files, runtime configuration, readiness, and compressed WASM safely', async t => {
  const directory = mkdtempSync(join(tmpdir(), 'blind-driver-web-'));
  const server = createFrontend({ directory, relay: 'https://railway-relay.example' });
  t.after(() => { server.closeAllConnections(); server.close(); rmSync(directory, { recursive: true, force: true }); });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const base = `http://127.0.0.1:${server.address().port}`;
  assert.equal((await fetch(`${base}/healthz`)).status, 503);
  mkdirSync(join(directory, 'media'));
  for (const file of ['game.html', 'game.js', 'game.wasm', 'game.pck', 'launcher.js', 'style.css', 'favicon.svg',
    'favicon.ico', 'apple-touch-icon.png', 'media/social-preview.png',
    'media/bank-getaway.png', 'media/two-seats.png', 'media/field-map.png',
    'media/broken-glasses.png', 'media/police-pursuit.png']) writeFileSync(join(directory, file), `contents:${file}`);
  writeFileSync(join(directory, 'secret.cfg'), 'private');
  writeFileSync(join(directory, '.env.json'), '{"key":"private"}');
  writeFileSync(join(directory, 'media/screenshot.png'), 'image-fixture');
  const outside = mkdtempSync(join(tmpdir(), 'blind-driver-private-'));
  t.after(() => rmSync(outside, { recursive: true, force: true }));
  writeFileSync(join(outside, 'secret.json'), '{"key":"private"}');
  symlinkSync(join(outside, 'secret.json'), join(directory, 'leak.json'));
  symlinkSync(join(outside, 'secret.json'), join(directory, 'game.js.br'));
  const compressed = gzipSync('contents:game.wasm');
  writeFileSync(join(directory, 'game.wasm.gz'), compressed);
  const health = await fetch(`${base}/healthz`);
  assert.equal(health.status, 200);
  assert.equal((await health.json()).protocol, VERSION);
  const home = await fetch(base);
  assert.match(home.headers.get('content-type'), /text\/html/);
  assert.equal(await home.text(), 'contents:game.html');
  assert.equal(home.headers.get('x-frame-options'), 'DENY');
  assert.match(home.headers.get('content-security-policy'), /frame-ancestors 'none'/);
  assert.equal((await fetch(base + '/media/screenshot.png')).headers.get('content-type'), 'image/png');
  const script = await fetch(base + '/game.js', { headers: { 'Accept-Encoding': 'br' } });
  assert.equal(script.headers.get('content-encoding'), null);
  assert.equal(await script.text(), 'contents:game.js');
  const config = await fetch(`${base}/config.js`);
  assert.equal(config.headers.get('cache-control'), 'no-store');
  assert.match(await config.text(), /https:\/\/railway-relay\.example/);
  const wasm = await fetch(`${base}/game.wasm`, { headers: { 'Accept-Encoding': 'gzip' } });
  assert.equal(wasm.headers.get('content-type'), 'application/wasm');
  assert.equal(wasm.headers.get('content-encoding'), 'gzip');
  assert.equal(await wasm.text(), 'contents:game.wasm');
  const plain = await fetch(`${base}/game.wasm`, { headers: { 'Accept-Encoding': 'br;q=0, gzip;q=0' } });
  assert.equal(plain.headers.get('content-encoding'), null);
  assert.equal((await fetch(`${base}/game.pck`, { method: 'HEAD' })).headers.get('content-length'), '17');
  assert.equal((await fetch(base, { method: 'POST' })).status, 405);
  for (const path of ['/secret.cfg', '/missing.wasm', '/server/index.mjs', '/game.wasm.gz', '/.env.json', '/leak.json']) assert.equal((await fetch(base + path)).status, 404);
  const traversal = await new Promise((resolve, reject) => {
    http.get(`${base}/%2e%2e%2fpackage.json`, response => { response.resume(); resolve(response.statusCode); }).on('error', reject);
  });
  assert.equal(traversal, 404);
});
