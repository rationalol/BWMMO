shader_type canvas_item;

// Soft circular avatar mask. Draws the sprite inside a circle with a one-pixel
// feathered edge so pixel art keeps crisp texels but the rim stays smooth.
uniform float radius = 0.5;
uniform float feather = 0.012;

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	float distance_from_center = length(UV - vec2(0.5));
	float alpha = 1.0 - smoothstep(radius - feather, radius, distance_from_center);
	COLOR = vec4(tex.rgb, tex.a * alpha);
}
