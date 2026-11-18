extends Control

signal teach_requested(party_index: int, move_id: String)
signal closed

const UI = preload("res://scripts/ui_theme.gd")
const POKEMON_ROOT := "res://assets/bw/pokemon"

var _panel: PanelContainer
var _title: Label
var _subtitle: Label
var _party_list: VBoxContainer
var _move_list: VBoxContainer
var _move_title: Label
var _hint: Label
var _service := "tutor"
var _npc_name := ""
var _party: Array = []
var _moves: Array = []
var _selected_party := 0
var _sprite_cache: Dictionary = {}

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
	_panel.name = "MoveServicePanel"
	_panel.custom_minimum_size = Vector2(820, 480)
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
	_title = UI.make_bold_label("", 18, UI.TEXT)
	title_col.add_child(_title)
	_subtitle = UI.make_label("", 9, UI.MUTED)
	_subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
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
	close_button.text = "X"
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
	party_col.custom_minimum_size = Vector2(340, 0)
	party_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	party_col.add_theme_constant_override("separation", 4)
	columns.add_child(party_col)
	party_col.add_child(Loc.make_label("PARTY  -  click a row to choose", 8, UI.MUTED))
	var party_scroll := ScrollContainer.new()
	party_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	party_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	party_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	party_col.add_child(party_scroll)
	_party_list = VBoxContainer.new()
	_party_list.name = "MoveServiceParty"
	_party_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_party_list.add_theme_constant_override("separation", 3)
	party_scroll.add_child(_party_list)

	var move_col := VBoxContainer.new()
	move_col.custom_minimum_size = Vector2(420, 0)
	move_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	move_col.add_theme_constant_override("separation", 4)
	columns.add_child(move_col)
	_move_title = UI.make_bold_label("", 12, UI.TEXT)
	move_col.add_child(_move_title)
	var move_scroll := ScrollContainer.new()
	move_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	move_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	move_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	move_col.add_child(move_scroll)
	_move_list = VBoxContainer.new()
	_move_list.name = "MoveServiceMoves"
	_move_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_move_list.add_theme_constant_override("separation", 3)
	move_scroll.add_child(_move_list)

	_hint = UI.make_label("", 8, UI.FAINT)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(_hint)

func _on_locale_changed(_code: String) -> void:
	if visible:
		_build()

func show_state(state: Dictionary) -> void:
	_apply_state(state)
	visible = true
	_build()

func update_state(state: Dictionary) -> void:
	_apply_state(state)
	if visible:
		_build()

func show_error(text: String) -> void:
	_subtitle.text = text
	_subtitle.add_theme_color_override("font_color", UI.DANGER)

func _apply_state(state: Dictionary) -> void:
	_service = str(state.get("service", "tutor"))
	_npc_name = str(state.get("npcName", ""))
	if _npc_name == "":
		_npc_name = Loc.t("Move Tutor" if _service == "tutor" else "Move Reminder")
	var party_value: Variant = state.get("party", [])
	_party = party_value if party_value is Array else []
	var moves_value: Variant = state.get("moves", [])
	_moves = moves_value if moves_value is Array else []
	_selected_party = clampi(_selected_party, 0, maxi(0, _party.size() - 1))
	_subtitle.add_theme_color_override("font_color", UI.MUTED)

func _build() -> void:
	for child in _party_list.get_children():
		_party_list.remove_child(child)
		child.queue_free()
	for child in _move_list.get_children():
		_move_list.remove_child(child)
		child.queue_free()

	_title.text = _npc_name
	_subtitle.text = (
		Loc.t("Choose a Pokémon and a move to teach.")
		if _service == "tutor"
		else Loc.t("Choose a Pokémon and a move it can remember.")
	)
	_hint.text = (
		Loc.t("TMs and tutors share the normal learn/replace prompt.")
		if _service == "tutor"
		else Loc.t("Only moves this Pokémon could already learn are listed.")
	)

	if _party.is_empty():
		_party_list.add_child(Loc.make_label("Your party is empty.", 11, UI.MUTED))
		_move_title.text = Loc.t("No Pokémon")
		return

	for index in range(_party.size()):
		if _party[index] is Dictionary:
			_party_list.add_child(_make_party_row(_party[index], index))

	var creature: Dictionary = _party[_selected_party] if _selected_party < _party.size() else {}
	var creature_name := str(creature.get("name", "?"))
	_move_title.text = Loc.tf("%s  -  %s", [
		creature_name,
		Loc.t("Teach") if _service == "tutor" else Loc.t("Remember")
	])

	var moves := _moves_for_selected()
	if moves.is_empty():
		_move_list.add_child(Loc.make_label(
			Loc.t("No move is available for this Pokémon."), 11, UI.MUTED
		))
		return
	for value in moves:
		if value is Dictionary:
			_move_list.add_child(_make_move_row(value, creature))

func _moves_for_selected() -> Array:
	if _service != "reminder":
		return _moves
	if _selected_party < 0 or _selected_party >= _party.size():
		return []
	var creature: Dictionary = _party[_selected_party]
	var value: Variant = creature.get("relearn", [])
	return value if value is Array else []

func _known_move_ids(creature: Dictionary) -> Dictionary:
	var known := {}
	var moves_value: Variant = creature.get("moves", [])
	if moves_value is Array:
		for move_value in moves_value:
			if move_value is Dictionary:
				known[str((move_value as Dictionary).get("id", ""))] = true
	return known

func _make_party_row(creature: Dictionary, index: int) -> PanelContainer:
	var selected := index == _selected_party
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0, 42)
	row.mouse_filter = MOUSE_FILTER_STOP
	row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	row.add_theme_stylebox_override("panel", _row_style(selected))
	row.gui_input.connect(_on_party_input.bind(index))

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 5)
	row.add_child(line)

	var icon := TextureRect.new()
	icon.texture = _pokemon_icon(str(creature.get("species", "")))
	icon.custom_minimum_size = Vector2(30, 30)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = MOUSE_FILTER_IGNORE
	line.add_child(icon)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 0)
	info.mouse_filter = MOUSE_FILTER_IGNORE
	line.add_child(info)
	var name_label := UI.make_bold_label(str(creature.get("name", "?")), 12, UI.TEXT)
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info.add_child(name_label)
	var known := _known_move_ids(creature).size()
	info.add_child(Loc.make_label("Lv %d   -   %d moves", 9, UI.MUTED, [
		int(creature.get("level", 1)), known
	]))
	return row

func _make_move_row(move: Dictionary, creature: Dictionary) -> PanelContainer:
	var move_id := str(move.get("id", ""))
	var known := bool(_known_move_ids(creature).has(move_id))
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0, 38)
	row.add_theme_stylebox_override("panel", _row_style(false))
	row.mouse_filter = MOUSE_FILTER_PASS
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 6)
	row.add_child(line)

	var type_name := str(move.get("type", "Normal"))
	var type_color := UI.type_color(type_name)
	var type_chip := PanelContainer.new()
	type_chip.mouse_filter = MOUSE_FILTER_IGNORE
	var chip := UI.chip_style(
		Color(type_color.r, type_color.g, type_color.b, 0.22), 4
	)
	chip.content_margin_left = 4
	chip.content_margin_right = 4
	chip.content_margin_top = 1
	chip.content_margin_bottom = 1
	type_chip.add_theme_stylebox_override("panel", chip)
	type_chip.add_child(UI.make_label(UI.type_label(type_name), 8, UI.TEXT))
	line.add_child(type_chip)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 0)
	info.mouse_filter = MOUSE_FILTER_IGNORE
	line.add_child(info)
	var name_label := UI.make_bold_label(str(move.get("name", "?")), 11, UI.TEXT)
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info.add_child(name_label)
	var power := int(move.get("power", 0))
	var detail := Loc.t("Status") if power <= 0 else Loc.tf("Power %d", [power])
	detail += "   -   " + Loc.tf("%d PP", [int(move.get("pp", 0))])
	info.add_child(UI.make_label(detail, 8, UI.MUTED))

	if known:
		line.add_child(Loc.make_label("KNOWN", 9, UI.FAINT))
	else:
		var teach := Button.new()
		Loc.bind(teach, "TEACH" if _service == "tutor" else "REMEMBER")
		teach.custom_minimum_size = Vector2(82, 24)
		teach.focus_mode = Control.FOCUS_NONE
		teach.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		UI.style_button(teach, false, true)
		teach.pressed.connect(_request_teach.bind(move_id))
		line.add_child(teach)
	return row

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
	style.content_margin_left = 6
	style.content_margin_top = 3
	style.content_margin_right = 6
	style.content_margin_bottom = 3
	return style

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

func _on_party_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_selected_party = index
		_build()
		accept_event()
	elif event is InputEventScreenTouch and event.pressed:
		_selected_party = index
		_build()
		accept_event()

func _request_teach(move_id: String) -> void:
	if move_id == "" or _selected_party < 0 or _selected_party >= _party.size():
		return
	var index := _selected_party
	close()
	teach_requested.emit(index, move_id)

func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			close()
			get_viewport().set_input_as_handled()
