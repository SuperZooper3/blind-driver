// Test-only loopback proxy. Never deployed with the relay.
import { createRequire } from 'node:module';
import { createRelay } from '../server/index.mjs';
const { WebSocket, WebSocketServer } = createRequire(new URL('../server/package.json', import.meta.url))('ws');
const relay = createRelay();
const address = await relay.listen(0, '127.0.0.1');
const proxy = new WebSocketServer({ host: '127.0.0.1', port: 0, perMessageDeflate: false });
const links = new Set();
let scheduled = false;
const timers = [];
proxy.on('connection', down => {
  const up = new WebSocket(`ws://127.0.0.1:${address.port}/ws`);
  const link = { down, up, role: '', blocked: false };
  links.add(link);
  const queued = [];
  up.on('open', () => { for (const data of queued) up.send(data); queued.length = 0; });
  down.on('message', raw => {
    const message = JSON.parse(raw);
    if (message.type === 'create') link.role = 'driver';
    if (message.type === 'join') link.role = 'navigator';
    if (message.type === 'resume') link.role = message.role;
    if (link.role === 'navigator' && !scheduled) {
      scheduled = true;
      timers.push(setTimeout(() => cut('driver'), 12000));
      timers.push(setTimeout(() => cut('navigator'), 28000));
      timers.push(setTimeout(() => {
        for (const current of links) if (current.role === 'driver') current.blocked = true;
        console.log('FAULT: driver connection blackholed until client abandons it');
      }, 42000));
    }
    if (link.blocked) return;
    if (up.readyState === WebSocket.OPEN) up.send(raw.toString());
    else if (up.readyState === WebSocket.CONNECTING) queued.push(raw.toString());
  });
  up.on('message', raw => { if (!link.blocked && down.readyState === WebSocket.OPEN) down.send(raw.toString()); });
  down.on('close', () => { links.delete(link); up.terminate(); });
  up.on('close', (code, reason) => { if (code === 1006) down.terminate(); else down.close(code, reason); });
  down.on('error', () => down.terminate()); up.on('error', () => up.terminate());
});
function cut(role) {
  for (const link of links) if (link.role === role) { link.down.terminate(); link.up.terminate(); }
  console.log('FAULT: terminated ' + role);
}
proxy.on('listening', () => console.log(`listening on 127.0.0.1:${proxy.address().port}`));
process.on('SIGTERM', async () => {
  for (const timer of timers) clearTimeout(timer);
  for (const link of links) { link.down.terminate(); link.up.terminate(); }
  proxy.close(); await relay.close(); process.exit(0);
});
