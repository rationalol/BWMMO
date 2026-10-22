extends Control

signal interact_pressed
signal menu_state_changed(open: bool)
signal chat_timestamps_requested(enabled: bool)
signal item_use_requested(item_id: String, party_index: int)
signal pokedex_requested
signal move_learn_choice(source: String, index: int, move_id: String, replace_index: int)
signal forget_move_requested(party_index: int, move_index: int)
signal capture_card_closed

const WorldTimeScript = preload("res://scripts/world_time.gd")
const UI = preload("res://scripts/ui_theme.gd")
const MinimapScript = preload("res://scripts/minimap_ui.gd")
const DashedSlotScript = preload("res://scripts/ui_dashed_slot.gd")
const AVATAR_SHADER = preload("res://shaders/ui_circle_mask.gdshader")

const ICON_ROOT := "res://assets/ui/icons"
const ACTOR_ROOT := "res://assets/bw/nuvema/actors"
const POKEMON_ROOT := "res://assets/bw/pokemon"
const PARTY_SIZE := 6
const DEX_PAGE_SIZE := 30
const NAV_DEFS := [
	{"kind": "bag", "label": "Bag", "icon": "bag.svg"},
	{"kind": "dex", "label": "Dex", "icon": "dex.svg"},
	{"kind": "map", "label": "Map", "icon": "map.svg"},
	{"kind": "party", "label": "Party", "icon": "party.svg"},
	{"kind": "settings", "label": "Settings", "icon": "settings.svg"}
]
const BAG_POCKETS := [
	{"id": "items", "label": "Items"},
	{"id": "medicine", "label": "Medicine"},
	{"id": "balls", "label": "Balls"},
	{"id": "tm", "label": "TMs"},
	{"id": "berries", "label": "Berries"},
	{"id": "key", "label": "Key Items"}
]

var menu_open: bool:
	get:
		return _menu_overlay != null and _menu_overlay.visible

var _trainer_card: PanelContainer
var _name_label: Label
var _level_label: Label
var _location_label: Label
var _clock_label: Label
var _money_label: Label
var _wins_label: Label
var _gender_rect: TextureRect
var _avatar_rect: TextureRect

var _party_panel: PanelContainer
var _party_slots: VBoxContainer
var _party_rail: VBoxContainer
var _party_title_label: Label
var _party_toggle: Button
var _party_toggle_icon: TextureRect
var _party_count_label: Label
var _party_collapsed := false
var _party_selected_index := 0
var _party: Array = []
var _max_party := PARTY_SIZE

var _nav_container: HBoxContainer
var _nav_buttons: Dictionary = {}
var _nav_icons: Dictionary = {}
var _nav_labels: Dictionary = {}
var _status_container: HBoxContainer
var _status_dot: PanelContainer
var _status_label: Label

var _minimap_panel: PanelContainer
var _minimap_title: Label
var _minimap
var _big_minimap

var _prompt_center: CenterContainer
var _prompt_button: Button
var _prompt_label: Label
var _hint_center: CenterContainer
var _hint_label: Label

var _notice_center: CenterContainer
var _notice_panel: PanelContainer
var _notice_label: Label
var _notice_timer: Timer

var _menu_overlay: Control
var _menu_panel: PanelContainer
var _menu_title: Label
var _menu_body: VBoxContainer
var _menu_kind := ""
var _bag_pocket := "balls"
var _bag_tabs: Dictionary = {}

var _trainer_name := "Trainer"
var _money := 0
var _wins := 0
var _balls := 0
var _inventory: Dictionary = {}
var _inventory_items: Dictionary = {}
var _item_catalog: Dictionary = {}
var _item_order: Dictionary = {}
var _pokedex_seen: Dictionary = {}
var _pokedex_caught: Dictionary = {}
var _pokedex_entries: Array = []
var _pokedex_by_id: Dictionary = {}
var _pokedex_total := 649
var _pokedex_page := 0
var _pokedex_filter := "all"
var _pokedex_selected := 0
var _learn_request: Dictionary = {}
var _forget_confirm := {}
var _map_name := ""
var _location_name := ""
var _local_count := 1
var _map_info: Dictionary = {}
var _self_info: Dictionary = {}
var _self_grid := Vector2i.ZERO
var _self_dir := "down"
var _season := "autumn"
var _world_hours := 12.0
var _ping := 0
var _connection := "ONLINE"
var _connected := true
var _hint_text := ""
var _nearby_npc: Dictionary = {}

var _touch_layout := false
var _show_minimap := true
var _dialogue_mode := false
var _show_hints := true
var _chat_timestamps := false
var _building_menu := false
var _locale_picker: OptionButton
var _capture_overlay: Control
var _icon_cache: Dictionary = {}
var _sprite_cache: Dictionary = {}

func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	Loc.locale_changed.connect(_on_locale_changed)
	_build_trainer_card()
	_build_party()
	_build_nav()
	_build_minimap()
	_build_prompt()
	_build_notice()
	_build_menu()
	_refresh_trainer()
	_refresh_avatar()
	_refresh_status()
	_sync_minimap()
	_update_prompt_visibility()

func _on_locale_changed(_code: String) -> void:
	Loc.refresh_all(self)
	_refresh_trainer()
	_rebuild_party()
	_refresh_status()
	_sync_minimap()
	_update_prompt_visibility()
	set_world_time(_world_hours)
	_refresh_nav()
	if menu_open:
		_build_menu_content()

func _icon(file: String) -> Texture2D:
	var path := "%s/%s" % [ICON_ROOT, file]
	if _icon_cache.has(path):
		return _icon_cache[path]
	var texture: Texture2D = null
	if ResourceLoader.exists(path):
		texture = load(path) as Texture2D
	_icon_cache[path] = texture
	return texture

func _build_trainer_card() -> void:
	_trainer_card = PanelContainer.new()
	_trainer_card.name = "TrainerCard"
	_trainer_card.anchor_left = 0.0
	_trainer_card.anchor_right = 0.0
	_trainer_card.anchor_top = 0.0
	_trainer_card.anchor_bottom = 0.0
	_trainer_card.offset_left = 10
	_trainer_card.offset_right = 274
	_trainer_card.offset_top = 10
	_trainer_card.offset_bottom = 86
	_trainer_card.add_theme_stylebox_override(
		"panel", UI.glass_style(UI.INK, 10, UI.BORDER, 1, 0)
	)
	_trainer_card.mouse_filter = MOUSE_FILTER_STOP
	add_child(_trainer_card)
	UI.add_bw_frame_overlay(_trainer_card)
	var trainer_margin := UI.add_panel_content(_trainer_card, 10, 8)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	trainer_margin.add_child(row)

	var avatar_frame := PanelContainer.new()
	avatar_frame.custom_minimum_size = Vector2(52, 52)
	avatar_frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	avatar_frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	avatar_frame.mouse_filter = MOUSE_FILTER_IGNORE
	var avatar_style := StyleBoxFlat.new()
	avatar_style.bg_color = Color(0.063, 0.133, 0.204, 1.0)
	avatar_style.corner_radius_top_left = 26
	avatar_style.corner_radius_top_right = 26
	avatar_style.corner_radius_bottom_left = 26
	avatar_style.corner_radius_bottom_right = 26
	avatar_style.border_width_left = 2
	avatar_style.border_width_top = 2
	avatar_style.border_width_right = 2
	avatar_style.border_width_bottom = 2
	avatar_style.border_color = Color(UI.ACCENT_DIM.r, UI.ACCENT_DIM.g, UI.ACCENT_DIM.b, 0.75)
	avatar_style.content_margin_left = 4
	avatar_style.content_margin_top = 4
	avatar_style.content_margin_right = 4
	avatar_style.content_margin_bottom = 4
	avatar_frame.add_theme_stylebox_override("panel", avatar_style)
	row.add_child(avatar_frame)

	_avatar_rect = TextureRect.new()
	_avatar_rect.name = "TrainerAvatar"
	_avatar_rect.custom_minimum_size = Vector2(44, 44)
	_avatar_rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_avatar_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_avatar_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_avatar_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_avatar_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_avatar_rect.mouse_filter = MOUSE_FILTER_IGNORE
	var avatar_material := ShaderMaterial.new()
	avatar_material.shader = AVATAR_SHADER
	_avatar_rect.material = avatar_material
	avatar_frame.add_child(_avatar_rect)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 0)
	row.add_child(info)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 4)
	info.add_child(name_row)

	_name_label = UI.make_bold_label(_trainer_name, 15, UI.TEXT)
	_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_label.clip_text = true
	_name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_row.add_child(_name_label)

	_gender_rect = TextureRect.new()
	_gender_rect.custom_minimum_size = Vector2(12, 12)
	_gender_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_gender_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_gender_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_gender_rect.mouse_filter = MOUSE_FILTER_IGNORE
	name_row.add_child(_gender_rect)

	_level_label = UI.make_label("", 10, UI.MUTED)
	info.add_child(_level_label)

	var location_row := HBoxContainer.new()
	location_row.add_theme_constant_override("separation", 4)
	info.add_child(location_row)

	_location_label = UI.make_label("", 10, UI.FAINT)
	_location_label.clip_text = true
	_location_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_location_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	location_row.add_child(_location_label)

	_clock_label = UI.make_label("", 10, UI.MUTED)
	_clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_clock_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	location_row.add_child(_clock_label)

	var money_col := VBoxContainer.new()
	money_col.custom_minimum_size = Vector2(66, 0)
	money_col.add_theme_constant_override("separation", 0)
	row.add_child(money_col)

	var money_row := HBoxContainer.new()
	money_row.alignment = BoxContainer.ALIGNMENT_END
	money_row.add_theme_constant_override("separation", 3)
	money_col.add_child(money_row)

	var coin := TextureRect.new()
	coin.texture = _icon("coin.svg")
	coin.custom_minimum_size = Vector2(12, 12)
	coin.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	coin.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	coin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	coin.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	coin.mouse_filter = MOUSE_FILTER_IGNORE
	money_row.add_child(coin)

	_money_label = UI.make_bold_label("$0", 11, UI.GOLD)
	money_row.add_child(_money_label)

	_wins_label = UI.make_label("", 8, UI.FAINT)
	_wins_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	money_col.add_child(_wins_label)

func _build_party() -> void:
	_party_panel = PanelContainer.new()
	_party_panel.name = "PartyPanel"
	_party_panel.anchor_left = 0.0
	_party_panel.anchor_right = 0.0
	_party_panel.anchor_top = 0.0
	_party_panel.anchor_bottom = 0.0
	_party_panel.offset_left = 10
	_party_panel.offset_right = 242
	_party_panel.offset_top = 92
	_party_panel.offset_bottom = 352
	_party_panel.add_theme_stylebox_override(
		"panel", UI.glass_style(UI.INK, 10, UI.BORDER, 1, 0)
	)
	_party_panel.mouse_filter = MOUSE_FILTER_STOP
	add_child(_party_panel)
	UI.add_bw_frame_overlay(_party_panel)
	var party_margin := UI.add_panel_content(_party_panel, 10, 8)

	var party_box := VBoxContainer.new()
	party_box.add_theme_constant_override("separation", 2)
	party_margin.add_child(party_box)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	party_box.add_child(header)
	_party_title_label = Loc.make_label("PARTY", 10, UI.MUTED)
	header.add_child(_party_title_label)
	_party_count_label = UI.make_label("0/%d" % PARTY_SIZE, 10, UI.FAINT)
	header.add_child(_party_count_label)
	var header_spacer := Control.new()
	header_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_spacer.mouse_filter = MOUSE_FILTER_IGNORE
	header.add_child(header_spacer)
	_party_toggle = Button.new()
	_party_toggle.custom_minimum_size = Vector2(16, 16)
	_party_toggle.focus_mode = Control.FOCUS_NONE
	Loc.bind_tooltip(_party_toggle, "Collapse party")
	_party_toggle.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var toggle_normal := UI.button_style(Color(1.0, 1.0, 1.0, 0.035), 4)
	var toggle_hover := UI.button_style(Color(1.0, 1.0, 1.0, 0.09), 4)
	var toggle_pressed := UI.button_style(Color(1.0, 1.0, 1.0, 0.14), 4)
	for toggle_style in [toggle_normal, toggle_hover, toggle_pressed]:
		toggle_style.content_margin_left = 0
		toggle_style.content_margin_top = 0
		toggle_style.content_margin_right = 0
		toggle_style.content_margin_bottom = 0
	_party_toggle.add_theme_stylebox_override("normal", toggle_normal)
	_party_toggle.add_theme_stylebox_override("hover", toggle_hover)
	_party_toggle.add_theme_stylebox_override("pressed", toggle_pressed)
	_party_toggle.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_party_toggle.pressed.connect(_toggle_party_collapsed)
	var toggle_center := CenterContainer.new()
	toggle_center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	toggle_center.mouse_filter = MOUSE_FILTER_IGNORE
	_party_toggle.add_child(toggle_center)
	_party_toggle_icon = TextureRect.new()
	_party_toggle_icon.texture = _icon("chevron_left.svg")
	_party_toggle_icon.custom_minimum_size = Vector2(10, 10)
	_party_toggle_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_party_toggle_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_party_toggle_icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_party_toggle_icon.mouse_filter = MOUSE_FILTER_IGNORE
	toggle_center.add_child(_party_toggle_icon)
	header.add_child(_party_toggle)

	_party_slots = VBoxContainer.new()
	_party_slots.name = "PartySlots"
	_party_slots.add_theme_constant_override("separation", 2)
	party_box.add_child(_party_slots)

	_party_rail = VBoxContainer.new()
	_party_rail.name = "PartyRail"
	_party_rail.add_theme_constant_override("separation", 3)
	_party_rail.visible = false
	party_box.add_child(_party_rail)
	_rebuild_party()

func _rebuild_party() -> void:
	if _party_slots == null:
		return
	for child in _party_slots.get_children():
		_party_slots.remove_child(child)
		child.queue_free()
	var slots := clampi(_max_party, 1, PARTY_SIZE)
	for index in range(slots):
		if index < _party.size() and _party[index] is Dictionary:
			_party_slots.add_child(_make_party_row(_party[index], index))
		else:
			var empty := DashedSlotScript.new()
			empty.name = "PartySlotEmpty%d" % index
			empty.text = Loc.t("EMPTY")
			empty.set_meta("label", empty.text)
			empty.custom_minimum_size = Vector2(0, 35)
			_party_slots.add_child(empty)
	if _party_count_label != null:
		_party_count_label.text = "%d/%d" % [_party.size(), PARTY_SIZE]
	_rebuild_party_rail()

func _rebuild_party_rail() -> void:
	if _party_rail == null:
		return
	for child in _party_rail.get_children():
		_party_rail.remove_child(child)
		child.queue_free()
	for creature_value in _party:
		if not (creature_value is Dictionary):
			continue
		var creature: Dictionary = creature_value
		var frame := PanelContainer.new()
		frame.custom_minimum_size = Vector2(34, 34)
		frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		frame.tooltip_text = "%s  Lv %d" % [
			str(creature.get("name", "?")), int(creature.get("level", 1))
		]
		var style := StyleBoxFlat.new()
		style.bg_color = UI.CARD
		style.corner_radius_top_left = 6
		style.corner_radius_top_right = 6
		style.corner_radius_bottom_left = 6
		style.corner_radius_bottom_right = 6
		style.border_width_left = 2 if creature == _party[0] else 1
		style.border_width_top = 1
		style.border_width_right = 1
		style.border_width_bottom = 1
		style.border_color = (
			Color(UI.ACCENT_DIM.r, UI.ACCENT_DIM.g, UI.ACCENT_DIM.b, 0.55)
			if creature == _party[0]
			else Color(1, 1, 1, 0.05)
		)
		style.content_margin_left = 2
		style.content_margin_top = 2
		style.content_margin_right = 2
		style.content_margin_bottom = 2
		frame.add_theme_stylebox_override("panel", style)
		var icon := TextureRect.new()
		icon.texture = _pokemon_icon(str(creature.get("species", "")))
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		icon.mouse_filter = MOUSE_FILTER_IGNORE
		frame.add_child(icon)
		_party_rail.add_child(frame)

func _toggle_party_collapsed() -> void:
	_party_collapsed = not _party_collapsed
	_party_slots.visible = not _party_collapsed
	_party_rail.visible = _party_collapsed
	_party_title_label.visible = not _party_collapsed
	_party_count_label.visible = not _party_collapsed
	_party_panel.offset_right = 68.0 if _party_collapsed else 242.0
	_party_panel.offset_bottom = 352.0
	_party_toggle_icon.texture = _icon(
		"chevron_right.svg" if _party_collapsed else "chevron_left.svg"
	)
	Loc.bind_tooltip(_party_toggle, "Expand party" if _party_collapsed else "Collapse party")

func _make_party_row(source: Dictionary, index: int) -> PanelContainer:
	var creature: Dictionary = source
	var max_hp := maxi(1, int(creature.get("maxHp", 1)))
	var hp := clampi(int(creature.get("hp", 0)), 0, max_hp)
	var ratio := float(hp) / float(max_hp)
	var fainted := hp <= 0

	var row := PanelContainer.new()
	row.name = "PartySlot%d" % index
	row.custom_minimum_size = Vector2(0, 35)
	row.mouse_filter = MOUSE_FILTER_PASS
	var style := StyleBoxFlat.new()
	style.bg_color = UI.CARD_ALT if index == 0 else UI.CARD
	style.corner_radius_top_left = 7
	style.corner_radius_top_right = 7
	style.corner_radius_bottom_left = 7
	style.corner_radius_bottom_right = 7
	style.border_width_left = 2 if index == 0 else 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = (
		Color(UI.ACCENT_DIM.r, UI.ACCENT_DIM.g, UI.ACCENT_DIM.b, 0.55)
		if index == 0
		else Color(1, 1, 1, 0.045)
	)
	style.content_margin_left = 4
	style.content_margin_top = 1
	style.content_margin_right = 4
	style.content_margin_bottom = 1
	style.anti_aliasing = true
	row.add_theme_stylebox_override("panel", style)

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 6)
	row.add_child(line)

	var icon_frame := PanelContainer.new()
	icon_frame.custom_minimum_size = Vector2(28, 28)
	icon_frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	icon_frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon_frame.mouse_filter = MOUSE_FILTER_IGNORE
	var icon_style := StyleBoxFlat.new()
	icon_style.bg_color = Color(0.024, 0.059, 0.098, 1.0)
	icon_style.corner_radius_top_left = 5
	icon_style.corner_radius_top_right = 5
	icon_style.corner_radius_bottom_left = 5
	icon_style.corner_radius_bottom_right = 5
	icon_style.border_width_left = 1
	icon_style.border_width_top = 1
	icon_style.border_width_right = 1
	icon_style.border_width_bottom = 1
	icon_style.border_color = Color(1, 1, 1, 0.05)
	icon_style.content_margin_left = 1
	icon_style.content_margin_top = 1
	icon_style.content_margin_right = 1
	icon_style.content_margin_bottom = 1
	icon_frame.add_theme_stylebox_override("panel", icon_style)
	line.add_child(icon_frame)

	var icon := TextureRect.new()
	icon.name = "PokemonIcon_%s" % str(creature.get("species", ""))
	icon.texture = _pokemon_icon(str(creature.get("species", "")))
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = MOUSE_FILTER_IGNORE
	if fainted:
		icon.modulate = Color(0.42, 0.47, 0.52, 0.9)
	icon_frame.add_child(icon)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 0)
	line.add_child(info)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 4)
	info.add_child(name_row)

	var name_label := UI.make_bold_label(str(creature.get("name", "?")), 10, UI.TEXT)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	if fainted:
		name_label.add_theme_color_override("font_color", UI.MUTED)
	name_row.add_child(name_label)

	var gender_label := _make_gender_label(creature)
	if gender_label != null:
		name_row.add_child(gender_label)

	var status := _status_code(creature, fainted)
	if status != "":
		name_row.add_child(_make_status_chip(status))

	var types: Array = creature.get("types", [])
	var type_icons := _make_type_icons(types)
	if type_icons != null:
		name_row.add_child(type_icons)

	var meta := HBoxContainer.new()
	meta.add_theme_constant_override("separation", 4)
	info.add_child(meta)

	meta.add_child(Loc.make_label("Lv %d", 8, UI.MUTED, [int(creature.get("level", 1))]))
	var meta_spacer := Control.new()
	meta_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	meta_spacer.mouse_filter = MOUSE_FILTER_IGNORE
	meta.add_child(meta_spacer)
	meta.add_child(UI.make_label("%d/%d" % [hp, max_hp], 8, UI.FAINT))

	var bar := ProgressBar.new()
	bar.max_value = max_hp
	bar.value = hp
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 4)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.mouse_filter = MOUSE_FILTER_IGNORE
	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0.012, 0.035, 0.059, 1.0)
	bar_bg.corner_radius_top_left = 2
	bar_bg.corner_radius_top_right = 2
	bar_bg.corner_radius_bottom_left = 2
	bar_bg.corner_radius_bottom_right = 2
	var bar_fill := StyleBoxFlat.new()
	bar_fill.bg_color = UI.hp_color(ratio)
	bar_fill.corner_radius_top_left = 2
	bar_fill.corner_radius_top_right = 2
	bar_fill.corner_radius_bottom_left = 2
	bar_fill.corner_radius_bottom_right = 2
	bar.add_theme_stylebox_override("background", bar_bg)
	bar.add_theme_stylebox_override("fill", bar_fill)
	info.add_child(bar)
	return row

func _status_code(creature: Dictionary, fainted: bool) -> String:
	if fainted:
		return "FNT"
	var status := str(creature.get("status", "")).strip_edges().to_upper()
	if status == "":
		return ""
	if status == "FAINTED":
		return "FNT"
	return status.substr(0, 3)

func _make_status_chip(code: String) -> PanelContainer:
	var color := UI.DANGER
	if code == "PAR":
		color = UI.GOLD
	elif code == "SLP":
		color = UI.MUTED
	elif code == "PSN":
		color = Color(0.729, 0.478, 0.929)
	elif code == "BRN":
		color = Color(0.933, 0.506, 0.188)
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
	var label := UI.make_label(UI.status_label(code), 7, color)
	chip.add_child(label)
	return chip

func _make_gender_label(creature: Dictionary) -> Label:
	var gender := str(creature.get("gender", "")).to_lower()
	var symbol := ""
	var color := UI.MUTED
	if gender == "male":
		symbol = "♂"
		color = UI.MALE
	elif gender == "female":
		symbol = "♀"
		color = UI.FEMALE
	if symbol == "":
		return null
	var label := UI.make_bold_label(symbol, 15, color)
	label.custom_minimum_size = Vector2(9, 0)
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return label

func _type_icon(type_name: String) -> Texture2D:
	var path := "res://assets/bw/ui/types/%s.png" % type_name.to_lower()
	if ResourceLoader.exists(path):
		if _icon_cache.has(path):
			return _icon_cache[path]
		var texture := load(path) as Texture2D
		if texture != null:
			_icon_cache[path] = texture
			return texture
	return null

func _make_type_icons(types: Array) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	row.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var added := 0
	for type_value in types:
		var texture := _type_icon(str(type_value))
		if texture == null:
			continue
		var icon := TextureRect.new()
		icon.texture = texture
		icon.custom_minimum_size = Vector2(32, 16)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		icon.mouse_filter = MOUSE_FILTER_IGNORE
		row.add_child(icon)
		added += 1
	if added == 0:
		row.queue_free()
		return null
	return row

func _pokemon_icon(species: String) -> Texture2D:
	var key := species.to_lower()
	if _sprite_cache.has("party:" + key):
		return _sprite_cache["party:" + key]
	var texture: Texture2D = null
	if key != "":
		texture = _square_texture("%s/%s_front.png" % [POKEMON_ROOT, key], "party:" + key)
	if texture == null:
		texture = _icon("party.svg")
	_sprite_cache["party:" + key] = texture
	return texture

func _square_texture(path: String, cache_key: String) -> Texture2D:
	if _sprite_cache.has(cache_key):
		return _sprite_cache[cache_key]
	var texture: Texture2D = null
	if ResourceLoader.exists(path):
		var source := load(path) as Texture2D
		if source != null:
			var image := source.get_image()
			if image != null:
				var used := image.get_used_rect()
				if used.size.x > 0 and used.size.y > 0:
					image = image.get_region(used)
				var side := maxi(image.get_width(), image.get_height()) + 4
				var square := Image.create(side, side, false, Image.FORMAT_RGBA8)
				square.fill(Color(0, 0, 0, 0))
				square.blit_rect(
					image,
					Rect2i(Vector2i.ZERO, image.get_size()),
					Vector2i(
						(side - image.get_width()) / 2,
						(side - image.get_height()) / 2
					)
				)
				texture = ImageTexture.create_from_image(square)
	_sprite_cache[cache_key] = texture
	return texture

func _build_nav() -> void:
	_nav_container = HBoxContainer.new()
	var nav := _nav_container
	nav.name = "NavButtons"
	nav.anchor_left = 1.0
	nav.anchor_right = 1.0
	nav.anchor_top = 1.0
	nav.anchor_bottom = 1.0
	nav.offset_left = -282
	nav.offset_right = -10
	nav.offset_top = -68
	nav.offset_bottom = -10
	nav.alignment = BoxContainer.ALIGNMENT_END
	nav.add_theme_constant_override("separation", 4)
	add_child(nav)

	for definition in NAV_DEFS:
		var entry: Dictionary = definition
		var kind := str(entry.get("kind", ""))
		var button := Button.new()
		button.name = "Nav" + kind.capitalize()
		button.custom_minimum_size = Vector2(48, 58)
		button.focus_mode = Control.FOCUS_NONE
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button.pressed.connect(_toggle_menu.bind(kind))
		nav.add_child(button)

		var box := VBoxContainer.new()
		box.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
		box.alignment = BoxContainer.ALIGNMENT_CENTER
		box.add_theme_constant_override("separation", 3)
		box.mouse_filter = MOUSE_FILTER_IGNORE
		button.add_child(box)

		var icon := TextureRect.new()
		icon.texture = _icon(str(entry.get("icon", "")))
		icon.custom_minimum_size = Vector2(22, 22)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		icon.mouse_filter = MOUSE_FILTER_IGNORE
		box.add_child(icon)

		var label := Loc.make_label(str(entry.get("label", "")), 10, UI.MUTED)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(label)

		_nav_buttons[kind] = button
		_nav_icons[kind] = icon
		_nav_labels[kind] = label

	_refresh_nav()

	_status_container = HBoxContainer.new()
	var status := _status_container
	status.name = "ConnectionStatus"
	status.anchor_left = 1.0
	status.anchor_right = 1.0
	status.anchor_top = 1.0
	status.anchor_bottom = 1.0
	status.offset_left = -282
	status.offset_right = -10
	status.offset_top = -88
	status.offset_bottom = -74
	status.alignment = BoxContainer.ALIGNMENT_END
	status.add_theme_constant_override("separation", 4)
	status.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(status)

	_status_dot = PanelContainer.new()
	_status_dot.custom_minimum_size = Vector2(5, 5)
	_status_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_status_dot.mouse_filter = MOUSE_FILTER_IGNORE
	status.add_child(_status_dot)

	_status_label = UI.make_label("", 8, UI.FAINT)
	status.add_child(_status_label)

func _refresh_nav() -> void:
	for kind in _nav_buttons.keys():
		var button: Button = _nav_buttons[kind]
		var active: bool = menu_open and _menu_kind == str(kind)
		var normal := UI.glass_style(
			Color(0.039, 0.086, 0.141, 0.92), 4,
			Color(1, 1, 1, 0.06), 1, 0
		)
		var hover := UI.glass_style(
			Color(0.055, 0.137, 0.145, 0.96), 4,
			Color(UI.ACCENT_DIM.r, UI.ACCENT_DIM.g, UI.ACCENT_DIM.b, 0.8), 1, 0
		)
		var pressed := UI.glass_style(
			Color(0.063, 0.169, 0.153, 1.0), 4, UI.ACCENT, 1, 0
		)
		if active:
			normal = UI.glass_style(
				Color(0.055, 0.157, 0.125, 0.98), 4, UI.ACCENT, 2, 0
			)
			hover = normal
		button.add_theme_stylebox_override("normal", normal)
		button.add_theme_stylebox_override("hover", hover)
		button.add_theme_stylebox_override("pressed", pressed)
		button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		var icon: TextureRect = _nav_icons[kind]
		var label: Label = _nav_labels[kind]
		icon.modulate = UI.ACCENT if active else Color(1, 1, 1, 0.88)
		label.add_theme_color_override("font_color", UI.ACCENT if active else UI.MUTED)

func _build_minimap() -> void:
	_minimap_panel = PanelContainer.new()
	_minimap_panel.name = "MinimapPanel"
	_minimap_panel.anchor_left = 1.0
	_minimap_panel.anchor_right = 1.0
	_minimap_panel.anchor_top = 0.0
	_minimap_panel.anchor_bottom = 0.0
	_minimap_panel.offset_left = -198
	_minimap_panel.offset_right = -10
	_minimap_panel.offset_top = 10
	_minimap_panel.offset_bottom = 180
	_minimap_panel.add_theme_stylebox_override(
		"panel", UI.glass_style(UI.INK, 10, UI.BORDER, 1, 0)
	)
	_minimap_panel.mouse_filter = MOUSE_FILTER_STOP
	add_child(_minimap_panel)
	UI.add_bw_frame_overlay(_minimap_panel)
	var minimap_margin := UI.add_panel_content(_minimap_panel, 8, 7)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	minimap_margin.add_child(box)

	var header := HBoxContainer.new()
	box.add_child(header)
	var tag := Loc.make_label("AREA", 8, Color(UI.ACCENT.r, UI.ACCENT.g, UI.ACCENT.b, 0.7))
	header.add_child(tag)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = MOUSE_FILTER_IGNORE
	header.add_child(spacer)
	_minimap_title = Loc.make_label("UNKNOWN", 9, UI.MUTED)
	_minimap_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header.add_child(_minimap_title)

	_minimap = MinimapScript.new()
	_minimap.name = "Minimap"
	_minimap.custom_minimum_size = Vector2(0, 132)
	_minimap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_minimap.map_pressed.connect(_open_menu.bind("map"))
	box.add_child(_minimap)

func _build_prompt() -> void:
	_prompt_center = CenterContainer.new()
	_prompt_center.anchor_left = 0.0
	_prompt_center.anchor_right = 1.0
	_prompt_center.anchor_top = 1.0
	_prompt_center.anchor_bottom = 1.0
	_prompt_center.offset_top = -78
	_prompt_center.offset_bottom = -30
	_prompt_center.mouse_filter = MOUSE_FILTER_IGNORE
	_prompt_center.visible = false
	add_child(_prompt_center)

	_prompt_button = Button.new()
	_prompt_button.name = "InteractPrompt"
	_prompt_button.focus_mode = Control.FOCUS_NONE
	_prompt_button.custom_minimum_size = Vector2(132, 30)
	_prompt_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_prompt_button.pressed.connect(func() -> void: interact_pressed.emit())
	var normal := UI.glass_style(Color(0.024, 0.063, 0.106, 0.96), 15, UI.BORDER, 1, 0)
	normal.content_margin_left = 7
	normal.content_margin_right = 13
	normal.content_margin_top = 5
	normal.content_margin_bottom = 5
	var hover := UI.glass_style(Color(0.031, 0.098, 0.086, 0.98), 15, UI.ACCENT_DIM, 1, 0)
	hover.content_margin_left = 7
	hover.content_margin_right = 13
	hover.content_margin_top = 5
	hover.content_margin_bottom = 5
	_prompt_button.add_theme_stylebox_override("normal", normal)
	_prompt_button.add_theme_stylebox_override("hover", hover)
	_prompt_button.add_theme_stylebox_override("pressed", hover)
	_prompt_button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_prompt_center.add_child(_prompt_button)

	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 7)
	row.mouse_filter = MOUSE_FILTER_IGNORE
	_prompt_button.add_child(row)

	var key := PanelContainer.new()
	key.custom_minimum_size = Vector2(19, 19)
	key.mouse_filter = MOUSE_FILTER_IGNORE
	var key_style := StyleBoxFlat.new()
	key_style.bg_color = Color(0.063, 0.204, 0.149, 1.0)
	key_style.corner_radius_top_left = 4
	key_style.corner_radius_top_right = 4
	key_style.corner_radius_bottom_left = 4
	key_style.corner_radius_bottom_right = 4
	key_style.border_width_left = 1
	key_style.border_width_top = 1
	key_style.border_width_right = 1
	key_style.border_width_bottom = 1
	key_style.border_color = Color(UI.ACCENT.r, UI.ACCENT.g, UI.ACCENT.b, 0.55)
	key.add_theme_stylebox_override("panel", key_style)
	row.add_child(key)
	var key_label := UI.make_bold_label("E", 10, UI.ACCENT)
	key_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	key_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	key.add_child(key_label)

	_prompt_label = Loc.make_bold_label("Talk", 11, UI.TEXT)
	_prompt_label.clip_text = true
	_prompt_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_prompt_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_prompt_label)

	_hint_center = CenterContainer.new()
	_hint_center.anchor_left = 0.0
	_hint_center.anchor_right = 1.0
	_hint_center.anchor_top = 1.0
	_hint_center.anchor_bottom = 1.0
	_hint_center.offset_top = -64
	_hint_center.offset_bottom = -34
	_hint_center.mouse_filter = MOUSE_FILTER_IGNORE
	_hint_center.visible = false
	add_child(_hint_center)

	var hint_panel := PanelContainer.new()
	hint_panel.mouse_filter = MOUSE_FILTER_IGNORE
	var hint_style := UI.glass_style(
		Color(0.015, 0.043, 0.075, 0.72), 10, Color(1, 1, 1, 0.04), 1, 0
	)
	hint_style.content_margin_left = 9
	hint_style.content_margin_right = 9
	hint_style.content_margin_top = 3
	hint_style.content_margin_bottom = 3
	hint_panel.add_theme_stylebox_override("panel", hint_style)
	_hint_center.add_child(hint_panel)
	_hint_label = UI.make_label("", 8, Color(UI.MUTED.r, UI.MUTED.g, UI.MUTED.b, 0.72))
	hint_panel.add_child(_hint_label)

func _build_notice() -> void:
	_notice_center = CenterContainer.new()
	_notice_center.anchor_left = 0.0
	_notice_center.anchor_right = 1.0
	_notice_center.anchor_top = 0.0
	_notice_center.anchor_bottom = 0.0
	_notice_center.offset_top = 84
	_notice_center.offset_bottom = 112
	_notice_center.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_notice_center)

	_notice_panel = PanelContainer.new()
	_notice_panel.add_theme_stylebox_override(
		"panel", UI.glass_style(Color(0.031, 0.086, 0.071, 0.98), 9, UI.ACCENT_DIM, 1, 8)
	)
	_notice_panel.visible = false
	_notice_panel.mouse_filter = MOUSE_FILTER_IGNORE
	_notice_center.add_child(_notice_panel)

	_notice_label = UI.make_label("", 10, UI.TEXT)
	_notice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice_panel.add_child(_notice_label)

	_notice_timer = Timer.new()
	_notice_timer.one_shot = true
	_notice_timer.wait_time = 4.0
	_notice_timer.timeout.connect(_hide_notice)
	add_child(_notice_timer)

func _build_menu() -> void:
	_menu_overlay = Control.new()
	_menu_overlay.name = "MenuOverlay"
	_menu_overlay.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_menu_overlay.mouse_filter = MOUSE_FILTER_STOP
	_menu_overlay.visible = false
	add_child(_menu_overlay)

	var dim := ColorRect.new()
	dim.color = Color(0.008, 0.024, 0.043, 0.62)
	dim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	dim.mouse_filter = MOUSE_FILTER_STOP
	dim.gui_input.connect(_on_dim_input)
	_menu_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	center.mouse_filter = MOUSE_FILTER_IGNORE
	_menu_overlay.add_child(center)

	_menu_panel = PanelContainer.new()
	_menu_panel.name = "MenuPanel"
	_menu_panel.custom_minimum_size = Vector2(560, 360)
	_menu_panel.add_theme_stylebox_override(
		"panel", UI.glass_style(UI.INK, 14, UI.BORDER_STRONG, 1, 0)
	)
	_menu_panel.mouse_filter = MOUSE_FILTER_STOP
	center.add_child(_menu_panel)
	UI.add_bw_frame_overlay(_menu_panel)
	var menu_margin := UI.add_panel_content(_menu_panel, 12, 10)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	menu_margin.add_child(box)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	box.add_child(header)

	_menu_title = Loc.make_bold_label("Menu", 16, UI.TEXT)
	_menu_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_menu_title)

	var close_button := Button.new()
	close_button.custom_minimum_size = Vector2(24, 24)
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	Loc.bind_tooltip(close_button, "Close (Esc)")
	var close_normal := UI.button_style(Color(1.0, 1.0, 1.0, 0.045), 7)
	var close_hover := UI.button_style(Color(1.0, 1.0, 1.0, 0.10), 7)
	var close_pressed := UI.button_style(Color(1.0, 1.0, 1.0, 0.16), 7)
	for close_style in [close_normal, close_hover, close_pressed]:
		close_style.content_margin_left = 0
		close_style.content_margin_top = 0
		close_style.content_margin_right = 0
		close_style.content_margin_bottom = 0
	close_button.add_theme_stylebox_override("normal", close_normal)
	close_button.add_theme_stylebox_override("hover", close_hover)
	close_button.add_theme_stylebox_override("pressed", close_pressed)
	close_button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	close_button.pressed.connect(close_menu)
	var close_center := CenterContainer.new()
	close_center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	close_center.mouse_filter = MOUSE_FILTER_IGNORE
	close_button.add_child(close_center)
	var close_icon := TextureRect.new()
	close_icon.texture = _icon("close.svg")
	close_icon.custom_minimum_size = Vector2(12, 12)
	close_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	close_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	close_icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	close_icon.mouse_filter = MOUSE_FILTER_IGNORE
	close_center.add_child(close_icon)
	header.add_child(close_button)

	var divider := ColorRect.new()
	divider.color = Color(1, 1, 1, 0.06)
	divider.custom_minimum_size = Vector2(0, 1)
	divider.mouse_filter = MOUSE_FILTER_IGNORE
	box.add_child(divider)

	_menu_body = VBoxContainer.new()
	_menu_body.name = "MenuBody"
	_menu_body.add_theme_constant_override("separation", 6)
	_menu_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_menu_body)

	var footer := Loc.make_label("ESC to close", 8, UI.FAINT)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(footer)

func _toggle_menu(kind: String) -> void:
	if menu_open and _menu_kind == kind:
		close_menu()
		return
	_open_menu(kind)

func _open_menu(kind: String) -> void:
	if _menu_overlay == null:
		return
	_menu_kind = kind
	_menu_overlay.visible = true
	_build_menu_content()
	_refresh_nav()
	menu_state_changed.emit(true)
	if kind == "dex" and _pokedex_entries.is_empty():
		pokedex_requested.emit()

func close_menu() -> bool:
	if not menu_open:
		return false
	if _menu_kind == "learn_move" and not _learn_request.is_empty():
		return false
	_menu_overlay.visible = false
	_menu_kind = ""
	_refresh_nav()
	menu_state_changed.emit(false)
	return true

func _build_menu_content() -> void:
	if _building_menu or _menu_body == null:
		return
	_building_menu = true
	for child in _menu_body.get_children():
		_menu_body.remove_child(child)
		child.queue_free()
	_big_minimap = null
	match _menu_kind:
		"bag":
			_menu_title.text = Loc.t("Bag")
			_menu_panel.custom_minimum_size = Vector2(660, 450)
			_build_bag_menu()
		"dex":
			_menu_title.text = Loc.t("Pokédex")
			_menu_panel.custom_minimum_size = Vector2(740, 468)
			_build_dex_menu()
		"map":
			_menu_title.text = Loc.t("Map")
			_menu_panel.custom_minimum_size = Vector2(620, 430)
			_build_map_menu()
		"party":
			_menu_title.text = Loc.t("Party")
			_menu_panel.custom_minimum_size = Vector2(660, 450)
			_build_party_menu()
		"settings":
			_menu_title.text = Loc.t("Settings")
			_menu_panel.custom_minimum_size = Vector2(560, 420)
			_build_settings_menu()
		"learn_move":
			_menu_title.text = Loc.t("Learn Move")
			_menu_panel.custom_minimum_size = Vector2(620, 430)
			_build_learn_move_menu()
		_:
			_menu_title.text = Loc.t("Menu")
			_menu_panel.custom_minimum_size = Vector2(560, 360)
	_building_menu = false

func _section_label(key: String, args: Array = []) -> Label:
	return UI.make_label(Loc.tf(key, args).to_upper(), 8, UI.MUTED)

func _build_party_menu() -> void:
	if _party.is_empty():
		_party_selected_index = 0
	else:
		_party_selected_index = clampi(_party_selected_index, 0, _party.size() - 1)
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_menu_body.add_child(body)

	var list_col := VBoxContainer.new()
	list_col.custom_minimum_size = Vector2(264, 0)
	list_col.add_theme_constant_override("separation", 3)
	body.add_child(list_col)
	list_col.add_child(_section_label("%d / %d SLOTS", [_party.size(), PARTY_SIZE]))
	for index in range(PARTY_SIZE):
		if index < _party.size() and _party[index] is Dictionary:
			list_col.add_child(_make_party_menu_row(_party[index], index))
		else:
			var empty := DashedSlotScript.new()
			empty.text = Loc.t("EMPTY")
			empty.set_meta("label", empty.text)
			empty.custom_minimum_size = Vector2(0, 44)
			list_col.add_child(empty)

	var detail := PanelContainer.new()
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail.add_theme_stylebox_override(
		"panel", UI.glass_style(UI.CARD, 8, UI.BORDER, 1, 10)
	)
	body.add_child(detail)
	var selected: Dictionary = {}
	if _party_selected_index < _party.size() and _party[_party_selected_index] is Dictionary:
		selected = _party[_party_selected_index]
	detail.add_child(_make_party_info(selected, _party_selected_index))

func _make_party_menu_row(source: Dictionary, index: int) -> PanelContainer:
	var creature: Dictionary = source
	var max_hp := maxi(1, int(creature.get("maxHp", 1)))
	var hp := clampi(int(creature.get("hp", 0)), 0, max_hp)
	var ratio := float(hp) / float(max_hp)
	var selected := index == _party_selected_index
	var fainted := hp <= 0
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0, 44)
	row.mouse_filter = MOUSE_FILTER_STOP
	row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var style := StyleBoxFlat.new()
	style.bg_color = UI.CARD_ALT if selected else UI.CARD
	style.corner_radius_top_left = 7
	style.corner_radius_top_right = 7
	style.corner_radius_bottom_left = 7
	style.corner_radius_bottom_right = 7
	style.border_width_left = 2 if selected else 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = (
		Color(UI.ACCENT_DIM.r, UI.ACCENT_DIM.g, UI.ACCENT_DIM.b, 0.75)
		if selected
		else Color(1, 1, 1, 0.05)
	)
	style.content_margin_left = 5
	style.content_margin_top = 3
	style.content_margin_right = 5
	style.content_margin_bottom = 3
	row.add_theme_stylebox_override("panel", style)
	row.gui_input.connect(_on_party_row_input.bind(index))

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 6)
	line.mouse_filter = MOUSE_FILTER_IGNORE
	row.add_child(line)

	var icon_frame := PanelContainer.new()
	icon_frame.custom_minimum_size = Vector2(34, 34)
	icon_frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon_frame.mouse_filter = MOUSE_FILTER_IGNORE
	var icon_style := StyleBoxFlat.new()
	icon_style.bg_color = Color(0.024, 0.059, 0.098, 1.0)
	icon_style.corner_radius_top_left = 5
	icon_style.corner_radius_top_right = 5
	icon_style.corner_radius_bottom_left = 5
	icon_style.corner_radius_bottom_right = 5
	icon_style.border_width_left = 1
	icon_style.border_width_top = 1
	icon_style.border_width_right = 1
	icon_style.border_width_bottom = 1
	icon_style.border_color = Color(1, 1, 1, 0.05)
	icon_style.content_margin_left = 2
	icon_style.content_margin_top = 2
	icon_style.content_margin_right = 2
	icon_style.content_margin_bottom = 2
	icon_frame.add_theme_stylebox_override("panel", icon_style)
	line.add_child(icon_frame)
	var icon := TextureRect.new()
	icon.texture = _pokemon_icon(str(creature.get("species", "")))
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = MOUSE_FILTER_IGNORE
	if fainted:
		icon.modulate = Color(0.42, 0.47, 0.52, 0.9)
	icon_frame.add_child(icon)

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
	var gender_label := _make_gender_label(creature)
	if gender_label != null:
		name_row.add_child(gender_label)
	var types: Array = creature.get("types", [])
	var type_icons := _make_type_icons(types)
	if type_icons != null:
		name_row.add_child(type_icons)

	var meta := HBoxContainer.new()
	meta.add_theme_constant_override("separation", 4)
	meta.mouse_filter = MOUSE_FILTER_IGNORE
	info.add_child(meta)
	meta.add_child(Loc.make_label("Lv %d", 9, UI.MUTED, [int(creature.get("level", 1))]))
	var meta_spacer := Control.new()
	meta_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	meta_spacer.mouse_filter = MOUSE_FILTER_IGNORE
	meta.add_child(meta_spacer)
	meta.add_child(UI.make_label("%d/%d" % [hp, max_hp], 9, UI.FAINT))

	var bar := ProgressBar.new()
	bar.max_value = max_hp
	bar.value = hp
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 4)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.mouse_filter = MOUSE_FILTER_IGNORE
	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0.012, 0.035, 0.059, 1.0)
	bar_bg.corner_radius_top_left = 2
	bar_bg.corner_radius_top_right = 2
	bar_bg.corner_radius_bottom_left = 2
	bar_bg.corner_radius_bottom_right = 2
	var bar_fill := StyleBoxFlat.new()
	bar_fill.bg_color = UI.hp_color(ratio)
	bar_fill.corner_radius_top_left = 2
	bar_fill.corner_radius_top_right = 2
	bar_fill.corner_radius_bottom_left = 2
	bar_fill.corner_radius_bottom_right = 2
	bar.add_theme_stylebox_override("background", bar_bg)
	bar.add_theme_stylebox_override("fill", bar_fill)
	info.add_child(bar)
	return row

func _on_party_row_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_party_selected_index = index
		_forget_confirm = {}
		_build_menu_content()
		accept_event()
	elif event is InputEventScreenTouch and event.pressed:
		_party_selected_index = index
		_forget_confirm = {}
		_build_menu_content()
		accept_event()

func _make_party_info(creature: Dictionary, creature_index: int = 0, read_only: bool = false) -> Control:
	if creature.is_empty():
		var empty_box := VBoxContainer.new()
		empty_box.add_child(Loc.make_label("No Pokémon selected", 15, UI.MUTED))
		return empty_box

	var max_hp := maxi(1, int(creature.get("maxHp", 1)))
	var hp := clampi(int(creature.get("hp", 0)), 0, max_hp)
	var level := int(creature.get("level", 1))
	var xp := int(creature.get("xp", 0))
	var xp_next := int(creature.get("xpToNext", 20 + level * 12))
	if xp_next <= 0:
		xp_next = 20 + level * 12
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 3)
	scroll.add_child(content)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	content.add_child(header)
	var portrait := TextureRect.new()
	portrait.texture = _pokemon_icon(str(creature.get("species", "")))
	portrait.custom_minimum_size = Vector2(64, 64)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	portrait.mouse_filter = MOUSE_FILTER_IGNORE
	header.add_child(portrait)
	var head_info := VBoxContainer.new()
	head_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head_info.add_theme_constant_override("separation", 2)
	header.add_child(head_info)
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 6)
	head_info.add_child(name_row)
	name_row.add_child(UI.make_bold_label(str(creature.get("name", "?")), 15, UI.TEXT))
	var gender_label := _make_gender_label(creature)
	if gender_label != null:
		name_row.add_child(gender_label)
	name_row.add_child(Loc.make_label("Lv %d", 12, UI.MUTED, [level]))
	var type_icons := _make_type_icons(creature.get("types", []))
	if type_icons != null:
		head_info.add_child(type_icons)
	var status := _status_code(creature, hp <= 0)
	if status != "":
		head_info.add_child(_make_status_chip(status))

	var hp_row := HBoxContainer.new()
	hp_row.add_theme_constant_override("separation", 6)
	content.add_child(hp_row)
	hp_row.add_child(Loc.make_label("HP", 9, UI.MUTED))
	var hp_spacer := Control.new()
	hp_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hp_spacer.mouse_filter = MOUSE_FILTER_IGNORE
	hp_row.add_child(hp_spacer)
	hp_row.add_child(UI.make_label("%d / %d" % [hp, max_hp], 12, UI.TEXT))
	var hp_bar := ProgressBar.new()
	hp_bar.max_value = max_hp
	hp_bar.value = hp
	hp_bar.show_percentage = false
	hp_bar.custom_minimum_size = Vector2(0, 6)
	hp_bar.mouse_filter = MOUSE_FILTER_IGNORE
	var hp_bg := StyleBoxFlat.new()
	hp_bg.bg_color = Color(0.012, 0.035, 0.059, 1.0)
	hp_bg.corner_radius_top_left = 3
	hp_bg.corner_radius_top_right = 3
	hp_bg.corner_radius_bottom_left = 3
	hp_bg.corner_radius_bottom_right = 3
	var hp_fill := StyleBoxFlat.new()
	hp_fill.bg_color = UI.hp_color(float(hp) / float(max_hp))
	hp_fill.corner_radius_top_left = 3
	hp_fill.corner_radius_top_right = 3
	hp_fill.corner_radius_bottom_left = 3
	hp_fill.corner_radius_bottom_right = 3
	hp_bar.add_theme_stylebox_override("background", hp_bg)
	hp_bar.add_theme_stylebox_override("fill", hp_fill)
	content.add_child(hp_bar)

	var xp_row := HBoxContainer.new()
	xp_row.add_theme_constant_override("separation", 6)
	content.add_child(xp_row)
	xp_row.add_child(Loc.make_label("XP", 9, UI.MUTED))
	var xp_spacer := Control.new()
	xp_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	xp_spacer.mouse_filter = MOUSE_FILTER_IGNORE
	xp_row.add_child(xp_spacer)
	xp_row.add_child(UI.make_label("%d / %d" % [xp, xp_next], 12, UI.TEXT))
	var xp_bar := ProgressBar.new()
	xp_bar.max_value = xp_next
	xp_bar.value = xp
	xp_bar.show_percentage = false
	xp_bar.custom_minimum_size = Vector2(0, 4)
	xp_bar.mouse_filter = MOUSE_FILTER_IGNORE
	var xp_bg := StyleBoxFlat.new()
	xp_bg.bg_color = Color(0.012, 0.035, 0.059, 1.0)
	xp_bg.corner_radius_top_left = 2
	xp_bg.corner_radius_top_right = 2
	xp_bg.corner_radius_bottom_left = 2
	xp_bg.corner_radius_bottom_right = 2
	var xp_fill := StyleBoxFlat.new()
	xp_fill.bg_color = Color(UI.ACCENT.r, UI.ACCENT.g, UI.ACCENT.b, 0.8)
	xp_fill.corner_radius_top_left = 2
	xp_fill.corner_radius_top_right = 2
	xp_fill.corner_radius_bottom_left = 2
	xp_fill.corner_radius_bottom_right = 2
	xp_bar.add_theme_stylebox_override("background", xp_bg)
	xp_bar.add_theme_stylebox_override("fill", xp_fill)
	content.add_child(xp_bar)

	var stats := [
		["HP", "ATK", "DEF", "SPA", "SPD", "SPE"],
		[
			str(int(creature.get("maxHp", 0))),
			str(int(creature.get("atk", 0))),
			str(int(creature.get("def", 0))),
			str(int(creature.get("spAtk", 0))) if creature.has("spAtk") else "-",
			str(int(creature.get("spDef", 0))) if creature.has("spDef") else "-",
			str(int(creature.get("speed", 0)))
		]
	]
	content.add_child(_section_label("Stats"))
	content.add_child(_make_stat_line("BASE", stats[1], UI.TEXT))
	var ivs: Dictionary = creature.get("ivs", {}) if creature.get("ivs") is Dictionary else {}
	var evs: Dictionary = creature.get("evs", {}) if creature.get("evs") is Dictionary else {}
	content.add_child(_make_stat_line("IV", [
		_stat_value(ivs, "hp"), _stat_value(ivs, "atk"), _stat_value(ivs, "def"),
		_stat_value(ivs, "spAtk"), _stat_value(ivs, "spDef"), _stat_value(ivs, "speed")
	], UI.ACCENT))
	content.add_child(_make_stat_line("EV", [
		_stat_value(evs, "hp"), _stat_value(evs, "atk"), _stat_value(evs, "def"),
		_stat_value(evs, "spAtk"), _stat_value(evs, "spDef"), _stat_value(evs, "speed")
	], UI.GOLD))

	var nature_row := HBoxContainer.new()
	nature_row.add_theme_constant_override("separation", 6)
	content.add_child(nature_row)
	nature_row.add_child(Loc.make_label("NATURE", 9, UI.MUTED))
	nature_row.add_child(UI.make_label(UI.nature_label(str(creature.get("nature", "-"))), 12, UI.TEXT))
	var nature_spacer := Control.new()
	nature_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nature_spacer.mouse_filter = MOUSE_FILTER_IGNORE
	nature_row.add_child(nature_spacer)
	nature_row.add_child(Loc.make_label("HELD ITEM", 9, UI.MUTED))
	var held := str(creature.get("heldItem", "")).strip_edges()
	nature_row.add_child(UI.make_label(held if held != "" else Loc.t("None"), 12, UI.TEXT))

	content.add_child(_section_label("Moves"))
	var moves: Array = creature.get("moves", [])
	var pending_moves: Array = creature.get("pendingMoves", [])
	if not pending_moves.is_empty():
		var pending_key := (
			"%d move waiting to be learned"
			if pending_moves.size() == 1
			else "%d moves waiting to be learned"
		)
		content.add_child(
			UI.make_label(
				Loc.tf(pending_key, [pending_moves.size()]),
				9,
				UI.GOLD
			)
		)
	for move_index in range(4):
		var move_row := PanelContainer.new()
		move_row.custom_minimum_size = Vector2(0, 24)
		var move_style := StyleBoxFlat.new()
		move_style.bg_color = Color(1, 1, 1, 0.025)
		move_style.corner_radius_top_left = 4
		move_style.corner_radius_top_right = 4
		move_style.corner_radius_bottom_left = 4
		move_style.corner_radius_bottom_right = 4
		move_style.content_margin_left = 4
		move_style.content_margin_top = 2
		move_style.content_margin_right = 4
		move_style.content_margin_bottom = 2
		move_row.add_theme_stylebox_override("panel", move_style)
		var move_line := HBoxContainer.new()
		move_line.add_theme_constant_override("separation", 5)
		move_row.add_child(move_line)
		if move_index < moves.size() and moves[move_index] is Dictionary:
			var move: Dictionary = moves[move_index]
			var move_icon := TextureRect.new()
			move_icon.texture = _type_icon(str(move.get("type", "Normal")))
			move_icon.custom_minimum_size = Vector2(32, 16)
			move_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			move_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			move_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			move_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			move_icon.mouse_filter = MOUSE_FILTER_IGNORE
			move_line.add_child(move_icon)
			var move_name := UI.make_label(str(move.get("name", "?")), 12, UI.TEXT)
			move_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			move_line.add_child(move_name)
			var power := int(move.get("power", 0))
			var max_pp := int(move.get("maxPp", move.get("pp", 0)))
			var current_pp := int(move.get("currentPp", max_pp))
			var detail := Loc.t("Status") if power <= 0 else Loc.tf("Pow %d", [power])
			if max_pp > 0:
				detail += "   " + Loc.tf("%d/%d PP", [current_pp, max_pp])
			move_line.add_child(UI.make_label(detail, 9, UI.FAINT))
			if moves.size() > 1 and not read_only:
				var confirm_key := "%d:%d" % [creature_index, move_index]
				var confirming := str(_forget_confirm.get("key", "")) == confirm_key
				var forget := Button.new()
				Loc.bind(forget, "SURE?" if confirming else "FORGET")
				forget.custom_minimum_size = Vector2(52, 20)
				forget.focus_mode = Control.FOCUS_NONE
				forget.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
				var forget_style := UI.button_style(
					Color(UI.DANGER.r, UI.DANGER.g, UI.DANGER.b, 0.32)
					if confirming
					else Color(1, 1, 1, 0.05),
					4
				)
				forget_style.content_margin_left = 3
				forget_style.content_margin_right = 3
				forget_style.content_margin_top = 1
				forget_style.content_margin_bottom = 1
				forget.add_theme_stylebox_override("normal", forget_style)
				forget.add_theme_stylebox_override("hover", forget_style)
				forget.add_theme_stylebox_override("pressed", forget_style)
				forget.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
				UI.apply_font(forget, 8)
				forget.add_theme_color_override(
					"font_color", UI.DANGER if confirming else UI.MUTED
				)
				forget.pressed.connect(
					_on_forget_move_pressed.bind(creature_index, move_index)
				)
				move_line.add_child(forget)
		else:
			move_line.add_child(UI.make_label("-", 9, UI.FAINT))
		content.add_child(move_row)
	return scroll

func _on_forget_move_pressed(party_index: int, move_index: int) -> void:
	var key := "%d:%d" % [party_index, move_index]
	if str(_forget_confirm.get("key", "")) == key:
		_forget_confirm = {}
		forget_move_requested.emit(party_index, move_index)
		return
	_forget_confirm = {"key": key}
	_build_menu_content()

func _stat_value(block: Dictionary, key_name: String) -> String:
	if block.is_empty() or not block.has(key_name):
		return "-"
	return str(int(block.get(key_name, 0)))

func _make_stat_line(title: String, values: Array, color: Color) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	var title_label := UI.make_label(Loc.t(title), 9, UI.MUTED)
	title_label.custom_minimum_size = Vector2(34, 0)
	row.add_child(title_label)
	for value in values:
		var label := UI.make_label(str(value), 12, color)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
	return row

func _dex_numbers_for_filter() -> Array:
	var numbers: Array = []
	if _pokedex_entries.is_empty():
		for dex in range(1, _pokedex_total + 1):
			if _pokedex_filter == "seen" and not _pokedex_seen.has(dex):
				continue
			if _pokedex_filter == "caught" and not _pokedex_caught.has(dex):
				continue
			numbers.append(dex)
		return numbers
	for entry_value in _pokedex_entries:
		if not (entry_value is Dictionary):
			continue
		var dex := int((entry_value as Dictionary).get("dex", 0))
		if dex <= 0:
			continue
		if _pokedex_filter == "seen" and not _pokedex_seen.has(dex):
			continue
		if _pokedex_filter == "caught" and not _pokedex_caught.has(dex):
			continue
		numbers.append(dex)
	return numbers

func _build_dex_menu() -> void:
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_menu_body.add_child(body)

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(454, 0)
	left.add_theme_constant_override("separation", 6)
	body.add_child(left)

	var summary := HBoxContainer.new()
	summary.add_theme_constant_override("separation", 10)
	left.add_child(summary)
	summary.add_child(
		Loc.make_bold_label("SEEN  %d", 12, UI.GOLD, [_pokedex_seen.size()])
	)
	summary.add_child(
		Loc.make_bold_label("CAUGHT  %d", 12, UI.ACCENT, [_pokedex_caught.size()])
	)
	var summary_spacer := Control.new()
	summary_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	summary_spacer.mouse_filter = MOUSE_FILTER_IGNORE
	summary.add_child(summary_spacer)
	summary.add_child(Loc.make_label("OF %d", 10, UI.FAINT, [_pokedex_total]))

	var filters := HBoxContainer.new()
	filters.add_theme_constant_override("separation", 4)
	left.add_child(filters)
	for filter_def in [["all", "ALL"], ["seen", "SEEN"], ["caught", "CAUGHT"]]:
		var filter_id := str(filter_def[0])
		var button := Button.new()
		button.text = Loc.t(str(filter_def[1]))
		button.custom_minimum_size = Vector2(66, 24)
		button.focus_mode = Control.FOCUS_NONE
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button.pressed.connect(_set_pokedex_filter.bind(filter_id))
		filters.add_child(button)
		_style_dex_filter(button, filter_id == _pokedex_filter)
	if _pokedex_entries.is_empty():
		var loading_spacer := Control.new()
		loading_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		loading_spacer.mouse_filter = MOUSE_FILTER_IGNORE
		filters.add_child(loading_spacer)
		filters.add_child(Loc.make_label("Loading entries...", 9, UI.MUTED))

	var numbers := _dex_numbers_for_filter()
	var page_count := maxi(1, ceili(float(numbers.size()) / float(DEX_PAGE_SIZE)))
	_pokedex_page = clampi(_pokedex_page, 0, page_count - 1)
	if not numbers.has(_pokedex_selected) and not numbers.is_empty():
		_pokedex_selected = int(numbers[0])

	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	left.add_child(grid)
	var start := _pokedex_page * DEX_PAGE_SIZE
	for offset in range(DEX_PAGE_SIZE):
		var index := start + offset
		if index >= numbers.size():
			break
		var dex := int(numbers[index])
		var entry: Dictionary = _pokedex_by_id.get(dex, {})
		var caught := _pokedex_caught.has(dex)
		var seen := _pokedex_seen.has(dex)
		var button := Button.new()
		button.name = "DexEntry%d" % dex
		button.custom_minimum_size = Vector2(86, 38)
		button.focus_mode = Control.FOCUS_NONE
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.text = "#%03d" % dex
		button.tooltip_text = (
			"#%03d %s" % [dex, str(entry.get("name", "?????"))]
			if seen
			else Loc.tf("#%03d Not yet seen", [dex])
		)
		if caught and not entry.is_empty():
			button.icon = _pokemon_icon(str(entry.get("id", "")))
			button.add_theme_constant_override("icon_max_width", 26)
		UI.apply_font(button, 10)
		var selected := dex == _pokedex_selected
		var style := UI.button_style(
			UI.ACCENT_SOFT if selected else (UI.CARD_ALT if caught else Color(1, 1, 1, 0.035)),
			6
		)
		style.content_margin_left = 4
		style.content_margin_right = 4
		style.content_margin_top = 2
		style.content_margin_bottom = 2
		style.border_width_left = 1
		style.border_width_top = 1
		style.border_width_right = 1
		style.border_width_bottom = 1
		style.border_color = (
			Color(UI.ACCENT_DIM.r, UI.ACCENT_DIM.g, UI.ACCENT_DIM.b, 0.9)
			if selected
			else Color(1, 1, 1, 0.06)
		)
		button.add_theme_stylebox_override("normal", style)
		button.add_theme_stylebox_override("hover", style)
		button.add_theme_stylebox_override("pressed", style)
		button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		button.add_theme_color_override(
			"font_color",
			UI.ACCENT if selected else (UI.TEXT if seen else UI.FAINT)
		)
		button.pressed.connect(_select_dex_entry.bind(dex))
		grid.add_child(button)

	var pager := HBoxContainer.new()
	pager.add_theme_constant_override("separation", 6)
	left.add_child(pager)
	var prev := Button.new()
	prev.text = "<"
	prev.custom_minimum_size = Vector2(34, 24)
	prev.disabled = _pokedex_page <= 0
	prev.focus_mode = Control.FOCUS_NONE
	prev.pressed.connect(_change_dex_page.bind(-1))
	pager.add_child(prev)
	var page_label := UI.make_label(
		Loc.tf("PAGE %d / %d   -   %d entries", [
			_pokedex_page + 1, page_count, numbers.size()
		]),
		9,
		UI.MUTED
	)
	page_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pager.add_child(page_label)
	var next := Button.new()
	next.text = ">"
	next.custom_minimum_size = Vector2(34, 24)
	next.disabled = _pokedex_page >= page_count - 1
	next.focus_mode = Control.FOCUS_NONE
	next.pressed.connect(_change_dex_page.bind(1))
	pager.add_child(next)

	var detail := PanelContainer.new()
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail.add_theme_stylebox_override(
		"panel", UI.glass_style(UI.CARD, 8, UI.BORDER, 1, 10)
	)
	body.add_child(detail)
	detail.add_child(_make_dex_detail(_pokedex_selected))

func _style_dex_filter(button: Button, active: bool) -> void:
	var normal := UI.button_style(UI.ACCENT_SOFT if active else Color(1, 1, 1, 0.035), 5)
	normal.content_margin_left = 6
	normal.content_margin_right = 6
	normal.content_margin_top = 2
	normal.content_margin_bottom = 2
	normal.border_width_left = 1
	normal.border_width_top = 1
	normal.border_width_right = 1
	normal.border_width_bottom = 1
	normal.border_color = (
		Color(UI.ACCENT_DIM.r, UI.ACCENT_DIM.g, UI.ACCENT_DIM.b, 0.9)
		if active
		else Color(1, 1, 1, 0.06)
	)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", normal)
	button.add_theme_stylebox_override("pressed", normal)
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	button.add_theme_color_override("font_color", UI.ACCENT if active else UI.MUTED)
	UI.apply_font(button, 9)

func _make_dex_detail(dex: int) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var entry: Dictionary = _pokedex_by_id.get(dex, {})
	var seen := _pokedex_seen.has(dex)
	var caught := _pokedex_caught.has(dex)
	var portrait := TextureRect.new()
	portrait.custom_minimum_size = Vector2(112, 112)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	portrait.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	portrait.mouse_filter = MOUSE_FILTER_IGNORE
	if seen and not entry.is_empty():
		portrait.texture = _pokemon_icon(str(entry.get("id", "")))
	else:
		portrait.texture = _pokemon_icon("")
		portrait.modulate = Color(0.18, 0.22, 0.27, 0.75)
	box.add_child(portrait)

	var number := UI.make_label("#%03d" % dex, 11, UI.ACCENT)
	number.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(number)
	var display_name := str(entry.get("name", "?????")) if seen else "?????"
	var title := UI.make_bold_label(display_name, 15, UI.TEXT if seen else UI.MUTED)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(title)

	if seen and not entry.is_empty():
		var types: Array = entry.get("types", [])
		var icons := _make_type_icons(types)
		if icons != null:
			icons.alignment = BoxContainer.ALIGNMENT_CENTER
			box.add_child(icons)
	var status_text := Loc.t("CAUGHT" if caught else ("SEEN" if seen else "NO DATA"))
	var status_color := UI.ACCENT if caught else (UI.GOLD if seen else UI.FAINT)
	var status := UI.make_bold_label(status_text, 11, status_color)
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(status)
	if not seen:
		var hint := Loc.make_label(
			"Encounter this species to register it\nin the Pokédex.",
			11,
			UI.MUTED
		)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(hint)
	else:
		var evolutions: Array = entry.get("evolutions", [])
		if not evolutions.is_empty():
			box.add_child(_section_label("Evolution"))
			for evolution_value in evolutions:
				if not (evolution_value is Dictionary):
					continue
				var evolution: Dictionary = evolution_value
				box.add_child(
					UI.make_label(_evolution_text(evolution), 10, UI.MUTED)
				)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = MOUSE_FILTER_IGNORE
	box.add_child(spacer)
	if caught:
		var caught_label := Loc.make_label(
			"Registered by capture or evolution.",
			9,
			UI.FAINT
		)
		caught_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		caught_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(caught_label)
	return box

func _evolution_text(evolution: Dictionary) -> String:
	var name := str(evolution.get("name", "?"))
	match str(evolution.get("method", "level")):
		"level":
			return Loc.tf("Lv.%d  %s", [int(evolution.get("level", 0)), name])
		"levelMove":
			return Loc.tf("Level up knowing a move  ->  %s", [name])
		"levelFriendship":
			return Loc.tf("High friendship  ->  %s", [name])
		"levelHold":
			return Loc.tf("Level up holding an item  ->  %s", [name])
		"useItem":
			return Loc.tf("Use an item  ->  %s", [name])
		"trade":
			return Loc.tf("Trade  ->  %s", [name])
		_:
			return Loc.tf("Special condition  ->  %s", [name])

func _set_pokedex_filter(filter_id: String) -> void:
	_pokedex_filter = filter_id
	_pokedex_page = 0
	_build_menu_content()

func _change_dex_page(delta: int) -> void:
	_pokedex_page = maxi(0, _pokedex_page + delta)
	_build_menu_content()

func _select_dex_entry(dex: int) -> void:
	_pokedex_selected = dex
	_build_menu_content()

func show_move_learn(request: Dictionary) -> void:
	if request.is_empty():
		return
	_learn_request = request.duplicate(true)
	_open_menu("learn_move")

func _build_learn_move_menu() -> void:
	if _learn_request.is_empty():
		_menu_body.add_child(Loc.make_label("No move is waiting to be learned.", 12, UI.MUTED))
		return
	var move: Dictionary = (
		_learn_request.get("move", {})
		if _learn_request.get("move", {}) is Dictionary
		else {}
	)
	var creature_name := str(_learn_request.get("creatureName", "Your Pokémon"))
	var moves: Array = (
		_learn_request.get("moves", [])
		if _learn_request.get("moves", []) is Array
		else []
	)
	_menu_body.add_child(
		UI.make_bold_label(Loc.tf("%s wants to learn %s!", [
			creature_name, str(move.get("name", Loc.t("a new move")))
		]), 15, UI.TEXT)
	)
	var info := HBoxContainer.new()
	info.add_theme_constant_override("separation", 8)
	_menu_body.add_child(info)
	var icon := TextureRect.new()
	icon.texture = _type_icon(str(move.get("type", "Normal")))
	icon.custom_minimum_size = Vector2(40, 20)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	info.add_child(icon)
	var power := int(move.get("power", 0))
	var pp := int(move.get("pp", 0))
	var detail := Loc.t("Status") if power <= 0 else Loc.tf("Power %d", [power])
	if pp > 0:
		detail += "   -   " + Loc.tf("%d PP", [pp])
	detail += "   -   " + Loc.t("category." + str(move.get("category", "status")))
	info.add_child(UI.make_label(detail, 10, UI.MUTED))

	if moves.size() < 4:
		var learn := Button.new()
		learn.text = Loc.tf("LEARN %s", [str(move.get("name", "")).to_upper()])
		learn.custom_minimum_size = Vector2(0, 32)
		UI.style_button(learn, true, true)
		learn.pressed.connect(_choose_move_learn.bind(0))
		_menu_body.add_child(learn)
	else:
		_menu_body.add_child(_section_label("Forget a move to make room"))
	for index in range(moves.size()):
		var known: Dictionary = moves[index] if moves[index] is Dictionary else {}
		var row := PanelContainer.new()
		row.custom_minimum_size = Vector2(0, 30)
		var style := UI.button_style(Color(1, 1, 1, 0.035), 6)
		style.content_margin_left = 6
		style.content_margin_right = 6
		style.content_margin_top = 3
		style.content_margin_bottom = 3
		row.add_theme_stylebox_override("panel", style)
		_menu_body.add_child(row)
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 6)
		row.add_child(line)
		var known_icon := TextureRect.new()
		known_icon.texture = _type_icon(str(known.get("type", "Normal")))
		known_icon.custom_minimum_size = Vector2(32, 16)
		known_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		known_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		known_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		line.add_child(known_icon)
		var known_name := UI.make_label(str(known.get("name", "?")), 12, UI.TEXT)
		known_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_child(known_name)
		var max_pp := int(known.get("maxPp", known.get("pp", 0)))
		var current_pp := int(known.get("currentPp", max_pp))
		line.add_child(UI.make_label(Loc.tf("%d/%d PP", [current_pp, max_pp]), 9, UI.FAINT))
		var replace := Button.new()
		Loc.bind(replace, "REPLACE")
		replace.custom_minimum_size = Vector2(84, 22)
		replace.focus_mode = Control.FOCUS_NONE
		UI.style_button(replace, false, true)
		replace.pressed.connect(_choose_move_learn.bind(index))
		line.add_child(replace)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 6)
	_menu_body.add_child(footer)
	var skip := Button.new()
	Loc.bind(skip, "DON'T LEARN")
	skip.custom_minimum_size = Vector2(140, 30)
	skip.focus_mode = Control.FOCUS_NONE
	UI.style_button(skip, false, true)
	skip.pressed.connect(_choose_move_learn.bind(-1))
	footer.add_child(skip)
	var hint := Loc.make_label(
		"The learned move starts with full PP.",
		9,
		UI.FAINT
	)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	footer.add_child(hint)

func _choose_move_learn(replace_index: int) -> void:
	if _learn_request.is_empty():
		return
	var source := str(_learn_request.get("source", "party"))
	var index := int(_learn_request.get("index", 0))
	var move_id := str(_learn_request.get("moveId", ""))
	_learn_request = {}
	_menu_overlay.visible = false
	_menu_kind = ""
	_refresh_nav()
	menu_state_changed.emit(false)
	move_learn_choice.emit(source, index, move_id, replace_index)

func _build_bag_menu() -> void:
	_bag_tabs.clear()
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 8)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_menu_body.add_child(body)

	var tabs := VBoxContainer.new()
	tabs.custom_minimum_size = Vector2(92, 0)
	tabs.add_theme_constant_override("separation", 4)
	body.add_child(tabs)
	for pocket in BAG_POCKETS:
		var entry: Dictionary = pocket
		var pocket_id := str(entry.get("id", ""))
		var button := Button.new()
		button.text = Loc.t(str(entry.get("label", "")))
		button.custom_minimum_size = Vector2(0, 32)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.focus_mode = Control.FOCUS_NONE
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		UI.apply_font(button, 10)
		button.pressed.connect(_select_bag_pocket.bind(pocket_id))
		tabs.add_child(button)
		_bag_tabs[pocket_id] = button

	var list_col := VBoxContainer.new()
	list_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_col.add_theme_constant_override("separation", 4)
	body.add_child(list_col)
	list_col.add_child(UI.make_label(_bag_pocket_title(_bag_pocket).to_upper(), 8, UI.MUTED))
	var items := _bag_items()
	for row_index in range(6):
		if row_index < items.size():
			list_col.add_child(_make_bag_row(items[row_index], row_index == 0))
		else:
			var empty := DashedSlotScript.new()
			empty.text = Loc.t("EMPTY")
			empty.set_meta("label", empty.text)
			empty.custom_minimum_size = Vector2(0, 32)
			list_col.add_child(empty)
	var money_spacer := Control.new()
	money_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	money_spacer.mouse_filter = MOUSE_FILTER_IGNORE
	list_col.add_child(money_spacer)
	list_col.add_child(_bag_money_row())

	var detail := PanelContainer.new()
	detail.custom_minimum_size = Vector2(224, 0)
	detail.add_theme_stylebox_override(
		"panel", UI.glass_style(UI.CARD, 8, UI.BORDER, 1, 10)
	)
	body.add_child(detail)
	detail.add_child(_make_bag_detail(items[0] if not items.is_empty() else {}))
	_refresh_bag_tabs()

func _select_bag_pocket(pocket: String) -> void:
	_bag_pocket = pocket
	_build_menu_content()

func _refresh_bag_tabs() -> void:
	for pocket_id in _bag_tabs.keys():
		var button: Button = _bag_tabs[pocket_id]
		var active: bool = str(pocket_id) == _bag_pocket
		var style := UI.button_style(
			UI.ACCENT_SOFT if active else Color(1, 1, 1, 0.035), 5
		)
		style.content_margin_left = 8
		style.content_margin_right = 8
		style.content_margin_top = 3
		style.content_margin_bottom = 3
		style.border_width_left = 1
		style.border_width_top = 1
		style.border_width_right = 1
		style.border_width_bottom = 1
		style.border_color = (
			Color(UI.ACCENT_DIM.r, UI.ACCENT_DIM.g, UI.ACCENT_DIM.b, 0.9)
			if active
			else Color(1, 1, 1, 0.06)
		)
		button.add_theme_stylebox_override("normal", style)
		button.add_theme_stylebox_override("hover", style)
		button.add_theme_stylebox_override("pressed", style)
		button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		var color := UI.ACCENT if active else UI.MUTED
		button.add_theme_color_override("font_color", color)
		button.add_theme_color_override("font_hover_color", UI.ACCENT)
		button.add_theme_color_override("font_pressed_color", color)

func _bag_pocket_title(pocket: String) -> String:
	match pocket:
		"items":
			return Loc.t("Items")
		"medicine":
			return Loc.t("Medicine")
		"balls":
			return Loc.t("Poké Balls")
		"tm":
			return Loc.t("TMs & HMs")
		"berries":
			return Loc.t("Berries")
		"key":
			return Loc.t("Key Items")
	return Loc.t("Items")

func _bag_items() -> Array:
	var category := ""
	match _bag_pocket:
		"balls":
			category = "ball"
		"medicine":
			category = "medicine"
		"items", "key":
			category = "key"
	var result: Array = []
	for item_value in _inventory_items.keys():
		var item_id := str(item_value)
		var count := int(_inventory_items[item_id])
		if count <= 0:
			continue
		var definition_value: Variant = _item_catalog.get(item_id, {})
		if not (definition_value is Dictionary):
			continue
		var definition: Dictionary = definition_value
		if definition.is_empty():
			continue
		if category != "" and str(definition.get("category", "")) != category:
			continue
		result.append({
			"id": item_id,
			"name": str(definition.get("name", item_id)),
			"qty": count,
			"icon": str(definition.get("icon", "poke_ball")),
			"desc": str(definition.get("description", "")),
			"category": str(definition.get("category", "")),
			"heal": int(definition.get("heal", 0)),
			"cureStatus": bool(definition.get("cureStatus", false)),
			"revive": bool(definition.get("revive", false)),
			"price": int(definition.get("price", 0))
		})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var order_a := int(_item_order.get(str(a.get("id", "")), 99))
		var order_b := int(_item_order.get(str(b.get("id", "")), 99))
		if order_a == order_b:
			return str(a.get("name", "")) < str(b.get("name", ""))
		return order_a < order_b
	)
	return result

func _item_icon(file: String) -> Texture2D:
	var key := file
	if key == "":
		key = "poke_ball"
	var candidates := [
		"res://assets/bw/ui/items/%s.png" % key,
		"res://assets/ui/icons/item_%s.svg" % key,
		"res://assets/ui/icons/%s.svg" % key
	]
	for path in candidates:
		if not ResourceLoader.exists(path):
			continue
		if _icon_cache.has(path):
			return _icon_cache[path]
		var texture := load(path) as Texture2D
		if texture != null:
			_icon_cache[path] = texture
			return texture
	return _icon("bag.svg")

func _make_bag_row(source: Dictionary, selected: bool) -> PanelContainer:
	var item: Dictionary = source
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0, 36)
	var style := StyleBoxFlat.new()
	style.bg_color = UI.CARD_ALT if selected else UI.CARD
	style.corner_radius_top_left = 7
	style.corner_radius_top_right = 7
	style.corner_radius_bottom_left = 7
	style.corner_radius_bottom_right = 7
	style.border_width_left = 2 if selected else 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = (
		Color(UI.ACCENT_DIM.r, UI.ACCENT_DIM.g, UI.ACCENT_DIM.b, 0.8)
		if selected
		else Color(1, 1, 1, 0.05)
	)
	style.content_margin_left = 7
	style.content_margin_top = 4
	style.content_margin_right = 7
	style.content_margin_bottom = 4
	row.add_theme_stylebox_override("panel", style)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 6)
	row.add_child(line)

	var cursor := UI.make_label(">" if selected else "", 15, UI.ACCENT)
	cursor.custom_minimum_size = Vector2(9, 0)
	line.add_child(cursor)

	var icon := TextureRect.new()
	icon.texture = _item_icon(str(item.get("icon", "poke_ball")))
	icon.custom_minimum_size = Vector2(26, 26)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = MOUSE_FILTER_IGNORE
	line.add_child(icon)

	var name_label := UI.make_label(str(item.get("name", "Item")), 15, UI.TEXT)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	line.add_child(name_label)

	var count := UI.make_label(Loc.tf("x %d", [int(item.get("qty", 1))]), 12, UI.GOLD)
	count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(count)
	return row

func _bag_money_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.add_child(Loc.make_label("MONEY", 9, UI.MUTED))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = MOUSE_FILTER_IGNORE
	row.add_child(spacer)
	var coin := TextureRect.new()
	coin.texture = _icon("coin.svg")
	coin.custom_minimum_size = Vector2(14, 14)
	coin.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	coin.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	coin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	coin.mouse_filter = MOUSE_FILTER_IGNORE
	row.add_child(coin)
	row.add_child(UI.make_bold_label(UI.format_money(_money), 15, UI.GOLD))
	return row

func _make_bag_detail(item: Dictionary) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var empty := item.is_empty()
	var icon := TextureRect.new()
	icon.texture = _item_icon(str(item.get("icon", "poke_ball")))
	icon.custom_minimum_size = Vector2(58, 58)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = MOUSE_FILTER_IGNORE
	if empty:
		icon.modulate = Color(0.55, 0.62, 0.70, 0.55)
	box.add_child(icon)

	var title := UI.make_bold_label(
		Loc.t("No items") if empty else str(item.get("name", Loc.t("Item"))), 15, UI.TEXT
	)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(title)
	var pocket := UI.make_label(Loc.tf("%s POCKET", [_bag_pocket_title(_bag_pocket).to_upper()]), 12, UI.ACCENT)
	pocket.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(pocket)
	var desc := UI.make_label(
		Loc.t("This pocket is empty.")
		if empty
		else str(item.get("desc", "")),
		12,
		UI.MUTED
	)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(0, 64)
	desc.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	box.add_child(desc)
	if not empty:
		var qty := UI.make_bold_label(Loc.tf("Quantity: %d", [int(item.get("qty", 1))]), 12, UI.GOLD)
		qty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(qty)
		if str(item.get("category", "")) == "medicine":
			box.add_child(_make_item_use_section(item))
	var detail_spacer := Control.new()
	detail_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_spacer.mouse_filter = MOUSE_FILTER_IGNORE
	box.add_child(detail_spacer)
	return box

func _make_item_use_section(item: Dictionary) -> Control:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", 3)
	section.size_flags_vertical = Control.SIZE_EXPAND_FILL
	section.add_child(_section_label("Use on"))

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.custom_minimum_size = Vector2(0, 132)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	section.add_child(scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 3)
	scroll.add_child(list)

	if _party.is_empty():
		list.add_child(Loc.make_label("Your party is empty.", 9, UI.MUTED))
		return section

	for index in range(_party.size()):
		if not (_party[index] is Dictionary):
			continue
		var creature: Dictionary = _party[index]
		var max_hp := maxi(1, int(creature.get("maxHp", 1)))
		var hp := clampi(int(creature.get("hp", 0)), 0, max_hp)
		var row := PanelContainer.new()
		row.custom_minimum_size = Vector2(0, 29)
		var style := StyleBoxFlat.new()
		style.bg_color = Color(1, 1, 1, 0.03)
		style.corner_radius_top_left = 5
		style.corner_radius_top_right = 5
		style.corner_radius_bottom_left = 5
		style.corner_radius_bottom_right = 5
		style.content_margin_left = 5
		style.content_margin_top = 2
		style.content_margin_right = 4
		style.content_margin_bottom = 2
		row.add_theme_stylebox_override("panel", style)
		list.add_child(row)

		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 4)
		row.add_child(line)
		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.add_theme_constant_override("separation", 0)
		line.add_child(info)
		var name_label := UI.make_label(str(creature.get("name", "?")), 11, UI.TEXT)
		name_label.clip_text = true
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		info.add_child(name_label)
		var status := _status_code(creature, hp <= 0)
		var detail_text := Loc.tf("Lv %d   %d/%d HP", [
			int(creature.get("level", 1)), hp, max_hp
		])
		if status != "":
			detail_text += "   " + UI.status_label(status)
		info.add_child(UI.make_label(detail_text, 8, UI.MUTED))

		var use_button := Button.new()
		Loc.bind(use_button, "USE")
		use_button.custom_minimum_size = Vector2(46, 22)
		use_button.focus_mode = Control.FOCUS_NONE
		use_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		UI.apply_font(use_button, 9)
		var normal := UI.button_style(UI.ACCENT_SOFT, 5)
		normal.content_margin_left = 4
		normal.content_margin_right = 4
		normal.content_margin_top = 1
		normal.content_margin_bottom = 1
		use_button.add_theme_stylebox_override("normal", normal)
		use_button.add_theme_stylebox_override("hover", normal)
		use_button.add_theme_stylebox_override("pressed", normal)
		use_button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		use_button.add_theme_color_override("font_color", UI.ACCENT)
		use_button.add_theme_color_override("font_disabled_color", UI.FAINT)
		use_button.disabled = not _can_use_item_on(item, creature)
		use_button.pressed.connect(
			func() -> void:
				item_use_requested.emit(str(item.get("id", "")), index)
		)
		line.add_child(use_button)
	return section

func _can_use_item_on(item: Dictionary, creature: Dictionary) -> bool:
	var hp := int(creature.get("hp", 0))
	var max_hp := maxi(1, int(creature.get("maxHp", 1)))
	var status := str(creature.get("status", "")).strip_edges()
	if bool(item.get("revive", false)):
		return hp <= 0
	if hp <= 0:
		return false
	if int(item.get("heal", 0)) > 0 and hp < max_hp:
		return true
	if bool(item.get("cureStatus", false)) and status != "":
		return true
	return false

func _build_map_menu() -> void:
	_menu_body.add_child(_section_label("World map"))
	_big_minimap = MinimapScript.new()
	_big_minimap.large = true
	_big_minimap.custom_minimum_size = Vector2(536, 292)
	_big_minimap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_big_minimap.map_pressed.connect(close_menu)
	_big_minimap.configure(
		_map_info, _map_name, _self_grid, _self_dir, str(_nearby_npc.get("id", ""))
	)
	_menu_body.add_child(_big_minimap)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 12)
	_menu_body.add_child(footer)
	footer.add_child(_legend_item(Color(0.596, 0.518, 0.341), "Path"))
	footer.add_child(_legend_item(Color(0.169, 0.322, 0.165), "Grass"))
	footer.add_child(_legend_item(Color(0.078, 0.176, 0.133), "Forest"))
	footer.add_child(_legend_item(Color(0.145, 0.380, 0.553), "Water"))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = MOUSE_FILTER_IGNORE
	footer.add_child(spacer)
	var here_key := (
		"%s  -  1 trainer here"
		if _local_count == 1
		else "%s  -  %d trainers here"
	)
	footer.add_child(UI.make_label(Loc.tf(here_key, [
		_location_name if _location_name != "" else Loc.t("Unknown area"),
		_local_count
	]), 8, UI.FAINT))

func _legend_item(color: Color, text: String) -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.mouse_filter = MOUSE_FILTER_IGNORE
	var swatch := ColorRect.new()
	swatch.color = color
	swatch.custom_minimum_size = Vector2(8, 8)
	swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	swatch.mouse_filter = MOUSE_FILTER_IGNORE
	box.add_child(swatch)
	box.add_child(UI.make_label(Loc.t(text), 8, UI.FAINT))
	return box

func _build_settings_menu() -> void:
	_menu_body.add_child(_section_label("Display"))
	_add_setting_toggle("Minimap", _show_minimap, "minimap")
	_add_setting_toggle("Control hints", _show_hints, "hints")
	_add_setting_toggle("Chat timestamps", _chat_timestamps, "timestamps")
	_menu_body.add_child(_section_label("Language"))
	_add_language_setting()
	_menu_body.add_child(_section_label("Controls"))
	_menu_body.add_child(
		Loc.make_label("WASD / arrows  move    -    Shift  run", 9, UI.MUTED)
	)
	_menu_body.add_child(
		Loc.make_label("E  talk    -    T / Enter  chat    -    Esc  close", 9, UI.MUTED)
	)
	_menu_body.add_child(_section_label("Connection"))
	var ping_text := Loc.tf("Ping %d ms", [_ping]) if _ping > 0 else Loc.t("Ping --")
	var conn_text := (
		Loc.tf("%s  -  %s  -  1 trainer here", [Loc.t(_connection), ping_text])
		if _local_count == 1
		else Loc.tf("%s  -  %s  -  %d trainers here", [
			Loc.t(_connection), ping_text, _local_count
		])
	)
	_menu_body.add_child(UI.make_label(conn_text, 9, UI.MUTED))

func _add_language_setting() -> void:
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0, 34)
	var style := StyleBoxFlat.new()
	style.bg_color = UI.CARD
	style.corner_radius_top_left = 7
	style.corner_radius_top_right = 7
	style.corner_radius_bottom_left = 7
	style.corner_radius_bottom_right = 7
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = Color(1, 1, 1, 0.05)
	style.content_margin_left = 9
	style.content_margin_top = 5
	style.content_margin_right = 7
	style.content_margin_bottom = 5
	row.add_theme_stylebox_override("panel", style)
	_menu_body.add_child(row)

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 8)
	row.add_child(line)
	var label := Loc.make_label("Language", 11, UI.TEXT)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(label)
	_locale_picker = OptionButton.new()
	_locale_picker.focus_mode = Control.FOCUS_NONE
	UI.style_button(_locale_picker, false, true)
	for code in Loc.SUPPORTED:
		_locale_picker.add_item(Loc.locale_label(code))
		_locale_picker.set_item_metadata(_locale_picker.item_count - 1, code)
	for index in range(_locale_picker.item_count):
		if str(_locale_picker.get_item_metadata(index)) == Loc.locale:
			_locale_picker.select(index)
			break
	_locale_picker.item_selected.connect(_on_locale_picker_selected)
	line.add_child(_locale_picker)

func _on_locale_picker_selected(index: int) -> void:
	Loc.set_locale(str(_locale_picker.get_item_metadata(index)))

func _add_setting_toggle(text: String, value: bool, key: String) -> void:
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0, 34)
	var style := StyleBoxFlat.new()
	style.bg_color = UI.CARD
	style.corner_radius_top_left = 7
	style.corner_radius_top_right = 7
	style.corner_radius_bottom_left = 7
	style.corner_radius_bottom_right = 7
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = Color(1, 1, 1, 0.05)
	style.content_margin_left = 9
	style.content_margin_top = 5
	style.content_margin_right = 7
	style.content_margin_bottom = 5
	row.add_theme_stylebox_override("panel", style)
	_menu_body.add_child(row)

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 8)
	row.add_child(line)
	var label := Loc.make_label(text, 11, UI.TEXT)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(label)
	var toggle := Button.new()
	toggle.custom_minimum_size = Vector2(46, 22)
	toggle.focus_mode = Control.FOCUS_NONE
	toggle.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	toggle.pressed.connect(_toggle_setting.bind(key, toggle))
	line.add_child(toggle)
	_refresh_toggle_button(toggle, value)

func _setting_value(key: String) -> bool:
	match key:
		"minimap":
			return _show_minimap
		"hints":
			return _show_hints
		"timestamps":
			return _chat_timestamps
	return false

func _toggle_setting(key: String, button: Button) -> void:
	var value := not _setting_value(key)
	_on_setting_toggled(value, key)
	_refresh_toggle_button(button, value)

func _refresh_toggle_button(button: Button, value: bool) -> void:
	button.text = Loc.t("ON") if value else Loc.t("OFF")
	var base := Color(1, 1, 1, 0.04)
	var border := UI.BORDER
	var font := UI.MUTED
	if value:
		base = UI.ACCENT_SOFT
		border = Color(UI.ACCENT_DIM.r, UI.ACCENT_DIM.g, UI.ACCENT_DIM.b, 0.8)
		font = UI.ACCENT
	var normal := UI.button_style(base, 10)
	normal.content_margin_left = 6
	normal.content_margin_right = 6
	normal.content_margin_top = 2
	normal.content_margin_bottom = 2
	normal.border_width_left = 1
	normal.border_width_top = 1
	normal.border_width_right = 1
	normal.border_width_bottom = 1
	normal.border_color = border
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(1, 1, 1, 0.08) if not value else Color(
		UI.ACCENT.r, UI.ACCENT.g, UI.ACCENT.b, 0.22
	)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(1, 1, 1, 0.12) if not value else Color(
		UI.ACCENT.r, UI.ACCENT.g, UI.ACCENT.b, 0.28
	)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	button.add_theme_color_override("font_color", font)
	button.add_theme_color_override("font_hover_color", font)
	button.add_theme_color_override("font_pressed_color", font)
	button.add_theme_font_size_override("font_size", UI.font_size(9))
	button.add_theme_font_override("font", UI.bw_font())

func _on_setting_toggled(value: bool, key: String) -> void:
	match key:
		"minimap":
			_show_minimap = value
			_minimap_panel.visible = value and not _dialogue_mode
		"hints":
			_show_hints = value
			_update_prompt_visibility()
		"timestamps":
			_chat_timestamps = value
			chat_timestamps_requested.emit(value)

func _on_dim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		close_menu()
		accept_event()
	elif event is InputEventScreenTouch and event.pressed:
		close_menu()
		accept_event()

func _refresh_trainer() -> void:
	if _name_label == null:
		return
	_name_label.text = _trainer_name
	var level := 0
	if not _party.is_empty() and _party[0] is Dictionary:
		level = int((_party[0] as Dictionary).get("level", 0))
	_level_label.text = (
		Loc.tf("Lv %d", [level]) if level > 0 else Loc.t("Lv --")
	)
	var location := (
		_location_name if _location_name != ""
		else (_map_name if _map_name != "" else Loc.t("Unova"))
	)
	_location_label.text = Loc.tf("%s  -  %s", [location, UI.season_label(_season)])
	_money_label.text = UI.format_money(_money)
	_wins_label.text = Loc.tf("%d win" if _wins == 1 else "%d wins", [_wins])
	if _big_minimap != null:
		_big_minimap.configure(
			_map_info, _map_name, _self_grid, _self_dir, str(_nearby_npc.get("id", ""))
		)

func _refresh_avatar() -> void:
	if _avatar_rect == null:
		return
	var sprite_id := int(_self_info.get("sprite", 0))
	var key := "hero"
	match sprite_id:
		1:
			key = "heroine"
		2:
			key = "boy4"
		3:
			key = "girl2"
	var texture := _square_texture(
		"%s/%s/frames/frame_04.png" % [ACTOR_ROOT, key], "avatar:" + key
	)
	if texture != null:
		_avatar_rect.texture = texture
	var female_override := str(_self_info.get("gender", "")).to_lower() == "female"
	var female := sprite_id == 1 or sprite_id == 3 or female_override
	_gender_rect.texture = _icon("gender_female.svg" if female else "gender_male.svg")

func _refresh_status() -> void:
	if _status_label == null:
		return
	_status_label.text = Loc.t(_connection)
	if _connected and _ping > 0:
		_status_label.text = Loc.tf("%s  -  %d ms", [Loc.t(_connection), _ping])
	_status_label.add_theme_color_override("font_color", UI.FAINT if _connected else UI.DANGER)
	var dot_color := UI.ACCENT if _connected else UI.DANGER
	var dot := StyleBoxFlat.new()
	dot.bg_color = dot_color
	dot.corner_radius_top_left = 3
	dot.corner_radius_top_right = 3
	dot.corner_radius_bottom_left = 3
	dot.corner_radius_bottom_right = 3
	_status_dot.add_theme_stylebox_override("panel", dot)

func _sync_minimap() -> void:
	if _minimap_title != null:
		_minimap_title.text = _location_name if _location_name != "" else Loc.t("Unknown")
	if _minimap != null:
		_minimap.configure(
			_map_info, _map_name, _self_grid, _self_dir, str(_nearby_npc.get("id", ""))
		)

func _update_prompt_visibility() -> void:
	if _prompt_center == null:
		return
	var has_npc := not _nearby_npc.is_empty()
	_prompt_center.visible = has_npc
	_hint_center.visible = (
		not has_npc and _show_hints and _hint_text.strip_edges() != ""
	)
	if has_npc:
		var npc_name := str(_nearby_npc.get("name", "")).strip_edges()
		_prompt_label.text = (
			Loc.tf("Talk to %s", [npc_name]) if npc_name != "" else Loc.t("Talk")
		)
		var font := _prompt_label.get_theme_font("font")
		var font_size := _prompt_label.get_theme_font_size("font_size")
		var text_width := font.get_string_size(
			_prompt_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size
		).x
		_prompt_button.custom_minimum_size = Vector2(
			clampf(text_width + 46.0, 124.0, 240.0), 30
		)
	_hint_label.text = _hint_text

func set_self(
	trainer_name: String,
	money: int,
	wins: int,
	info: Dictionary = {}
) -> void:
	_trainer_name = trainer_name
	_money = money
	_wins = wins
	if not info.is_empty():
		_apply_self_info(info)
	_refresh_trainer()
	if menu_open and _menu_kind == "bag":
		_build_menu_content()

func _apply_self_info(info: Dictionary) -> void:
	_self_info = info
	if info.has("name"):
		_trainer_name = str(info.get("name", _trainer_name))
	_refresh_avatar()

func set_player_info(info: Dictionary) -> void:
	_apply_self_info(info)
	_refresh_trainer()

func set_party(party: Array, max_party: int = PARTY_SIZE) -> void:
	_party = party.duplicate()
	_max_party = max_party
	_rebuild_party()
	_refresh_trainer()
	if menu_open and _menu_kind == "party":
		_build_menu_content()

func set_pokedex(
	seen: Array,
	caught: Array,
	entries: Array = [],
	total: int = 649
) -> void:
	_pokedex_seen.clear()
	_pokedex_caught.clear()
	for value in seen:
		_pokedex_seen[int(value)] = true
	for value in caught:
		_pokedex_caught[int(value)] = true
	_pokedex_total = maxi(total, 1)
	if not entries.is_empty():
		_pokedex_entries = entries.duplicate(true)
		_pokedex_by_id.clear()
		for entry_value in _pokedex_entries:
			if not (entry_value is Dictionary):
				continue
			var entry: Dictionary = entry_value
			_pokedex_by_id[int(entry.get("dex", 0))] = entry
		if _pokedex_selected <= 0 and not _pokedex_seen.is_empty():
			var seen_numbers: Array = _pokedex_seen.keys()
			seen_numbers.sort()
			_pokedex_selected = int(seen_numbers[0])
	if menu_open and _menu_kind == "dex":
		_build_menu_content()

func set_items(items: Array) -> void:
	_item_catalog.clear()
	_item_order.clear()
	for index in range(items.size()):
		var value: Variant = items[index]
		if not (value is Dictionary):
			continue
		var definition: Dictionary = value
		var item_id := str(definition.get("id", ""))
		if item_id == "":
			continue
		_item_catalog[item_id] = definition
		_item_order[item_id] = index
	if menu_open and _menu_kind == "bag":
		_build_menu_content()

func set_inventory(inventory: Dictionary) -> void:
	_inventory = inventory
	_inventory_items = {}
	var raw_items: Variant = inventory.get("items", {})
	if raw_items is Dictionary:
		for item_value in (raw_items as Dictionary).keys():
			_inventory_items[str(item_value)] = int((raw_items as Dictionary)[item_value])
	elif inventory.has("balls"):
		# Legacy servers/saves only sent a single ball counter.
		_inventory_items["poke_ball"] = int(inventory.get("balls", 0))
	_balls = int(_inventory_items.get("poke_ball", 0))
	if menu_open and _menu_kind == "bag":
		_build_menu_content()

func set_map(map_name: String, local_count: int = 1, location_name: String = "") -> void:
	_map_name = map_name
	_location_name = location_name if location_name != "" else map_name
	_local_count = local_count
	_refresh_trainer()
	_sync_minimap()

func set_location(location_name: String) -> void:
	if location_name == "" or location_name == _location_name:
		return
	_location_name = location_name
	_refresh_trainer()
	_sync_minimap()

func set_map_data(map_info: Dictionary, self_info: Dictionary) -> void:
	_map_info = map_info
	_self_grid = Vector2i(
		int(self_info.get("x", _self_grid.x)),
		int(self_info.get("y", _self_grid.y))
	)
	_self_dir = str(self_info.get("dir", _self_dir))
	_apply_self_info(self_info)
	_refresh_trainer()
	_sync_minimap()

func update_map_window(message: Dictionary) -> void:
	for key in ["tiles", "tileX", "tileY", "tileWidth", "tileHeight", "windowed"]:
		if message.has(key):
			_map_info[key] = message[key]
	_sync_minimap()

func update_self_position(x: int, y: int, direction: String) -> void:
	var grid := Vector2i(x, y)
	if grid == _self_grid and direction == _self_dir:
		return
	_self_grid = grid
	_self_dir = direction
	_sync_minimap()

func set_season(season: String) -> void:
	_season = season
	_refresh_trainer()

func set_world_time(hours: float) -> void:
	if _clock_label == null:
		return
	_world_hours = hours
	_clock_label.text = "%s %s" % [
		WorldTimeScript.phase_label(hours), WorldTimeScript.clock_text(hours)
	]
	_clock_label.add_theme_color_override("font_color", WorldTimeScript.phase_color(hours))

func set_nearby_npc(npc: Dictionary) -> void:
	var previous := str(_nearby_npc.get("id", ""))
	_nearby_npc = npc.duplicate()
	var changed := previous != str(_nearby_npc.get("id", ""))
	_update_prompt_visibility()
	if changed:
		_sync_minimap()

func set_ping(milliseconds: int) -> void:
	_ping = milliseconds
	_refresh_status()

func set_connection(text: String, ok: bool = true) -> void:
	_connection = text
	_connected = ok
	_refresh_status()

func set_hint(text: String) -> void:
	_hint_text = text
	_update_prompt_visibility()

func set_dialogue_mode(active: bool) -> void:
	_dialogue_mode = active
	_minimap_panel.visible = _show_minimap and not active

func set_touch_layout(enabled: bool) -> void:
	_touch_layout = enabled
	if _minimap_panel == null or _nav_container == null or _status_container == null:
		return
	if enabled:
		# Touch controls occupy the bottom-right; keep the old top-right stack
		# there so the D-pad has room.
		_minimap_panel.anchor_top = 0.0
		_minimap_panel.anchor_bottom = 0.0
		_minimap_panel.offset_top = 92
		_minimap_panel.offset_bottom = 262
		_nav_container.anchor_top = 0.0
		_nav_container.anchor_bottom = 0.0
		_nav_container.offset_top = 10
		_nav_container.offset_bottom = 68
		_status_container.anchor_top = 0.0
		_status_container.anchor_bottom = 0.0
		_status_container.offset_top = 72
		_status_container.offset_bottom = 86
	else:
		# Desktop: minimap on top, navigation at the bottom-right.
		_minimap_panel.anchor_top = 0.0
		_minimap_panel.anchor_bottom = 0.0
		_minimap_panel.offset_top = 10
		_minimap_panel.offset_bottom = 180
		_nav_container.anchor_top = 1.0
		_nav_container.anchor_bottom = 1.0
		_nav_container.offset_top = -68
		_nav_container.offset_bottom = -10
		_status_container.anchor_top = 1.0
		_status_container.anchor_bottom = 1.0
		_status_container.offset_top = -88
		_status_container.offset_bottom = -74

func show_notice(text: String) -> void:
	_notice_label.text = text
	_notice_panel.visible = true
	# Keep server feedback above the menu overlay (which is a later child).
	if _notice_center != null and _notice_center.get_index() != get_child_count() - 1:
		move_child(_notice_center, get_child_count() - 1)
	_notice_timer.start()

func _hide_notice() -> void:
	_notice_panel.visible = false


func show_capture_card(creature: Dictionary) -> void:
	_close_capture_card(false)
	if creature.is_empty():
		return
	_capture_overlay = Control.new()
	_capture_overlay.name = "CaptureCardOverlay"
	_capture_overlay.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_capture_overlay.mouse_filter = MOUSE_FILTER_STOP
	_capture_overlay.z_index = 20
	add_child(_capture_overlay)

	var dim := ColorRect.new()
	dim.color = Color(0.008, 0.024, 0.043, 0.76)
	dim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	dim.mouse_filter = MOUSE_FILTER_STOP
	_capture_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	center.mouse_filter = MOUSE_FILTER_IGNORE
	_capture_overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(620, 470)
	panel.add_theme_stylebox_override(
		"panel", UI.glass_style(UI.INK, 14, UI.BORDER_STRONG, 1, 0)
	)
	panel.mouse_filter = MOUSE_FILTER_STOP
	center.add_child(panel)
	UI.add_bw_frame_overlay(panel)
	var margin := UI.add_panel_content(panel, 14, 12)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 7)
	margin.add_child(box)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	box.add_child(header)
	header.add_child(Loc.make_bold_label("New Pokémon", 20, UI.ACCENT))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = MOUSE_FILTER_IGNORE
	header.add_child(spacer)
	header.add_child(Loc.make_label("Added to your party.", 11, UI.MUTED))

	var divider := ColorRect.new()
	divider.color = Color(1, 1, 1, 0.07)
	divider.custom_minimum_size = Vector2(0, 1)
	divider.mouse_filter = MOUSE_FILTER_IGNORE
	box.add_child(divider)

	var info := _make_party_info(creature, 0, true)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(info)

	var close_row := HBoxContainer.new()
	close_row.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(close_row)
	var close := Button.new()
	close.custom_minimum_size = Vector2(120, 30)
	UI.style_button(close, true, true)
	Loc.bind(close, "Close")
	close.pressed.connect(_close_capture_card)
	close_row.add_child(close)
	close.grab_focus()

func close_capture_card() -> void:
	_close_capture_card()

func _close_capture_card(notify: bool = true) -> void:
	if _capture_overlay == null:
		return
	_capture_overlay.queue_free()
	_capture_overlay = null
	get_viewport().gui_release_focus()
	if notify:
		capture_card_closed.emit()

func _unhandled_input(event: InputEvent) -> void:
	if _capture_overlay == null:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			_close_capture_card()
			get_viewport().set_input_as_handled()

