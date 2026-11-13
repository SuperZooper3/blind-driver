import { WebSocket } from 'ws';
import { performance } from 'node:perf_hooks';
import { VERSION } from './protocol.mjs';

// npm run check -- https://your-relay.onrender.com 75
const input = process.argv[2];
if (!input) { console.error('Usage: npm run check -- https://your-relay.onrender.com [seconds=75]'); process.exit(2); }
let url;
try {
  url = new URL(input);
  if (!['http:', 'https:', 'ws:', 'wss:'].includes(url.protocol) || url.username || url.password) throw Error();
  url.protocol = ['https:', 'wss:'].includes(url.protocol) ? 'wss:' : 'ws:';
  if (url.pathname === '/') url.pathname = '/ws';
} catch { console.error('Enter a valid HTTP(S) or WS(S) relay URL without credentials.'); process.exit(2); }
const seconds = Number(process.argv[3] ?? 75);
if (!Number.isFinite(seconds) || seconds < 10 || seconds > 600) { console.error('Duration must be between 10 and 600 seconds.'); process.exit(2); }
const log = (event, fields = {}) => console.log(JSON.stringify({ time: new Date().toISOString(), event, ...fields }));
const pending = new Map(), rtts = [];
let started = 0, sent = 0, missed = 0, finished = false;
const socket = new WebSocket(url, { handshakeTimeout: 90000, maxPayload: 4096, perMessageDeflate: false });
const deadline = setTimeout(() => finish('handshake_timeout', 1), 95000);
let timer;
function finish(reason, code) {
  if (finished) return;
  finished = true; clearTimeout(deadline); clearInterval(timer);
  missed += pending.size;
  rtts.sort((a, b) => a - b);
  const percentile = p => Math.round(rtts[Math.max(0, Math.ceil(rtts.length * p) - 1)] ?? 0);
  const clean = missed === 0 && rtts.length >= (seconds - 5) * .8;
  log('check_finished', { reason, sent, replies: rtts.length, missed, median_ms: percentile(.5), p95_ms: percentile(.95), uninterrupted: clean && code === 0 });
  process.exitCode = code || (clean ? 0 : 1);
  socket.close(1000, 'Check complete');
  const force = setTimeout(() => socket.terminate(), 1000); force.unref();
}
socket.on('open', () => { log('socket_open'); socket.send(JSON.stringify({ type: 'check', version: VERSION })); });
socket.on('error', error => { log('socket_error', { code: error.code ?? 'connection_failed' }); finish('socket_error', 1); });
socket.on('close', (code, reason) => { log('socket_closed', { code, reason: reason.toString() }); if (!finished) finish('disconnected', 1); });
socket.on('message', raw => {
  let message;
  try { message = JSON.parse(raw); } catch { finish('invalid_response', 1); return; }
  if (message.type === 'error' || message.type === 'room_closed') { log('server_error', { code: message.code, message: message.message }); finish('server_rejected', 1); return; }
  if (message.type === 'check_ready' && !started) {
    if (message.version !== VERSION) { finish('protocol_mismatch', 1); return; }
    clearTimeout(deadline); started = performance.now();
    log('check_ready', { instance: message.instance, connection: message.connection, duration_seconds: seconds });
    timer = setInterval(() => {
      const now = performance.now();
      for (const [id, at] of pending) if (now - at > 5000) { pending.delete(id); missed++; log('probe_missed', { id }); }
      if (now - started >= seconds * 1000) { finish('complete', 0); return; }
      if (now - started < (seconds - 5) * 1000) { pending.set(++sent, now); socket.send(JSON.stringify({ type: 'ping', id: sent })); }
    }, 1000);
  }
  if (message.type === 'pong' && pending.has(message.id)) {
    const rtt = performance.now() - pending.get(message.id); pending.delete(message.id); rtts.push(rtt);
    log('sample', { rtt_ms: Math.round(rtt) });
  }
});
