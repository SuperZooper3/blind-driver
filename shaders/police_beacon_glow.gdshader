shader_type spatial;
// Local bloom for the browser's Compatibility renderer. Keep depth testing so
// terrain and trees can hide it; no scene-wide bloom or extra lights are needed.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled;

uniform vec4 light_color : source_color = vec4(1.0, 0.1, 0.05, 1.0);

void vertex() {
	vec3 center = (VIEW_MATRIX * MODEL_MATRIX[3]).xyz;
	// Face each viewport's own camera. A modest minimum apparent size keeps
	// the distant strobe readable in both seats, including shared-screen play.
	float diameter = clamp(length(center) * 0.028, 1.5, 7.0);
	MODELVIEW_MATRIX = mat4(vec4(1.0, 0.0, 0.0, 0.0),
		vec4(0.0, 1.0, 0.0, 0.0), vec4(0.0, 0.0, 1.0, 0.0), vec4(center, 1.0));
	VERTEX.xy *= diameter;
}

void fragment() {
	float radius = length((UV - 0.5) * 2.0);
	float core = exp(-radius * radius * 70.0);
	float halo = exp(-radius * radius * 5.0);
	float edge = 1.0 - smoothstep(0.7, 1.0, radius);
	ALBEDO = mix(light_color.rgb, vec3(1.0), core * 0.65);
	ALPHA = (halo * 0.65 + core * 0.35) * edge;
}
