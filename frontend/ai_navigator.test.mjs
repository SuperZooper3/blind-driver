import { test } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createFrontend } from './server.mjs';
const observation = { view: '/9j/AAAA', map: '/9j/AAAA', speed_kmh: 30, previous_instruction: 'Straight ahead',
  previous_latency_ms: 900, instruction_age_ms: 20, route: 'Fork ahead: 70 m' };
const answer = instruction => new Response(JSON.stringify({ candidates: [{ finishReason: 'STOP', content: { parts: [
  { thought: true, text: 'private reasoning' }, { text: instruction }] } }] }));
async function fixture(t, ai) {
  const server = createFrontend({ ai });
  t.after(() => { server.closeAllConnections(); server.close(); });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const base = `http://127.0.0.1:${server.address().port}`;
  return { base, post: (body = observation, headers = {}) => fetch(`${base}/api/ai/navigate`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body) }) };
}
test('fresh visual observation uses Hydrogen low thinking; returns only advice and timing', async t => {
  let calls = 0;
  const { base, post } = await fixture(t, { key: 'secret-fixture', fetchImpl: async (url, options) => {
    calls++;
    assert.match(url, /gemini-4-hydrogen:generateContent$/);
    assert.equal(options.headers['x-goog-api-key'], 'secret-fixture');
    const body = JSON.parse(options.body);
    assert.equal(body.generationConfig.thinkingConfig.thinkingLevel, 'low');
    assert.equal(body.generationConfig.mediaResolution, 'MEDIA_RESOLUTION_LOW');
    assert.equal(body.contents[0].parts.filter(p => p.inlineData).length, 2);
    assert.match(body.contents[0].parts[0].text, /Straight ahead/);
    return answer('Ease left (A), then straighten.');
  } });
  const response = await post();
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  const data = await response.json();
  assert.equal(data.instruction, 'Ease left (A), then straighten.');
  assert.equal(data.model, 'gemini-4-hydrogen');
  assert.ok(data.latency_ms >= 0);
  assert.equal(calls, 1);
  const config = await (await fetch(`${base}/config.js`)).text();
  assert.ok(!config.includes('secret-fixture'));
});
test('missing key, invalid images, oversized observations and foreign origins never call Gemini', async t => {
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
    calls++; return new Response(JSON.stringify({ error: { message: 'sensitive project info', details: [
      { '@type': 'type.googleapis.com/google.rpc.RetryInfo', retryDelay: '120s' }] } }), { status: 429 });
  } });
  const first = await post(); const data = await first.json();
  assert.equal(first.status, 429); assert.equal(data.retry_after, 120);
  assert.ok(!JSON.stringify(data).includes('sensitive'));
  assert.equal((await post()).status, 429); assert.equal(calls, 1);
});
test('access errors stop retries; truncated, empty and excessive replies are rejected', async t => {
  for (const result of [new Response('{}', { status: 403 }), answer(''), answer('x'.repeat(241)),
    new Response(JSON.stringify({ candidates: [{ finishReason: 'MAX_TOKENS', content: { parts: [{ text: 'Turn' }] } }] }))]) {
    const { post } = await fixture(t, { key: 'fixture', fetchImpl: async () => result });
    const response = await post(); assert.equal(response.status, 502);
    if (result.status === 403) assert.equal((await response.json()).permanent, true);
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
