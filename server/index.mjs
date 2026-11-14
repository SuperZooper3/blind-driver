import http from 'node:http';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { performance } from 'node:perf_hooks';
import { pathToFileURL } from 'node:url';
import { WebSocketServer, WebSocket } from 'ws';
import { VERSION, MAX_PAYLOAD, isRecord, validSnapshot, validGraph, snapshotIssue, graphIssue, validPose, poseIssue, validDirect, normalizeLobby, normalizeShare, SHARE_ALPHABET, SHARE_LENGTH } from './protocol.mjs';

export function createRelay(options = {}) {
  const maxRooms = options.maxRooms ?? Number(process.env.MAX_ROOMS || 100);
  const maxConnections = options.maxConnections ?? Number(process.env.MAX_CONNECTIONS || 256);
  const waitingTimeout = options.waitingTimeout ?? 30 * 60 * 1000;
  const grace = options.reconnectGrace ?? 120000;
  const heartbeatInterval = options.heartbeatInterval ?? 10000;
  const heartbeatTimeout = options.heartbeatTimeout ?? 45000;
  const rooms = new Map();
  const lobbyRooms = new Map();
  const shareRooms = new Map();
  const newShareCode = () => {
    let code;
    do {
      code = [...randomBytes(SHARE_LENGTH)].map(byte => SHARE_ALPHABET[byte % SHARE_ALPHABET.length]).join('');
    } while (shareRooms.has(code));
    return code;
  };
  const clients = new Set();
  const instance = randomBytes(6).toString('hex');
  const started = performance.now();
  const logger = options.logger ?? (entry => console.log(JSON.stringify(entry)));
  const log = (event, client, detail = {}) => logger({ time: new Date().toISOString(), event, instance,
    ...(client ? { connection: client.id, role: client.role, room: rooms.get(client.room)?.id } : {}), ...detail });
  let admissions = [];
  let shuttingDown = false;
  const server = http.createServer((request, response) => {
    response.setHeader('Content-Type', 'application/json');
    response.setHeader('Cache-Control', 'no-store');
    if (request.method === 'GET' && request.url === '/healthz') {
      response.writeHead(shuttingDown ? 503 : 200);
      response.end(JSON.stringify({ ok: !shuttingDown, protocol: VERSION, instance, uptime_seconds: Math.floor((performance.now() - started) / 1000) }));
    } else if (request.method === 'GET' && request.url === '/diagnostics') {
      response.setHeader('Content-Type', 'text/html; charset=utf-8');
      response.setHeader('Content-Security-Policy', "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'");
      response.end(readFileSync(new URL('./diagnostics.html', import.meta.url)));
    } else if (request.method === 'GET' && request.url === '/') {
      response.end(JSON.stringify({ service: 'Blind Driver relay', protocol: VERSION, websocket: '/ws', health: '/healthz', diagnostics: '/diagnostics' }));
    } else {
      response.writeHead(404);
      response.end(JSON.stringify({ error: 'not_found' }));
    }
  });
  server.headersTimeout = 10000;
  server.requestTimeout = 10000;
  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_PAYLOAD, perMessageDeflate: false });

  // `droppable` messages are skipped once this many bytes are already queued to a slow
  // navigator: the next one supersedes them, and a backlog only adds delay.
  const send = (client, message, droppable = 0) => {
    if (!client || client.socket.readyState !== WebSocket.OPEN) return false;
    if (droppable && client.socket.bufferedAmount > droppable) { client.dropped++; return false; }
    if (client.socket.bufferedAmount > MAX_PAYLOAD * 2) {
      log('backpressure_close', client, { buffered_bytes: client.socket.bufferedAmount });
      client.socket.close(1013, 'Connection too slow');
      return false;
    }
    const data = JSON.stringify(message);
    client.sent++; client.sentBytes += Buffer.byteLength(data);
    client.socket.send(data);
    return true;
  };
  const fail = (client, code, message) => {
    log('request_rejected', client, { code });
    send(client, { type: 'error', code, message });
  };
  const reject = (client, reason, detail = {}) => {
    log('protocol_rejected', client, { reason, ...detail });
    client.socket.close(1008, reason);
  };
  const otherRole = role => role === 'driver' ? 'navigator' : 'driver';
  const closeRoom = (code, reason) => {
    const room = rooms.get(code);
    if (!room) return;
    log('room_closed', null, { room: room.id, reason });
    rooms.delete(code);
    if (room.lobby) lobbyRooms.delete(room.lobby);
    shareRooms.delete(room.share);
    for (const role of ['driver', 'navigator']) {
      const client = room[role]?.client;
      send(client, { type: 'room_closed', message: reason });
      client?.socket.close(1000, 'Room ended');
    }
  };
  const detach = (client, intentional = false) => {
    const room = rooms.get(client.room);
    const seat = room?.[client.role];
    if (!seat || seat.client !== client) return; // Replaced socket cannot detach its replacement.
    seat.client = null;
    seat.deadline = performance.now() + grace;
    if (intentional) {
      if (client.role === 'driver') { closeRoom(client.room, 'The driver left. Join your saved lobby again for another ride.'); return; }
      room.navigator = null;
      if (!room.driver) { closeRoom(client.room, 'Room closed.'); return; }
      room.waitingSince = performance.now();
    }
    send(room[otherRole(client.role)]?.client, { type: intentional ? 'navigator_left' : 'peer_reconnecting', role: client.role, grace_seconds: grace / 1000 });
    log(intentional ? 'seat_left' : 'seat_reserved', client, { grace_ms: intentional ? 0 : grace });
    client.room = null;
  };
  // `build` is the game's PROTOTYPE number, passed to the partner so mismatches show in-game.
  const seat = client => ({ client, token: randomBytes(32).toString('hex'), deadline: Infinity, build: client.build });
  const replySeat = (client, type) => {
    const room = rooms.get(client.room);
    send(client, { type, room: client.room, share: room.share, version: VERSION, token: room[client.role].token,
      role: client.role, connection: client.id, instance, peer_connected: !!room[otherRole(client.role)]?.client, partner_build: room[otherRole(client.role)]?.build ?? null, grace_seconds: grace / 1000 });
  };
  const notifyReady = (room, role) => {
    const build = room[role]?.build ?? null;
    if (role === 'navigator') send(room.driver?.client, { type: 'navigator_joined', partner_build: build });
    else if (room.navigator?.client) send(room.navigator.client, { type: 'peer_restored', role: 'driver', partner_build: build });
  };

  server.on('upgrade', (request, socket, head) => {
    const now = performance.now();
    admissions = admissions.filter(time => now - time < 60000);
    if (request.url !== '/ws' || shuttingDown || clients.size >= maxConnections || admissions.length >= 240) {
      log('upgrade_rejected', null, { reason: shuttingDown ? 'shutdown' : 'path_or_capacity' });
      socket.end('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n');
      return;
    }
    admissions.push(now);
    wss.handleUpgrade(request, socket, head, websocket => wss.emit('connection', websocket));
  });

  wss.on('connection', socket => {
    const now = performance.now();
    const client = { socket, id: randomBytes(6).toString('hex'), room: null, role: null, lastSeen: now, opened: now,
      budgetAt: now, budget: 100, byteBudget: MAX_PAYLOAD * 4, graphBudget: 8, attempts: 0,
      received: 0, receivedBytes: 0, sent: 0, sentBytes: 0, dropped: 0, rtt: null, pingAt: 0, lastSummary: now };
    clients.add(client);
    log('connected', client);
    socket.on('error', error => { log('socket_error', client, { code: error.code ?? 'socket_error' }); socket.terminate(); });
    socket.on('close', (code, reason) => {
      // Do not log arbitrary peer-controlled close text: it can contain a room code or token.
      log('disconnected', client, { code, peer_reason_bytes: reason.length, duration_ms: Math.round(performance.now() - client.opened),
        received: client.received, sent: client.sent, dropped: client.dropped });
      clients.delete(client);
      detach(client);
    });
    socket.on('pong', () => { client.lastSeen = performance.now(); if (client.pingAt) client.rtt = Math.round(client.lastSeen - client.pingAt); });
    socket.on('message', (raw, binary) => {
      const now = performance.now();
      const seconds = (now - client.budgetAt) / 1000;
      // Token buckets tolerate packet bursts after jitter without accepting unbounded floods.
      // Drivers send ~30 poses + 10 snapshots + heartbeats per second.
      client.budget = Math.min(100, client.budget + seconds * 60) - 1;
      client.byteBudget = Math.min(MAX_PAYLOAD * 4, client.byteBudget + seconds * MAX_PAYLOAD * 3) - raw.length;
      client.graphBudget = Math.min(8, client.graphBudget + seconds * 4);
      client.budgetAt = now;
      client.received++; client.receivedBytes += raw.length;
      if (binary || client.budget < 0 || client.byteBudget < 0) { reject(client, 'Message limit exceeded', { bytes: raw.length }); return; }
      let message;
      try { message = JSON.parse(raw.toString()); } catch { reject(client, 'Invalid JSON'); return; }
      if (!isRecord(message)) { reject(client, 'Invalid message'); return; }
      if (message.type === 'ping') {
        if (!Number.isSafeInteger(message.id) || message.id < 0 || raw.length > 128) { reject(client, 'Invalid heartbeat'); return; }
        client.lastSeen = now;
        send(client, { type: 'pong', id: message.id });
        return;
      }
      if (['create', 'join', 'resume', 'check'].includes(message.type)) {
        client.build = Number.isSafeInteger(message.build) && message.build >= 0 && message.build <= 9999 ? message.build : null;
        if (++client.attempts > 8) { reject(client, 'Too many room attempts'); return; }
        if (client.room || client.role === 'check') { fail(client, 'already_joined', 'Leave the current session first.'); return; }
        if (message.version !== VERSION) { fail(client, 'version', 'Game and relay versions differ. Deploy the updated relay and update both games.'); return; }
        client.lastSeen = now;
        if (message.type === 'check') {
          client.role = 'check';
          send(client, { type: 'check_ready', version: VERSION, instance, connection: client.id });
          log('check_started', client);
          return;
        }
        const named = message.type !== 'resume' && message.lobby !== undefined;
        const lobby = named ? normalizeLobby(message.lobby) : null;
        if (named && !lobby) { fail(client, 'lobby_name', 'Use 3–40 letters, numbers, spaces, or hyphens for the lobby name.'); return; }
        const typed = typeof message.room === 'string' ? message.room.replaceAll('-', '').trim().toUpperCase() : '';
        const code = named ? lobbyRooms.get(lobby) : (shareRooms.get(normalizeShare(typed)) ?? typed);
        // The room's creator may take either seat; the friend who joins gets the other.
        const creatorSeat = message.type === 'create' && !named && message.seat === 'navigator' ? 'navigator' : 'driver';
        let room = /^[A-F0-9]{18}$/.test(code ?? '') ? rooms.get(code) : null;
        if (message.type === 'create' || (named && message.type === 'join' && !room)) {
          if (room?.driver && message.type === 'create') {
            fail(client, 'driver_taken', 'This lobby already has a driver, or their connection is recovering. Choose Navigate or another lobby name.'); return;
          }
          if (!room) {
            if (rooms.size >= maxRooms) { fail(client, 'capacity', 'Server is full. Try again later.'); return; }
            let newCode;
            do { newCode = randomBytes(9).toString('hex').toUpperCase(); } while (rooms.has(newCode));
            room = { id: randomBytes(6).toString('hex'), code: newCode, share: newShareCode(), lobby, driver: null, navigator: null, waitingSince: now };
            rooms.set(newCode, room);
            shareRooms.set(room.share, newCode);
            if (lobby) lobbyRooms.set(lobby, newCode);
          }
          client.room = room.code; client.role = message.type === 'create' ? creatorSeat : 'navigator';
          room[client.role] = seat(client);
          replySeat(client, message.type === 'create' ? 'created' : 'joined');
          notifyReady(room, client.role);
          log(message.type === 'create' ? 'room_created' : 'seat_waiting', client);
        } else if (message.type === 'resume') {
          const reserved = room && ['driver', 'navigator'].includes(message.role) ? room[message.role] : null;
          const token = typeof message.token === 'string' && /^[a-f0-9]{64}$/.test(message.token) ? message.token : '';
          if (!reserved || reserved.deadline <= now || token.length !== reserved.token.length || !timingSafeEqual(Buffer.from(token), Buffer.from(reserved.token))) {
            fail(client, 'resume_expired', 'The room cannot be restored (server restarted or recovery time expired). Create a new room.'); return;
          }
          const previous = reserved.client;
          client.room = code; client.role = message.role;
          reserved.client = client; reserved.deadline = Infinity; reserved.build = client.build;
          previous?.socket.close(4001, 'Session resumed elsewhere');
          replySeat(client, 'resumed'); notifyReady(room, client.role); log('seat_resumed', client);
        } else {
          if (!room) { fail(client, 'not_found', 'Room not found. Check the code with your friend, or create a new room.'); return; }
          const free = !room.driver ? 'driver' : (!room.navigator ? 'navigator' : null);
          if (!free) { fail(client, 'full', 'This room already has two players (or one is reconnecting). Wait or create a new room.'); return; }
          client.room = room.code; client.role = free; room[free] = seat(client);
          replySeat(client, 'joined'); notifyReady(room, client.role); log('seat_joined', client);
        }
        return;
      }
      if (message.type === 'leave') { detach(client, true); socket.close(1000, 'Left room'); return; }
      if (message.type === 'direct') {
        // Either player may offer a direct local-network link; only the partner sees it.
        const room = rooms.get(client.room);
        if (!room || room[client.role]?.client !== client || raw.length > 1024 || !validDirect(message)) { reject(client, 'Invalid direct offer'); return; }
        const { on, reply, addrs = [], port = 0, key = '' } = message;
        send(room[otherRole(client.role)]?.client, { type: 'direct', on, reply, addrs, port, key });
        log('direct_offer', client, { on, addresses: addrs.length });
        return;
      }
      if (message.type === 'swap') {
        // Either player may swap seats, but only while both are connected.
        const room = rooms.get(client.room);
        if (!room || room[client.role]?.client !== client || !room.driver?.client || !room.navigator?.client) {
          fail(client, 'swap_unavailable', 'Both players need to be connected to swap seats.'); return;
        }
        [room.driver, room.navigator] = [room.navigator, room.driver];
        for (const role of ['driver', 'navigator']) {
          room[role].client.role = role;
          send(room[role].client, { type: 'seat_swapped', role });
        }
        log('seats_swapped', client);
        return;
      }
      if (client.role !== 'driver') { fail(client, 'not_driver', 'Only the driver can send game state.'); return; }
      const room = rooms.get(client.room);
      if (!room || room.driver.client !== client) return;
      if (message.type === 'pose' && raw.length <= 1024 && validPose(message.state)) {
        client.lastSeen = now;
        send(room.navigator?.client, message, 16384);
      } else if (message.type === 'snapshot' && raw.length <= 4096 && validSnapshot(message.state)) {
        client.lastSeen = now;
        send(room.navigator?.client, message, 65536);
      } else if (message.type === 'graph' && --client.graphBudget >= 0 && validGraph(message.roads)) {
        client.lastSeen = now;
        send(room.navigator?.client, message);
      } else {
        reject(client, 'Invalid game state', { kind: ['graph', 'snapshot', 'pose'].includes(message.type) ? message.type : 'unknown', bytes: raw.length,
          validation: message.type === 'pose' ? (raw.length > 1024 ? 'pose_size' : poseIssue(message.state))
            : message.type === 'snapshot' ? (raw.length > 4096 ? 'snapshot_size' : snapshotIssue(message.state)) : (client.graphBudget < 0 ? 'graph_rate' : graphIssue(message.roads)) });
      }
    });
  });

  let lastSweep = performance.now();
  const sweep = setInterval(() => {
    const now = performance.now();
    if (now - lastSweep > heartbeatInterval + 2000) log('event_loop_delay', null, { delay_ms: Math.round(now - lastSweep - heartbeatInterval) });
    lastSweep = now;
    for (const client of clients) {
      const age = now - client.lastSeen;
      if (age > heartbeatTimeout || (!client.role && now - client.opened > 90000)) {
        log('heartbeat_timeout', client, { silent_ms: Math.round(age) });
        client.socket.terminate(); continue;
      }
      if (client.socket.readyState === WebSocket.OPEN) { client.pingAt = now; client.socket.ping(); }
      if (now - client.lastSummary >= (options.summaryInterval ?? 30000)) {
        log('connection_summary', client, { rtt_ms: client.rtt, silent_ms: Math.round(age), received: client.received, sent: client.sent,
          received_bytes: client.receivedBytes, sent_bytes: client.sentBytes, dropped: client.dropped, buffered_bytes: client.socket.bufferedAmount });
        client.lastSummary = now;
      }
    }
    for (const [code, room] of rooms) {
      if (room.driver && room.driver.deadline <= now) { closeRoom(code, 'Driver did not return within the recovery window. Create a new room.'); continue; }
      if (room.navigator && room.navigator.deadline <= now) {
        log('seat_expired', null, { room: room.id, role: 'navigator' });
        room.navigator = null; room.waitingSince = now;
        send(room.driver?.client, { type: 'navigator_left' });
      }
      if (!room.driver && !room.navigator) { closeRoom(code, 'Lobby empty.'); continue; }
      if ((!room.driver || !room.navigator) && now - room.waitingSince > waitingTimeout) closeRoom(code, 'Empty room expired. Create a new room.');
    }
  }, heartbeatInterval);
  sweep.unref();

  return {
    server,
    async listen(port = Number(process.env.PORT || 10000), host = '0.0.0.0') {
      await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, host, resolve); });
      log('listening', null, { protocol: VERSION, port: server.address().port });
      return server.address();
    },
    async close() {
      shuttingDown = true; clearInterval(sweep); log('shutdown');
      for (const client of clients) {
        send(client, { type: 'room_closed', message: 'Server restarting. Create a new room after the server returns.' });
        client.socket.close(1012, 'Service restart');
      }
      const force = setTimeout(() => { for (const client of clients) client.socket.terminate(); }, 1000);
      force.unref();
      await new Promise(resolve => server.close(resolve));
      clearTimeout(force); wss.close();
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
    await relay.close(); process.exit(0);
  });
}
