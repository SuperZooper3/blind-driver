import { test } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import http from 'node:http';
import { createFrontend } from './server.mjs';
const observation = { view: '/9j/AAAA', map: '/9j/AAAA', speed_kmh: 30, previous_instruction: 'Straight ahead',
  previous_latency_ms: 900, instruction_age_ms: 20, route: 'Fork ahead: 70 m' };
const answer = instruction => new Response(JSON.stringify({ finish_reason: 'COMPLETE', message: { content: [
  { type: 'thinking', text: 'private reasoning' }, { type: 'text', text: instruction }] } }));
async function fixture(t, ai) {
  const server = createFrontend({ ai: { enabled: true, ...ai } });
  t.after(() => { server.closeAllConnections(); server.close(); });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const base = `http://127.0.0.1:${server.address().port}`;
  return { base, post: (body = observation, headers = {}) => fetch(`${base}/api/ai/navigate`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body) }) };
}
test('clear passenger view and map reach Cohere Command A Vision; returns only advice and timing', async t => {
  let calls = 0;
  const { base, post } = await fixture(t, { key: 'secret-fixture', fetchImpl: async (url, options) => {
    calls++;
    assert.equal(url, 'https://api.cohere.com/v2/chat');
    assert.equal(options.headers.Authorization, 'Bearer secret-fixture');
    const body = JSON.parse(options.body);
    assert.equal(body.model, 'command-a-vision-07-2025');
    assert.equal(body.max_tokens, 128);
    const current = body.messages.find(message => message.role === 'user').content;
    assert.deepEqual(current.filter(part => part.type === 'image_url').map(part => part.image_url.url),
      [observation.view, observation.map].map(jpeg => 'data:image/jpeg;base64,' + jpeg));
    assert.match(current[0].text, /current clear passenger camera/);
    assert.match(current[0].text, /Straight ahead/);
    return answer('Ease left (A), then straighten.');
  } });
  const response = await post();
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  const data = await response.json();
  assert.equal(data.instruction, 'Ease left (A), then straighten.');
  assert.equal(data.model, 'command-a-vision-07-2025');
  assert.ok(data.latency_ms >= 0);
  assert.equal(calls, 1);
  const config = await (await fetch(`${base}/config.js`)).text();
  assert.ok(!config.includes('secret-fixture'));
});
test('missing key, invalid images, oversized observations and foreign origins never call Cohere', async t => {
  const missing = await fixture(t, { key: '' });
  assert.equal((await (await missing.post()).json()).permanent, true);
  let calls = 0;
  const { post } = await fixture(t, { key: 'fixture', fetchImpl: async () => { calls++; return answer('Go'); } });
  assert.equal((await post({ ...observation, view: 'bad' })).status, 400);
  assert.equal((await post({ ...observation, speed_kmh: null })).status, 400);
  assert.equal((await post(observation, { Origin: 'https://foreign.example' })).status, 403);
  assert.equal((await post(observation, { 'Content-Type': 'text/plain' })).status, 415);
  assert.equal((await post({ padding: 'x'.repeat(1_500_001) })).status, 413);
  assert.equal(calls, 0);
});
test('quota errors honor provider cooldown across clients without exposing provider data', async t => {
  let calls = 0;
  const { post } = await fixture(t, { key: 'fixture', fetchImpl: async () => {
    calls++; return new Response(JSON.stringify({ message: 'sensitive project info' }),
      { status: 429, headers: { 'Retry-After': '120' } });
  } });
  const first = await post(); const data = await first.json();
  assert.equal(first.status, 429); assert.equal(data.retry_after, 120);
  assert.ok(!JSON.stringify(data).includes('sensitive'));
  assert.equal((await post()).status, 429); assert.equal(calls, 1);
});
test('access errors stop retries; truncated, empty and excessive replies are rejected', async t => {
  for (const result of [new Response('{}', { status: 403 }), new Response('{}', { status: 498 }), answer(''), answer('x'.repeat(241)),
    new Response(JSON.stringify({ finish_reason: 'MAX_TOKENS', message: { content: [{ type: 'text', text: 'Turn' }] } }))]) {
    const { post } = await fixture(t, { key: 'fixture', fetchImpl: async () => result });
    const response = await post(); assert.equal(response.status, 502);
    if ([403, 498].includes(result.status)) assert.equal((await response.json()).permanent, true);
  }
});
test('timed out calls release capacity for another request', async t => {
  let calls = 0;
  const { post } = await fixture(t, { key: 'fixture', timeoutMs: 30, fetchImpl: async (_url, { signal }) => {
    if (++calls > 1) return answer('Go straight.');
    return new Promise((resolve, reject) => signal.addEventListener('abort', () => reject(new Error('timeout'))));
  } });
  assert.match((await (await post()).json()).error, /timed out/);
  assert.equal((await post()).status, 200);
});

test('disconnecting the game cancels its upstream call', async t => {
  let started;
  let cancelled;
  const begun = new Promise(resolve => { started = resolve; });
  const aborted = new Promise(resolve => { cancelled = resolve; });
  const { base } = await fixture(t, { key: 'fixture', fetchImpl: async (_url, { signal }) => {
    started();
    return new Promise((_resolve, reject) => signal.addEventListener('abort', () => { cancelled(); reject(new Error('cancelled')); }));
  } });
  const controller = new AbortController();
  const pending = fetch(`${base}/api/ai/navigate`, { method: 'POST', signal: controller.signal,
    headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(observation) }).catch(() => {});
  await begun;
  controller.abort();
  await Promise.race([aborted, new Promise((_resolve, reject) => { const timer = setTimeout(() => reject(new Error('upstream not cancelled')), 1000); timer.unref(); })]);
  await pending;
});

test('a configured key does not expose AI without explicit local opt-in', async t => {
  let calls = 0;
  const { post } = await fixture(t, { enabled: false, key: 'fixture', fetchImpl: async () => { calls++; return answer('Go'); } });
  assert.equal((await post()).status, 503);
  assert.equal(calls, 0);
});

test('local AI rejects proxy forwarding and non-local Host names before billing', async t => {
  let calls = 0;
  const { base, post } = await fixture(t, { key: 'fixture', fetchImpl: async () => { calls++; return answer('Go'); } });
  const foreignHost = await new Promise((resolve, reject) => {
    const request = http.request(base + '/api/ai/navigate', { method: 'POST',
      headers: { Host: 'rebind.example', 'Content-Type': 'application/json' } }, response => { response.resume(); resolve(response.statusCode); });
    request.on('error', reject); request.end(JSON.stringify(observation));
  });
  assert.equal(foreignHost, 403);
  for (const headers of [{ 'X-Forwarded-For': '198.51.100.1' },
    { Forwarded: 'for=198.51.100.1' }, { 'X-Forwarded-Host': 'public.example' }, { 'X-Real-IP': '198.51.100.1' }]) {
    assert.equal((await post(observation, headers)).status, 403);
  }
  assert.equal(calls, 0);
});
