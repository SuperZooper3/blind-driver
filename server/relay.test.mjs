import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { WebSocket } from 'ws';
import { createRelay } from './index.mjs';

async function setup(t, options = {}) {
  const relay = createRelay(options);
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
  assert.deepEqual(await response.json(), { ok: true, protocol: 1 });
});

test('two seats relay state, reject a third, allow navigator rejoin, and close with driver', async t => {
  const { connect } = await setup(t);
  const driver = await connect();
  driver.send({ type: 'create', version: 1 });
  const created = await driver.next();
  assert.match(created.room, /^[A-F0-9]{18}$/);
  const navigator = await connect();
  navigator.send({ type: 'join', version: 1, room: created.room });
  assert.equal((await navigator.next()).type, 'joined');
  assert.equal((await driver.next()).type, 'navigator_joined');
  driver.send({ type: 'graph', roads });
  assert.deepEqual(await navigator.next(), { type: 'graph', roads });
  driver.send({ type: 'snapshot', state });
  assert.deepEqual(await navigator.next(), { type: 'snapshot', state });
  navigator.send({ type: 'snapshot', state });
  assert.equal((await navigator.next()).code, 'not_driver');
  const third = await connect();
  third.send({ type: 'join', version: 1, room: created.room });
  assert.equal((await third.next()).code, 'full');
  navigator.socket.close();
  assert.equal((await driver.next()).type, 'navigator_left');
  third.send({ type: 'join', version: 1, room: created.room });
  assert.equal((await third.next()).type, 'joined');
  assert.equal((await driver.next()).type, 'navigator_joined');
  driver.socket.close();
  assert.equal((await third.next()).type, 'room_closed');
});

test('rooms are isolated and malformed state is rejected', async t => {
  const { connect } = await setup(t);
  const first = await connect();
  const second = await connect();
  first.send({ type: 'create', version: 1 });
  second.send({ type: 'create', version: 1 });
  const one = await first.next();
  const two = await second.next();
  assert.notEqual(one.room, two.room);
  const navigator = await connect();
  navigator.send({ type: 'join', version: 1, room: two.room });
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
  client.send({ type: 'join', version: 1, room: '000000000000000000' });
  assert.equal((await client.next()).code, 'not_found');
  client.send({ type: 'create', version: 1 });
  assert.equal((await client.next()).type, 'created');
  const second = await connect();
  second.send({ type: 'create', version: 1 });
  assert.equal((await second.next()).code, 'capacity');
  const closed = once(client.socket, 'close');
  for (let i = 0; i < 55; i++) client.send({ type: 'snapshot', state });
  assert.equal((await closed)[0], 1008);
});

test('degenerate roads and oversized snapshots cannot be forwarded', async t => {
  const { connect } = await setup(t);
  for (const message of [
    { type: 'graph', roads: [{ ...roads[0], points: [[0, 0, 0], [0, 0, 0]] }] },
    { type: 'snapshot', state, padding: 'x'.repeat(4096) },
  ]) {
    const driver = await connect();
    driver.send({ type: 'create', version: 1 });
    await driver.next();
    const closed = once(driver.socket, 'close');
    driver.send(message);
    assert.equal((await closed)[0], 1008);
  }
});
