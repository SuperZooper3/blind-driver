shader_type spatial;
uniform vec4 leaf_low : source_color;
uniform vec4 leaf_high : source_color;
uniform vec4 thorn_low : source_color;
uniform vec4 thorn_high : source_color;

void fragment() {
	// Preserve the thorn silhouette and its contrast against seasonal brush/snow.
	if (COLOR.r > 0.6) {
		float shade = clamp((COLOR.r - 178.0 / 255.0) / (30.0 / 255.0), 0.0, 1.0);
		ALBEDO = mix(thorn_low.rgb, thorn_high.rgb, shade);
	} else {
		float shade = clamp((COLOR.r - 77.0 / 255.0) / (29.0 / 255.0), 0.0, 1.0);
		ALBEDO = mix(leaf_low.rgb, leaf_high.rgb, shade);
	}
	ROUGHNESS = 0.95;
}
