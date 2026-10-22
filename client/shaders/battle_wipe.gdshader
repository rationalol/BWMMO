shader_type canvas_item;

// Radial spiral wipe used when a wild encounter starts. progress 0 covers the
// screen, progress 1 leaves only the corners, which then fade with the overlay.
uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform vec4 wipe_color : source_color = vec4(0.015, 0.030, 0.050, 1.0);
uniform vec4 rim_color : source_color = vec4(0.388, 0.902, 0.643, 1.0);

void fragment() {
	vec2 p = UV - vec2(0.5);
	float distance_from_center = length(p);
	float angle = atan(p.y, p.x);
	float spiral = 0.030 * sin(angle * 7.0 + distance_from_center * 22.0);
	float edge = mix(0.0, 0.78, progress) + spiral;
	float alpha = smoothstep(edge - 0.035, edge + 0.035, distance_from_center);
	float rim = smoothstep(edge - 0.022, edge, distance_from_center)
		* (1.0 - smoothstep(edge, edge + 0.018, distance_from_center));
	vec3 color = mix(wipe_color.rgb, rim_color.rgb, rim * 0.55);
	COLOR = vec4(color, wipe_color.a * alpha);
}
