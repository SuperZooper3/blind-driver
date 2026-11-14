shader_type spatial;
uniform vec4 ground_low : source_color;
uniform vec4 ground_high : source_color;
uniform vec4 previous_low : source_color;
uniform vec4 previous_high : source_color;
uniform float transition_start = 0.0;
uniform float transition_distance = 0.0;
varying float world_z;

void vertex() {
	world_z = (MODEL_MATRIX * vec4(VERTEX, 1.0)).z;
}

void fragment() {
	// Keep the original seeded terrain variation; only its palette changes.
	float shade = clamp((COLOR.r - 67.0 / 255.0) / (46.0 / 255.0), 0.0, 1.0);
	vec3 color = mix(ground_low.rgb, ground_high.rgb, shade);
	if (transition_distance > 0.0) {
		float blend = smoothstep(0.0, transition_distance, transition_start - world_z);
		color = mix(mix(previous_low.rgb, previous_high.rgb, shade), color, blend);
	}
	ALBEDO = color;
	ROUGHNESS = 0.95;
}
