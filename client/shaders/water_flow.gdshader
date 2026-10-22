shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform vec2 flow_direction = vec2(0.82, 0.18);
uniform float flow_speed : hint_range(0.0, 0.3) = 0.035;
uniform float wave_strength : hint_range(0.0, 0.1) = 0.012;

void fragment() {
	vec2 uv = UV + flow_direction * TIME * flow_speed;
	uv.x += sin(UV.y * 18.0 + TIME * 1.2) * wave_strength;
	uv.y += cos(UV.x * 14.0 + TIME * 0.9) * wave_strength * 0.6;
	vec4 tex = texture(albedo_texture, uv);
	float glint = 0.97 + 0.03 * sin(TIME * 1.6 + UV.x * 22.0 + UV.y * 17.0);
	ALBEDO = tex.rgb * mix(vec3(1.0), COLOR.rgb, 0.85) * glint;
}
