// Explicit JSON protocol, shared conceptually with scripts/wire_protocol.gd.
// No Godot objects, Variant decoding, executable payloads, or arbitrary RPC calls.
export const VERSION = 9;
export const MAX_PAYLOAD = 512 * 1024;
export const isRecord = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const number = (value, min = -1e7, max = 1e7) => typeof value === 'number' && Number.isFinite(value) && value >= min && value <= max;
const integer = (value, min = 0, max = 2147483647) => Number.isSafeInteger(value) && value >= min && value <= max;
const vector = (value, length) => Array.isArray(value) && value.length === length && value.every(item => number(item));

// Return only field names/reasons, never player data, for useful rejection logs.
export function snapshotIssue(state) {
  if (!isRecord(state)) return 'state_type';
  for (const key of ['seq', 'reset']) if (!integer(state[key])) return key;
  for (const [key, min, max] of [['time', 0, 1e12], ['speed', -200, 200], ['steering', -1.01, 1.01], ['throttle', -1.01, 1.01], ['distance', 0, 1e10]]) {
    if (!number(state[key], min, max)) return key;
  }
  for (const [key, length] of [['position', 3], ['rotation', 4], ['velocity', 3]]) if (!vector(state[key], length)) return key;
  if (Math.abs(state.rotation.reduce((sum, value) => sum + value * value, 0) - 1) >= 0.02) return 'rotation_normalization';
  if (!integer(state.grounded, 0, 4)) return 'grounded';
  if (typeof state.lights !== 'boolean') return 'lights';
  if (!vector(state.angular_velocity, 3)) return 'angular_velocity';
  if (!vector(state.wheels, 4) || state.wheels.some(value => value < -2 || value > 2)) return 'wheels';
  if (!['driving', 'falling', 'game_over'].includes(state.run_state)) return 'run_state';
  if (typeof state.crash_reason !== 'string' || state.crash_reason.length > 96) return 'crash_reason';
  if (!integer(state.run_id)) return 'run_id';
  if (typeof state.on_road !== 'boolean') return 'on_road';
  if (!number(state.impact, 0, 1)) return 'impact';
  if (!integer(state.tires, 0, 15)) return 'tires';
  if (!validPolice(state.police)) return 'police';
  if (!number(state.challenge_time, 0, 1e12)) return 'challenge_time';
  // Optional per-part car health (0..1); absent from clients older than car damage.
  if (state.damage !== undefined && !(Array.isArray(state.damage) && state.damage.length === 8 && state.damage.every(item => number(item, 0, 1)))) return 'damage';
  return null;
}
export const validSnapshot = state => snapshotIssue(state) === null;

// The small, frequent car pose (position, rotation, motion, steering); see wire_protocol.gd.
export function poseIssue(state) {
  if (!isRecord(state)) return 'state_type';
  for (const key of ['seq', 'reset']) if (!integer(state[key])) return key;
  for (const [key, min, max] of [['time', 0, 1e12], ['speed', -200, 200], ['steering', -1.01, 1.01], ['throttle', -1.01, 1.01]]) {
    if (!number(state[key], min, max)) return key;
  }
  for (const key of ['p', 'v', 'w']) if (!vector(state[key], 3)) return key;
  if (!vector(state.q, 4) || Math.abs(state.q.reduce((sum, value) => sum + value * value, 0) - 1) >= 0.02) return 'q';
  if (!integer(state.grounded, 0, 4)) return 'grounded';
  if (!vector(state.wheels, 4) || state.wheels.some(value => value < -2 || value > 2)) return 'wheels';
  return null;
}
export const validPose = state => poseIssue(state) === null;

export function graphIssue(roads) {
  if (!Array.isArray(roads) || roads.length < 1 || roads.length > 100) return 'road_count';
  const ids = new Set();
  for (const [index, road] of roads.entries()) {
    const at = field => `road[${index}].${field}`;
    if (!isRecord(road)) return at('type');
    for (const key of ['id', 'parent', 'depth']) if (!integer(road[key])) return at(key);
    if (ids.has(road.id)) return at('duplicate_id');
    if (!number(road.heading, -Math.PI * 2, Math.PI * 2)) return at('heading');
    if (typeof road.expanded !== 'boolean') return at('expanded');
    if (typeof road.danger !== 'boolean') return at('danger');
    if (!['main', 'scenic', 'rough', 'culdesac', 'cliff'].includes(road.profile)
        || !integer(road.level, 0, 4) || !integer(road.next, -1) || !integer(road.merge_with, -1)) return at('route');
    if (road.danger !== (road.profile === 'cliff') || (['culdesac', 'cliff', 'rough'].includes(road.profile) && !road.expanded)) return at('route');
    if (!Array.isArray(road.hazards) || road.hazards.length > 8) return at('hazards');
    for (const hazard of road.hazards) {
      if (!isRecord(hazard) || !['rock', 'tree', 'ramp', 'bumps', 'construction', 'cliff', 'lake', 'jump_gap', 'timed_bridge'].includes(hazard.kind)) return at('hazard_kind');
      if (!vector(hazard.position, 3) || !vector(hazard.size, 3) || !number(hazard.yaw, -Math.PI * 2, Math.PI * 2)) return at('hazard_geometry');
      if (hazard.size.some((value, axis) => value <= 0 || value > (axis === 1 ? 48 : 192))) return at('hazard_size');
      if (['jump_gap', 'timed_bridge'].includes(hazard.kind)
          && (!number(hazard.lane_x) || Math.abs(hazard.lane_x - hazard.position[0]) > hazard.size[0] / 2 - 6 || hazard.yaw !== 0 || !integer(hazard.level, 0, 4))) return at('challenge_geometry');
    }
    if (!Array.isArray(road.points) || road.points.length < 2 || road.points.length > 64) return at('point_count');
    if (!road.points.every(point => vector(point, 3))) return at('point_coordinates');
    for (let i = 1; i < road.points.length; i++) {
      const distanceSquared = road.points[i].reduce((sum, value, axis) => sum + (value - road.points[i - 1][axis]) ** 2, 0);
      if (distanceSquared < 0.0001 || distanceSquared > 1e6) return at(`point[${i}].spacing`);
    }
    ids.add(road.id);
  }
  return null;
}
export const validGraph = roads => graphIssue(roads) === null;

// Names are reusable rendezvous points, not saved games or permanent reservations.
// Short, speakable room codes: no 0/O, 1/I/L lookalikes.
export const SHARE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
export const SHARE_LENGTH = 6;
export function normalizeShare(value) {
  if (typeof value !== 'string' || value.length > 24) return null;
  const code = value.toUpperCase().replace(/[^A-Z0-9]/g, '');
  return code.length === SHARE_LENGTH && [...code].every(c => SHARE_ALPHABET.includes(c)) ? code : null;
}

export function normalizeLobby(value) {
  if (typeof value !== 'string' || value.length > 40 || !/^[a-z0-9 -]+$/i.test(value)) return null;
  const name = value.trim().toLowerCase().replace(/[ -]+/g, '-');
  return name.length >= 3 && name.length <= 40 && /^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(name) ? name : null;
}

export function validPolice(value) {
  return isRecord(value) && vector(value.position, 3) && vector(value.rotation, 4)
    && Math.abs(value.rotation.reduce((sum, n) => sum + n * n, 0) - 1) < 0.02
    && ['waiting', 'chasing', 'escaped', 'caught'].includes(value.phase) && typeof value.paused === 'boolean'
    && number(value.elapsed, 0, 1e12) && number(value.speed, 0, 45) && number(value.gap, 0, 1e7)
    && number(value.closing, -100, 100) && number(value.catch, 0, 1);
}
