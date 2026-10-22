extends Control

signal create_requested(character_name: String, color: String, starter_id: String)

const UI = preload("res://scripts/ui_theme.gd")
const COLORS := [
	"#e76f51",
	"#2a9d8f",
	"#457b9d",
	"#9b5de5",
	"#f4a261",
	"#577590",
	"#e63946",
	"#43aa8b"
]
const FALLBACK_STARTERS := [
	{
		"id": "snivy",
		"name": "Snivy",
		"types": ["Grass"],
		"level": 5,
		"moves": ["Tackle", "Vine Whip", "Quick Attack"]
	},
	{
		"id": "tepig",
		"name": "Tepig",
		"types": ["Fire"],
		"level": 5,
		"moves": ["Tackle", "Ember", "Quick Attack"]
	},
	{
		"id": "oshawott",
		"name": "Oshawott",
		"types": ["Water"],
		"level": 5,
		"moves": ["Tackle", "Water Gun", "Quick Attack"]
	}
]

var name_input: LineEdit
var status_label: Label
var create_button: Button
var color_buttons: Array = []
var starter_buttons: Array = []
var starter_options: Array = []
var selected_color := COLORS[0]
var selected_starter := "snivy"
var _starter_row: HBoxContainer
var _starter_hint: Label

func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_STOP
	Loc.locale_changed.connect(_on_locale_changed)

	var background := ColorRect.new()
	background.color = Color(0.043, 0.067, 0.090, 0.96)
	background.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(background)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UI.panel_style(UI.PANEL, 18))
	panel.custom_minimum_size = Vector2(620, 0)
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 30)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_right", 30)
	margin.add_theme_constant_override("margin_bottom", 14)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)

	var title := Loc.make_label("Create your trainer", 26, UI.TEXT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var subtitle := Loc.make_label(
		"Pick a look and a partner. The trainer name is unique across the server.",
		11,
		UI.MUTED
	)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(subtitle)

	box.add_child(Loc.make_label("Trainer name", 11, UI.MUTED))
	name_input = LineEdit.new()
	UI.style_line_edit(name_input)
	Loc.bind(name_input, "2-16 letters, numbers, or underscores")
	name_input.max_length = 16
	box.add_child(name_input)

	box.add_child(Loc.make_label("Trainer color", 11, UI.MUTED))
	var swatches := HBoxContainer.new()
	swatches.add_theme_constant_override("separation", 6)
	box.add_child(swatches)
	for i in range(COLORS.size()):
		var button := Button.new()
		button.custom_minimum_size = Vector2(44, 44)
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(_on_color_pressed.bind(i))
		swatches.add_child(button)
		color_buttons.append(button)

	box.add_child(Loc.make_label("Choose your partner", 11, UI.MUTED))
	_starter_row = HBoxContainer.new()
	_starter_row.add_theme_constant_override("separation", 6)
	box.add_child(_starter_row)
	_starter_hint = UI.make_label("", 11, UI.MUTED)
	_starter_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_starter_hint)

	create_button = Button.new()
	UI.style_button(create_button, true)
	Loc.bind(create_button, "Enter Unova")
	create_button.pressed.connect(_on_create_pressed)
	name_input.text_submitted.connect(_on_name_submitted)
	box.add_child(create_button)

	status_label = UI.make_label("", 11, UI.DANGER)
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.custom_minimum_size = Vector2(0, 26)
	box.add_child(status_label)

	set_starters(FALLBACK_STARTERS)
	_refresh_colors()

func set_starters(options: Array) -> void:
	var source: Array = options if not options.is_empty() else FALLBACK_STARTERS
	starter_options = source.duplicate(true)
	var valid := false
	for option in starter_options:
		if option is Dictionary and str(option.get("id", "")) == selected_starter:
			valid = true
			break
	if not valid:
		selected_starter = str((starter_options[0] as Dictionary).get("id", "snivy"))
	_rebuild_starter_row()

func _rebuild_starter_row() -> void:
	if _starter_row == null:
		return
	for child in _starter_row.get_children():
		_starter_row.remove_child(child)
		child.queue_free()
	starter_buttons.clear()
	for option in starter_options:
		if not (option is Dictionary):
			continue
		var species_id := str(option.get("id", ""))
		var species_name := UI.translate_or(
			"species", species_id, str(option.get("name", "?"))
		)
		var types: Array = option.get("types", [])
		var type_name := str(types[0]) if not types.is_empty() else "Normal"
		var button := Button.new()
		button.text = "%s  -  %s" % [species_name, UI.type_label(type_name)]
		button.custom_minimum_size = Vector2(0, 50)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UI.apply_font(button, 11)
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(_on_starter_pressed.bind(species_id))
		_starter_row.add_child(button)
		starter_buttons.append(button)
	_refresh_starters()

func _on_locale_changed(_code: String) -> void:
	Loc.refresh_all(self)
	_rebuild_starter_row()

func _on_color_pressed(index: int) -> void:
	selected_color = COLORS[index]
	_refresh_colors()

func _on_starter_pressed(starter_id: String) -> void:
	selected_starter = starter_id
	_refresh_starters()

func _refresh_colors() -> void:
	for i in range(color_buttons.size()):
		var button: Button = color_buttons[i]
		var color := Color(COLORS[i])
		var selected: bool = COLORS[i] == selected_color
		var style := StyleBoxFlat.new()
		style.bg_color = color
		style.corner_radius_top_left = 8
		style.corner_radius_top_right = 8
		style.corner_radius_bottom_left = 8
		style.corner_radius_bottom_right = 8
		style.border_width_left = 3 if selected else 1
		style.border_width_top = 3 if selected else 1
		style.border_width_right = 3 if selected else 1
		style.border_width_bottom = 3 if selected else 1
		style.border_color = UI.TEXT if selected else Color(0, 0, 0, 0.35)
		button.add_theme_stylebox_override("normal", style)
		button.add_theme_stylebox_override("hover", style)
		button.add_theme_stylebox_override("pressed", style)
		button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

func _refresh_starters() -> void:
	if _starter_row == null:
		return
	var selected_option: Dictionary = {}
	for i in range(starter_buttons.size()):
		if i >= starter_options.size():
			continue
		var option: Dictionary = starter_options[i]
		var button: Button = starter_buttons[i]
		var types: Array = option.get("types", [])
		var type_name := str(types[0]) if not types.is_empty() else "Normal"
		var type_color := UI.type_color(type_name)
		var selected := str(option.get("id", "")) == selected_starter
		if selected:
			selected_option = option
		var style := UI.button_style(Color(0.043, 0.075, 0.106, 1.0), 8)
		style.border_width_left = 2 if selected else 1
		style.border_width_top = 2 if selected else 1
		style.border_width_right = 2 if selected else 1
		style.border_width_bottom = 2 if selected else 1
		style.border_color = type_color if selected else Color(1, 1, 1, 0.06)
		button.add_theme_stylebox_override("normal", style)
		button.add_theme_stylebox_override("hover", style)
		button.add_theme_stylebox_override("pressed", style)
		button.add_theme_color_override("font_color", type_color if selected else UI.TEXT)
	if selected_option.is_empty():
		_starter_hint.text = ""
		return
	var moves: Array = selected_option.get("moves", [])
	var move_names: Array = []
	for move in moves:
		var move_name := str(move)
		move_names.append(
			UI.translate_or("move", move_name.to_snake_case(), move_name)
		)
	_starter_hint.text = Loc.tf("Lv.%d - %s", [
		int(selected_option.get("level", 5)),
		" / ".join(move_names)
	])

func _on_name_submitted(_text: String) -> void:
	_on_create_pressed()

func _on_create_pressed() -> void:
	var character_name := name_input.text.strip_edges()
	if character_name.length() < 2:
		set_status(Loc.t("Trainer name must be at least 2 characters."), true)
		return
	if character_name.length() > 16:
		set_status(Loc.t("Trainer name must be at most 16 characters."), true)
		return
	if selected_starter == "":
		set_status(Loc.t("Choose a partner Pokemon."), true)
		return
	create_button.disabled = true
	set_status(Loc.t("Creating trainer..."), false)
	create_requested.emit(character_name, selected_color, selected_starter)

func set_status(text: String, is_error: bool = true) -> void:
	status_label.text = text
	status_label.add_theme_color_override("font_color", UI.DANGER if is_error else UI.MUTED)

func set_busy(busy: bool) -> void:
	create_button.disabled = busy
	name_input.editable = not busy
	for button in color_buttons:
		button.disabled = busy
	for button in starter_buttons:
		button.disabled = busy

func reset(name_hint: String = "") -> void:
	name_input.text = name_hint
	set_status("", false)
	set_busy(false)
	_refresh_starters()
	name_input.grab_focus()

func select_starter_for_test(starter_id: String) -> void:
	for option in starter_options:
		if option is Dictionary and str(option.get("id", "")) == starter_id:
			selected_starter = starter_id
			_refresh_starters()
			return

func submit_for_test() -> void:
	_on_create_pressed()
