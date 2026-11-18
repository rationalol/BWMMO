extends Control

signal requested(message: Dictionary)
signal closed

const UI = preload("res://scripts/ui_theme.gd")
const POKEMON_ROOT := "res://assets/bw/pokemon"

var _panel: PanelContainer
var _subtitle: Label
var _party_list: VBoxContainer
var _box_list: VBoxContainer
var _selected_party := 0
var _party: Array = []
var _box: Array = []
var _max_party := 6
var _max_box := 30
var _sprite_cache: Dictionary = {}
var _dialog_layer: Control
var _dialog_title: Label
var _dialog_body: Label
var _dialog_input: LineEdit
var _dialog_confirm: Button
var _dialog_cancel: Button
var _dialog_action := ""
var _dialog_index := -1

func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_STOP
	visible = false
	Loc.locale_changed.connect(_on_locale_changed)

	var dim := ColorRect.new()
	dim.color = Color(0.008, 0.024, 0.043, 0.68)
	dim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	dim.mouse_filter = MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	center.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(center)

	_panel = PanelContainer.new()
	_panel.name = "PcPanel"
	_panel.custom_minimum_size = Vector2(860, 480)
	_panel.add_theme_stylebox_override(
		"panel", UI.glass_style(UI.INK, 14, UI.BORDER_STRONG, 1, 0)
	)
	_panel.mouse_filter = MOUSE_FILTER_STOP
	center.add_child(_panel)
	UI.add_bw_frame_overlay(_panel)
	var margin := UI.add_panel_content(_panel, 12, 10)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	box.add_child(header)
	var title_col := VBoxContainer.new()
	title_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_col.add_theme_constant_override("separation", 0)
	header.add_child(title_col)
	title_col.add_child(Loc.make_bold_label("PC Storage", 18, UI.TEXT))
	_subtitle = UI.make_label("", 9, UI.MUTED)
	_subtitle.clip_text = true
	_subtitle.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_col.add_child(_subtitle)

	var close_button := Button.new()
	close_button.custom_minimum_size = Vector2(24, 24)
	close_button.focus_mode = Control.FOCUS_NONE
	Loc.bind_tooltip(close_button, "Close (Esc)")
	close_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	close_button.add_theme_stylebox_override(
		"normal", UI.button_style(Color(1, 1, 1, 0.045), 7)
	)
	close_button.add_theme_stylebox_override(
		"hover", UI.button_style(Color(1, 1, 1, 0.10), 7)
	)
	close_button.add_theme_stylebox_override(
		"pressed", UI.button_style(Color(1, 1, 1, 0.16), 7)
	)
	close_button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	close_button.pressed.connect(close)
	var close_icon := TextureRect.new()
	close_icon.texture = _icon("close.svg")
	close_icon.custom_minimum_size = Vector2(12, 12)
	close_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	close_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	close_icon.mouse_filter = MOUSE_FILTER_IGNORE
	close_icon.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	close_icon.offset_left = 6
	close_icon.offset_top = 6
	close_icon.offset_right = -6
	close_icon.offset_bottom = -6
	close_button.add_child(close_icon)
	header.add_child(close_button)

	var divider := ColorRect.new()
	divider.color = Color(1, 1, 1, 0.06)
	divider.custom_minimum_size = Vector2(0, 1)
	divider.mouse_filter = MOUSE_FILTER_IGNORE
	box.add_child(divider)

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 10)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(columns)

	var party_col := VBoxContainer.new()
	party_col.custom_minimum_size = Vector2(370, 0)
	party_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	party_col.add_theme_constant_override("separation", 4)
	columns.add_child(party_col)
	party_col.add_child(Loc.make_label("PARTY  -  click a row to select for swapping", 8, UI.MUTED))
	_party_list = VBoxContainer.new()
	_party_list.name = "PcPartyList"
	_party_list.add_theme_constant_override("separation", 3)
	party_col.add_child(_party_list)

	var box_col := VBoxContainer.new()
	box_col.custom_minimum_size = Vector2(370, 0)
	box_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box_col.add_theme_constant_override("separation", 4)
	columns.add_child(box_col)
	box_col.add_child(Loc.make_label("BOX", 8, UI.MUTED))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box_col.add_child(scroll)
	_box_list = VBoxContainer.new()
	_box_list.name = "PcBoxList"
	_box_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_box_list.add_theme_constant_override("separation", 3)
	scroll.add_child(_box_list)

	var footer := Loc.make_label(
		"Stored Pokémon keep their HP and status. ESC to close.", 8, UI.FAINT
	)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(footer)
	_build_dialog()

func _icon(file: String) -> Texture2D:
	var path := "res://assets/ui/icons/%s" % file
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	return null

func _pokemon_icon(species: String) -> Texture2D:
	var key := species.to_lower()
	if _sprite_cache.has(key):
		return _sprite_cache[key]
	var texture: Texture2D = null
	var path := "%s/%s_front.png" % [POKEMON_ROOT, key]
	if key != "" and ResourceLoader.exists(path):
		texture = load(path) as Texture2D
	_sprite_cache[key] = texture
	return texture

func show_pc(state: Dictionary) -> void:
	_apply_state(state)
	visible = true
	_build()

func update_pc(state: Dictionary) -> void:
	_apply_state(state)
	if visible:
		_build()

func _on_locale_changed(_code: String) -> void:
	Loc.refresh_all(self)
	_apply_state(_state_snapshot())
	if visible:
		_build()

func _state_snapshot() -> Dictionary:
	return {
		"party": _party,
		"box": _box,
		"maxParty": _max_party,
		"maxBox": _max_box
	}

func _apply_state(state: Dictionary) -> void:
	var party_value: Variant = state.get("party", [])
	_party = party_value if party_value is Array else []
	var box_value: Variant = state.get("box", [])
	_box = box_value if box_value is Array else []
	_max_party = int(state.get("maxParty", _max_party))
	_max_box = int(state.get("maxBox", _max_box))
	_selected_party = clampi(_selected_party, 0, maxi(0, _party.size() - 1))
	_subtitle.text = Loc.tf("PARTY %d/%d   -   BOX %d/%d", [
		_party.size(), _max_party, _box.size(), _max_box
	])
	_subtitle.add_theme_color_override("font_color", UI.MUTED)

func show_error(text: String) -> void:
	_subtitle.text = text.to_upper()
	_subtitle.add_theme_color_override("font_color", UI.DANGER)

func _build() -> void:
	for child in _party_list.get_children():
		_party_list.remove_child(child)
		child.queue_free()
	for child in _box_list.get_children():
		_box_list.remove_child(child)
		child.queue_free()

	var keep_last := _party.size() <= 1
	for index in range(_party.size()):
		if _party[index] is Dictionary:
			_party_list.add_child(_make_party_row(_party[index], index, keep_last))

	if _box.is_empty():
		_box_list.add_child(Loc.make_label("The box is empty.", 11, UI.MUTED))
	else:
		for index in range(_box.size()):
			if _box[index] is Dictionary:
				_box_list.add_child(_make_box_row(_box[index], index))

func _row_style(selected: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = UI.CARD_ALT if selected else UI.CARD
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	style.border_width_left = 2 if selected else 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = (
		Color(UI.ACCENT_DIM.r, UI.ACCENT_DIM.g, UI.ACCENT_DIM.b, 0.8)
		if selected
		else Color(1, 1, 1, 0.05)
	)
	style.content_margin_left = 5
	style.content_margin_top = 3
	style.content_margin_right = 5
	style.content_margin_bottom = 3
	return style

func _make_creature_info(creature: Dictionary) -> HBoxContainer:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 6)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var icon := TextureRect.new()
	icon.texture = _pokemon_icon(str(creature.get("species", "")))
	icon.custom_minimum_size = Vector2(30, 30)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = MOUSE_FILTER_IGNORE
	if int(creature.get("hp", 0)) <= 0:
		icon.modulate = Color(0.42, 0.47, 0.52, 0.9)
	line.add_child(icon)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 0)
	info.mouse_filter = MOUSE_FILTER_IGNORE
	line.add_child(info)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 4)
	name_row.mouse_filter = MOUSE_FILTER_IGNORE
	info.add_child(name_row)
	var name_label := UI.make_bold_label(str(creature.get("name", "?")), 12, UI.TEXT)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	name_row.add_child(name_label)
	var status := _status_code(creature)
	if status != "":
		name_row.add_child(_status_chip(status))

	var max_hp := maxi(1, int(creature.get("maxHp", 1)))
	var hp := clampi(int(creature.get("hp", 0)), 0, max_hp)
	var ability_name := str(creature.get("abilityName", ""))
	var detail_key := "Lv %d   %d/%d HP"
	var detail_args: Array = [int(creature.get("level", 1)), hp, max_hp]
	if ability_name != "":
		detail_key = "Lv %d   %d/%d HP   -   %s"
		detail_args.append(ability_name)
	var detail_label := Loc.make_label(detail_key, 9, UI.MUTED, detail_args)
	detail_label.clip_text = true
	detail_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info.add_child(detail_label)
	return line

func _status_code(creature: Dictionary) -> String:
	if int(creature.get("hp", 0)) <= 0:
		return "FNT"
	var status := str(creature.get("status", "")).strip_edges().to_upper()
	if status == "":
		return ""
	return status.substr(0, 3)

func _status_chip(code: String) -> PanelContainer:
	var color := UI.DANGER
	if code == "PAR":
		color = UI.GOLD
	elif code == "PSN":
		color = Color(0.729, 0.478, 0.929)
	elif code == "BRN":
		color = Color(0.933, 0.506, 0.188)
	elif code == "SLP":
		color = UI.MUTED
	elif code == "FRZ":
		color = Color(0.478, 0.804, 0.929)
	var chip := PanelContainer.new()
	chip.mouse_filter = MOUSE_FILTER_IGNORE
	var style := UI.chip_style(Color(color.r, color.g, color.b, 0.16), 4)
	style.content_margin_left = 3
	style.content_margin_right = 3
	style.content_margin_top = 0
	style.content_margin_bottom = 0
	chip.add_theme_stylebox_override("panel", style)
	chip.add_child(UI.make_label(UI.status_label(code), 7, color))
	return chip

func _make_party_row(creature: Dictionary, index: int, keep_last: bool) -> PanelContainer:
	var selected := index == _selected_party
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0, 44)
	row.mouse_filter = MOUSE_FILTER_STOP
	row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	row.add_theme_stylebox_override("panel", _row_style(selected))
	row.gui_input.connect(_on_party_input.bind(index))
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 5)
	row.add_child(line)
	line.add_child(_make_creature_info(creature))
	var rename := _make_action("NAME")
	rename.pressed.connect(func() -> void: _open_rename("party", index))
	line.add_child(rename)
	var store := _make_action("STORE")
	store.disabled = keep_last
	store.pressed.connect(
		func() -> void: requested.emit({"type": "pc_deposit", "partyIndex": index})
	)
	line.add_child(store)
	return row

func _make_box_row(creature: Dictionary, index: int) -> PanelContainer:
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0, 44)
	row.add_theme_stylebox_override("panel", _row_style(false))
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 5)
	row.add_child(line)
	line.add_child(_make_creature_info(creature))
	var rename := _make_action("NAME")
	rename.pressed.connect(func() -> void: _open_rename("box", index))
	line.add_child(rename)
	var take := _make_action("TAKE")
	take.disabled = _party.size() >= _max_party
	take.pressed.connect(
		func() -> void: requested.emit({"type": "pc_withdraw", "boxIndex": index})
	)
	line.add_child(take)
	var swap := _make_action("SWAP")
	swap.disabled = _party.is_empty()
	swap.pressed.connect(
		func() -> void:
			requested.emit({
				"type": "pc_swap",
				"partyIndex": _selected_party,
				"boxIndex": index
			})
	)
	line.add_child(swap)
	var release := _make_action("FREE")
	release.pressed.connect(func() -> void: _open_release(index))
	line.add_child(release)
	return row

func _make_action(key: String) -> Button:
	var button := Button.new()
	Loc.bind(button, key)
	button.custom_minimum_size = Vector2(46, 26)
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	UI.apply_font(button, 8)
	var normal := UI.button_style(UI.ACCENT_SOFT, 5)
	normal.content_margin_left = 3
	normal.content_margin_right = 3
	normal.content_margin_top = 1
	normal.content_margin_bottom = 1
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(UI.ACCENT.r, UI.ACCENT.g, UI.ACCENT.b, 0.24)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(UI.ACCENT.r, UI.ACCENT.g, UI.ACCENT.b, 0.30)
	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(1, 1, 1, 0.03)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("disabled", disabled)
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	button.add_theme_color_override("font_color", UI.ACCENT)
	button.add_theme_color_override("font_hover_color", UI.TEXT)
	button.add_theme_color_override("font_pressed_color", UI.TEXT)
	button.add_theme_color_override("font_disabled_color", UI.FAINT)
	return button

func _on_party_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_selected_party = index
		_build()
		accept_event()
	elif event is InputEventScreenTouch and event.pressed:
		_selected_party = index
		_build()
		accept_event()

func _build_dialog() -> void:
	_dialog_layer = Control.new()
	_dialog_layer.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_dialog_layer.mouse_filter = MOUSE_FILTER_STOP
	_dialog_layer.visible = false
	add_child(_dialog_layer)

	var dim := ColorRect.new()
	dim.color = Color(0.004, 0.012, 0.022, 0.72)
	dim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	dim.mouse_filter = MOUSE_FILTER_STOP
	_dialog_layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	center.mouse_filter = MOUSE_FILTER_IGNORE
	_dialog_layer.add_child(center)

	var panel := PanelContainer.new()
	panel.name = "PcDialog"
	panel.custom_minimum_size = Vector2(420, 0)
	panel.add_theme_stylebox_override(
		"panel", UI.glass_style(UI.INK, 12, UI.BORDER_STRONG, 1, 0)
	)
	panel.mouse_filter = MOUSE_FILTER_STOP
	center.add_child(panel)
	UI.add_bw_frame_overlay(panel)
	var margin := UI.add_panel_content(panel, 12, 10)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)

	_dialog_title = UI.make_bold_label("", 15, UI.TEXT)
	_dialog_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_dialog_title)
	_dialog_body = UI.make_label("", 10, UI.MUTED)
	_dialog_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_dialog_body)

	_dialog_input = LineEdit.new()
	_dialog_input.custom_minimum_size = Vector2(0, 30)
	_dialog_input.max_length = 12
	_dialog_input.focus_mode = Control.FOCUS_ALL
	Loc.bind(_dialog_input, "Nickname")
	UI.apply_font(_dialog_input, 12)
	box.add_child(_dialog_input)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(row)
	_dialog_cancel = Button.new()
	Loc.bind(_dialog_cancel, "CANCEL")
	_dialog_cancel.custom_minimum_size = Vector2(84, 28)
	_dialog_cancel.focus_mode = Control.FOCUS_NONE
	UI.style_button(_dialog_cancel, false, true)
	_dialog_cancel.pressed.connect(_close_dialog)
	row.add_child(_dialog_cancel)
	_dialog_confirm = Button.new()
	_dialog_confirm.custom_minimum_size = Vector2(84, 28)
	_dialog_confirm.focus_mode = Control.FOCUS_NONE
	UI.style_button(_dialog_confirm, true, true)
	_dialog_confirm.pressed.connect(_dialog_confirm_pressed)
	row.add_child(_dialog_confirm)

func _open_rename(source: String, index: int) -> void:
	var list := _party if source == "party" else _box
	if index < 0 or index >= list.size() or not (list[index] is Dictionary):
		return
	var creature: Dictionary = list[index]
	_dialog_action = "rename:%s" % source
	_dialog_index = index
	_dialog_title.text = Loc.tf("Rename %s", [str(creature.get("name", "?"))])
	_dialog_body.text = Loc.t("Enter a nickname of 1-12 characters.")
	_dialog_body.visible = true
	_dialog_input.visible = true
	_dialog_input.text = str(creature.get("name", ""))
	Loc.bind(_dialog_confirm, "SAVE")
	Loc.apply(_dialog_confirm)
	_dialog_layer.visible = true
	_dialog_input.grab_focus()
	_dialog_input.select_all()

func _open_release(index: int) -> void:
	if index < 0 or index >= _box.size() or not (_box[index] is Dictionary):
		return
	var creature: Dictionary = _box[index]
	_dialog_action = "release"
	_dialog_index = index
	_dialog_title.text = Loc.tf("Release %s?", [str(creature.get("name", "?"))])
	_dialog_body.text = Loc.t("This cannot be undone. The Pokémon will be gone forever.")
	_dialog_body.visible = true
	_dialog_input.visible = false
	Loc.bind(_dialog_confirm, "RELEASE")
	Loc.apply(_dialog_confirm)
	_dialog_layer.visible = true

func _dialog_confirm_pressed() -> void:
	if _dialog_action.begins_with("rename:"):
		var name := _dialog_input.text.strip_edges()
		if name == "":
			_dialog_body.text = Loc.t("Enter a nickname.")
			return
		var source := _dialog_action.substr("rename:".length())
		requested.emit({
			"type": "rename_creature",
			"source": source,
			"index": _dialog_index,
			"name": name
		})
		_close_dialog()
		return
	if _dialog_action == "release":
		requested.emit({"type": "pc_release", "boxIndex": _dialog_index})
		_close_dialog()

func _close_dialog() -> void:
	if _dialog_layer != null:
		_dialog_layer.visible = false
	_dialog_action = ""
	_dialog_index = -1

func close() -> void:
	if not visible:
		return
	_close_dialog()
	visible = false
	closed.emit()

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			if _dialog_layer != null and _dialog_layer.visible:
				_close_dialog()
			else:
				close()
			get_viewport().set_input_as_handled()
