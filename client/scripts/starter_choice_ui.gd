extends Control

signal chosen(option_id: String)

const UI = preload("res://scripts/ui_theme.gd")
const FxScript = preload("res://scripts/starter_scene_fx.gd")

const BACKGROUND_PATH := "res://assets/ui/starter/room_bg.png"
const BOX_PATH := "res://assets/ui/starter/gift_box.png"
const BALL_PATH := "res://assets/ui/starter/poke_ball.png"
const GLOW_PATH := "res://assets/ui/starter/glow.png"
const POKEMON_ROOT := "res://assets/bw/pokemon"

const STAGE_SIZE := Vector2(960, 540)
const BOX_POS := Vector2(140, 20)
const BOX_SIZE := Vector2(680, 510)
const BALL_SLOTS := [
	Vector2(0.3375, 0.523),
	Vector2(0.5, 0.523),
	Vector2(0.6625, 0.523)
]
const BALL_BUTTON_SIZE := 120.0
const BALL_ICON_SIZE := 92.0
const POKEMON_SIZE := 176.0
const POKEMON_TARGET := Vector2(480, 145)  # centre of the floating partner
const FALLBACK_TYPES := {
	"snivy": "Grass",
	"tepig": "Fire",
	"oshawott": "Water"
}

var _options: Array = []
var _buttons: Array = []
var _ball_icons: Array = []
var _ball_glows: Array = []
var _ball_rings: Array = []
var _base_positions: Array = []
var _selected := -1
var _hovered := -1
var _accepting := false
var _time := 0.0

var _backdrop: Control
var _background: TextureRect
var _stage: Control
var _box: TextureRect
var _ball_layer: Control
var _name_label: Label
var _types_wrapper: CenterContainer
var _types_row: HBoxContainer
var _pokemon_holder: Control
var _pokemon_glow: TextureRect
var _pokemon: TextureRect
var _pokemon_placeholder: Label
var _prompt_label: Label
var _detail_label: Label
var _confirm_button: Button
var _hint_label: Label
var _intro_tween: Tween
var _partner_tween: Tween
var _label_tween: Tween

func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_STOP
	visible = false
	Loc.locale_changed.connect(_on_locale_changed)
	_build()
	_refresh_detail()

func _build() -> void:
	# The backdrop fades in with the stage so the cutscene does not snap on top
	# of the bedroom dialogue.
	_backdrop = Control.new()
	_backdrop.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_backdrop.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_backdrop)

	var fallback := ColorRect.new()
	fallback.color = Color(0.075, 0.047, 0.102)
	fallback.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	fallback.mouse_filter = MOUSE_FILTER_IGNORE
	_backdrop.add_child(fallback)

	_background = TextureRect.new()
	_background.texture = _load_texture(BACKGROUND_PATH)
	_background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_background.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_background.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_background.mouse_filter = MOUSE_FILTER_IGNORE
	_backdrop.add_child(_background)

	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	centre.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(centre)

	_stage = Control.new()
	_stage.custom_minimum_size = STAGE_SIZE
	_stage.size = STAGE_SIZE
	_stage.mouse_filter = MOUSE_FILTER_IGNORE
	centre.add_child(_stage)

	var box_fallback := Panel.new()
	box_fallback.position = BOX_POS + Vector2(40, 40)
	box_fallback.size = BOX_SIZE - Vector2(80, 80)
	var box_style := UI.panel_style(Color(0.29, 0.16, 0.38, 0.9), 26)
	box_style.shadow_size = 18
	box_fallback.add_theme_stylebox_override("panel", box_style)
	box_fallback.mouse_filter = MOUSE_FILTER_IGNORE
	_stage.add_child(box_fallback)

	_box = TextureRect.new()
	_box.texture = _load_texture(BOX_PATH)
	_box.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_box.stretch_mode = TextureRect.STRETCH_SCALE
	_box.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_box.position = BOX_POS
	_box.size = BOX_SIZE
	_box.mouse_filter = MOUSE_FILTER_IGNORE
	_stage.add_child(_box)

	var fx: Control = FxScript.new()
	fx.position = Vector2.ZERO
	fx.size = STAGE_SIZE
	fx.mouse_filter = MOUSE_FILTER_IGNORE
	_stage.add_child(fx)

	_ball_layer = Control.new()
	_ball_layer.size = STAGE_SIZE
	_ball_layer.mouse_filter = MOUSE_FILTER_PASS
	_stage.add_child(_ball_layer)

	_build_partner_stage()
	_build_dialogue()
	_build_hint()

func _build_partner_stage() -> void:
	_name_label = UI.make_bold_label("", 22, UI.TEXT)
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_name_label.position = Vector2(0, 6)
	_name_label.size = Vector2(STAGE_SIZE.x, 30)
	_name_label.add_theme_constant_override("outline_size", 5)
	_name_label.add_theme_color_override("font_outline_color", Color(0.10, 0.05, 0.15, 0.92))
	_name_label.mouse_filter = MOUSE_FILTER_IGNORE
	_name_label.modulate.a = 0.0
	_stage.add_child(_name_label)

	_types_wrapper = CenterContainer.new()
	_types_wrapper.position = Vector2(0, 37)
	_types_wrapper.size = Vector2(STAGE_SIZE.x, 24)
	_types_wrapper.mouse_filter = MOUSE_FILTER_IGNORE
	_types_wrapper.modulate.a = 0.0
	_stage.add_child(_types_wrapper)

	_types_row = HBoxContainer.new()
	_types_row.add_theme_constant_override("separation", 6)
	_types_row.mouse_filter = MOUSE_FILTER_IGNORE
	_types_wrapper.add_child(_types_row)

	_pokemon_holder = Control.new()
	_pokemon_holder.size = Vector2(POKEMON_SIZE, POKEMON_SIZE)
	_pokemon_holder.pivot_offset = _pokemon_holder.size * 0.5
	_pokemon_holder.position = POKEMON_TARGET - _pokemon_holder.size * 0.5
	_pokemon_holder.mouse_filter = MOUSE_FILTER_IGNORE
	_pokemon_holder.visible = false
	_stage.add_child(_pokemon_holder)

	_pokemon_glow = TextureRect.new()
	_pokemon_glow.texture = _load_texture(GLOW_PATH)
	_pokemon_glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_pokemon_glow.stretch_mode = TextureRect.STRETCH_SCALE
	_pokemon_glow.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_pokemon_glow.position = Vector2(-72, -72)
	_pokemon_glow.size = Vector2(320, 320)
	_pokemon_glow.pivot_offset = _pokemon_glow.size * 0.5
	_pokemon_glow.mouse_filter = MOUSE_FILTER_IGNORE
	_pokemon_holder.add_child(_pokemon_glow)

	_pokemon = TextureRect.new()
	_pokemon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_pokemon.stretch_mode = TextureRect.STRETCH_SCALE
	_pokemon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_pokemon.size = _pokemon_holder.size
	_pokemon.mouse_filter = MOUSE_FILTER_IGNORE
	_pokemon_holder.add_child(_pokemon)

	_pokemon_placeholder = UI.make_bold_label("?", 64, UI.TEXT)
	_pokemon_placeholder.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pokemon_placeholder.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_pokemon_placeholder.size = _pokemon_holder.size
	_pokemon_placeholder.mouse_filter = MOUSE_FILTER_IGNORE
	_pokemon_placeholder.visible = false
	_pokemon_holder.add_child(_pokemon_placeholder)

func _build_dialogue() -> void:
	var panel := PanelContainer.new()
	panel.position = Vector2(90, 410)
	panel.size = Vector2(780, 112)
	panel.custom_minimum_size = Vector2(780, 112)
	panel.mouse_filter = MOUSE_FILTER_STOP
	var style := UI.glass_style(
		Color(0.027, 0.055, 0.090, 0.95),
		14,
		Color(0.961, 0.784, 0.357, 0.38),
		1,
		0
	)
	panel.add_theme_stylebox_override("panel", style)
	UI.add_bw_frame_overlay(panel)
	_stage.add_child(panel)

	var margin := UI.add_panel_content(panel, 20, 12)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 3)
	margin.add_child(column)

	var kicker := Loc.make_label("GIFT BOX", 10, UI.GOLD)
	kicker.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	column.add_child(kicker)

	_prompt_label = UI.make_label("", 16, UI.TEXT)
	_prompt_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_prompt_label.max_lines_visible = 2
	_prompt_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(_prompt_label)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	column.add_child(row)

	_detail_label = UI.make_label("", 11, UI.MUTED)
	_detail_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_detail_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_label.clip_text = true
	_detail_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(_detail_label)

	_confirm_button = Button.new()
	_confirm_button.text = Loc.t("Choose")
	_confirm_button.focus_mode = Control.FOCUS_NONE
	_confirm_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_confirm_button.custom_minimum_size = Vector2(196, 38)
	_confirm_button.disabled = true
	_style_gold_button(_confirm_button)
	_confirm_button.pressed.connect(_confirm)
	row.add_child(_confirm_button)

func _build_hint() -> void:
	_hint_label = UI.make_label(
		"← → to look  ·  Enter or click to choose",
		9,
		Color(UI.MUTED.r, UI.MUTED.g, UI.MUTED.b, 0.9)
	)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hint_label.position = Vector2(0, 524)
	_hint_label.size = Vector2(STAGE_SIZE.x, 16)
	_hint_label.add_theme_constant_override("outline_size", 3)
	_hint_label.add_theme_color_override("font_outline_color", Color(0.06, 0.03, 0.09, 0.85))
	_hint_label.mouse_filter = MOUSE_FILTER_IGNORE
	_stage.add_child(_hint_label)

func show_choice(prompt: Array, options: Array) -> void:
	if _intro_tween != null and _intro_tween.is_valid():
		_intro_tween.kill()
	if _partner_tween != null and _partner_tween.is_valid():
		_partner_tween.kill()
	if _label_tween != null and _label_tween.is_valid():
		_label_tween.kill()
	_options.clear()
	for option in options:
		if option is Dictionary:
			_options.append((option as Dictionary).duplicate(true))
	var prompt_lines: Array = prompt if prompt is Array else [str(prompt)]
	_prompt_label.text = "\n".join(prompt_lines)
	_rebuild_balls()
	_selected = -1
	_hovered = -1
	_accepting = true
	visible = true
	_pokemon_holder.visible = false
	_name_label.modulate.a = 0.0
	_types_wrapper.modulate.a = 0.0
	_confirm_button.disabled = true
	_confirm_button.text = Loc.t("Choose")
	_refresh_detail()
	_stage.modulate.a = 0.0
	_stage.scale = Vector2(0.985, 0.985)
	_stage.pivot_offset = STAGE_SIZE * 0.5
	_backdrop.modulate.a = 0.0
	_intro_tween = create_tween().set_parallel(true)
	_intro_tween.tween_property(_backdrop, "modulate:a", 1.0, 0.25)
	_intro_tween.tween_property(_stage, "modulate:a", 1.0, 0.22).set_delay(0.04)
	_intro_tween.tween_property(_stage, "scale", Vector2.ONE, 0.32).set_trans(
		Tween.TRANS_BACK
	).set_ease(Tween.EASE_OUT)

func close() -> void:
	_accepting = false
	visible = false
	if _intro_tween != null and _intro_tween.is_valid():
		_intro_tween.kill()
	if _partner_tween != null and _partner_tween.is_valid():
		_partner_tween.kill()
	if _label_tween != null and _label_tween.is_valid():
		_label_tween.kill()

func _process(delta: float) -> void:
	if not visible:
		return
	_time += delta
	var pulse := 0.5 + 0.5 * sin(_time * 2.6)
	for index in range(_buttons.size()):
		var button: Button = _buttons[index]
		var target_scale := 1.0
		if index == _selected:
			target_scale = 1.12
		elif index == _hovered:
			target_scale = 1.06
		var speed := minf(1.0, delta * 12.0)
		button.scale = button.scale.lerp(Vector2(target_scale, target_scale), speed)
		var lift := -16.0 if index == _selected else 0.0
		var bob := sin(_time * 2.1 + float(index) * 1.8) * 2.0
		button.position = (_base_positions[index] as Vector2) + Vector2(0.0, lift + bob)
		var icon: TextureRect = _ball_icons[index]
		var glow: TextureRect = _ball_glows[index]
		var ring: Panel = _ball_rings[index]
		var glow_target := 0.0
		if index == _selected:
			glow_target = 0.72 + pulse * 0.18
		elif index == _hovered:
			glow_target = 0.34
		glow.modulate.a = lerpf(glow.modulate.a, glow_target, speed)
		icon.modulate = Color(1, 1, 1, 1).lerp(
			Color(0.8, 0.78, 0.86, 0.92), 0.0 if index == _selected else 0.55
		)
		if index == _selected:
			ring.visible = true
			ring.scale = Vector2.ONE * (1.0 + pulse * 0.045)
			ring.modulate.a = 0.72 + pulse * 0.28
		else:
			ring.visible = false
	if _pokemon_holder.visible:
		_pokemon.position.y = sin(_time * 2.3) * 3.0
		_pokemon_glow.scale = Vector2.ONE * (1.0 + sin(_time * 1.7) * 0.015)

func _rebuild_balls() -> void:
	for child in _ball_layer.get_children():
		_ball_layer.remove_child(child)
		child.queue_free()
	_buttons.clear()
	_ball_icons.clear()
	_ball_glows.clear()
	_ball_rings.clear()
	_base_positions.clear()
	var ball_texture := _load_texture(BALL_PATH)
	var glow_texture := _load_texture(GLOW_PATH)
	for index in range(_options.size()):
		var option: Dictionary = _options[index]
		var button := Button.new()
		button.text = ""
		button.flat = true
		button.focus_mode = Control.FOCUS_NONE
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button.custom_minimum_size = Vector2(BALL_BUTTON_SIZE, BALL_BUTTON_SIZE)
		button.size = Vector2(BALL_BUTTON_SIZE, BALL_BUTTON_SIZE)
		button.pivot_offset = button.size * 0.5
		button.tooltip_text = _option_name(option)
		button.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
		button.add_theme_stylebox_override("hover", StyleBoxEmpty.new())
		button.add_theme_stylebox_override("pressed", StyleBoxEmpty.new())
		button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		button.pressed.connect(_select.bind(index))
		button.mouse_entered.connect(_on_ball_hovered.bind(index))
		button.mouse_exited.connect(_on_ball_unhovered.bind(index))

		var glow := TextureRect.new()
		glow.texture = glow_texture
		glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		glow.stretch_mode = TextureRect.STRETCH_SCALE
		glow.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		glow.size = Vector2(BALL_BUTTON_SIZE, BALL_BUTTON_SIZE)
		glow.modulate = Color(1.0, 0.84, 0.45, 0.0)
		glow.mouse_filter = MOUSE_FILTER_IGNORE
		button.add_child(glow)

		var ring := Panel.new()
		ring.size = Vector2(BALL_ICON_SIZE + 20, BALL_ICON_SIZE + 20)
		ring.position = (button.size - ring.size) * 0.5
		ring.pivot_offset = ring.size * 0.5
		ring.mouse_filter = MOUSE_FILTER_IGNORE
		var ring_style := StyleBoxFlat.new()
		ring_style.bg_color = Color(1.0, 0.86, 0.47, 0.04)
		ring_style.border_color = Color(1.0, 0.88, 0.52, 0.92)
		ring_style.set_border_width_all(2)
		ring_style.set_corner_radius_all(999)
		ring_style.shadow_color = Color(1.0, 0.74, 0.25, 0.42)
		ring_style.shadow_size = 8
		ring.add_theme_stylebox_override("panel", ring_style)
		ring.visible = false
		button.add_child(ring)

		var icon := TextureRect.new()
		icon.texture = ball_texture
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_SCALE
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		icon.size = Vector2(BALL_ICON_SIZE, BALL_ICON_SIZE)
		icon.position = (button.size - icon.size) * 0.5
		icon.mouse_filter = MOUSE_FILTER_IGNORE
		button.add_child(icon)

		var centre := _ball_centre(index)
		var base := centre - button.size * 0.5
		button.position = base
		_ball_layer.add_child(button)
		_buttons.append(button)
		_ball_icons.append(icon)
		_ball_glows.append(glow)
		_ball_rings.append(ring)
		_base_positions.append(base)

func _ball_centre(index: int) -> Vector2:
	if index < BALL_SLOTS.size():
		var slot: Vector2 = BALL_SLOTS[index]
		return BOX_POS + Vector2(BOX_SIZE.x * slot.x, BOX_SIZE.y * slot.y)
	var count := maxi(_options.size(), 1)
	var x := 0.5 + (float(index) - float(count - 1) * 0.5) * 0.18
	return BOX_POS + Vector2(BOX_SIZE.x * x, BOX_SIZE.y * 0.523)

func _select(index: int) -> void:
	if not _accepting or index < 0 or index >= _options.size():
		return
	if _selected == index:
		_confirm()
		return
	_selected = index
	_hovered = index
	var option: Dictionary = _options[index]
	var partner_name := _option_name(option)
	var types := _option_types(option)
	var type_color := UI.type_color(str(types[0]))
	_name_label.text = "%s   Lv.%d" % [partner_name, int(option.get("level", 5))]
	_set_type_chips(types)
	_name_label.remove_theme_color_override("font_color")
	_name_label.add_theme_color_override("font_color", UI.TEXT)
	_pokemon.texture = _load_pokemon_texture(str(option.get("id", "")))
	_pokemon_placeholder.visible = _pokemon.texture == null
	_pokemon_glow.modulate = Color(type_color.r, type_color.g, type_color.b, 0.65)
	_pokemon_holder.visible = true
	_animate_partner(index)
	_refresh_detail()
	_fade_partner_labels()
	_confirm_button.disabled = false
	_confirm_button.text = Loc.tf("Choose %s", [partner_name])
	_hint_label.text = Loc.t("Enter or Choose to confirm  ·  Esc to look again")

func _animate_partner(index: int) -> void:
	if _partner_tween != null and _partner_tween.is_valid():
		_partner_tween.kill()
	var ball_centre := _ball_centre(index)
	_pokemon_holder.scale = Vector2(0.2, 0.2)
	_pokemon_holder.position = ball_centre - _pokemon_holder.size * 0.5
	_pokemon_holder.modulate.a = 0.0
	var target := POKEMON_TARGET - _pokemon_holder.size * 0.5
	_partner_tween = create_tween().set_parallel(true)
	_partner_tween.tween_property(_pokemon_holder, "position", target, 0.42).set_trans(
		Tween.TRANS_CUBIC
	).set_ease(Tween.EASE_OUT)
	_partner_tween.tween_property(
		_pokemon_holder, "scale", Vector2.ONE, 0.46
	).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_partner_tween.tween_property(_pokemon_holder, "modulate:a", 1.0, 0.2)

func _fade_partner_labels() -> void:
	if _label_tween != null and _label_tween.is_valid():
		_label_tween.kill()
	_name_label.modulate.a = 0.0
	_types_wrapper.modulate.a = 0.0
	_label_tween = create_tween().set_parallel(true)
	_label_tween.tween_property(_name_label, "modulate:a", 1.0, 0.2).set_delay(0.1)
	_label_tween.tween_property(_types_wrapper, "modulate:a", 1.0, 0.2).set_delay(0.16)

func _unselect() -> void:
	if _selected < 0:
		return
	_selected = -1
	_hovered = -1
	_pokemon_holder.visible = false
	_name_label.modulate.a = 0.0
	_types_wrapper.modulate.a = 0.0
	_confirm_button.disabled = true
	_confirm_button.text = Loc.t("Choose")
	_hint_label.text = Loc.t("← → to look  ·  Enter or click to choose")
	_refresh_detail()

func _confirm() -> void:
	if not _accepting or _selected < 0:
		return
	_accepting = false
	var option: Dictionary = _options[_selected]
	for button in _buttons:
		(button as Button).disabled = true
	_confirm_button.disabled = true
	_hint_label.text = Loc.t("Waiting...")
	chosen.emit(str(option.get("id", "")))

func _on_ball_hovered(index: int) -> void:
	_hovered = index
	_refresh_detail()
	if _selected < 0:
		var option: Dictionary = _options[index]
		_detail_label.text = "%s   Lv.%d   %s" % [
			_option_name(option),
			int(option.get("level", 5)),
			_type_summary(_option_types(option))
		]

func _on_ball_unhovered(index: int) -> void:
	if _selected < 0 and _hovered == index:
		_hovered = -1
		_refresh_detail()

func _refresh_detail() -> void:
	if _selected >= 0 and _selected < _options.size():
		var option: Dictionary = _options[_selected]
		_detail_label.text = "%s   Lv.%d   %s" % [
			_option_name(option),
			int(option.get("level", 5)),
			_type_summary(_option_types(option))
		]
		return
	_detail_label.text = Loc.t("Three Poké Balls rest inside the gift box.")
	_confirm_button.text = Loc.t("Choose")
	_hint_label.text = Loc.t("← → to look  ·  Enter or click to choose")

func _set_type_chips(types: Array) -> void:
	for child in _types_row.get_children():
		_types_row.remove_child(child)
		child.queue_free()
	for type_name in types:
		var label := str(type_name)
		var color := UI.type_color(label)
		var chip := PanelContainer.new()
		chip.add_theme_stylebox_override("panel", UI.chip_style(color, 5))
		chip.mouse_filter = MOUSE_FILTER_IGNORE
		var text := UI.make_label(UI.type_label(label), 10, Color(0.09, 0.07, 0.06))
		if color.get_luminance() < 0.6:
			text.add_theme_color_override("font_color", Color(1.0, 0.98, 0.94))
		text.mouse_filter = MOUSE_FILTER_IGNORE
		chip.add_child(text)
		_types_row.add_child(chip)

func _type_summary(types: Array) -> String:
	var labels: Array[String] = []
	for type_name in types:
		labels.append(UI.type_label(str(type_name)))
	return " / ".join(labels)

func _option_name(option: Dictionary) -> String:
	var species_id := str(option.get("id", ""))
	var fallback := str(option.get("name", species_id.capitalize()))
	return UI.translate_or("species", species_id, fallback)

func _option_types(option: Dictionary) -> Array:
	var types: Array = option.get("types", [])
	if not types.is_empty():
		return types
	var species_id := str(option.get("id", ""))
	return [FALLBACK_TYPES.get(species_id, "Normal")]

func _load_pokemon_texture(species_id: String) -> Texture2D:
	if species_id == "":
		return null
	return _load_texture("%s/%s_front.png" % [POKEMON_ROOT, species_id])

func _load_texture(path: String) -> Texture2D:
	if path == "" or not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D

func _style_gold_button(button: Button) -> void:
	var base := Color(0.965, 0.784, 0.333)
	var font := Color(0.137, 0.078, 0.027)
	var normal := UI.button_style(base, 9)
	normal.content_margin_left = 24
	normal.content_margin_right = 24
	normal.content_margin_top = 8
	normal.content_margin_bottom = 8
	var hover := UI.button_style(base.lightened(0.12), 9)
	hover.content_margin_left = 24
	hover.content_margin_right = 24
	hover.content_margin_top = 8
	hover.content_margin_bottom = 8
	var pressed := UI.button_style(base.darkened(0.1), 9)
	pressed.content_margin_left = 24
	pressed.content_margin_right = 24
	pressed.content_margin_top = 8
	pressed.content_margin_bottom = 8
	var disabled := UI.button_style(Color(base.r, base.g, base.b, 0.34), 9)
	disabled.content_margin_left = 24
	disabled.content_margin_right = 24
	disabled.content_margin_top = 8
	disabled.content_margin_bottom = 8
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("disabled", disabled)
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	button.add_theme_color_override("font_color", font)
	button.add_theme_color_override("font_hover_color", font)
	button.add_theme_color_override("font_pressed_color", font)
	button.add_theme_color_override("font_disabled_color", Color(font.r, font.g, font.b, 0.45))
	UI.apply_font(button, 14)

func _input(event: InputEvent) -> void:
	if not visible or not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	var key := key_event.keycode
	var consumed := false
	match key:
		KEY_LEFT, KEY_A:
			if _accepting:
				_move_hover(-1)
			consumed = true
		KEY_RIGHT, KEY_D:
			if _accepting:
				_move_hover(1)
			consumed = true
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE, KEY_J:
			if _accepting:
				if _selected >= 0:
					_confirm()
				elif _hovered >= 0:
					_select(_hovered)
				elif not _options.is_empty():
					_select(0)
			consumed = true
		KEY_ESCAPE, KEY_K:
			if _accepting and _selected >= 0:
				_unselect()
			consumed = true
	if consumed:
		get_viewport().set_input_as_handled()

func _move_hover(step: int) -> void:
	if _options.is_empty():
		return
	if _hovered < 0:
		_hovered = 0
	else:
		_hovered = posmod(_hovered + step, _options.size())
	if _selected >= 0:
		_select(_hovered)
	else:
		var option: Dictionary = _options[_hovered]
		_detail_label.text = "%s   Lv.%d   %s" % [
			_option_name(option),
			int(option.get("level", 5)),
			_type_summary(_option_types(option))
		]

func _on_locale_changed(_code: String) -> void:
	if _prompt_label == null:
		return
	Loc.refresh_all(self)
	for index in range(_buttons.size()):
		if index < _options.size():
			(_buttons[index] as Button).tooltip_text = _option_name(_options[index])
	if _selected >= 0 and _selected < _options.size():
		var option: Dictionary = _options[_selected]
		_name_label.text = "%s   Lv.%d" % [
			_option_name(option),
			int(option.get("level", 5))
		]
		_set_type_chips(_option_types(option))
		_confirm_button.text = Loc.tf("Choose %s", [_option_name(option)])
		_hint_label.text = Loc.t("Enter or Choose to confirm  ·  Esc to look again")
		_refresh_detail()
	elif _hovered >= 0 and _hovered < _options.size():
		_confirm_button.text = Loc.t("Choose")
		_refresh_detail()
	else:
		_refresh_detail()

func select_for_test(index: int) -> void:
	_select(index)

func confirm_for_test() -> void:
	_confirm()

func option_count() -> int:
	return _options.size()

func selected_index() -> int:
	return _selected
