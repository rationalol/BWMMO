extends Control

# On-screen controls for touch devices (Android), matching the NDS pad layout:
# the D-pad sits under the left thumb and A/B/X/Y under the right thumb.
#
# A = interact/confirm, B = cancel/back (hold while moving to run, as in the
# original games). X and Y are present but reserved for later features, the
# same way the desktop client reserves U and I.
#
# The world-mode face buttons use the NDS diamond: X top, Y left, A right,
# B bottom. In dialogue the D-pad and X/Y hide and A/B move to the right edge
# of the screen, clear of the dialogue panel.

signal dir_changed(direction: String)
signal interact_pressed
signal cancel_pressed
signal b_held(held: bool)
signal extra_pressed(button: String)

const UI = preload("res://scripts/ui_theme.gd")

const MODE_HIDDEN := "hidden"
const MODE_WORLD := "world"
const MODE_DIALOGUE := "dialogue"

const PAD_SIZE := 196.0
const PAD_BUTTON := 62.0
const FACE_BUTTON := 64.0
const ACTION_MARGIN := 16.0

var mode := MODE_HIDDEN

var _pad: Control
var _dir_buttons: Dictionary = {}
var _active_dir := ""
var _face_plate: Control
var _buttons: Dictionary = {}
var _fade_tween: Tween


class DirButton:
	extends Button

	var direction := "up"

	func _init(dir: String) -> void:
		direction = dir
		text = ""
		focus_mode = Control.FOCUS_NONE
		keep_pressed_outside = true
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	func _draw() -> void:
		var center := size * 0.5
		var half := minf(size.x, size.y) * 0.5
		var reach := half * 0.40
		var spread := half * 0.34
		var points := PackedVector2Array()
		match direction:
			"up":
				points.append(center + Vector2(0, -reach))
				points.append(center + Vector2(-spread, reach * 0.55))
				points.append(center + Vector2(spread, reach * 0.55))
			"down":
				points.append(center + Vector2(0, reach))
				points.append(center + Vector2(-spread, -reach * 0.55))
				points.append(center + Vector2(spread, -reach * 0.55))
			"left":
				points.append(center + Vector2(-reach, 0))
				points.append(center + Vector2(reach * 0.55, -spread))
				points.append(center + Vector2(reach * 0.55, spread))
			"right":
				points.append(center + Vector2(reach, 0))
				points.append(center + Vector2(-reach * 0.55, -spread))
				points.append(center + Vector2(-reach * 0.55, spread))
		var tint := Color(1, 1, 1, 0.92)
		if button_pressed:
			tint = Color(0.06, 0.10, 0.08, 0.95)
		draw_colored_polygon(points, tint)


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	_build_pad()
	_build_face()
	Loc.locale_changed.connect(_on_locale_changed)
	set_mode(MODE_HIDDEN)


func set_mode(value: String) -> void:
	if value == mode and value == MODE_HIDDEN:
		visible = false
		return
	var was_hidden := mode == MODE_HIDDEN
	mode = value
	visible = value != MODE_HIDDEN
	var world := value == MODE_WORLD
	if _pad != null:
		_pad.visible = world
		_face_plate.visible = world
		_buttons["x"].visible = world
		_buttons["y"].visible = world
		_buttons["a"].visible = value != MODE_HIDDEN
		_buttons["b"].visible = value != MODE_HIDDEN
	if not world:
		_clear_direction()
		# Moving into a dialogue or a modal must not leave "B is held" latched
		# if the button was pressed while walking.
		if _buttons["b"].button_pressed:
			_buttons["b"].set_pressed_no_signal(false)
			b_held.emit(false)
	_apply_face_positions(value)
	if visible and was_hidden:
		_fade_in()


func is_world_mode() -> bool:
	return mode == MODE_WORLD


func _fade_in() -> void:
	if _fade_tween != null:
		_fade_tween.kill()
	modulate.a = 0.0
	_fade_tween = create_tween()
	_fade_tween.tween_property(self, "modulate:a", 1.0, 0.16)


func _build_pad() -> void:
	_pad = Control.new()
	_pad.name = "DPad"
	_pad.anchor_left = 0.0
	_pad.anchor_right = 0.0
	_pad.anchor_top = 1.0
	_pad.anchor_bottom = 1.0
	_pad.offset_left = ACTION_MARGIN
	_pad.offset_right = ACTION_MARGIN + PAD_SIZE
	_pad.offset_top = -(PAD_SIZE + ACTION_MARGIN)
	_pad.offset_bottom = -ACTION_MARGIN
	_pad.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_pad)

	var plate := Panel.new()
	plate.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	plate.mouse_filter = MOUSE_FILTER_IGNORE
	plate.add_theme_stylebox_override(
		"panel", UI.glass_style(Color(0.02, 0.05, 0.08, 0.22), 28,
			Color(1, 1, 1, 0.05), 1, 0)
	)
	_pad.add_child(plate)

	var positions := {
		"up": Vector2(67, 0),
		"left": Vector2(0, 67),
		"right": Vector2(134, 67),
		"down": Vector2(67, 134),
	}
	for direction in positions:
		var button := DirButton.new(direction)
		button.position = positions[direction]
		button.size = Vector2(PAD_BUTTON, PAD_BUTTON)
		button.add_theme_stylebox_override("normal", _pad_style(0.42))
		button.add_theme_stylebox_override("hover", _pad_style(0.55))
		button.add_theme_stylebox_override("pressed", _pad_pressed_style())
		button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		button.button_down.connect(_on_dir_down.bind(direction))
		button.button_up.connect(_on_dir_up.bind(direction))
		_pad.add_child(button)
		_dir_buttons[direction] = button

	var hub := Panel.new()
	hub.position = Vector2(70, 70)
	hub.size = Vector2(56, 56)
	hub.mouse_filter = MOUSE_FILTER_IGNORE
	hub.add_theme_stylebox_override(
		"panel", UI.glass_style(Color(0.02, 0.05, 0.08, 0.30), 28,
			Color(1, 1, 1, 0.06), 1, 0)
	)
	_pad.add_child(hub)


func _build_face() -> void:
	_face_plate = Control.new()
	_face_plate.name = "FacePlate"
	_face_plate.anchor_left = 1.0
	_face_plate.anchor_right = 1.0
	_face_plate.anchor_top = 1.0
	_face_plate.anchor_bottom = 1.0
	_face_plate.offset_left = -(PAD_SIZE + ACTION_MARGIN)
	_face_plate.offset_right = -ACTION_MARGIN
	_face_plate.offset_top = -(PAD_SIZE + ACTION_MARGIN)
	_face_plate.offset_bottom = -ACTION_MARGIN
	_face_plate.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_face_plate)
	var plate := Panel.new()
	plate.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	plate.mouse_filter = MOUSE_FILTER_IGNORE
	plate.add_theme_stylebox_override(
		"panel", UI.glass_style(Color(0.02, 0.05, 0.08, 0.22), 28,
			Color(1, 1, 1, 0.05), 1, 0)
	)
	_face_plate.add_child(plate)

	_buttons["x"] = _face_button("X", false, true)
	_buttons["y"] = _face_button("Y", false, true)
	_buttons["a"] = _face_button("A", true, false)
	_buttons["b"] = _face_button("B", true, false)


func _face_button(letter: String, primary: bool, reserved: bool) -> Button:
	var button := Button.new()
	button.name = "Touch" + letter
	button.focus_mode = Control.FOCUS_NONE
	button.keep_pressed_outside = true
	button.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_anchor_face(button)

	var normal := _face_style(0.52 if primary else 0.34, primary, reserved)
	var hover := _face_style(0.62 if primary else 0.44, primary, reserved)
	var pressed := _face_style(0.78 if primary else 0.56, primary, reserved)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	add_child(button)

	var label := UI.make_label(letter, 26 if primary else 22,
		UI.TEXT if primary else UI.MUTED)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	label.mouse_filter = MOUSE_FILTER_IGNORE
	button.add_child(label)

	match letter:
		"A":
			button.pressed.connect(func() -> void: interact_pressed.emit())
		"B":
			button.pressed.connect(func() -> void: cancel_pressed.emit())
			button.button_down.connect(func() -> void: b_held.emit(true))
			button.button_up.connect(func() -> void: b_held.emit(false))
		_:
			button.pressed.connect(func() -> void: extra_pressed.emit(letter.to_lower()))
	return button


# World: X top, Y left, A right, B bottom (NDS diamond) around the bottom-right.
# Dialogue: A/B move to the right edge, clear of the dialogue panel.
func _apply_face_positions(value: String) -> void:
	if _buttons.is_empty():
		return
	if value == MODE_DIALOGUE:
		_set_offsets(_buttons["a"], Vector2(-160, -100))
		_set_offsets(_buttons["b"], Vector2(-160, -180))
		return
	_set_offsets(_buttons["x"], Vector2(-146, -212))
	_set_offsets(_buttons["y"], Vector2(-212, -146))
	_set_offsets(_buttons["a"], Vector2(-80, -146))
	_set_offsets(_buttons["b"], Vector2(-146, -80))


func _anchor_face(button: Button) -> void:
	button.anchor_left = 1.0
	button.anchor_right = 1.0
	button.anchor_top = 1.0
	button.anchor_bottom = 1.0


func _set_offsets(button: Button, from_corner: Vector2) -> void:
	button.offset_left = from_corner.x
	button.offset_right = from_corner.x + FACE_BUTTON
	button.offset_top = from_corner.y
	button.offset_bottom = from_corner.y + FACE_BUTTON


func _pad_style(alpha: float) -> StyleBoxFlat:
	return UI.glass_style(Color(0.03, 0.07, 0.10, alpha), 16,
		Color(1, 1, 1, 0.10), 1, 0)


func _pad_pressed_style() -> StyleBoxFlat:
	return UI.glass_style(Color(0.18, 0.42, 0.30, 0.88), 16,
		UI.ACCENT, 2, 0)


func _face_style(alpha: float, primary: bool, reserved: bool) -> StyleBoxFlat:
	var border := Color(1, 1, 1, 0.12)
	if primary:
		border = Color(UI.ACCENT.r, UI.ACCENT.g, UI.ACCENT.b, 0.55)
	elif reserved:
		border = Color(1, 1, 1, 0.07)
	return UI.glass_style(Color(0.03, 0.07, 0.10, alpha), 32, border, 1, 0)


func _on_dir_down(direction: String) -> void:
	_active_dir = direction
	dir_changed.emit(direction)


func _on_dir_up(direction: String) -> void:
	if _active_dir == direction:
		_active_dir = ""
		dir_changed.emit("")


func _clear_direction() -> void:
	for button in _dir_buttons.values():
		(button as Button).set_pressed_no_signal(false)
	if _active_dir != "":
		_active_dir = ""
		dir_changed.emit("")


func _on_locale_changed(_code: String) -> void:
	# ABXY are fixed letters; nothing to re-translate, but keep the connection
	# so future captions (X/Y actions) can refresh here.
	pass
