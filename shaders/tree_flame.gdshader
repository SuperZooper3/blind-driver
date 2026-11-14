shader_type spatial;
render_mode unshaded, cull_disabled;

void vertex() {
	VERTEX.x += sin(TIME * 8.0 + VERTEX.y * 4.0) * 0.07;
	VERTEX.y += sin(TIME * 11.0 + VERTEX.x * 7.0) * 0.08;
}

void fragment() {
	ALBEDO = COLOR.rgb * (0.9 + 0.1 * sin(TIME * 13.0));
}
