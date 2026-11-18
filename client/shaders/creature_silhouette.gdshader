shader_type canvas_item;

// Evolution sequence effect. The battler is a Control that paints itself in
// _draw(), so this runs on every primitive it emits (sprite frames, fallback
// shapes). Progressing silhouette -> flash and back gives the BW-style
// dark-silhouette / white-out strobe without swapping textures.
uniform float silhouette : hint_range(0.0, 1.0) = 0.0;
uniform float flash : hint_range(0.0, 1.0) = 0.0;
uniform vec4 silhouette_color : source_color = vec4(0.02, 0.03, 0.05, 1.0);
uniform vec4 flash_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

void fragment() {
	vec4 base = texture(TEXTURE, UV) * COLOR;
	vec4 shadow = vec4(silhouette_color.rgb, base.a * silhouette_color.a);
	vec4 tinted = mix(base, shadow, silhouette);
	vec4 lit = vec4(flash_color.rgb, tinted.a * flash_color.a);
	COLOR = mix(tinted, lit, flash);
}
