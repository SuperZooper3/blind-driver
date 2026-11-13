// Explicit JSON protocol, shared conceptually with scripts/wire_protocol.gd.
// No Godot objects, Variant decoding, executable payloads, or arbitrary RPC calls.
export const VERSION = 1;
export const MAX_PAYLOAD = 512 * 1024;
export const isRecord = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const number = (value, min = -1e7, max = 1e7) => typeof value === 'number' && Number.isFinite(value) && value >= min && value <= max;
const integer = (value, min = 0, max = 2147483647) => Number.isSafeInteger(value) && value >= min && value <= max;
const vector = (value, length) => Array.isArray(value) && value.length === length && value.every(item => number(item));

export function validSnapshot(state) {
  return isRecord(state) && integer(state.seq) && number(state.time, 0, 1e12)
    && vector(state.position, 3) && vector(state.rotation, 4)
    && Math.abs(state.rotation.reduce((sum, value) => sum + value * value, 0) - 1) < 0.02
    && vector(state.velocity, 3) && number(state.speed, -200, 200)
    && number(state.steering, -1.01, 1.01) && number(state.throttle, -1.01, 1.01)
    && number(state.distance, 0, 1e10) && integer(state.grounded, 0, 4)
    && integer(state.reset) && typeof state.lights === 'boolean';
}

export function validGraph(roads) {
  if (!Array.isArray(roads) || roads.length < 1 || roads.length > 100) return false;
  const ids = new Set();
  return roads.every(road => {
    if (!isRecord(road) || !integer(road.id) || ids.has(road.id)
      || !integer(road.parent) || !integer(road.depth)
      || !number(road.heading, -Math.PI * 2, Math.PI * 2)
      || typeof road.expanded !== 'boolean' || !Array.isArray(road.points)
      || road.points.length < 2 || road.points.length > 64
      || !road.points.every(point => vector(point, 3))) return false;
    for (let i = 1; i < road.points.length; i++) {
      const distanceSquared = road.points[i].reduce((sum, value, axis) => sum + (value - road.points[i - 1][axis]) ** 2, 0);
      if (distanceSquared < 0.0001 || distanceSquared > 1e6) return false;
    }
    ids.add(road.id);
    return true;
  });
}
