extends CanvasLayer

# Splash/loading layer shown from process start until Main has built its UI.
# It only uses built-in drawing (no textures, fonts or theme resources) because
# it must be on screen before game.pck is mounted. Boot drives the text and
# progress; Main calls finish() once its first frame is ready.

const UI = preload("res://scripts/ui_theme.gd")

const FADE_IN := 0.35
const FADE_OUT := 0.40

var _root: Control
var _spinner: Control
var _title: Label
var _subtitle: Label
var _status: Label
var _bar: Control
var _hint: Label
var _font: Font = null
var _active := false
var _target := 0.0
var _shown := 0.0
var _localized := false
var _status_key := ""
var _status_args: Array = []


class BallSpinner:
	extends Control

	var spin := 0.0

	func _process(delta: float) -> void:
		spin += delta * 1.15
		rotation = spin
		queue_redraw()

	func _draw() -> void:
		var center := size * 0.5
		var radius := minf(size.x, size.y) * 0.46
		# Soft mint halo.
		draw_circle(center, radius * 1.28, Color(0.388, 0.902, 0.643, 0.07))
		draw_circle(center, radius * 1.13, Color(0.388, 0.902, 0.643, 0.09))
		# Bottom shell.
		draw_circle(center, radius, Color(0.90, 0.94, 0.98, 0.96))
		# Top shell as a true semicircle (the band follows the equator).
		var top := PackedVector2Array()
		top.append(center)
		for step in range(0, 33):
			var angle := PI + PI * float(step) / 32.0
			top.append(center + Vector2(cos(angle), sin(angle)) * radius)
		draw_colored_polygon(top, Color(0.86, 0.20, 0.25, 0.98))
		# Outline + equator band.
		draw_arc(center, radius, 0.0, TAU, 72, Color(0.05, 0.08, 0.11, 0.95), 3.0, true)
		draw_rect(
			Rect2(center.x - radius, center.y - radius * 0.115, radius * 2.0, radius * 0.23),
			Color(0.05, 0.08, 0.11, 0.95)
		)
		# Release button.
		draw_circle(center, radius * 0.30, Color(0.05, 0.08, 0.11, 0.98))
		draw_circle(center, radius * 0.22, Color(0.90, 0.94, 0.98, 0.98))
		draw_circle(center, radius * 0.10, Color(0.72, 0.78, 0.86, 0.95))


class LoadBar:
	extends Control

	var value := 0.0

	func _draw() -> void:
		var height := 7.0
		var top := (size.y - height) * 0.5
		var track := Rect2(Vector2(0, top), Vector2(size.x, height))
		draw_rect(track, Color(1, 1, 1, 0.09))
		var fill_width := size.x * clampf(value, 0.0, 1.0)
		if fill_width > 0.0:
			draw_rect(Rect2(Vector2(0, top), Vector2(fill_width, height)),
				Color(UI.ACCENT.r, UI.ACCENT.g, UI.ACCENT.b, 0.95))
			draw_circle(Vector2(fill_width, top + height * 0.5), height * 0.5,
				Color(UI.ACCENT.r, UI.ACCENT.g, UI.ACCENT.b, 0.95))
			draw_circle(Vector2(fill_width, top + height * 0.5), height * 2.2,
				Color(UI.ACCENT.r, UI.ACCENT.g, UI.ACCENT.b, 0.10))


func _ready() -> void:
	layer = 128
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	_root.visible = false


func _build() -> void:
	_root = Control.new()
	_root.name = "LoadingScreen"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var background := ColorRect.new()
	background.color = Color(0.024, 0.051, 0.082, 1.0)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(background)

	# The static boot-splash art doubles as the loading backdrop. It is packed
	# as a raw PNG (include_filter) precisely because this app loads it with
	# Image.load_from_file before the resource pack is mounted.
	var splash_art := _load_splash_art()
	var has_art := splash_art != null
	if has_art:
		var splash := TextureRect.new()
		splash.name = "SplashArt"
		splash.texture = splash_art
		splash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		splash.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		splash.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		splash.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_root.add_child(splash)

	# Two soft color blooms keep the procedural background from looking like a
	# dead frame while the engine is busy. They are skipped over the splash art,
	# which already carries its own glow.
	var bloom := ColorRect.new()
	bloom.color = Color(0.11, 0.35, 0.26, 0.22)
	bloom.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bloom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bloom_material := CanvasItemMaterial.new()
	bloom_material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	bloom.material = bloom_material
	bloom.visible = not has_art
	_root.add_child(bloom)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.visible = not has_art
	_root.add_child(center)

	var column := VBoxContainer.new()
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 10)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(column)

	_spinner = BallSpinner.new()
	_spinner.custom_minimum_size = Vector2(112, 112)
	_spinner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_spinner.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_spinner.pivot_offset = Vector2(56, 56)
	column.add_child(_spinner)

	_title = _make_label("BWMMO", 42, Color(0.914, 0.945, 0.980, 1.0))
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_title)

	_subtitle = _make_label("UNOVA ONLINE", 13, Color(0.388, 0.902, 0.643, 1.0))
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_subtitle)

	# Status and progress sit at the bottom of the screen in both layouts, so
	# they never cover the splash art's wordmark.
	var bottom := CenterContainer.new()
	bottom.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bottom.anchor_top = 1.0
	bottom.anchor_bottom = 1.0
	bottom.offset_top = -136
	bottom.offset_bottom = -24
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bottom)

	var bottom_column := VBoxContainer.new()
	bottom_column.alignment = BoxContainer.ALIGNMENT_END
	bottom_column.add_theme_constant_override("separation", 8)
	bottom_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bottom.add_child(bottom_column)

	# A small spinner keeps an unmistakable "still working" cue even when the
	# static splash art replaces the big procedural ball.
	var mini_spinner := BallSpinner.new()
	mini_spinner.custom_minimum_size = Vector2(22, 22)
	mini_spinner.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	mini_spinner.pivot_offset = Vector2(11, 11)
	mini_spinner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mini_spinner.visible = has_art
	bottom_column.add_child(mini_spinner)

	_status = _make_label("Starting up...", 14, Color(0.557, 0.643, 0.749, 1.0))
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bottom_column.add_child(_status)

	_bar = LoadBar.new()
	_bar.custom_minimum_size = Vector2(320, 18)
	_bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bottom_column.add_child(_bar)

	_hint = _make_label("", 11, Color(0.557, 0.643, 0.749, 0.62))
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bottom_column.add_child(_hint)


func _load_splash_art() -> Texture2D:
	# The exporter keeps the imported .ctex in the APK even though the raw PNG
	# is not included, so prefer the normal resource path. The raw fallback
	# covers builds whose include_filter carries the source file instead.
	if ResourceLoader.exists("res://boot_splash.png"):
		var texture := load("res://boot_splash.png") as Texture2D
		if texture != null:
			return texture
	var bytes := FileAccess.get_file_as_bytes("res://boot_splash.png")
	if bytes.is_empty():
		return null
	var image := Image.new()
	if image.load_png_from_buffer(bytes) != OK or image.is_empty():
		return null
	return ImageTexture.create_from_image(image)


func _make_label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", size)
	label.set_meta("loading_size", size)
	label.set_meta("loading_color", color)
	return label


func _process(delta: float) -> void:
	if not _root.visible:
		return
	_shown = move_toward(_shown, _target, delta * 0.9)
	if _bar != null:
		_bar.set("value", _shown)
		_bar.queue_redraw()


func is_active() -> bool:
	return _active and _root.visible


func show_loading(title: String = "", status: String = "") -> void:
	_active = true
	_localized = false
	_status_key = ""
	_status_args = []
	_shown = 0.0
	_target = 0.02
	_title.text = title if title != "" else "BWMMO"
	if _font != null:
		_apply_font()
	if status != "":
		_status.text = status
	if _root.visible:
		return
	_root.visible = true
	_root.modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(_root, "modulate:a", 1.0, FADE_IN)


func set_status(text: String) -> void:
	_status_key = ""
	if _status != null:
		_status.text = text


func set_status_key(key: String, args: Array = []) -> void:
	_status_key = key
	_status_args = args
	if _localized and _status != null:
		_status.text = Loc.tf(key, args)


func set_progress(value: float, status: String = "") -> void:
	_target = clampf(value, 0.0, 1.0)
	if status != "":
		set_status(status)


# Called by Boot once game.pck is mounted: switch the splash to the real UI
# font (CJK included) and re-render any localized status.
func set_font(font: Font) -> void:
	_font = font
	_localized = true
	if font != null:
		ThemeDB.fallback_font = font
	_apply_font()
	if _status_key != "":
		set_status_key(_status_key, _status_args)


func _apply_font() -> void:
	for label in [_title, _subtitle, _status, _hint]:
		if label == null:
			continue
		if _font != null:
			label.add_theme_font_override("font", _font)
		label.add_theme_font_size_override("font_size", int(label.get_meta("loading_size", 14)))


func finish(delay: float = 0.12) -> void:
	if not _active:
		return
	_active = false
	_target = 1.0
	if not _root.visible:
		return
	var tree := get_tree()
	if tree == null:
		return
	await tree.create_timer(delay).timeout
	if not is_inside_tree():
		return
	var tween := create_tween()
	tween.tween_property(_root, "modulate:a", 0.0, FADE_OUT)
	tween.tween_callback(func() -> void:
		_root.visible = false
		_root.modulate.a = 1.0
		_shown = 0.0
		_target = 0.0
	)
