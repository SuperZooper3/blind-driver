shader_type spatial;
// Local bloom for the browser's Compatibility renderer. Keep depth testing so
// terrain and trees can hide it; no scene-wide bloom or extra lights are needed.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled;

uniform vec4 light_color : source_color = vec4(1.0, 0.1, 0.05, 1.0);
varying float distance_boost;

void vertex() {
	vec3 center = (VIEW_MATRIX * MODEL_MATRIX[3]).xyz;
	// Each seat gets its own distance boost. Distant flashes grow in apparent
	// size AND intensity, remaining prominent through the driver's blur too.
	float distance = length(center);
	distance_boost = smoothstep(20.0, 220.0, distance);
	float diameter = clamp(distance * mix(0.045, 0.12, distance_boost), 1.8, 80.0);
	MODELVIEW_MATRIX = mat4(vec4(1.0, 0.0, 0.0, 0.0),
		vec4(0.0, 1.0, 0.0, 0.0), vec4(0.0, 0.0, 1.0, 0.0), vec4(center, 1.0));
	VERTEX.xy *= diameter;
}

void fragment() {
	float radius = length((UV - 0.5) * 2.0);
	float core = exp(-radius * radius * 55.0);
	float halo = exp(-radius * radius * 4.5);
	float edge = 1.0 - smoothstep(0.7, 1.0, radius);
	ALBEDO = mix(light_color.rgb, vec3(1.0), core * 0.88) * mix(1.2, 3.8, distance_boost);
	ALPHA = (halo * 0.8 + core * 0.6) * edge;
}
