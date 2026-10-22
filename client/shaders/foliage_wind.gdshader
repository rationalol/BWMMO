shader_type spatial;
render_mode unshaded, cull_disabled, depth_prepass_alpha;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform vec2 tex_size = vec2(32.0, 32.0);
uniform float sway_strength : hint_range(0.0, 1.5) = 0.25;
uniform float sway_height = 12.0;
uniform vec4 tint : source_color = vec4(1.0);
uniform float vertex_color_strength : hint_range(0.0, 1.0) = 0.8;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float height = clamp(VERTEX.y / sway_height, 0.0, 1.0);
	float wave = sin(TIME * 1.3 + world.x * 0.08 + world.z * 0.05);
	VERTEX.x += wave * sway_strength * height;
	VERTEX.z += cos(TIME * 1.1 + world.z * 0.07 + world.x * 0.03) * sway_strength * 0.45 * height;
}

void fragment() {
	// ROM foliage strips tile with UVs exactly on the texture border. Bilinear
	// filtering there blends the magenta padding into visible seams, so sample
	// from texel centers inside each tile instead.
	vec2 texel = 1.0 / tex_size;
	vec2 uv = fract(UV) * (vec2(1.0) - texel) + texel * 0.5;
	vec4 tex = texture(albedo_texture, uv);
	ALBEDO = tex.rgb * mix(vec3(1.0), COLOR.rgb, vertex_color_strength) * tint.rgb;
	ALPHA = tex.a * COLOR.a * tint.a;
	ALPHA_SCISSOR_THRESHOLD = 0.35;
}
