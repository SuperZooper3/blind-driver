import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { WebSocket } from 'ws';
import { createRelay } from './index.mjs';
import { snapshotIssue, graphIssue } from './protocol.mjs';

async function setup(t, options = {}) {
  const relay = createRelay({ logger: () => {}, ...options });
  const address = await relay.listen(0, '127.0.0.1');
  const sockets = [];
  t.after(async () => { for (const socket of sockets) socket.terminate(); await relay.close(); });
  async function connect() {
    const socket = new WebSocket(`ws://127.0.0.1:${address.port}/ws`);
    sockets.push(socket);
    const inbox = [];
    const waiters = [];
    socket.on('message', data => {
      const message = JSON.parse(data);
      if (waiters.length) waiters.shift()(message); else inbox.push(message);
    });
    await once(socket, 'open');
    return {
      socket,
      send(message) { socket.send(JSON.stringify(message)); },
      async next() {
        if (inbox.length) return inbox.shift();
        return new Promise((resolve, reject) => {
          const timeout = setTimeout(() => reject(new Error('Timed out waiting for relay message')), 2000);
          waiters.push(message => { clearTimeout(timeout); resolve(message); });
        });
      },
    };
  }
  return { connect, port: address.port };
}

const state = { seq: 1, time: 1.2, position: [0, 1, 2], rotation: [0, 0, 0, 1], velocity: [0, 0, -5], speed: 5, steering: 0.2, throttle: 1, distance: 10, grounded: 4, reset: 0, lights: false };
const roads = [{ id: 0, parent: 0, depth: 0, heading: 0, expanded: false, points: [[0, 0, 0], [0, 0, -5]] }];

test('health endpoint works on the same port as WebSocket', async t => {
  const { port } = await setup(t);
  const response = await fetch(`http://127.0.0.1:${port}/healthz`);
  assert.equal(response.status, 200);
  const health = await response.json();
  assert.equal(health.ok, true);
  assert.equal(health.protocol, 2);
  assert.ok(health.instance);
  assert.equal((await fetch(`http://127.0.0.1:${port}/diagnostics`)).status, 200);
});

test('two seats relay state, reject a third, allow navigator rejoin, and close with driver', async t => {
  const { connect } = await setup(t);
  const driver = await connect();
  driver.send({ type: 'create', version: 2 });
  const created = await driver.next();
  assert.match(created.room, /^[A-F0-9]{18}$/);
  const navigator = await connect();
  navigator.send({ type: 'join', version: 2, room: created.room });
  assert.equal((await navigator.next()).type, 'joined');
  assert.equal((await driver.next()).type, 'navigator_joined');
  driver.send({ type: 'graph', roads });
  assert.deepEqual(await navigator.next(), { type: 'graph', roads });
  driver.send({ type: 'snapshot', state });
  assert.deepEqual(await navigator.next(), { type: 'snapshot', state });
  navigator.send({ type: 'snapshot', state });
  assert.equal((await navigator.next()).code, 'not_driver');
  const third = await connect();
  third.send({ type: 'join', version: 2, room: created.room });
  assert.equal((await third.next()).code, 'full');
  navigator.send({ type: 'leave' });
  assert.equal((await driver.next()).type, 'navigator_left');
  third.send({ type: 'join', version: 2, room: created.room });
  assert.equal((await third.next()).type, 'joined');
  assert.equal((await driver.next()).type, 'navigator_joined');
  driver.send({ type: 'leave' });
  assert.equal((await third.next()).type, 'room_closed');
});

test('rooms are isolated and malformed state is rejected', async t => {
  const { connect } = await setup(t);
  const first = await connect();
  const second = await connect();
  first.send({ type: 'create', version: 2 });
  second.send({ type: 'create', version: 2 });
  const one = await first.next();
  const two = await second.next();
  assert.notEqual(one.room, two.room);
  const navigator = await connect();
  navigator.send({ type: 'join', version: 2, room: two.room });
  await navigator.next();
  await second.next();
  first.send({ type: 'snapshot', state: { ...state, seq: 99 } });
  second.send({ type: 'snapshot', state });
  assert.equal((await navigator.next()).state.seq, 1);
  const closed = once(first.socket, 'close');
  first.send({ type: 'snapshot', state: { ...state, rotation: [0, 0, 0, 0] } });
  assert.equal((await closed)[0], 1008);
});

test('version, unknown rooms, capacity, and message rate limits', async t => {
  const { connect } = await setup(t, { maxRooms: 1 });
  const client = await connect();
  client.send({ type: 'create', version: 999 });
  assert.equal((await client.next()).code, 'version');
  client.send({ type: 'join', version: 2, room: '000000000000000000' });
  assert.equal((await client.next()).code, 'not_found');
  client.send({ type: 'create', version: 2 });
  assert.equal((await client.next()).type, 'created');
  const second = await connect();
  second.send({ type: 'create', version: 2 });
  assert.equal((await second.next()).code, 'capacity');
  const closed = once(client.socket, 'close');
  for (let i = 0; i < 110; i++) client.send({ type: 'snapshot', state });
  assert.equal((await closed)[0], 1008);
});

test('degenerate roads and oversized snapshots cannot be forwarded', async t => {
  const { connect } = await setup(t);
  for (const message of [
    { type: 'graph', roads: [{ ...roads[0], points: [[0, 0, 0], [0, 0, 0]] }] },
    { type: 'snapshot', state, padding: 'x'.repeat(4096) },
  ]) {
    const driver = await connect();
    driver.send({ type: 'create', version: 2 });
    await driver.next();
    const closed = once(driver.socket, 'close');
    driver.send(message);
    assert.equal((await closed)[0], 1008);
  }
});

test('both seats resume after transport loss, protect tokens, and replace stale sockets safely', async t => {
  const logs = [];
  const { connect } = await setup(t, { logger: entry => logs.push(entry) });
  const driver = await connect(); driver.send({ type: 'create', version: 2 });
  const created = await driver.next();
  const nav = await connect(); nav.send({ type: 'join', version: 2, room: created.room });
  const joined = await nav.next(); await driver.next();
  driver.socket.terminate();
  assert.equal((await nav.next()).type, 'peer_reconnecting');
  const replacement = await connect();
  replacement.send({ type: 'resume', version: 2, room: created.room, role: 'driver', token: '0'.repeat(64) });
  assert.equal((await replacement.next()).code, 'resume_expired');
  replacement.send({ type: 'resume', version: 2, room: created.room, role: 'driver', token: created.token });
  assert.equal((await replacement.next()).peer_connected, true);
  assert.equal((await nav.next()).type, 'peer_restored');
  replacement.send({ type: 'snapshot', state });
  assert.equal((await nav.next()).state.seq, 1);
  const nav2 = await connect();
  const oldClosed = once(nav.socket, 'close');
  nav2.send({ type: 'resume', version: 2, room: created.room, role: 'navigator', token: joined.token });
  assert.equal((await nav2.next()).type, 'resumed');
  assert.equal((await replacement.next()).type, 'navigator_joined');
  assert.equal((await oldClosed)[0], 4001);
  replacement.send({ type: 'graph', roads });
  assert.deepEqual((await nav2.next()).roads, roads);
  const serialized = JSON.stringify(logs);
  for (const secret of [created.room, created.token, joined.token]) assert.ok(!serialized.includes(secret));
  assert.ok(logs.some(entry => entry.event === 'seat_resumed'));
});

test('reservation expires and diagnostic connections echo without occupying rooms', async t => {
  const { connect } = await setup(t, { reconnectGrace: 60, heartbeatInterval: 20, heartbeatTimeout: 1000 });
  const driver = await connect(); driver.send({ type: 'create', version: 2 }); const created = await driver.next();
  const nav = await connect(); nav.send({ type: 'join', version: 2, room: created.room }); await nav.next(); await driver.next();
  nav.socket.terminate(); assert.equal((await driver.next()).type, 'peer_reconnecting');
  assert.equal((await driver.next()).type, 'navigator_left');
  const check = await connect(); check.send({ type: 'check', version: 2 });
  assert.equal((await check.next()).type, 'check_ready');
  check.send({ type: 'ping', id: 42 }); assert.deepEqual(await check.next(), { type: 'pong', id: 42 });
  const nav2 = await connect(); nav2.send({ type: 'join', version: 2, room: created.room });
  assert.equal((await nav2.next()).type, 'joined'); await driver.next();
  driver.socket.terminate(); assert.equal((await nav2.next()).type, 'peer_reconnecting');
  assert.equal((await nav2.next()).type, 'room_closed');
});

test('application traffic keeps a connection alive even if control pongs are lost; silent peers time out', async t => {
  const logs = [];
  const { port } = await setup(t, { heartbeatInterval: 20, heartbeatTimeout: 150, logger: x => logs.push(x) });
  const socket = new WebSocket(`ws://127.0.0.1:${port}/ws`, { autoPong: false });
  await once(socket, 'open');
  socket.send(JSON.stringify({ type: 'check', version: 2 }));
  let id = 0;
  const timer = setInterval(() => socket.send(JSON.stringify({ type: 'ping', id: ++id })), 30);
  t.after(() => { clearInterval(timer); socket.terminate(); });
  await new Promise(resolve => setTimeout(resolve, 350));
  assert.equal(socket.readyState, WebSocket.OPEN);
  clearInterval(timer);
  const closed = await once(socket, 'close');
  assert.equal(closed[0], 1006);
  assert.ok(logs.some(x => x.event === 'heartbeat_timeout'));
});

test('validation reports the failing field without including payload contents', () => {
  assert.equal(snapshotIssue({ ...state, rotation: [0, 0, 0, 0] }), 'rotation_normalization');
  assert.equal(snapshotIssue({ ...state, speed: Infinity }), 'speed');
  assert.equal(graphIssue([{ ...roads[0], points: [[0, 0, 0], [0, 0, 0]] }]), 'road[0].point[1].spacing');
});
