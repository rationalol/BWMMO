extends Control

signal chosen(option_id: String)

const UI = preload("res://scripts/ui_theme.gd")

var _panel: PanelContainer
var _prompt_label: Label
var _row: HBoxContainer
var _hint_label: Label
var _options: Array = []
var _buttons: Array = []
var _accepting := false

func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_STOP
	visible = false
	Loc.locale_changed.connect(_on_locale_changed)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.045, 0.55)
	dim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	dim.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	center.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(center)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(560, 0)
	_panel.add_theme_stylebox_override(
		"panel", UI.glass_style(UI.INK, 16, UI.BORDER, 1, 0)
	)
	center.add_child(_panel)
	UI.scale_hud(_panel, Vector2(0.5, 0.5))
	UI.add_bw_frame_overlay(_panel)
	var margin := UI.add_panel_content(_panel, 22, 18)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	margin.add_child(box)

	_prompt_label = UI.make_label("", 17, UI.TEXT)
	_prompt_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_prompt_label)

	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 10)
	box.add_child(_row)

	_hint_label = Loc.make_label("Pick the partner you want to travel with.", 10, UI.MUTED)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_hint_label)

func show_choice(prompt: Array, options: Array) -> void:
	_options = options
	_prompt_label.text = "\n".join(prompt)
	_rebuild()
	visible = true
	_accepting = true
	if not _buttons.is_empty():
		(_buttons[0] as Button).grab_focus()

func close() -> void:
	_accepting = false
	visible = false

func _rebuild() -> void:
	for child in _row.get_children():
		_row.remove_child(child)
		child.queue_free()
	_buttons.clear()
	for option in _options:
		if not (option is Dictionary):
			continue
		var option_id := str(option.get("id", ""))
		var label := str(option.get("name", option_id))
		var level := int(option.get("level", 5))
		var button := Button.new()
		button.text = "%s\nLv.%d" % [label, level]
		button.custom_minimum_size = Vector2(0, 74)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.focus_mode = Control.FOCUS_ALL
		UI.style_button(button, false)
		UI.apply_font(button, 13)
		button.pressed.connect(_on_option_pressed.bind(option_id))
		_row.add_child(button)
		_buttons.append(button)

func _on_option_pressed(option_id: String) -> void:
	if not _accepting:
		return
	_accepting = false
	close()
	chosen.emit(option_id)

func _on_locale_changed(_code: String) -> void:
	Loc.refresh_all(self)
	_rebuild()
