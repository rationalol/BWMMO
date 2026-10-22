extends Control

const UI = preload("res://scripts/ui_theme.gd")

const ANIM_ROOT := "res://assets/bw/pokemon_anim"
const ANIM_MANIFEST := "res://assets/bw/pokemon_anim/manifest.json"

static var _anim_manifest: Dictionary = {}
static var _anim_manifest_loaded := false

var species_id := ""
var species := "Snivy"
var type_name := "Grass"
var is_wild := false
var sprite_texture: Texture2D = null
var anim_sheet: Texture2D = null
var anim_frame_width := 0
var anim_frame_height := 0
var anim_frame_count := 0
var anim_durations: Array = []
var anim_index := 0
var anim_elapsed := 0.0
var _frozen := false

func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	resized.connect(queue_redraw)
	set_process(true)

func _load_manifest() -> Dictionary:
	if _anim_manifest_loaded:
		return _anim_manifest
	_anim_manifest_loaded = true
	if not FileAccess.file_exists(ANIM_MANIFEST):
		return _anim_manifest
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(ANIM_MANIFEST))
	if parsed is Dictionary:
		_anim_manifest = parsed
	return _anim_manifest

func _load_animation(id: String, side: String) -> bool:
	var manifest := _load_manifest()
	var species_entry: Variant = manifest.get("species", {}).get(id, null)
	if not (species_entry is Dictionary):
		return false
	var side_entry: Variant = species_entry.get(side, null)
	if not (side_entry is Dictionary):
		return false
	var file_name := str(side_entry.get("sheet", ""))
	if file_name == "":
		return false
	var path := "%s/%s" % [ANIM_ROOT, file_name]
	if not ResourceLoader.exists(path):
		return false
	anim_sheet = load(path)
	anim_frame_width = int(side_entry.get("frameWidth", 0))
	anim_frame_height = int(side_entry.get("frameHeight", 0))
	anim_frame_count = int(side_entry.get("frames", 0))
	anim_durations = side_entry.get("durations", [])
	anim_index = 0
	anim_elapsed = 0.0
	return (
		anim_sheet != null
		and anim_frame_width > 0
		and anim_frame_height > 0
		and anim_frame_count > 0
	)

func setup(id: String, species_name: String, creature_type: String, wild: bool) -> void:
	species_id = id
	species = species_name
	type_name = creature_type
	is_wild = wild
	_frozen = false
	sprite_texture = null
	anim_sheet = null
	anim_frame_count = 0
	anim_index = 0
	anim_elapsed = 0.0
	var side := "front" if wild else "back"
	if id != "":
		_load_animation(id, side)
		var path := "res://assets/bw/pokemon/%s_%s.png" % [id, side]
		if ResourceLoader.exists(path):
			sprite_texture = load(path)
	queue_redraw()

func _process(delta: float) -> void:
	if _frozen or anim_sheet == null or anim_frame_count <= 1:
		return
	anim_elapsed += delta * 1000.0
	var guard := 0
	while guard < anim_frame_count:
		guard += 1
		var duration := 100.0
		if anim_index < anim_durations.size():
			duration = maxf(20.0, float(anim_durations[anim_index]))
		if anim_elapsed < duration:
			break
		anim_elapsed -= duration
		anim_index = (anim_index + 1) % anim_frame_count
		queue_redraw()

func set_frozen(frozen: bool) -> void:
	_frozen = frozen

func is_frozen() -> bool:
	return _frozen

func _draw() -> void:
	var center := Vector2(size.x * 0.5, size.y * 0.5 + 16)
	if anim_sheet != null or sprite_texture != null:
		var tex_size := Vector2(anim_frame_width, anim_frame_height)
		if anim_sheet == null:
			tex_size = sprite_texture.get_size()
		if tex_size.x > 0 and tex_size.y > 0:
			var fit := minf((size.x - 24.0) / tex_size.x, (size.y - 16.0) / tex_size.y)
			var scale_factor := clampf(fit, 0.5, 8.0)
			var draw_size := tex_size * scale_factor
			var feet := Vector2(size.x * 0.5, size.y - 6.0)
			var top_left := feet - Vector2(draw_size.x * 0.5, draw_size.y)
			var shadow := Vector2(feet.x, feet.y - 3.0)
			draw_set_transform(
				shadow,
				0.0,
				Vector2(1.0, maxf(0.14, draw_size.y * 0.045 / maxf(1.0, draw_size.x * 0.24)))
			)
			draw_circle(Vector2.ZERO, draw_size.x * 0.24, Color(0.01, 0.06, 0.03, 0.24))
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			if anim_sheet != null:
				var source := Rect2(
					anim_index * anim_frame_width,
					0,
					anim_frame_width,
					anim_frame_height
				)
				draw_texture_rect_region(
					anim_sheet,
					Rect2(top_left, draw_size),
					source
				)
			else:
				draw_texture_rect(
					sprite_texture,
					Rect2(top_left, draw_size),
					false
				)
			return

	var body_color := UI.type_color(type_name)
	var light := body_color.lightened(0.18)
	var dark := body_color.darkened(0.25)

	draw_set_transform(center + Vector2(0, 54), 0.0, Vector2(1.0, 0.30))
	draw_circle(Vector2.ZERO, 54, Color(0, 0, 0, 0.30))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	if type_name == "Electric":
		draw_colored_polygon(
			PackedVector2Array([
				center + Vector2(-40, -30),
				center + Vector2(-48, -78),
				center + Vector2(-16, -42)
			]),
			dark
		)
		draw_colored_polygon(
			PackedVector2Array([
				center + Vector2(40, -30),
				center + Vector2(48, -78),
				center + Vector2(16, -42)
			]),
			dark
		)
	elif type_name == "Grass":
		draw_line(center + Vector2(0, -42), center + Vector2(6, -70), Color(0.20, 0.45, 0.22), 5.0)
		draw_circle(center + Vector2(10, -74), 14, Color(0.35, 0.68, 0.32))
		draw_circle(center + Vector2(2, -80), 8, Color(0.55, 0.82, 0.40))
	elif type_name == "Fire":
		draw_colored_polygon(
			PackedVector2Array([
				center + Vector2(-30, -36),
				center + Vector2(-20, -70),
				center + Vector2(-4, -40)
			]),
			dark
		)
		draw_colored_polygon(
			PackedVector2Array([
				center + Vector2(30, -36),
				center + Vector2(20, -70),
				center + Vector2(4, -40)
			]),
			dark
		)

	draw_circle(center, 48, dark)
	draw_circle(center + Vector2(0, 3), 42, body_color)
	draw_circle(center + Vector2(-15, 10), 22, light)
	draw_circle(center + Vector2(16, 12), 15, light)

	var eye := Color(0.08, 0.10, 0.13)
	var eye_offset := Vector2(-12, -8) if is_wild else Vector2(-8, -8)
	draw_circle(center + eye_offset + Vector2(-7, 0), 6.5, Color(0.98, 0.98, 0.96))
	draw_circle(center + eye_offset + Vector2(13, 0), 6.5, Color(0.98, 0.98, 0.96))
	draw_circle(center + eye_offset + Vector2(-5, 1), 3.0, eye)
	draw_circle(center + eye_offset + Vector2(15, 1), 3.0, eye)

	draw_line(center + Vector2(-6, 16), center + Vector2(2, 20), eye, 2.0)
	draw_line(center + Vector2(2, 20), center + Vector2(9, 15), eye, 2.0)
	draw_circle(center + Vector2(-28, 16), 5.0, Color(1.0, 0.55, 0.55, 0.35))
	draw_circle(center + Vector2(28, 16), 5.0, Color(1.0, 0.55, 0.55, 0.35))
