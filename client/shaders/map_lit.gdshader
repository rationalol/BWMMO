shader_type spatial;
render_mode unshaded, cull_disabled, depth_prepass_alpha;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform vec3 light_direction = vec3(-0.35, -0.82, -0.25);
uniform float ambient = 0.95;
uniform float diffuse = 0.08;
// The ROM's 3D meshes carry baked vertex shading. Lifting it slightly keeps the
// original soft, bright DS look instead of the harsh real-time shadow contrast.
uniform float vertex_color_strength : hint_range(0.0, 1.0) = 0.75;

varying vec3 world_normal;

void vertex() {
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec4 tex = texture(albedo_texture, UV);
	float ndl = max(dot(normalize(world_normal), normalize(-light_direction)), 0.0);
	float shade = ambient + diffuse * ndl;
	ALBEDO = tex.rgb * mix(vec3(1.0), COLOR.rgb, vertex_color_strength) * shade;
	ALPHA = tex.a * COLOR.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
