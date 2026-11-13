// Explicit JSON protocol, shared conceptually with scripts/wire_protocol.gd.
// No Godot objects, Variant decoding, executable payloads, or arbitrary RPC calls.
export const VERSION = 3;
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
  return null;
}
export const validSnapshot = state => snapshotIssue(state) === null;

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
    if (!Array.isArray(road.hazards) || road.hazards.length > 8) return at('hazards');
    for (const hazard of road.hazards) {
      if (!isRecord(hazard) || !['rock', 'tree', 'ramp', 'bumps', 'construction', 'cliff', 'lake'].includes(hazard.kind)) return at('hazard_kind');
      if (!vector(hazard.position, 3) || !vector(hazard.size, 3) || !number(hazard.yaw, -Math.PI * 2, Math.PI * 2)) return at('hazard_geometry');
      if (hazard.size.some((value, axis) => value <= 0 || value > (axis === 1 ? 32 : 64))) return at('hazard_size');
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
