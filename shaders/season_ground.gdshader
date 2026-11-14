shader_type spatial;
uniform vec4 ground_low : source_color;
uniform vec4 ground_high : source_color;

void fragment() {
	// Keep the original seeded terrain variation; only its palette changes.
	float shade = clamp((COLOR.r - 67.0 / 255.0) / (46.0 / 255.0), 0.0, 1.0);
	ALBEDO = mix(ground_low.rgb, ground_high.rgb, shade);
	ROUGHNESS = 0.95;
}
