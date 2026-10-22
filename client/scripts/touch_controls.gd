extends Control

signal dir_changed(direction: String)
signal interact_pressed
signal chat_pressed

const UI = preload("res://scripts/ui_theme.gd")

var _active_dir := ""

func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	Loc.locale_changed.connect(_on_locale_changed)

	var dpad := GridContainer.new()
	dpad.columns = 3
	dpad.add_theme_constant_override("h_separation", 6)
	dpad.add_theme_constant_override("v_separation", 6)
	dpad.anchor_left = 1.0
	dpad.anchor_right = 1.0
	dpad.anchor_top = 1.0
	dpad.anchor_bottom = 1.0
	dpad.offset_left = -196
	dpad.offset_right = -16
	dpad.offset_top = -196
	dpad.offset_bottom = -16
	dpad.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(dpad)

	_add_spacer(dpad)
	_add_direction(dpad, "^", "up")
	_add_spacer(dpad)
	_add_direction(dpad, "<", "left")
	_add_spacer(dpad)
	_add_direction(dpad, ">", "right")
	_add_spacer(dpad)
	_add_direction(dpad, "v", "down")
	_add_spacer(dpad)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	actions.anchor_left = 1.0
	actions.anchor_right = 1.0
	actions.anchor_top = 1.0
	actions.anchor_bottom = 1.0
	actions.offset_left = -196
	actions.offset_right = -16
	actions.offset_top = -258
	actions.offset_bottom = -208
	add_child(actions)

	var talk := Button.new()
	talk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	talk.focus_mode = Control.FOCUS_NONE
	talk.add_theme_stylebox_override("normal", _round_style(Color(0.07, 0.11, 0.15, 0.78)))
	talk.add_theme_stylebox_override("hover", _round_style(Color(0.12, 0.18, 0.24, 0.9)))
	talk.add_theme_stylebox_override("pressed", _round_style(Color(0.18, 0.27, 0.35, 0.95)))
	talk.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	talk.add_theme_color_override("font_color", UI.TEXT)
	UI.apply_font(talk, 15)
	Loc.bind(talk, "Talk")
	talk.pressed.connect(func() -> void: interact_pressed.emit())
	actions.add_child(talk)

	var chat := Button.new()
	chat.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chat.focus_mode = Control.FOCUS_NONE
	chat.add_theme_stylebox_override("normal", _round_style(Color(0.07, 0.11, 0.15, 0.78)))
	chat.add_theme_stylebox_override("hover", _round_style(Color(0.12, 0.18, 0.24, 0.9)))
	chat.add_theme_stylebox_override("pressed", _round_style(Color(0.18, 0.27, 0.35, 0.95)))
	chat.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	chat.add_theme_color_override("font_color", UI.TEXT)
	UI.apply_font(chat, 15)
	Loc.bind(chat, "Chat")
	chat.pressed.connect(func() -> void: chat_pressed.emit())
	actions.add_child(chat)

func _on_locale_changed(_code: String) -> void:
	Loc.refresh_all(self)

func _add_spacer(parent: Control) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(56, 56)
	spacer.mouse_filter = MOUSE_FILTER_IGNORE
	parent.add_child(spacer)

func _add_direction(parent: Control, text: String, direction: String) -> void:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(56, 56)
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 22)
	button.add_theme_stylebox_override("normal", _round_style(Color(0.07, 0.11, 0.15, 0.78)))
	button.add_theme_stylebox_override("hover", _round_style(Color(0.12, 0.18, 0.24, 0.9)))
	button.add_theme_stylebox_override("pressed", _round_style(Color(0.28, 0.50, 0.36, 0.95)))
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	button.add_theme_color_override("font_color", UI.TEXT)
	button.button_down.connect(_on_dir_down.bind(direction))
	button.button_up.connect(_on_dir_up.bind(direction))
	parent.add_child(button)

func _round_style(color: Color) -> StyleBoxFlat:
	var style := UI.button_style(color, 10)
	return style

func _on_dir_down(direction: String) -> void:
	_active_dir = direction
	dir_changed.emit(direction)

func _on_dir_up(direction: String) -> void:
	if _active_dir == direction:
		_active_dir = ""
		dir_changed.emit("")
