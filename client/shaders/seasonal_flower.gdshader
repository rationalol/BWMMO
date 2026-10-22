shader_type spatial;
render_mode unshaded, cull_disabled, depth_prepass_alpha;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform vec2 tex_size = vec2(32.0, 32.0);
// 0 spring, 1 summer, 2 autumn, 3 winter
uniform int season = 2;
uniform float sway_strength : hint_range(0.0, 0.5) = 0.12;
uniform float sway_height = 8.0;
uniform float vertex_color_strength : hint_range(0.0, 1.0) = 0.7;

vec3 rgb_to_hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv_to_rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float height = clamp(VERTEX.y / sway_height, 0.0, 1.0);
	float wave = sin(TIME * 1.1 + world.x * 0.09 + world.z * 0.06);
	VERTEX.x += wave * sway_strength * height;
}

void fragment() {
	vec2 texel = 1.0 / tex_size;
	vec2 uv = fract(UV) * (vec2(1.0) - texel) + texel * 0.5;
	vec4 tex = texture(albedo_texture, uv);
	vec3 hsv = rgb_to_hsv(tex.rgb);
	// Pink/red or bright white petals; green stems and leaves keep their hue.
	bool petal = (
		(hsv.y > 0.16 && (hsv.x > 0.70 || hsv.x < 0.13))
		|| (hsv.z > 0.65 && hsv.y < 0.30)
	);
	if (petal && season == 2) {
		hsv.x = 0.118;
		hsv.y = clamp(hsv.y * 1.25 + 0.38, 0.60, 1.0);
		hsv.z = min(1.0, hsv.z * 1.04);
	} else if (petal && season == 1) {
		hsv.x = 0.015;
	} else if (petal && season == 3) {
		hsv.y *= 0.22;
		hsv.z = min(1.0, hsv.z + 0.22);
	}
	ALBEDO = hsv_to_rgb(hsv) * mix(vec3(1.0), COLOR.rgb, vertex_color_strength);
	ALPHA = tex.a * COLOR.a;
	ALPHA_SCISSOR_THRESHOLD = 0.35;
}
