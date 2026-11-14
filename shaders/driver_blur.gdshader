shader_type canvas_item;

uniform float blur_amount : hint_range(0.0, 0.08) = 0.040;
uniform float blind_strength : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec2 uv = UV;
	vec4 color = texture(TEXTURE, uv) * 0.12;
	for (int ring = 1; ring <= 3; ring++) {
		for (int i = 0; i < 12; i++) {
			float angle = float(i) * 6.283185 / 12.0;
			vec2 offset = vec2(cos(angle), sin(angle)) * blur_amount * float(ring) * vec2(1.0, 1.5);
			color += texture(TEXTURE, clamp(uv + offset, vec2(0.001), vec2(0.999))) * (0.88 / 36.0);
		}
	}
	float vignette = smoothstep(0.8, 0.15, distance(uv, vec2(0.5)));
	vec3 hazy = mix(color.rgb, vec3(0.65, 0.68, 0.58), 0.14);
	hazy *= mix(0.52, 1.0, vignette);
	COLOR = vec4(mix(texture(TEXTURE, UV).rgb, hazy, blind_strength), 1.0);
}
