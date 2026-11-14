// Test-only loopback proxy that reproduces a bad internet path to the navigator.
// Never deployed with the relay. Modelled on measurements against the hosted
// relay: ~45 ms one way with jitter, and every few seconds a stall of 150-750 ms
// after which the queued messages arrive in a burst, in order (TCP behaviour).
// Seeded, so every run sees the same hiccups.
import { createRequire } from 'node:module';
import { createRelay } from '../server/index.mjs';
const { WebSocket, WebSocketServer } = createRequire(new URL('../server/package.json', import.meta.url))('ws');

let seed = Number(process.env.JITTER_SEED || 7);
const random = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
const relay = createRelay();
const address = await relay.listen(0, '127.0.0.1');
const proxy = new WebSocketServer({ host: '127.0.0.1', port: 0, perMessageDeflate: false });
const links = new Set();

proxy.on('connection', down => {
  const up = new WebSocket(`ws://127.0.0.1:${address.port}/ws`);
  const link = { down, up, role: '', releaseAt: 0, stallUntil: 0, nextStall: performance.now() + 2000 + random() * 3000 };
  links.add(link);
  const queued = [];
  up.on('open', () => { for (const data of queued) up.send(data); queued.length = 0; });
  down.on('message', raw => {
    const message = JSON.parse(raw);
    if (message.type === 'create' || message.type === 'join') link.role = message.type;
    if (up.readyState === WebSocket.OPEN) up.send(raw.toString());
    else if (up.readyState === WebSocket.CONNECTING) queued.push(raw.toString());
  });
  up.on('message', raw => {
    const data = raw.toString();
    // Only the joining (navigator) side gets the bad path; the driver's own game is local.
    if (link.role !== 'join') { if (down.readyState === WebSocket.OPEN) down.send(data); return; }
    const now = performance.now();
    if (now >= link.nextStall) {
      link.stallUntil = now + 150 + random() * 600;
      link.nextStall = now + 2000 + random() * 3000;
    }
    const delay = 40 + random() * 25 + (random() < 0.1 ? random() * 70 : 0);
    // In order: nothing overtakes a stalled message.
    link.releaseAt = Math.max(link.releaseAt, now + delay, link.stallUntil);
    setTimeout(() => { if (down.readyState === WebSocket.OPEN) down.send(data); }, link.releaseAt - now);
  });
  down.on('close', () => { links.delete(link); up.terminate(); });
  up.on('close', (code, reason) => { if (code === 1006) down.terminate(); else down.close(code, reason); });
  down.on('error', () => down.terminate()); up.on('error', () => up.terminate());
});
proxy.on('listening', () => console.log(`listening on 127.0.0.1:${proxy.address().port}`));
process.on('SIGTERM', async () => {
  for (const link of links) { link.down.terminate(); link.up.terminate(); }
  proxy.close(); await relay.close(); process.exit(0);
});
