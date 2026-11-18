extends Control

signal ability_requested(party_index: int, ability_id: String)
signal closed

const UI = preload("res://scripts/ui_theme.gd")
const POKEMON_ROOT := "res://assets/bw/pokemon"

var _panel: PanelContainer
var _title: Label
var _subtitle: Label
var _party_list: VBoxContainer
var _detail: VBoxContainer
var _npc_name := ""
var _party: Array = []
var _selected_party := 0
var _pending := false
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
	_panel.name = "AbilityServicePanel"
	_panel.custom_minimum_size = Vector2(820, 500)
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
	_party_list.name = "AbilityServiceParty"
	_party_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_party_list.add_theme_constant_override("separation", 3)
	party_scroll.add_child(_party_list)

	var detail_col := VBoxContainer.new()
	detail_col.custom_minimum_size = Vector2(380, 0)
	detail_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_col.add_theme_constant_override("separation", 5)
	columns.add_child(detail_col)
	_detail = VBoxContainer.new()
	_detail.name = "AbilityServiceOptions"
	_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail.add_theme_constant_override("separation", 5)
	detail_col.add_child(_detail)

	var hint := Loc.make_label(
		"Choosing an ability saves it immediately. Hidden abilities are marked.",
		8,
		UI.FAINT
	)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(hint)

func _on_locale_changed(_code: String) -> void:
	if visible:
		_build()

func show_state(state: Dictionary) -> void:
	_apply_state(state)
	visible = true
	_build()

func update_state(state: Dictionary) -> void:
	_apply_state(state)
	_pending = false
	if visible:
		_build()

func show_error(text: String) -> void:
	_subtitle.text = text
	_subtitle.add_theme_color_override("font_color", UI.DANGER)
	_pending = false
	if visible:
		_build()

func _apply_state(state: Dictionary) -> void:
	_npc_name = str(state.get("npcName", ""))
	if _npc_name == "":
		_npc_name = Loc.t("Ability Expert")
	var party_value: Variant = state.get("party", [])
	_party = party_value if party_value is Array else []
	_selected_party = clampi(_selected_party, 0, maxi(0, _party.size() - 1))
	_subtitle.text = Loc.t("Choose a Pokémon and the ability it should have.")
	_subtitle.add_theme_color_override("font_color", UI.MUTED)
	_pending = false

func _build() -> void:
	for child in _party_list.get_children():
		_party_list.remove_child(child)
		child.queue_free()
	for child in _detail.get_children():
		_detail.remove_child(child)
		child.queue_free()
	_title.text = _npc_name

	if _party.is_empty():
		_party_list.add_child(Loc.make_label("Your party is empty.", 11, UI.MUTED))
		_detail.add_child(Loc.make_label("No Pokémon selected", 12, UI.MUTED))
		return

	for index in range(_party.size()):
		if _party[index] is Dictionary:
			_party_list.add_child(_make_party_row(_party[index], index))

	var creature: Dictionary = _party[_selected_party] if _selected_party < _party.size() else {}
	if creature.is_empty():
		return
	_build_detail(creature)

func _make_party_row(creature: Dictionary, index: int) -> PanelContainer:
	var selected := index == _selected_party
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0, 48)
	row.mouse_filter = MOUSE_FILTER_STOP
	row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	row.add_theme_stylebox_override("panel", _row_style(selected))
	row.gui_input.connect(_on_party_input.bind(index))

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 6)
	row.add_child(line)

	var icon := TextureRect.new()
	icon.texture = _pokemon_icon(str(creature.get("species", "")))
	icon.custom_minimum_size = Vector2(34, 34)
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
	var ability_name := str(creature.get("abilityName", creature.get("ability", "-")))
	info.add_child(UI.make_label(
		Loc.tf("Lv %d   -   %s", [int(creature.get("level", 1)), ability_name]),
		9,
		UI.MUTED
	))
	return row

func _build_detail(creature: Dictionary) -> void:
	var creature_name := str(creature.get("name", "?"))
	var current_id := str(creature.get("ability", ""))
	var current_name := str(creature.get("abilityName", current_id))
	var current_desc := str(creature.get("abilityDescription", ""))

	var heading := UI.make_bold_label(
		"%s  -  %s" % [creature_name, Loc.t("Ability")], 13, UI.TEXT
	)
	_detail.add_child(heading)

	var current := PanelContainer.new()
	current.add_theme_stylebox_override("panel", _row_style(true))
	var current_box := VBoxContainer.new()
	current_box.add_theme_constant_override("separation", 2)
	current.add_child(current_box)
	var current_line := HBoxContainer.new()
	current_line.add_theme_constant_override("separation", 6)
	current_box.add_child(current_line)
	var current_label := UI.make_bold_label(current_name, 11, UI.ACCENT)
	current_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	current_line.add_child(current_label)
	current_line.add_child(Loc.make_label("CURRENT", 8, UI.ACCENT))
	if int(creature.get("abilitySlot", 0)) == 2:
		current_line.add_child(Loc.make_label("HIDDEN", 8, UI.GOLD))
	if current_desc != "":
		var current_text := UI.make_label(current_desc, 8, UI.MUTED)
		current_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		current_box.add_child(current_text)
	_detail.add_child(current)

	_detail.add_child(Loc.make_label("Available abilities", 8, UI.MUTED))
	var options_value: Variant = creature.get("abilities", [])
	var options: Array = options_value if options_value is Array else []
	if options.size() <= 1:
		_detail.add_child(Loc.make_label(
			"This Pokémon has only one ability.", 10, UI.MUTED
		))
	var option_scroll := ScrollContainer.new()
	option_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	option_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	option_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail.add_child(option_scroll)
	var option_list := VBoxContainer.new()
	option_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option_list.add_theme_constant_override("separation", 3)
	option_scroll.add_child(option_list)
	for value in options:
		if value is Dictionary:
			option_list.add_child(_make_option_row(value, current_id))

func _make_option_row(option: Dictionary, current_id: String) -> PanelContainer:
	var ability_id := str(option.get("id", ""))
	var is_current := ability_id == current_id
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0, 44)
	row.add_theme_stylebox_override("panel", _row_style(is_current))
	row.mouse_filter = MOUSE_FILTER_PASS
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 6)
	row.add_child(line)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 0)
	info.mouse_filter = MOUSE_FILTER_IGNORE
	line.add_child(info)
	var name_line := HBoxContainer.new()
	name_line.add_theme_constant_override("separation", 5)
	info.add_child(name_line)
	var name_label := UI.make_bold_label(str(option.get("name", ability_id)), 11, UI.TEXT)
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_line.add_child(name_label)
	if bool(option.get("hidden", false)):
		name_line.add_child(Loc.make_label("HIDDEN", 8, UI.GOLD))
	var description := str(option.get("description", ""))
	if description != "":
		var text := UI.make_label(description, 8, UI.MUTED)
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info.add_child(text)

	if is_current:
		line.add_child(Loc.make_label("CURRENT", 8, UI.ACCENT))
	else:
		var switch_button := Button.new()
		switch_button.custom_minimum_size = Vector2(78, 24)
		switch_button.focus_mode = Control.FOCUS_NONE
		switch_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		switch_button.disabled = _pending
		Loc.bind(switch_button, "SWITCH")
		UI.style_button(switch_button, false, true)
		switch_button.pressed.connect(_request_ability.bind(ability_id))
		line.add_child(switch_button)
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

func _request_ability(ability_id: String) -> void:
	if _pending or ability_id == "":
		return
	if _selected_party < 0 or _selected_party >= _party.size():
		return
	var creature: Dictionary = _party[_selected_party]
	if str(creature.get("ability", "")) == ability_id:
		return
	_pending = true
	_build()
	ability_requested.emit(_selected_party, ability_id)

func close() -> void:
	if not visible:
		return
	_pending = false
	visible = false
	closed.emit()

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			close()
			get_viewport().set_input_as_handled()
