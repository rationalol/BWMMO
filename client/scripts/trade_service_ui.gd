extends Control

signal trade_requested(party_index: int)
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
	_panel.name = "TradeServicePanel"
	_panel.custom_minimum_size = Vector2(760, 430)
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
	party_col.custom_minimum_size = Vector2(360, 0)
	party_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	party_col.add_theme_constant_override("separation", 4)
	columns.add_child(party_col)
	party_col.add_child(Loc.make_label("PARTY  -  choose a Pokémon to trade", 8, UI.MUTED))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	party_col.add_child(scroll)
	_party_list = VBoxContainer.new()
	_party_list.name = "TradeServiceParty"
	_party_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_party_list.add_theme_constant_override("separation", 3)
	scroll.add_child(_party_list)

	var detail_col := VBoxContainer.new()
	detail_col.custom_minimum_size = Vector2(340, 0)
	detail_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_col.add_theme_constant_override("separation", 6)
	columns.add_child(detail_col)
	detail_col.add_child(UI.make_bold_label("LINK TRADE", 12, UI.ACCENT))
	_detail = VBoxContainer.new()
	_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail.add_theme_constant_override("separation", 6)
	detail_col.add_child(_detail)

	var hint := Loc.make_label(
		"The trade is simulated and happens instantly. Holding a required item is respected.",
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
	if visible:
		_build()

func show_error(text: String) -> void:
	_subtitle.text = text
	_subtitle.add_theme_color_override("font_color", UI.DANGER)

func _apply_state(state: Dictionary) -> void:
	_npc_name = str(state.get("npcName", ""))
	if _npc_name == "":
		_npc_name = Loc.t("Link Trade")
	var party_value: Variant = state.get("party", [])
	_party = party_value if party_value is Array else []
	_selected_party = clampi(_selected_party, 0, maxi(0, _party.size() - 1))
	_subtitle.text = Loc.t("Choose a Pokémon that evolves by trading.")
	_subtitle.add_theme_color_override("font_color", UI.MUTED)

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
		_detail.add_child(Loc.make_label("No Pokémon is available.", 11, UI.MUTED))
		return

	var any_tradeable := false
	for index in range(_party.size()):
		if _party[index] is Dictionary:
			var creature: Dictionary = _party[index]
			if bool(creature.get("tradeable", false)):
				any_tradeable = true
			_party_list.add_child(_make_party_row(creature, index))

	if not any_tradeable:
		_detail.add_child(Loc.make_label(
			"No Pokémon in your party evolves through a link trade yet.", 11, UI.MUTED
		))

	var creature: Dictionary = _party[_selected_party] if _selected_party < _party.size() else {}
	if creature.is_empty():
		return
	var icon := TextureRect.new()
	icon.texture = _pokemon_icon(str(creature.get("species", "")))
	icon.custom_minimum_size = Vector2(96, 96)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_detail.add_child(icon)
	var name_label := UI.make_bold_label(str(creature.get("name", "?")), 16, UI.TEXT)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail.add_child(name_label)
	var level := Loc.make_label("Lv %d", 10, UI.MUTED, [int(creature.get("level", 1))])
	level.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail.add_child(level)
	var tradeable := bool(creature.get("tradeable", false))
	var status := Loc.make_label(
		"Ready to evolve by trade." if tradeable else "This Pokémon has no trade evolution.",
		11,
		UI.GOLD if tradeable else UI.FAINT
	)
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.add_child(status)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = MOUSE_FILTER_IGNORE
	_detail.add_child(spacer)
	var trade := Button.new()
	Loc.bind(trade, "TRADE")
	trade.custom_minimum_size = Vector2(0, 34)
	trade.disabled = not tradeable
	trade.focus_mode = Control.FOCUS_NONE
	trade.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	UI.style_button(trade, true, false)
	trade.pressed.connect(_request_trade)
	_detail.add_child(trade)

func _make_party_row(creature: Dictionary, index: int) -> PanelContainer:
	var selected := index == _selected_party
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0, 44)
	row.mouse_filter = MOUSE_FILTER_STOP
	row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
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
	row.add_theme_stylebox_override("panel", style)
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
	info.add_child(Loc.make_label("Lv %d", 9, UI.MUTED, [int(creature.get("level", 1))]))
	if bool(creature.get("tradeable", false)):
		line.add_child(Loc.make_label("READY", 8, UI.GOLD))
	return row

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

func _request_trade() -> void:
	if _selected_party < 0 or _selected_party >= _party.size():
		return
	var creature: Dictionary = _party[_selected_party]
	if not bool(creature.get("tradeable", false)):
		return
	var index := _selected_party
	close()
	trade_requested.emit(index)

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
