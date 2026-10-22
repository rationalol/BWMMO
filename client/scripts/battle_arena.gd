extends Control

const WorldTimeScript = preload("res://scripts/world_time.gd")

# The battlefield behind the BW battle HUD. The real games render a 3D stage;
# this draws the same composition in 2D: a banded sky, a wavy horizon, the
# layered grass field and the two raised rings the Pokémon stand on. Colours
# follow the original seasonal battle backgrounds (batt_bg02a-d/batt_stage23a-d).

const THEMES := {
	"spring": {
		"sky": [Color("4fbcf0"), Color("9fe9f2"), Color("e6fff0")],
		"field": [Color("c6f6ac"), Color("7bdc9b"), Color("14784a")],
		"rim": Color("146439"),
		"rim_dark": Color("0b4428"),
		"top": Color("34c45c"),
		"top_light": Color("5ce27c"),
		"glow": Color("a0ffb4")
	},
	"summer": {
		"sky": [Color("49c4ff"), Color("9beaf7"), Color("dcffee")],
		"field": [Color("b8f58a"), Color("58cf78"), Color("0e6b3a")],
		"rim": Color("125c34"),
		"rim_dark": Color("0a3d22"),
		"top": Color("3bc862"),
		"top_light": Color("67e483"),
		"glow": Color("b4ffc0")
	},
	"autumn": {
		"sky": [Color("a082e1"), Color("d6b8ef"), Color("ffe2b0")],
		"field": [Color("f0cd78"), Color("d9a044"), Color("4e2a14")],
		"rim": Color("703e16"),
		"rim_dark": Color("4a260c"),
		"top": Color("c47824"),
		"top_light": Color("e0a040"),
		"glow": Color("ffd08a")
	},
	"winter": {
		"sky": [Color("a5d2f5"), Color("d6efff"), Color("f2fbff")],
		"field": [Color("eaf8ff"), Color("cfe6f2"), Color("7fa6bc")],
		"rim": Color("7898aa"),
		"rim_dark": Color("547585"),
		"top": Color("cfe8f5"),
		"top_light": Color("eafaff"),
		"glow": Color("ffffff")
	},
	"indoor": {
		"sky": [Color("1a232c"), Color("2c3944"), Color("4a5660")],
		"field": [Color("55636c"), Color("3c484f"), Color("1a2228")],
		"rim": Color("2c363c"),
		"rim_dark": Color("161d21"),
		"top": Color("59666e"),
		"top_light": Color("75838b"),
		"glow": Color("aab6bc")
	}
}

var season := "autumn"
var indoor := false
var _tint := Color(1, 1, 1, 1)
var _hours := 12.0
var _grain: Texture2D = null

func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)
	_build_grain()

func setup(
	p_season: String,
	p_indoor: bool,
	p_tint: Color = Color(1, 1, 1, 1),
	p_hours: float = 12.0
) -> void:
	season = p_season.to_lower()
	indoor = p_indoor
	_tint = p_tint
	_hours = p_hours
	if indoor:
		season = "indoor"
	if not THEMES.has(season):
		season = "autumn"
	queue_redraw()

func _theme() -> Dictionary:
	var source: Dictionary = THEMES[season]
	if _tint.is_equal_approx(Color(1, 1, 1, 1)):
		return source
	var tinted := source.duplicate(true)
	var sky: Array = []
	for color in source["sky"]:
		sky.append(_shade(color, _tint))
	tinted["sky"] = sky
	var field: Array = []
	for color in source["field"]:
		field.append(_shade(color, _tint))
	tinted["field"] = field
	for key in ["rim", "rim_dark", "top", "top_light", "glow"]:
		tinted[key] = _shade(source[key], _tint)
	return tinted

func _shade(color: Color, tint: Color) -> Color:
	return Color(
		clampf(color.r * tint.r, 0.0, 1.0),
		clampf(color.g * tint.g, 0.0, 1.0),
		clampf(color.b * tint.b, 0.0, 1.0),
		color.a
	)

func _build_grain() -> void:
	var image := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in range(64):
		for x in range(64):
			var value := float((x * 37 + y * 91 + (x * y) % 17) % 23) / 23.0
			image.set_pixel(x, y, Color(0.0, 0.0, 0.0, 0.035 + value * 0.025))
	_grain = ImageTexture.create_from_image(image)

func _horizon_y(x: float) -> float:
	var w := maxf(1.0, size.x)
	return size.y * 0.34 + sin(x / w * 9.0) * size.y * 0.010 + sin(x / w * 27.0) * size.y * 0.005

func _draw() -> void:
	var theme := _theme()
	var w := size.x
	var h := size.y
	if w <= 0.0 or h <= 0.0:
		return

	_draw_sky(theme)
	_draw_sky_objects()
	_draw_field(theme)
	_draw_platform(Vector2(w * 0.725, h * 0.440), w * 0.156, h * 0.100, theme)
	_draw_platform(Vector2(w * 0.248, h * 0.735), w * 0.185, h * 0.120, theme)

func _draw_sky(theme: Dictionary) -> void:
	var gradient := Gradient.new()
	gradient.colors = PackedColorArray([
		theme["sky"][0], theme["sky"][1], theme["sky"][2]
	])
	gradient.offsets = PackedFloat32Array([0.0, 0.58, 1.0])
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill_from = Vector2(0.0, 0.0)
	texture.fill_to = Vector2(0.0, 1.0)
	texture.width = 8
	texture.height = 128
	draw_texture_rect(texture, Rect2(0.0, 0.0, size.x, _horizon_y(size.x * 0.5) + 8.0), false)

func _draw_sky_objects() -> void:
	if indoor:
		return
	var darkness := WorldTimeScript.darkness(_hours)
	if darkness <= 0.06:
		return
	# Stars are deterministic, so the sky does not shimmer as the clock moves.
	if darkness > 0.25:
		for index in range(54):
			var fx := fposmod(sin(float(index) * 12.9898) * 43758.5453, 1.0)
			var fy := fposmod(sin(float(index) * 78.233 + 3.7) * 12543.123, 1.0)
			var position := Vector2(fx * size.x, 6.0 + fy * (size.y * 0.30 - 6.0))
			var twinkle := 0.5 + 0.5 * sin(_hours * 2.4 + float(index) * 1.7)
			var alpha := darkness * (0.20 + 0.55 * twinkle)
			if alpha <= 0.04:
				continue
			draw_circle(position, 0.9 + float(index % 3) * 0.55, Color(0.92, 0.95, 1.0, alpha))
	if darkness > 0.75:
		var moon := Vector2(size.x * 0.82, size.y * 0.13)
		var alpha := clampf((darkness - 0.55) / 0.45, 0.0, 1.0)
		draw_circle(moon, 34.0, Color(0.86, 0.90, 1.0, 0.08 * alpha))
		draw_circle(moon, 21.0, Color(0.94, 0.96, 1.0, 0.92 * alpha))
		draw_circle(moon + Vector2(-7, -5), 4.0, Color(0.78, 0.82, 0.90, 0.30 * alpha))
		draw_circle(moon + Vector2(6, 4), 3.0, Color(0.78, 0.82, 0.90, 0.25 * alpha))
		draw_circle(moon + Vector2(2, -9), 2.0, Color(0.78, 0.82, 0.90, 0.22 * alpha))
	var phase := WorldTimeScript.phase(_hours)
	if phase == "dawn" or phase == "dusk":
		var sun_x := size.x * (0.18 if phase == "dawn" else 0.82)
		var sun_y := _horizon_y(sun_x) - 18.0
		draw_circle(Vector2(sun_x, sun_y), 82.0, Color(1.0, 0.58, 0.28, 0.10))
		draw_circle(Vector2(sun_x, sun_y), 44.0, Color(1.0, 0.72, 0.42, 0.20))
		draw_circle(Vector2(sun_x, sun_y), 19.0, Color(1.0, 0.86, 0.66, 0.55))

func _draw_field(theme: Dictionary) -> void:
	var w := size.x
	var h := size.y
	var top: Color = theme["field"][0]
	var mid: Color = theme["field"][1]
	var bottom: Color = theme["field"][2]
	var mid_y := h * 0.68
	var step := 12.0
	var x := 0.0
	while x < w:
		var x2 := minf(w, x + step)
		var y1 := _horizon_y(x)
		var y2 := _horizon_y(x2)
		draw_polygon(
			PackedVector2Array([Vector2(x, y1), Vector2(x2, y2), Vector2(x2, mid_y), Vector2(x, mid_y)]),
			PackedColorArray([top, top, mid, mid])
		)
		draw_polygon(
			PackedVector2Array([Vector2(x, mid_y), Vector2(x2, mid_y), Vector2(x2, h), Vector2(x, h)]),
			PackedColorArray([mid, mid, bottom, bottom])
		)
		x += step

	# Faint contour lines, the soft horizontal bands of the ROM field texture.
	var band := PackedVector2Array()
	for pass_index in range(3):
		band.clear()
		var count := 34
		for i in range(count + 1):
			var t := float(i) / float(count)
			var bx := t * w
			var by := _horizon_y(bx) + h * (0.10 + 0.13 * pass_index) + sin(t * 7.0 + pass_index) * h * 0.008
			band.append(Vector2(bx, by))
		draw_polyline(band, Color(1.0, 1.0, 1.0, 0.055), 3.0, true)

	if _grain != null:
		draw_texture_rect(
			_grain,
			Rect2(0.0, h * 0.36, w, h * 0.64),
			true,
			Color(1, 1, 1, 0.55)
		)

func _draw_platform(center: Vector2, rx: float, ry: float, theme: Dictionary) -> void:
	# Contact shadow under the disc.
	_ellipse(center + Vector2(0, ry * 1.02), rx * 1.07, ry * 0.42, Color(0.02, 0.10, 0.06, 0.24))
	# Thick dark side of the disc.
	_ellipse(center + Vector2(0, ry * 0.30), rx, ry, theme["rim_dark"])
	_ellipse(center + Vector2(0, ry * 0.20), rx * 0.985, ry * 0.95, theme["rim"])
	# Top face with a couple of lighter inner rings.
	_ellipse(center, rx, ry, theme["top"])
	_ellipse(center + Vector2(0, -ry * 0.02), rx * 0.955, ry * 0.90, theme["top_light"])
	_ellipse(center + Vector2(0, -ry * 0.04), rx * 0.80, ry * 0.72, theme["top"])
	# Rim highlight and inner glow.
	_ellipse_outline(center, rx * 0.995, ry * 0.995, theme["rim_dark"].lightened(0.18), 2.0, 0.55)
	_ellipse_outline(center + Vector2(0, -ry * 0.03), rx * 0.70, ry * 0.60, theme["glow"], 2.0, 0.22)

func _ellipse(center: Vector2, rx: float, ry: float, color: Color) -> void:
	if rx <= 0.0 or ry <= 0.0:
		return
	draw_set_transform(center, 0.0, Vector2(1.0, maxf(0.01, ry / rx)))
	draw_circle(Vector2.ZERO, rx, color)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _ellipse_outline(
	center: Vector2,
	rx: float,
	ry: float,
	color: Color,
	width: float,
	alpha: float
) -> void:
	draw_set_transform(center, 0.0, Vector2(1.0, maxf(0.01, ry / rx)))
	draw_arc(Vector2.ZERO, rx, 0.0, TAU, 64, Color(color.r, color.g, color.b, alpha), width, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
