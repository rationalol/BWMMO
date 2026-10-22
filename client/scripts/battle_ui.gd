extends Control

signal action_selected(action: String, value: int, item_id: String)
signal item_used(item_id: String, party_index: int)
signal closed

const WorldTimeScript = preload("res://scripts/world_time.gd")
const UI = preload("res://scripts/ui_theme.gd")
const ArenaScript = preload("res://scripts/battle_arena.gd")
const PlateScript = preload("res://scripts/battle_plate.gd")
const BattleCreatureScript = preload("res://scripts/battle_creature.gd")
const BattleEffectsScript = preload("res://scripts/battle_effects.gd")
const BattleActorFXScript = preload("res://scripts/battle_actor_fx.gd")
const BattleEventPlayerScript = preload("res://scripts/battle_event_player.gd")
const BATTLE_WIPE_SHADER = preload("res://shaders/battle_wipe.gdshader")

const FONT_2X_PATH := "res://assets/bw/ui/bw_font_2x.fnt"
const FONT_3X_PATH := "res://assets/bw/ui/bw_font_3x.fnt"
const OUTLINE := Color("0a0f0f")
const PANEL_BG := Color(0.055, 0.050, 0.048, 0.97)
const PANEL_BORDER := Color("d6dedc")
const PANEL_INNER := Color("342e2a")
const BUTTON_BG := Color("2c2a2a")
const BUTTON_HOVER := Color("3c3938")
const BUTTON_PRESSED := Color("542824")
const TEXT := Color("f7fcfb")
const MUTED := Color("b6c4c0")
const FIGHT_COLOR := Color("ff4e60")
const BAG_COLOR := Color("ffc850")
const MON_COLOR := Color("78f05a")
const RUN_COLOR := Color("5ac8ff")

var _battle: Dictionary = {}
var _awaiting := false
var _displayed_active := -1
var _menu_mode := "commands"
var _entry_active := false
var _season := "autumn"
var _indoor := false
var _world_tint := Color(1, 1, 1, 1)
var _world_hours := 12.0
var _items: Dictionary = {}
var _target_item := ""

var _font_huge: Font = null
var _font_big: Font = null
var _font_small: Font = null
var _field_root: Control
var _effects
var _actor_fx
var _event_player
var _arena
var _enemy_plate
var _player_plate
var _enemy_creature
var _player_creature
var _sprite_tint := Color(1, 1, 1, 1)
var _turn_animating := false
var _pending_result: Dictionary = {}
var _caught_pending := false
var _message_panel: Panel
var _message_primary: Label
var _battle_clock: Label
var _command_panel: Panel
var _command_row: HBoxContainer

var _switch_overlay: Control
var _switch_title: Label
var _switch_help: Label
var _switch_list: VBoxContainer
var _switch_cancel: Button
var _item_overlay: Control
var _item_list: VBoxContainer
var _item_cancel: Button
var _end_overlay: Control
var _result_label: Label
var _result_message: Label
var _continue_button: Button
var _entry_overlay: Control
var _entry_wipe: ColorRect
var _entry_flash: ColorRect
var _entry_banner: Label
var _entry_tween: Tween = null

func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_STOP
	visible = false
	Loc.locale_changed.connect(_on_locale_changed)
	_load_fonts()
	_build_ui()

func _load_fonts() -> void:
	if UI.cjk_locale() and UI.has_cjk_font():
		_font_huge = UI.cjk_font()
		_font_big = UI.cjk_font()
		_font_small = UI.cjk_font()
		return
	_font_huge = null
	_font_big = null
	if ResourceLoader.exists(FONT_3X_PATH):
		_font_huge = load(FONT_3X_PATH) as Font
	if ResourceLoader.exists(FONT_2X_PATH):
		_font_big = load(FONT_2X_PATH) as Font
	if _font_big == null:
		_font_big = UI.bw_font()
	if _font_huge == null:
		_font_huge = _font_big
	_font_small = UI.bw_font()

func _build_ui() -> void:
	# Everything that belongs to the battlefield lives under one root so the
	# camera commands can nudge the arena and both battlers without moving the
	# message box or command menu.
	_field_root = Control.new()
	_field_root.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_field_root.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_field_root)

	_arena = ArenaScript.new()
	_field_root.add_child(_arena)
	_arena.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_arena.setup(_season, _indoor)

	_enemy_plate = PlateScript.new()
	_enemy_plate.setup("enemy")
	_enemy_plate.anchor_left = 0.0
	_enemy_plate.anchor_top = 0.0
	_enemy_plate.offset_left = 33.0
	_enemy_plate.offset_top = 24.0
	_enemy_plate.offset_right = 33.0 + 420.0
	_enemy_plate.offset_bottom = 24.0 + 104.0
	_field_root.add_child(_enemy_plate)

	_player_plate = PlateScript.new()
	_player_plate.setup("player")
	_player_plate.anchor_left = 1.0
	_player_plate.anchor_top = 0.0
	_player_plate.offset_left = -453.0
	_player_plate.offset_top = 238.0
	_player_plate.offset_right = -33.0
	_player_plate.offset_bottom = 238.0 + 140.0
	_field_root.add_child(_player_plate)

	_enemy_creature = BattleCreatureScript.new()
	_enemy_creature.anchor_left = 0.0
	_enemy_creature.anchor_top = 0.0
	_enemy_creature.offset_left = 546.0
	_enemy_creature.offset_top = 56.0
	_enemy_creature.offset_right = 546.0 + 300.0
	_enemy_creature.offset_bottom = 56.0 + 190.0
	_field_root.add_child(_enemy_creature)

	_player_creature = BattleCreatureScript.new()
	_player_creature.anchor_left = 0.0
	_player_creature.anchor_top = 0.0
	_player_creature.offset_left = 48.0
	_player_creature.offset_top = 145.0
	_player_creature.offset_right = 48.0 + 380.0
	_player_creature.offset_bottom = 145.0 + 260.0
	_field_root.add_child(_player_creature)

	_actor_fx = BattleActorFXScript.new()
	add_child(_actor_fx)
	_actor_fx.setup(_field_root, _player_creature, _enemy_creature, _sprite_tint)

	_effects = BattleEffectsScript.new()
	_field_root.add_child(_effects)
	_effects.screen_shake_requested.connect(_shake_field)
	_effects.actor_effect_requested.connect(_on_actor_effect)
	_effects.camera_focus_requested.connect(_focus_camera)

	_build_message_box()
	_build_command_panel()
	_build_battle_clock()
	_build_switch_overlay()
	_build_item_overlay()
	_build_end_overlay()
	_build_entry_overlay()

	_event_player = BattleEventPlayerScript.new()
	add_child(_event_player)
	_event_player.setup(
		_player_plate,
		_enemy_plate,
		_player_creature,
		_enemy_creature,
		_effects,
		_actor_fx,
		_message_primary,
		func() -> bool: return visible
	)

func set_environment(season: String, indoor: bool) -> void:
	_season = season.to_lower()
	_indoor = indoor
	set_world_time(WorldTimeScript.now_hours())

func set_world_time(hours: float) -> void:
	_world_hours = hours
	_world_tint = WorldTimeScript.arena_tint(hours, _indoor)
	if _arena != null:
		_arena.setup(_season, _indoor, _world_tint, _world_hours)
	var sprite_tint := WorldTimeScript.sprite_tint(hours, _indoor)
	_sprite_tint = sprite_tint
	if _actor_fx != null:
		_actor_fx.set_tint(sprite_tint)
	if _battle_clock != null:
		_battle_clock.text = "%s %s" % [
			WorldTimeScript.phase_label(hours), WorldTimeScript.clock_text(hours)
		]
		_battle_clock.add_theme_color_override(
			"font_color", WorldTimeScript.phase_color(hours)
		)
	if _enemy_creature != null and not _turn_animating:
		_enemy_creature.modulate = sprite_tint
	if _player_creature != null and not _turn_animating:
		_player_creature.modulate = sprite_tint

func _huge_font_size() -> int:
	if UI.cjk_locale():
		return 30
	return 45 if _font_huge != UI.bw_font() else 15

func _big_font_size() -> int:
	if UI.cjk_locale():
		return 22
	return 30 if _font_big != UI.bw_font() else 15

func _font_for(tier: String) -> Font:
	if tier == "huge":
		return _font_huge
	if tier == "big":
		return _font_big
	return _font_small

func _size_for(tier: String) -> int:
	if tier == "huge":
		return _huge_font_size()
	if tier == "big":
		return _big_font_size()
	if UI.cjk_locale():
		return 14
	return 15

func _on_locale_changed(_code: String) -> void:
	_load_fonts()
	if _enemy_plate != null:
		_enemy_plate.refresh_fonts()
	if _player_plate != null:
		_player_plate.refresh_fonts()
	Loc.refresh_all(self)
	_apply_battle_fonts(self)
	_update_message()
	set_world_time(_world_hours)

func _apply_battle_fonts(root: Node) -> void:
	if root is Control and root.has_meta("battle_tier"):
		var control := root as Control
		var tier := str(control.get_meta("battle_tier"))
		control.add_theme_font_override("font", _font_for(tier))
		control.add_theme_font_size_override("font_size", _size_for(tier))
	for child in root.get_children():
		_apply_battle_fonts(child)

func _build_message_box() -> void:
	_message_panel = Panel.new()
	_message_panel.anchor_left = 0.0
	_message_panel.anchor_right = 1.0
	_message_panel.anchor_top = 0.0
	_message_panel.anchor_bottom = 0.0
	_message_panel.offset_left = 18.0
	_message_panel.offset_right = -18.0
	_message_panel.offset_top = 405.0
	_message_panel.offset_bottom = 463.0
	_message_panel.mouse_filter = MOUSE_FILTER_IGNORE
	_message_panel.add_theme_stylebox_override("panel", _battle_panel_style(7, 3))
	add_child(_message_panel)

	var inner := Panel.new()
	inner.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	inner.offset_left = 6.0
	inner.offset_top = 6.0
	inner.offset_right = -6.0
	inner.offset_bottom = -6.0
	inner.mouse_filter = MOUSE_FILTER_IGNORE
	var inner_style := StyleBoxFlat.new()
	inner_style.bg_color = Color(0, 0, 0, 0)
	inner_style.border_width_left = 1
	inner_style.border_width_top = 1
	inner_style.border_width_right = 1
	inner_style.border_width_bottom = 1
	inner_style.border_color = Color("344242")
	inner_style.corner_radius_top_left = 5
	inner_style.corner_radius_top_right = 5
	inner_style.corner_radius_bottom_left = 5
	inner_style.corner_radius_bottom_right = 5
	inner.add_theme_stylebox_override("panel", inner_style)
	_message_panel.add_child(inner)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 4)
	margin.mouse_filter = MOUSE_FILTER_IGNORE
	_message_panel.add_child(margin)

	_message_primary = _make_label("", TEXT, "huge")
	_message_primary.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_message_primary.clip_text = true
	_message_primary.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	margin.add_child(_message_primary)

func _build_command_panel() -> void:
	_command_panel = Panel.new()
	_command_panel.anchor_left = 0.0
	_command_panel.anchor_right = 1.0
	_command_panel.anchor_top = 1.0
	_command_panel.anchor_bottom = 1.0
	_command_panel.offset_left = 18.0
	_command_panel.offset_right = -18.0
	_command_panel.offset_top = -68.0
	_command_panel.offset_bottom = -6.0
	_command_panel.add_theme_stylebox_override("panel", _battle_panel_style(9, 3))
	add_child(_command_panel)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 6)
	margin.add_theme_constant_override("margin_right", 6)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 4)
	_command_panel.add_child(margin)

	_command_row = HBoxContainer.new()
	_command_row.add_theme_constant_override("separation", 8)
	_command_row.mouse_filter = MOUSE_FILTER_PASS
	margin.add_child(_command_row)

func _build_battle_clock() -> void:
	_battle_clock = UI.make_label("", 15, MUTED)
	_battle_clock.anchor_left = 1.0
	_battle_clock.anchor_right = 1.0
	_battle_clock.anchor_top = 0.0
	_battle_clock.anchor_bottom = 0.0
	_battle_clock.offset_left = -200.0
	_battle_clock.offset_right = -18.0
	_battle_clock.offset_top = 8.0
	_battle_clock.offset_bottom = 30.0
	_battle_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_battle_clock.add_theme_constant_override("outline_size", 3)
	_battle_clock.add_theme_color_override("font_outline_color", OUTLINE)
	_battle_clock.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_battle_clock)

func _build_switch_overlay() -> void:
	_switch_overlay = Control.new()
	_switch_overlay.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_switch_overlay.mouse_filter = MOUSE_FILTER_STOP
	_switch_overlay.visible = false
	add_child(_switch_overlay)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	dim.mouse_filter = MOUSE_FILTER_STOP
	_switch_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_switch_overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _battle_panel_style(12, 3, 18))
	panel.custom_minimum_size = Vector2(620.0, 0.0)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	_switch_title = _make_label("", TEXT, "huge")
	Loc.bind(_switch_title, "Choose a party member")
	_switch_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_switch_title)
	_switch_help = _make_label("", MUTED, "small")
	_switch_help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_switch_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_switch_help)
	_switch_list = VBoxContainer.new()
	_switch_list.add_theme_constant_override("separation", 5)
	box.add_child(_switch_list)
	_switch_cancel = _make_text_button("", MUTED, "small")
	Loc.bind(_switch_cancel, "CANCEL")
	_switch_cancel.custom_minimum_size = Vector2(0, 34)
	_switch_cancel.pressed.connect(_hide_switch_menu)
	box.add_child(_switch_cancel)

func _build_item_overlay() -> void:
	_item_overlay = Control.new()
	_item_overlay.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_item_overlay.mouse_filter = MOUSE_FILTER_STOP
	_item_overlay.visible = false
	add_child(_item_overlay)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	dim.mouse_filter = MOUSE_FILTER_STOP
	_item_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_item_overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _battle_panel_style(12, 3, 18))
	panel.custom_minimum_size = Vector2(600.0, 0.0)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	var title := _make_label("", TEXT, "big")
	Loc.bind(title, "Choose an item")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var help := _make_label("", MUTED, "small")
	Loc.bind(help, "Medicine is used on one party member and costs your turn.")
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(help)
	_item_list = VBoxContainer.new()
	_item_list.add_theme_constant_override("separation", 5)
	box.add_child(_item_list)
	_item_cancel = _make_text_button("", MUTED, "small")
	Loc.bind(_item_cancel, "CANCEL")
	_item_cancel.custom_minimum_size = Vector2(0, 34)
	_item_cancel.pressed.connect(_hide_item_menu)
	box.add_child(_item_cancel)

func set_items(items: Array) -> void:
	_items.clear()
	for value in items:
		if not (value is Dictionary):
			continue
		var definition: Dictionary = value
		var item_id := str(definition.get("id", ""))
		if item_id != "":
			_items[item_id] = definition

func _build_end_overlay() -> void:
	_end_overlay = Control.new()
	_end_overlay.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_end_overlay.mouse_filter = MOUSE_FILTER_STOP
	_end_overlay.visible = false
	add_child(_end_overlay)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	dim.mouse_filter = MOUSE_FILTER_STOP
	_end_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_end_overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _battle_panel_style(12, 3, 22))
	panel.custom_minimum_size = Vector2(560.0, 0.0)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	_result_label = _make_label("", TEXT, "huge")
	Loc.bind(_result_label, "Victory!")
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_result_label)
	_result_message = _make_label("", TEXT, "small")
	_result_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_result_message.custom_minimum_size = Vector2(0, 34)
	box.add_child(_result_message)
	_continue_button = _make_text_button("", TEXT, "huge")
	Loc.bind(_continue_button, "CONTINUE")
	_continue_button.custom_minimum_size = Vector2(0, 52)
	_continue_button.pressed.connect(_on_continue_pressed)
	box.add_child(_continue_button)

func _build_entry_overlay() -> void:
	_entry_overlay = Control.new()
	_entry_overlay.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_entry_overlay.mouse_filter = MOUSE_FILTER_STOP
	_entry_overlay.visible = false
	add_child(_entry_overlay)

	_entry_wipe = ColorRect.new()
	_entry_wipe.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_entry_wipe.mouse_filter = MOUSE_FILTER_IGNORE
	var wipe_material := ShaderMaterial.new()
	wipe_material.shader = BATTLE_WIPE_SHADER
	_entry_wipe.material = wipe_material
	_entry_overlay.add_child(_entry_wipe)

	_entry_flash = ColorRect.new()
	_entry_flash.color = Color(1.0, 0.98, 0.90, 1.0)
	_entry_flash.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_entry_flash.mouse_filter = MOUSE_FILTER_IGNORE
	_entry_overlay.add_child(_entry_flash)

	_entry_banner = _make_label("", TEXT, "huge")
	_entry_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_entry_banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_entry_banner.anchor_left = 0.0
	_entry_banner.anchor_right = 1.0
	_entry_banner.anchor_top = 0.0
	_entry_banner.anchor_bottom = 0.0
	_entry_banner.offset_top = 120.0
	_entry_banner.offset_bottom = 180.0
	_entry_banner.modulate = Color(1, 1, 1, 0)
	_entry_banner.mouse_filter = MOUSE_FILTER_IGNORE
	_entry_overlay.add_child(_entry_banner)

func _battle_panel_style(
	radius: int,
	border: int,
	content: int = 0,
	bg: Color = PANEL_BG
) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	style.border_width_left = border
	style.border_width_top = border
	style.border_width_right = border
	style.border_width_bottom = border
	style.border_color = PANEL_BORDER
	style.content_margin_left = content
	style.content_margin_top = content
	style.content_margin_right = content
	style.content_margin_bottom = content
	style.shadow_color = Color(0, 0, 0, 0.45)
	style.shadow_size = 6
	style.shadow_offset = Vector2(0, 3)
	return style

func _make_label(text: String, color: Color, tier: String) -> Label:
	var label := Label.new()
	label.text = text
	label.set_meta("battle_tier", tier)
	label.add_theme_font_override("font", _font_for(tier))
	label.add_theme_font_size_override("font_size", _size_for(tier))
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", OUTLINE)
	label.add_theme_constant_override(
		"outline_size", 5 if tier == "huge" else (4 if tier == "big" else 2)
	)
	label.mouse_filter = MOUSE_FILTER_IGNORE
	return label

func _style_battle_button(button: Button, color: Color, tier: String) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = BUTTON_BG
	normal.corner_radius_top_left = 9
	normal.corner_radius_top_right = 9
	normal.corner_radius_bottom_left = 9
	normal.corner_radius_bottom_right = 9
	normal.border_width_left = 2
	normal.border_width_top = 2
	normal.border_width_right = 2
	normal.border_width_bottom = 2
	normal.border_color = Color("e4eae8")
	normal.content_margin_left = 8
	normal.content_margin_right = 8
	normal.content_margin_top = 2
	normal.content_margin_bottom = 2
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = BUTTON_HOVER
	hover.border_color = Color("ffffff")
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = BUTTON_PRESSED
	pressed.border_color = Color("ffd9c8")
	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(0.16, 0.15, 0.15, 0.65)
	disabled.border_color = Color(0.55, 0.60, 0.59, 0.45)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("disabled", disabled)
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	button.add_theme_font_override("font", _font_for(tier))
	button.add_theme_font_size_override("font_size", _size_for(tier))
	button.add_theme_color_override("font_color", color)
	button.add_theme_color_override("font_hover_color", color.lightened(0.15))
	button.add_theme_color_override("font_pressed_color", color.lightened(0.25))
	button.add_theme_color_override("font_disabled_color", Color(color.r, color.g, color.b, 0.38))
	button.add_theme_color_override("font_outline_color", OUTLINE)
	button.add_theme_constant_override(
		"outline_size", 5 if tier == "huge" else (4 if tier == "big" else 2)
	)
	button.focus_mode = Control.FOCUS_NONE

func _make_text_button(text: String, color: Color, tier: String) -> Button:
	var button := Button.new()
	button.text = text
	button.set_meta("battle_tier", tier)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.custom_minimum_size.y = 52.0 if tier == "huge" else 40.0
	_style_battle_button(button, color, tier)
	return button

func _play_entry() -> void:
	if _entry_overlay == null:
		return
	_cancel_entry()
	_entry_active = true
	_entry_overlay.visible = true
	_entry_overlay.modulate = Color(1, 1, 1, 1)
	_entry_flash.modulate = Color(1, 1, 1, 1)
	_entry_banner.modulate = Color(1, 1, 1, 0)
	_set_wipe_progress(0.0)
	_command_panel.visible = true
	_awaiting = false
	_rebuild_menu()
	var wild: Dictionary = _battle.get("wild", {})
	Loc.bind(_entry_banner, "A wild %s appeared!", [str(wild.get("name", Loc.t("Pokémon")))])
	await get_tree().process_frame
	if not _entry_active:
		return
	var tween := create_tween()
	_entry_tween = tween
	tween.set_parallel(true)
	tween.tween_property(_entry_flash, "modulate:a", 0.0, 0.20)
	tween.tween_method(_set_wipe_progress, 0.0, 1.0, 0.62).set_delay(0.04)
	tween.tween_property(_entry_overlay, "modulate:a", 0.0, 0.26).set_delay(0.58)
	tween.tween_property(_entry_banner, "modulate:a", 1.0, 0.18).set_delay(0.42)
	tween.tween_property(_entry_banner, "modulate:a", 0.0, 0.24).set_delay(1.32)
	tween.finished.connect(_finish_entry)

func _finish_entry() -> void:
	if not _entry_active:
		return
	_entry_active = false
	_entry_tween = null
	_entry_overlay.visible = false
	_set_awaiting(_battle_awaiting())

func _cancel_entry() -> void:
	if _entry_tween != null:
		_entry_tween.kill()
		_entry_tween = null
	if not _entry_active:
		return
	_entry_active = false
	_entry_overlay.visible = false

func _set_wipe_progress(value: float) -> void:
	if _entry_wipe == null:
		return
	var material := _entry_wipe.material as ShaderMaterial
	if material != null:
		material.set_shader_parameter("progress", value)

func show_battle(battle: Dictionary) -> void:
	_cancel_entry()
	if _effects != null:
		_effects.stop()
	_reset_actor_visuals()
	_pending_result = {}
	_caught_pending = false
	_turn_animating = false
	_battle = battle
	visible = true
	_end_overlay.visible = false
	_switch_overlay.visible = false
	_item_overlay.visible = false
	_target_item = ""
	_command_panel.visible = true
	_menu_mode = "commands"
	_displayed_active = int(battle.get("activeIndex", 0))
	_enemy_plate.reset()
	_player_plate.reset()
	_arena.setup(_season, _indoor, _world_tint, _world_hours)
	_update_from_battle()
	set_world_time(WorldTimeScript.now_hours())
	_play_entry()

func update_battle(battle: Dictionary) -> void:
	var events: Array = battle.get("events", [])
	_battle = battle
	# `battle_end` repeats the final `battle_turn` snapshot. Keep the newest
	# data, but never start a second playback while the first is running.
	if _turn_animating:
		return
	if not visible:
		_update_from_battle()
		return
	if events.is_empty():
		_update_from_battle()
		return
	_turn_animating = true
	_cancel_entry()
	_set_awaiting(false)
	_reset_actor_visuals()
	_event_player.battle = battle
	await _event_player.play(events)
	if not visible:
		_turn_animating = false
		return
	_turn_animating = false
	if _caught_pending:
		_complete_caught()
		return
	_update_from_battle()
	_present_pending_result()

func finish_caught() -> void:
	_caught_pending = true
	if not _turn_animating:
		_complete_caught()

func _complete_caught() -> void:
	if not _caught_pending:
		return
	_caught_pending = false
	if _enemy_creature != null:
		_enemy_creature.visible = false
	_on_continue_pressed()

func show_result(result: String, message: String) -> void:
	_pending_result = {"result": result, "message": message}
	if _turn_animating:
		return
	_present_pending_result()

func _present_pending_result() -> void:
	if _pending_result.is_empty():
		return
	var result := str(_pending_result.get("result", ""))
	var message := str(_pending_result.get("message", ""))
	_pending_result = {}
	_cancel_entry()
	_end_overlay.visible = true
	_switch_overlay.visible = false
	_item_overlay.visible = false
	_target_item = ""
	_command_panel.visible = false
	_set_awaiting(false)
	match result:
		"won":
			Loc.bind(_result_label, "Victory!")
			_result_label.add_theme_color_override("font_color", Color("ffd75e"))
		"lost":
			Loc.bind(_result_label, "Blacked out...")
			_result_label.add_theme_color_override("font_color", Color("ff7a86"))
		"caught":
			Loc.bind(_result_label, "Gotcha!")
			_result_label.add_theme_color_override("font_color", Color("8dff7a"))
		_:
			Loc.bind(_result_label, "Escaped!")
			_result_label.add_theme_color_override("font_color", Color("8fd8ff"))
	_result_message.text = message
	_continue_button.grab_focus()

func _active_player() -> Dictionary:
	var value: Variant = _battle.get("player", {})
	return value if value is Dictionary else {}

func _reset_actor_visuals() -> void:
	if _actor_fx != null:
		_actor_fx.reset()

func _on_actor_effect(side: String, kind: String, values: Array) -> void:
	if _actor_fx != null:
		_actor_fx.handle(side, kind, values)

func _shake_field(strength: float, duration: float) -> void:
	if _actor_fx != null:
		_actor_fx.shake_screen(strength, duration)

func _focus_camera(side: String, duration: float) -> void:
	if _actor_fx != null:
		_actor_fx.focus_camera(side, duration)

func _battle_awaiting() -> bool:
	if _battle.is_empty():
		return false
	var status := str(_battle.get("status", "active"))
	return bool(_battle.get("awaitingAction", false)) and status == "active"

# Restores the command menu when the server rejected an action without using the turn.
func reset_after_error() -> void:
	if not visible or _battle.is_empty():
		return
	if not _battle_awaiting():
		return
	_menu_mode = "commands"
	_target_item = ""
	_set_awaiting(true)

func _update_from_battle() -> void:
	if _battle.is_empty():
		return
	if not _turn_animating:
		_reset_actor_visuals()
	var wild: Dictionary = _battle["wild"]
	var player := _active_player()
	var active_index := int(_battle.get("activeIndex", 0))
	var index_changed := active_index != _displayed_active
	if index_changed:
		_displayed_active = active_index
	var wild_type := _primary_type(wild)
	var player_type := _primary_type(player)
	_enemy_creature.setup(str(wild.get("species", "")), str(wild["name"]), wild_type, true)
	_player_creature.setup(str(player.get("species", "")), str(player["name"]), player_type, false)
	_enemy_plate.set_creature(wild)
	_player_plate.set_creature(player)
	if index_changed:
		_menu_mode = "commands"
		_player_plate.reset()
	_update_message()

	var awaiting := _battle_awaiting()
	if _entry_active:
		awaiting = false
	_set_awaiting(awaiting)
	if bool(_battle.get("mustSwitch", false)) and not _switch_overlay.visible:
		_open_switch_menu(true)

func _update_message() -> void:
	if _message_primary == null:
		return
	var log_lines: Array = _battle.get("log", [])
	var last := ""
	if log_lines.size() > 0:
		last = str(log_lines[-1])
	var player := _active_player()
	var name := str(player.get("name", "your Pokémon"))
	var prompt := Loc.tf("What will %s do?", [name])
	if _menu_mode == "moves":
		prompt = Loc.t("Choose a move.")
	elif _menu_mode == "bag":
		prompt = Loc.t("Choose an item.")
	_message_primary.text = prompt if _awaiting and not _entry_active else last

func _primary_type(creature: Dictionary) -> String:
	var types: Array = creature.get("types", [])
	if types.is_empty():
		return str(creature.get("type", "Normal"))
	return str(types[0])

func _set_awaiting(awaiting: bool) -> void:
	var was_awaiting := _awaiting
	_awaiting = awaiting
	if awaiting and (not was_awaiting or _menu_mode == "waiting"):
		_menu_mode = "commands"
	_rebuild_menu()
	_update_message()

func _clear_row() -> void:
	for child in _command_row.get_children():
		_command_row.remove_child(child)
		child.queue_free()

func _rebuild_menu() -> void:
	if _command_row == null:
		return
	_clear_row()
	if _battle.is_empty():
		return
	if _menu_mode == "moves":
		_populate_moves()
	elif _menu_mode == "bag":
		_populate_bag()
	else:
		_populate_commands()
	_apply_enabled()

func _apply_enabled() -> void:
	var must_switch := bool(_battle.get("mustSwitch", false))
	var can_act := _awaiting and not must_switch and _menu_mode != "waiting"
	for child in _command_row.get_children():
		if not (child is Button):
			continue
		var button := child as Button
		if button.has_meta("back"):
			button.disabled = not _awaiting
			continue
		if button.has_meta("command"):
			var command := str(button.get_meta("command"))
			match command:
				"fight", "bag", "run":
					button.disabled = not can_act
				"pokemon":
					button.disabled = not can_act or _living_reserves() == 0
				_:
					button.disabled = not can_act
			continue
		if button.has_meta("move"):
			button.disabled = not can_act or bool(button.get_meta("no_pp", false))
			continue
		if button.has_meta("ball"):
			var party: Array = _battle.get("party", [])
			var max_party := int(_battle.get("maxParty", 6))
			var ball_count := _bag_count(str(button.get_meta("ball")))
			button.disabled = not can_act or ball_count <= 0 or party.size() >= max_party
			continue
		if button.has_meta("medicine_menu"):
			button.disabled = not can_act

func _populate_commands() -> void:
	var fight := _make_text_button("", FIGHT_COLOR, "huge")
	Loc.bind(fight, "FIGHT")
	fight.set_meta("command", "fight")
	fight.pressed.connect(_on_fight_pressed)
	_command_row.add_child(fight)

	var bag := _make_text_button("", BAG_COLOR, "huge")
	Loc.bind(bag, "BAG")
	bag.set_meta("command", "bag")
	bag.pressed.connect(_on_bag_pressed)
	_command_row.add_child(bag)

	var mons := _make_text_button("", MON_COLOR, "huge")
	Loc.bind(mons, "POKéMON")
	mons.set_meta("command", "pokemon")
	mons.pressed.connect(_on_switch_pressed)
	_command_row.add_child(mons)

	var run := _make_text_button("", RUN_COLOR, "huge")
	Loc.bind(run, "RUN")
	run.set_meta("command", "run")
	run.pressed.connect(_on_run_pressed)
	_command_row.add_child(run)

func _populate_moves() -> void:
	var moves: Array = _active_player().get("moves", [])
	var count := mini(4, moves.size())
	for i in range(count):
		var move: Dictionary = moves[i]
		var max_pp := int(move.get("maxPp", move.get("pp", 0)))
		var current_pp := int(move.get("currentPp", max_pp if max_pp > 0 else 1))
		var label := str(move.get("name", "?"))
		if max_pp > 0:
			label += "  %d/%d" % [current_pp, max_pp]
		var button := _make_text_button(
			label,
			UI.type_color(str(move.get("type", "Normal"))),
			"big"
		)
		button.add_theme_font_size_override("font_size", 22)
		button.set_meta("move", i)
		button.set_meta("no_pp", current_pp <= 0)
		button.tooltip_text = (
			Loc.t("No PP left") if current_pp <= 0 else Loc.tf("PP %d/%d", [current_pp, max_pp])
		)
		button.custom_minimum_size.y = 38.0
		button.pressed.connect(_on_move_pressed.bind(i))
		_command_row.add_child(button)
	if count == 0:
		var empty := _make_text_button("", MUTED, "small")
		Loc.bind(empty, "NO MOVES")
		empty.disabled = true
		_command_row.add_child(empty)
	_add_back_button()

func _populate_bag() -> void:
	var party: Array = _battle.get("party", [])
	var max_party := int(_battle.get("maxParty", 6))
	var party_full := party.size() >= max_party
	var ball_buttons := 0
	for item in _catalog_items("ball"):
		var item_id := str(item.get("id", ""))
		var count := _bag_count(item_id)
		if count <= 0:
			continue
		var button := _make_text_button(
			"%s ×%d" % [str(item.get("name", item_id)), count],
			FIGHT_COLOR,
			"small"
		)
		button.set_meta("ball", item_id)
		button.custom_minimum_size.y = 38.0
		button.disabled = party_full
		button.pressed.connect(_on_ball_pressed.bind(item_id))
		_command_row.add_child(button)
		ball_buttons += 1

	var medicine_total := 0
	for item in _catalog_items("medicine"):
		medicine_total += _bag_count(str(item.get("id", "")))
	if medicine_total > 0:
		var items_button := _make_text_button(
			Loc.tf("ITEMS ×%d", [medicine_total]), BAG_COLOR, "small"
		)
		items_button.set_meta("medicine_menu", true)
		items_button.custom_minimum_size.y = 38.0
		items_button.pressed.connect(_open_item_menu)
		_command_row.add_child(items_button)

	if ball_buttons == 0 and medicine_total == 0:
		var empty := _make_text_button("", MUTED, "small")
		Loc.bind(empty, "BAG EMPTY")
		empty.disabled = true
		_command_row.add_child(empty)
	_add_back_button()

func _bag_counts() -> Dictionary:
	var inventory_value: Variant = _battle.get("inventory", {})
	if inventory_value is Dictionary:
		var items_value: Variant = (inventory_value as Dictionary).get("items", {})
		if items_value is Dictionary:
			return items_value
	return {}

func _bag_count(item_id: String) -> int:
	return maxi(0, int(_bag_counts().get(item_id, 0)))

func _catalog_items(category: String) -> Array:
	var result: Array = []
	for item_value in _items.values():
		if not (item_value is Dictionary):
			continue
		var item: Dictionary = item_value
		if str(item.get("category", "")) != category:
			continue
		result.append(item)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var price_a := int(a.get("price", 0))
		var price_b := int(b.get("price", 0))
		if price_a == price_b:
			return str(a.get("name", "")) < str(b.get("name", ""))
		return price_a < price_b
	)
	return result

func _open_item_menu() -> void:
	if not _awaiting:
		return
	for child in _item_list.get_children():
		_item_list.remove_child(child)
		child.queue_free()
	var shown := 0
	for item in _catalog_items("medicine"):
		var item_id := str(item.get("id", ""))
		var count := _bag_count(item_id)
		if count <= 0:
			continue
		var button := _make_text_button(
			"%s  ×%d" % [str(item.get("name", item_id)), count],
			BAG_COLOR,
			"small"
		)
		button.custom_minimum_size = Vector2(0, 34)
		button.pressed.connect(_open_item_targets.bind(item))
		_item_list.add_child(button)
		shown += 1
	if shown == 0:
		var empty := _make_text_button("", MUTED, "small")
		Loc.bind(empty, "NO MEDICINE")
		empty.disabled = true
		_item_list.add_child(empty)
	_item_overlay.visible = true

func _hide_item_menu() -> void:
	_item_overlay.visible = false

func _open_item_targets(item: Dictionary) -> void:
	if not _awaiting:
		return
	_item_overlay.visible = false
	_target_item = str(item.get("id", ""))
	for child in _switch_list.get_children():
		_switch_list.remove_child(child)
		child.queue_free()
	var party: Array = _battle.get("party", [])
	for i in range(party.size()):
		var creature: Dictionary = party[i]
		var hp := int(creature.get("hp", 0))
		var max_hp := maxi(1, int(creature.get("maxHp", 1)))
		var suffix := ""
		var status := str(creature.get("status", "")).strip_edges()
		if hp <= 0:
			suffix = "  " + Loc.t("(fainted)")
		elif status != "":
			suffix = "  %s" % status
		var button := _make_text_button(
			"%s  Lv.%d   %d/%d%s" % [
				str(creature.get("name", "?")),
				int(creature.get("level", 1)),
				hp,
				max_hp,
				suffix
			],
			TEXT,
			"small"
		)
		button.custom_minimum_size = Vector2(0, 32)
		button.disabled = not _can_use_medicine(item, creature)
		button.pressed.connect(_on_party_selected.bind(i))
		_switch_list.add_child(button)
	Loc.bind(_switch_title, "Use %s on whom?", [str(item.get("name", Loc.t("the item")))])
	Loc.bind(_switch_help, "Using a medicine costs your turn.")
	_switch_cancel.visible = true
	_switch_overlay.visible = true

func _can_use_medicine(item: Dictionary, creature: Dictionary) -> bool:
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

func _add_back_button() -> void:
	var back := _make_text_button("", MUTED, "big")
	Loc.bind(back, "BACK")
	back.set_meta("back", true)
	back.custom_minimum_size.x = 120.0
	back.size_flags_horizontal = Control.SIZE_SHRINK_END
	back.pressed.connect(_on_back_pressed)
	_command_row.add_child(back)

func _on_fight_pressed() -> void:
	_menu_mode = "moves"
	_rebuild_menu()
	_update_message()

func _on_bag_pressed() -> void:
	_menu_mode = "bag"
	_rebuild_menu()
	_update_message()

func _on_back_pressed() -> void:
	_menu_mode = "commands"
	_rebuild_menu()
	_update_message()

func _on_move_pressed(index: int) -> void:
	if not _awaiting:
		return
	_menu_mode = "waiting"
	_rebuild_menu()
	action_selected.emit("move", index, "")

func _on_ball_pressed(item_id: String) -> void:
	if not _awaiting:
		return
	_menu_mode = "waiting"
	_rebuild_menu()
	action_selected.emit("catch", -1, item_id)

func _on_run_pressed() -> void:
	if not _awaiting:
		return
	_menu_mode = "waiting"
	_rebuild_menu()
	action_selected.emit("run", -1, "")

func _on_switch_pressed() -> void:
	if not _awaiting:
		return
	_open_switch_menu(false)

func _living_reserves() -> int:
	var party: Array = _battle.get("party", [])
	var active_index := int(_battle.get("activeIndex", 0))
	var count := 0
	for i in range(party.size()):
		if i == active_index:
			continue
		var creature: Dictionary = party[i]
		if int(creature.get("hp", 0)) > 0:
			count += 1
	return count

func _open_switch_menu(forced: bool) -> void:
	if _battle.is_empty():
		return
	_target_item = ""
	_item_overlay.visible = false
	for child in _switch_list.get_children():
		_switch_list.remove_child(child)
		child.queue_free()

	var party: Array = _battle.get("party", [])
	var active_index := int(_battle.get("activeIndex", 0))
	Loc.bind(_switch_title, "Your partner fainted" if forced else "Choose a party member")
	Loc.bind(_switch_help, (
		"Send out a healthy party member to continue."
		if forced
		else "Switching uses your turn. The wild Pokémon will attack."
	))
	for i in range(party.size()):
		var creature: Dictionary = party[i]
		var hp := int(creature.get("hp", 0))
		var max_hp := maxi(1, int(creature.get("maxHp", 1)))
		var active := i == active_index
		var suffix := "  " + Loc.t("(active)") if active else ""
		var button := _make_text_button(
			"%s  Lv.%d   %d/%d%s" % [
				str(creature.get("name", "?")),
				int(creature.get("level", 1)),
				hp,
				max_hp,
				suffix
			],
			TEXT,
			"small"
		)
		button.custom_minimum_size = Vector2(0, 32)
		button.disabled = active or hp <= 0
		button.pressed.connect(_on_party_selected.bind(i))
		_switch_list.add_child(button)
	_switch_cancel.visible = not forced
	_switch_overlay.visible = true

func _hide_switch_menu() -> void:
	_switch_overlay.visible = false
	_target_item = ""
	_menu_mode = "commands"
	_rebuild_menu()
	_update_message()

func _on_party_selected(index: int) -> void:
	if not _awaiting:
		return
	_switch_overlay.visible = false
	if _target_item != "":
		var item_id := _target_item
		_target_item = ""
		_menu_mode = "waiting"
		_rebuild_menu()
		item_used.emit(item_id, index)
		return
	_menu_mode = "waiting"
	_rebuild_menu()
	action_selected.emit("switch", index, "")

func _on_continue_pressed() -> void:
	if _effects != null:
		_effects.stop()
	_turn_animating = false
	_pending_result = {}
	visible = false
	_end_overlay.visible = false
	_switch_overlay.visible = false
	_item_overlay.visible = false
	_target_item = ""
	closed.emit()
