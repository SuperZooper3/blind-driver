import http from 'node:http';
import { randomBytes } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { WebSocketServer, WebSocket } from 'ws';
import { VERSION, MAX_PAYLOAD, isRecord, validSnapshot, validGraph } from './protocol.mjs';

export function createRelay(options = {}) {
  const maxRooms = options.maxRooms ?? Number(process.env.MAX_ROOMS || 100);
  const maxConnections = options.maxConnections ?? Number(process.env.MAX_CONNECTIONS || 256);
  const waitingTimeout = options.waitingTimeout ?? 30 * 60 * 1000;
  const rooms = new Map();
  const clients = new Set();
  // A global rolling admission limit also bounds abuse behind Render's proxy,
  // without trusting a client-supplied X-Forwarded-For header.
  let admissions = [];
  let shuttingDown = false;
  const server = http.createServer((request, response) => {
    response.setHeader('Content-Type', 'application/json');
    response.setHeader('Cache-Control', 'no-store');
    if (request.method === 'GET' && request.url === '/healthz') {
      response.writeHead(shuttingDown ? 503 : 200);
      response.end(JSON.stringify({ ok: !shuttingDown, protocol: VERSION }));
    } else if (request.method === 'GET' && request.url === '/') {
      response.end(JSON.stringify({ service: 'Blind Driver relay', protocol: VERSION, websocket: '/ws', health: '/healthz' }));
    } else {
      response.writeHead(404);
      response.end(JSON.stringify({ error: 'not_found' }));
    }
  });
  server.headersTimeout = 10000;
  server.requestTimeout = 10000;
  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_PAYLOAD, perMessageDeflate: false });

  const send = (client, message, droppable = false) => {
    if (!client || client.socket.readyState !== WebSocket.OPEN) return;
    if (droppable && client.socket.bufferedAmount > 65536) return;
    if (client.socket.bufferedAmount > MAX_PAYLOAD * 2) {
      client.socket.close(1013, 'Connection too slow');
      return;
    }
    client.socket.send(JSON.stringify(message));
  };
  const fail = (client, code, message) => send(client, { type: 'error', code, message });
  const remove = client => {
    if (!clients.delete(client)) return;
    const room = rooms.get(client.room);
    if (!room) return;
    if (room.driver === client) {
      rooms.delete(client.room);
      send(room.navigator, { type: 'room_closed', message: 'Driver left. Create a new room to restart.' });
      room.navigator?.socket.close(1000, 'Driver left');
    } else if (room.navigator === client) {
      room.navigator = null;
      room.waitingSince = Date.now();
      send(room.driver, { type: 'navigator_left' });
    }
  };

  server.on('upgrade', (request, socket, head) => {
    admissions = admissions.filter(time => Date.now() - time < 60000);
    if (request.url !== '/ws' || shuttingDown || clients.size >= maxConnections || admissions.length >= 120) {
      socket.end('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n');
      return;
    }
    admissions.push(Date.now());
    wss.handleUpgrade(request, socket, head, websocket => wss.emit('connection', websocket));
  });

  wss.on('connection', socket => {
    const client = { socket, room: null, role: null, alive: true, opened: Date.now(), window: Date.now(), count: 0, graphs: 0, bytes: 0, attempts: 0 };
    clients.add(client);
    socket.on('error', () => { socket.terminate(); remove(client); });
    socket.on('close', () => remove(client));
    socket.on('pong', () => { client.alive = true; });
    socket.on('message', (raw, binary) => {
      if (Date.now() - client.window >= 1000) {
        client.window = Date.now(); client.count = 0; client.graphs = 0; client.bytes = 0;
      }
      client.count += 1;
      client.bytes += raw.length;
      if (binary || client.count > 50 || client.bytes > MAX_PAYLOAD * 3) {
        socket.close(1008, 'Message limit exceeded');
        return;
      }
      let message;
      try { message = JSON.parse(raw.toString()); } catch { socket.close(1008, 'Invalid JSON'); return; }
      if (!isRecord(message)) { socket.close(1008, 'Invalid message'); return; }
      if (message.type === 'create' || message.type === 'join') {
        if (++client.attempts > 8) { socket.close(1008, 'Too many room attempts'); return; }
        if (client.room) { fail(client, 'already_joined', 'Leave the current room first.'); return; }
        if (message.version !== VERSION) { fail(client, 'version', 'Game and relay versions differ. Update the game.'); return; }
        if (message.type === 'create') {
          if (rooms.size >= maxRooms) { fail(client, 'capacity', 'Server is full. Try again later.'); return; }
          let code;
          do { code = randomBytes(9).toString('hex').toUpperCase(); } while (rooms.has(code));
          client.room = code; client.role = 'driver';
          rooms.set(code, { driver: client, navigator: null, waitingSince: Date.now() });
          send(client, { type: 'created', room: code, version: VERSION });
        } else {
          const code = typeof message.room === 'string' ? message.room.replaceAll('-', '').trim().toUpperCase() : '';
          const room = /^[A-F0-9]{18}$/.test(code) ? rooms.get(code) : null;
          if (!room) { fail(client, 'not_found', 'Room not found. Check the code or ask the driver to create a room.'); return; }
          if (room.navigator) { fail(client, 'full', 'Both seats are already taken.'); return; }
          client.room = code; client.role = 'navigator'; room.navigator = client;
          send(client, { type: 'joined', room: code, version: VERSION });
          send(room.driver, { type: 'navigator_joined' });
        }
        return;
      }
      if (client.role !== 'driver') { fail(client, 'not_driver', 'Only the driver can send game state.'); return; }
      const room = rooms.get(client.room);
      if (!room) return;
      if (message.type === 'snapshot' && validSnapshot(message.state)) {
        send(room.navigator, message, true);
      } else if (message.type === 'graph' && ++client.graphs <= 4 && validGraph(message.roads)) {
        send(room.navigator, message);
      } else {
        socket.close(1008, 'Invalid game state');
      }
    });
  });

  const sweep = setInterval(() => {
    const now = Date.now();
    for (const client of clients) {
      if (!client.alive || (!client.room && now - client.opened > 30000)) {
        client.socket.terminate(); remove(client); continue;
      }
      client.alive = false;
      if (client.socket.readyState === WebSocket.OPEN) client.socket.ping();
    }
    for (const room of rooms.values()) {
      if (!room.navigator && now - room.waitingSince > waitingTimeout) {
        send(room.driver, { type: 'room_closed', message: 'Empty room expired. Create a new room.' });
        room.driver.socket.close(1000, 'Room expired');
      }
    }
  }, options.heartbeatInterval ?? 15000);
  sweep.unref();

  return {
    server,
    async listen(port = Number(process.env.PORT || 10000), host = '0.0.0.0') {
      await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, host, resolve); });
      return server.address();
    },
    async close() {
      shuttingDown = true;
      clearInterval(sweep);
      for (const client of clients) {
        send(client, { type: 'room_closed', message: 'Server restarting. Reconnect and create a new room.' });
        client.socket.close(1012, 'Service restart');
      }
      const force = setTimeout(() => { for (const client of clients) client.socket.terminate(); }, 1000);
      force.unref();
      await new Promise(resolve => server.close(resolve));
      clearTimeout(force);
      wss.close();
    },
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const relay = createRelay();
  const address = await relay.listen(undefined, process.env.HOST || '0.0.0.0');
  console.log(`Blind Driver relay listening on ${address.address}:${address.port}; protocol ${VERSION}`);
  let stopping = false;
  for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, async () => {
    if (stopping) return;
    stopping = true;
    await relay.close();
    process.exit(0);
  });
}
