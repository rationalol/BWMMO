extends Control

signal closed

const UI = preload("res://scripts/ui_theme.gd")

var _panel: PanelContainer
var _name_label: Label
var _text_label: Label
var _hint_label: Label
var _lines: Array = []
var _index := 0

func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	visible = false
	Loc.locale_changed.connect(_on_locale_changed)

	_panel = PanelContainer.new()
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -370
	_panel.offset_right = 370
	_panel.offset_top = -172
	_panel.offset_bottom = -22
	_panel.add_theme_stylebox_override(
		"panel", UI.glass_style(UI.INK, 14, UI.BORDER, 1, 0)
	)
	_panel.mouse_filter = MOUSE_FILTER_STOP
	_panel.gui_input.connect(_on_panel_input)
	add_child(_panel)
	UI.add_bw_frame_overlay(_panel)
	var panel_margin := UI.add_panel_content(_panel, 12, 10)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel_margin.add_child(box)

	_name_label = UI.make_label("", 15, UI.GOLD)
	box.add_child(_name_label)

	_text_label = UI.make_label("", 16, UI.TEXT)
	_text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text_label.custom_minimum_size = Vector2(0, 48)
	_text_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	box.add_child(_text_label)

	_hint_label = Loc.make_label("E / Space / Tap to continue", 10, UI.MUTED)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(_hint_label)

func _on_locale_changed(_code: String) -> void:
	Loc.refresh_all(self)
	if visible and not _lines.is_empty():
		_update_line()

func show_dialogue(npc_name: String, lines: Array, kind: String = "npc") -> void:
	_lines = lines
	_index = 0
	if _lines.is_empty():
		return
	_name_label.text = npc_name
	_name_label.add_theme_color_override(
		"font_color",
		UI.ACCENT if kind == "healer" else UI.GOLD
	)
	visible = true
	_update_line()

func _update_line() -> void:
	_text_label.text = str(_lines[_index])
	var key := (
		"E / Space / Tap to close"
		if _index >= _lines.size() - 1
		else "E / Space / Tap to continue"
	)
	Loc.bind(_hint_label, key)

func advance() -> void:
	if not visible:
		return
	_index += 1
	if _index >= _lines.size():
		close()
	else:
		_update_line()

func close() -> void:
	if not visible:
		return
	visible = false
	_lines = []
	closed.emit()

func _on_panel_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		advance()
		accept_event()
	elif event is InputEventScreenTouch and event.pressed:
		advance()
		accept_event()
