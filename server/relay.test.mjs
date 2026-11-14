import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { WebSocket } from 'ws';
import { createRelay } from './index.mjs';
import { snapshotIssue, graphIssue, poseIssue } from './protocol.mjs';

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

const state = { challenge_time: 0, seq: 1, time: 1.2, position: [0, 1, 2], rotation: [0, 0, 0, 1], velocity: [0, 0, -5], speed: 5, steering: 0.2, throttle: 1, distance: 10, grounded: 4, reset: 0, lights: false, angular_velocity: [0, 0, 0], wheels: [-0.4, -0.4, -0.4, -0.4], run_state: 'driving', crash_reason: '', run_id: 0, on_road: true, impact: 0, tires: 0, police: { position: [0, 1, 90], rotation: [0, 0, 0, 1], phase: 'waiting', elapsed: 0, speed: 0, gap: 85, closing: 0, catch: 0, paused: true } };
const roads = [{ profile: 'main', level: 0, next: -1, merge_with: -1, id: 0, parent: 0, depth: 0, heading: 0, expanded: false, danger: false, hazards: [], points: [[0, 0, 0], [0, 0, -5]] }];

test('health endpoint works on the same port as WebSocket', async t => {
  const { port } = await setup(t);
  const response = await fetch(`http://127.0.0.1:${port}/healthz`);
  assert.equal(response.status, 200);
  const health = await response.json();
  assert.equal(health.ok, true);
  assert.equal(health.protocol, 9);
  assert.ok(health.instance);
  assert.equal((await fetch(`http://127.0.0.1:${port}/diagnostics`)).status, 200);
});

test('two seats relay state, reject a third, allow navigator rejoin, and close with driver', async t => {
  const { connect } = await setup(t);
  const driver = await connect();
  driver.send({ type: 'create', version: 9 });
  const created = await driver.next();
  assert.match(created.room, /^[A-F0-9]{18}$/);
  const navigator = await connect();
  navigator.send({ type: 'join', version: 9, room: created.room });
  assert.equal((await navigator.next()).type, 'joined');
  assert.equal((await driver.next()).type, 'navigator_joined');
  driver.send({ type: 'graph', roads });
  assert.deepEqual(await navigator.next(), { type: 'graph', roads });
  driver.send({ type: 'snapshot', state });
  assert.deepEqual(await navigator.next(), { type: 'snapshot', state });
  navigator.send({ type: 'snapshot', state });
  assert.equal((await navigator.next()).code, 'not_driver');
  const third = await connect();
  third.send({ type: 'join', version: 9, room: created.room });
  assert.equal((await third.next()).code, 'full');
  navigator.send({ type: 'leave' });
  assert.equal((await driver.next()).type, 'navigator_left');
  third.send({ type: 'join', version: 9, room: created.room });
  assert.equal((await third.next()).type, 'joined');
  assert.equal((await driver.next()).type, 'navigator_joined');
  driver.send({ type: 'leave' });
  assert.equal((await third.next()).type, 'room_closed');
});

test('short share codes join either seat and the creator can choose to navigate', async t => {
  const { connect } = await setup(t);
  const driver = await connect();
  driver.send({ type: 'create', version: 9 });
  const created = await driver.next();
  assert.match(created.share, /^[ABCDEFGHJKMNPQRSTUVWXYZ2-9]{6}$/);
  const friend = await connect();
  // Lowercase, spaces and dashes are forgiven when a code is typed.
  friend.send({ type: 'join', version: 9, room: ` ${created.share.slice(0, 3).toLowerCase()}-${created.share.slice(3)} ` });
  const joined = await friend.next();
  assert.equal(joined.type, 'joined');
  assert.equal(joined.role, 'navigator');
  assert.equal(joined.share, created.share);
  assert.equal(joined.room, created.room);
  assert.equal((await driver.next()).type, 'navigator_joined');

  const navigatorFirst = await connect();
  navigatorFirst.send({ type: 'create', version: 9, seat: 'navigator' });
  const room = await navigatorFirst.next();
  assert.equal(room.type, 'created');
  assert.equal(room.role, 'navigator');
  assert.equal(room.peer_connected, false);
  const late = await connect();
  late.send({ type: 'join', version: 9, room: room.share });
  const seat = await late.next();
  assert.equal(seat.role, 'driver');
  assert.equal(seat.peer_connected, true);
  assert.equal((await navigatorFirst.next()).type, 'peer_restored');
  late.send({ type: 'snapshot', state });
  assert.deepEqual(await navigatorFirst.next(), { type: 'snapshot', state });
  const third = await connect();
  third.send({ type: 'join', version: 9, room: room.share });
  assert.equal((await third.next()).code, 'full');
  const stranger = await connect();
  stranger.send({ type: 'join', version: 9, room: 'ZZZZZ2' });
  assert.equal((await stranger.next()).code, 'not_found');
});

test('either player swaps seats; the new driver sends state and resume follows the seat', async t => {
  const { connect } = await setup(t);
  const first = await connect();
  first.send({ type: 'create', version: 9 });
  const created = await first.next();
  const second = await connect();
  second.send({ type: 'join', version: 9, room: created.share });
  const joined = await second.next();
  await first.next();
  second.send({ type: 'swap' });
  assert.deepEqual(await first.next(), { type: 'seat_swapped', role: 'navigator' });
  assert.deepEqual(await second.next(), { type: 'seat_swapped', role: 'driver' });
  second.send({ type: 'snapshot', state });
  assert.deepEqual(await first.next(), { type: 'snapshot', state });
  first.send({ type: 'snapshot', state });
  assert.equal((await first.next()).code, 'not_driver');
  // A dropped connection resumes into its new seat with its original credential.
  const closed = once(second.socket, 'close');
  second.socket.terminate();
  await closed;
  assert.equal((await first.next()).type, 'peer_reconnecting');
  const back = await connect();
  back.send({ type: 'resume', version: 9, room: joined.room, token: joined.token, role: 'driver' });
  const resumed = await back.next();
  assert.equal(resumed.type, 'resumed');
  assert.equal(resumed.role, 'driver');
  first.send({ type: 'swap' });
  assert.equal((await back.next()).type, 'seat_swapped');
});

test('swapping needs both players connected', async t => {
  const { connect } = await setup(t);
  const alone = await connect();
  alone.send({ type: 'create', version: 9 });
  await alone.next();
  alone.send({ type: 'swap' });
  assert.equal((await alone.next()).code, 'swap_unavailable');
});

const pose = { seq: 1, time: 1.25, reset: 0, p: [0, 1, 2], q: [0, 0, 0, 1], v: [0, 0, -18], w: [0, 0.4, 0], speed: 18, steering: 0.3, throttle: 1, grounded: 4, wheels: [-0.4, -0.4, -0.4, -0.4] };

test('compact poses reach the navigator; malformed ones close the driver', async t => {
  const { connect } = await setup(t);
  const driver = await connect();
  driver.send({ type: 'create', version: 9 });
  const created = await driver.next();
  const navigator = await connect();
  navigator.send({ type: 'join', version: 9, room: created.share });
  await navigator.next();
  await driver.next();
  driver.send({ type: 'pose', state: pose });
  assert.deepEqual(await navigator.next(), { type: 'pose', state: pose });
  navigator.send({ type: 'pose', state: pose });
  assert.equal((await navigator.next()).code, 'not_driver');
  assert.equal(poseIssue({ ...pose, q: [0, 0, 0, 0] }), 'q');
  assert.equal(poseIssue({ ...pose, wheels: [0, 0, 0] }), 'wheels');
  assert.equal(poseIssue({ ...pose, steering: 3 }), 'steering');
  const closed = once(driver.socket, 'close');
  driver.send({ type: 'pose', state: { ...pose, p: [0, 1] } });
  assert.equal((await closed)[0], 1008);
});

test('rooms are isolated and malformed state is rejected', async t => {
  const { connect } = await setup(t);
  const first = await connect();
  const second = await connect();
  first.send({ type: 'create', version: 9 });
  second.send({ type: 'create', version: 9 });
  const one = await first.next();
  const two = await second.next();
  assert.notEqual(one.room, two.room);
  const navigator = await connect();
  navigator.send({ type: 'join', version: 9, room: two.room });
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
  client.send({ type: 'join', version: 9, room: '000000000000000000' });
  assert.equal((await client.next()).code, 'not_found');
  client.send({ type: 'create', version: 9 });
  assert.equal((await client.next()).type, 'created');
  const second = await connect();
  second.send({ type: 'create', version: 9 });
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
    driver.send({ type: 'create', version: 9 });
    await driver.next();
    const closed = once(driver.socket, 'close');
    driver.send(message);
    assert.equal((await closed)[0], 1008);
  }
});

test('both seats resume after transport loss, protect tokens, and replace stale sockets safely', async t => {
  const logs = [];
  const { connect } = await setup(t, { logger: entry => logs.push(entry) });
  const driver = await connect(); driver.send({ type: 'create', version: 9 });
  const created = await driver.next();
  const nav = await connect(); nav.send({ type: 'join', version: 9, room: created.room });
  const joined = await nav.next(); await driver.next();
  driver.socket.terminate();
  assert.equal((await nav.next()).type, 'peer_reconnecting');
  const replacement = await connect();
  replacement.send({ type: 'resume', version: 9, room: created.room, role: 'driver', token: '0'.repeat(64) });
  assert.equal((await replacement.next()).code, 'resume_expired');
  replacement.send({ type: 'resume', version: 9, room: created.room, role: 'driver', token: created.token });
  assert.equal((await replacement.next()).peer_connected, true);
  assert.equal((await nav.next()).type, 'peer_restored');
  replacement.send({ type: 'snapshot', state });
  assert.equal((await nav.next()).state.seq, 1);
  const nav2 = await connect();
  const oldClosed = once(nav.socket, 'close');
  nav2.send({ type: 'resume', version: 9, room: created.room, role: 'navigator', token: joined.token });
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
  const driver = await connect(); driver.send({ type: 'create', version: 9 }); const created = await driver.next();
  const nav = await connect(); nav.send({ type: 'join', version: 9, room: created.room }); await nav.next(); await driver.next();
  nav.socket.terminate(); assert.equal((await driver.next()).type, 'peer_reconnecting');
  assert.equal((await driver.next()).type, 'navigator_left');
  const check = await connect(); check.send({ type: 'check', version: 9 });
  assert.equal((await check.next()).type, 'check_ready');
  check.send({ type: 'ping', id: 42 }); assert.deepEqual(await check.next(), { type: 'pong', id: 42 });
  const nav2 = await connect(); nav2.send({ type: 'join', version: 9, room: created.room });
  assert.equal((await nav2.next()).type, 'joined'); await driver.next();
  driver.socket.terminate(); assert.equal((await nav2.next()).type, 'peer_reconnecting');
  assert.equal((await nav2.next()).type, 'room_closed');
});

test('application traffic keeps a connection alive even if control pongs are lost; silent peers time out', async t => {
  const logs = [];
  const { port } = await setup(t, { heartbeatInterval: 20, heartbeatTimeout: 150, logger: x => logs.push(x) });
  const socket = new WebSocket(`ws://127.0.0.1:${port}/ws`, { autoPong: false });
  await once(socket, 'open');
  socket.send(JSON.stringify({ type: 'check', version: 9 }));
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
  assert.equal(snapshotIssue({ ...state, damage: [1, 1, 0.5, 1, 0, 1, 1, 0.2] }), null);
  assert.equal(snapshotIssue({ ...state, damage: [1, 1, 1] }), 'damage');
  assert.equal(snapshotIssue({ ...state, damage: [1, 1, 1, 1, 1, 1, 1, 2] }), 'damage');
  assert.equal(graphIssue([{ ...roads[0], points: [[0, 0, 0], [0, 0, 0]] }]), 'road[0].point[1].spacing');
});


test('survival state and physical hazards are validated and forwarded intact', async t => {
  const { connect } = await setup(t);
  const driver = await connect();
  driver.send({ type: 'create', version: 9 });
  const created = await driver.next();
  const navigator = await connect();
  navigator.send({ type: 'join', version: 9, room: created.room });
  await navigator.next(); await driver.next();
  const cliff = [{ ...roads[0], danger: true, profile: 'cliff', expanded: true, hazards: [{ kind: 'cliff', position: [48, -24, -96], size: [48, 24, 48], yaw: 0 }] }];
  driver.send({ type: 'graph', roads: cliff });
  assert.deepEqual((await navigator.next()).roads, cliff);
  const ended = { ...state, run_state: 'game_over', crash_reason: 'The road ended at a cliff', distance: 1234 };
  driver.send({ type: 'snapshot', state: ended });
  assert.deepEqual((await navigator.next()).state, ended);
  assert.equal(snapshotIssue({ ...state, run_state: 'invalid' }), 'run_state');
  assert.equal(snapshotIssue({ ...state, run_id: -1 }), 'run_id');
  assert.equal(snapshotIssue({ ...state, wheels: [0] }), 'wheels');
  assert.equal(graphIssue([{ ...cliff[0], hazards: [{ ...cliff[0].hazards[0], size: [999, 24, 48] }] }]), 'road[0].hazard_size');
  assert.equal(graphIssue([{ ...cliff[0], hazards: [{ ...cliff[0].hazards[0], kind: 'unknown' }] }]), 'road[0].hazard_kind');
});

test('named lobbies match case and spaces, let navigator arrive first, and protect both seats', async t => {
  const { connect } = await setup(t);
  const navigator = await connect();
  navigator.send({ type: 'join', version: 9, lobby: ' Forest Friends ' });
  const waiting = await navigator.next();
  assert.equal(waiting.type, 'joined');
  assert.equal(waiting.peer_connected, false);
  const driver = await connect();
  driver.send({ type: 'create', version: 9, lobby: 'forest-friends' });
  const created = await driver.next();
  assert.equal(created.room, waiting.room);
  assert.equal(created.peer_connected, true);
  assert.equal((await navigator.next()).type, 'peer_restored');
  const third = await connect();
  third.send({ type: 'create', version: 9, lobby: 'FOREST  FRIENDS' });
  assert.equal((await third.next()).code, 'driver_taken');
  third.send({ type: 'join', version: 9, lobby: 'forest-friends' });
  assert.equal((await third.next()).code, 'full');
  driver.send({ type: 'graph', roads });
  assert.deepEqual((await navigator.next()).roads, roads);
  driver.send({ type: 'snapshot', state });
  assert.deepEqual((await navigator.next()).state, state);
});

test('the same lobby name works for another ride and after a relay restart', async t => {
  const { connect } = await setup(t);
  const driver = await connect();
  driver.send({ type: 'create', version: 9, lobby: 'weekend-drive' });
  const original = await driver.next();
  const closed = once(driver.socket, 'close');
  driver.send({ type: 'leave' });
  await closed;
  const nextDriver = await connect();
  nextDriver.send({ type: 'create', version: 9, lobby: 'weekend-drive' });
  const next = await nextDriver.next();
  assert.equal(next.type, 'created');
  assert.notEqual(next.room, original.room);
  const navigator = await connect();
  navigator.send({ type: 'join', version: 9, lobby: 'weekend-drive' });
  assert.equal((await navigator.next()).room, next.room);
  await nextDriver.next();
  const restarted = await setup(t);
  const fresh = await restarted.connect();
  fresh.send({ type: 'create', version: 9, lobby: 'weekend-drive' });
  assert.equal((await fresh.next()).type, 'created');
});

test('waiting lobbies resume and expire cleanly; invalid names are rejected', async t => {
  const { connect } = await setup(t, { waitingTimeout: 120, heartbeatInterval: 20, heartbeatTimeout: 1000 });
  for (const lobby of ['', 'ab', 'x'.repeat(41), 'private/lobby', '-hello', 123]) {
    const invalid = await connect();
    invalid.send({ type: 'join', version: 9, lobby });
    assert.equal((await invalid.next()).code, 'lobby_name');
  }
  const nav = await connect();
  nav.send({ type: 'join', version: 9, lobby: 'waiting-room' });
  const joined = await nav.next();
  nav.socket.terminate();
  const replacement = await connect();
  replacement.send({ type: 'resume', version: 9, room: joined.room, role: 'navigator', token: joined.token });
  const resumed = await replacement.next();
  assert.equal(resumed.type, 'resumed');
  assert.equal(resumed.peer_connected, false);
  assert.equal((await replacement.next()).type, 'room_closed');
  const driver = await connect();
  driver.send({ type: 'create', version: 9, lobby: 'waiting-room' });
  assert.equal((await driver.next()).type, 'created');
});


test('punctures and large ravines validate, malformed tire damage is rejected', () => {
  assert.equal(snapshotIssue({ ...state, run_state: 'game_over', crash_reason: 'Thorns punctured your tires', tires: 5 }), null);
  for (const tires of [-1, 16, 1.5, null]) assert.equal(snapshotIssue({ ...state, tires }), 'tires');
  const cliff = { kind: 'cliff', position: [120, -36, -320], size: [160, 36, 112], yaw: 0 };
  assert.equal(graphIssue([{ ...roads[0], danger: true, profile: 'cliff', expanded: true, hazards: [cliff] }]), null);
  assert.match(graphIssue([{ ...roads[0], hazards: [{ ...cliff, size: [300, 36, 112] }] }]), /hazard_size/);
});


test('police snapshots validate pose, gap, catch progress, and phase', () => {
  assert.equal(snapshotIssue({ ...state, police: { ...state.police, phase: 'chasing', speed: 28, gap: 65, closing: 4, catch: 0.2, paused: false } }), null);
  for (const police of [null, { ...state.police, phase: 'unknown' }, { ...state.police, gap: -1 }, { ...state.police, catch: 2 }, { ...state.police, rotation: [0, 0, 0, 0] }, { ...state.police, speed: 100 }]) {
    assert.equal(snapshotIssue({ ...state, police }), 'police');
  }
});

test('jump gaps, timed bridges, and the shared crossing clock validate', () => {
  for (const kind of ['jump_gap', 'timed_bridge']) {
    const hazard = { kind, position: [8, -18, -400], size: [64, 18, 16], lane_x: 10, yaw: 0, level: 0 };
    assert.equal(graphIssue([{ ...roads[0], hazards: [hazard] }]), null);
    for (const lane_x of [undefined, null, '10', 1000]) {
      assert.match(graphIssue([{ ...roads[0], hazards: [{ ...hazard, lane_x }] }]), /challenge_geometry/);
    }
    assert.match(graphIssue([{ ...roads[0], hazards: [{ ...hazard, yaw: 0.5 }] }]), /challenge_geometry/);
    for (const level of [undefined, -1, 5, 1.5, '2']) {
      assert.match(graphIssue([{ ...roads[0], hazards: [{ ...hazard, level }] }]), /challenge_geometry/);
    }
  }
  assert.equal(snapshotIssue({ ...state, challenge_time: 124.5 }), null);
  for (const challenge_time of [undefined, null, -1, '12', Infinity]) {
    assert.equal(snapshotIssue({ ...state, challenge_time }), 'challenge_time');
  }
});

test('route alternatives, cul-de-sacs, and heat validate and relay unchanged', async t => {
  const choices = [
    { ...roads[0], expanded: true, next: 1 },
    { ...roads[0], id: 1, depth: 1, profile: 'scenic', level: 4, points: [[0, 0, -5], [-10, 0, -15], [0, 0, -25]] },
    { ...roads[0], id: 2, depth: 1, profile: 'rough', level: 4, expanded: true, merge_with: 1, points: [[0, 0, -5], [0, 0, -25]] },
    { ...roads[0], id: 3, depth: 1, profile: 'culdesac', expanded: true, points: [[0, 0, -5], [10, 0, -15]] },
  ];
  assert.equal(graphIssue(choices), null);
  for (const change of [{ profile: 'missing' }, { level: 5 }, { level: 0.5 }, { next: -2 }, { merge_with: '1' }, { profile: 'culdesac', expanded: false }, { profile: 'cliff', expanded: true, danger: false }]) {
    assert.match(graphIssue([{ ...roads[0], ...change }]), /route/);
  }
  const { connect } = await setup(t);
  const driver = await connect(); driver.send({ type: 'create', version: 9 });
  const created = await driver.next();
  const nav = await connect(); nav.send({ type: 'join', version: 9, room: created.room });
  await nav.next(); await driver.next();
  driver.send({ type: 'graph', roads: choices });
  assert.deepEqual((await nav.next()).roads, choices);
});
