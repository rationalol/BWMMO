extends Control

signal message_submitted(text: String)
signal social_message_submitted(text: String, target_id: String)
signal tab_changed(tab: String)

const UI = preload("res://scripts/ui_theme.gd")
const ICON_ROOT := "res://assets/ui/icons"
const MAX_JOURNAL_ENTRIES := 200

var _panel: PanelContainer
var _log_area: Control
var _world_log: RichTextLabel
var _system_log: RichTextLabel
var _social_log: RichTextLabel
var _world_tab: Button
var _system_tab: Button
var _social_tab: Button
var _social_bar: HBoxContainer
var _social_picker: OptionButton
var _collapse_button: Button
var _input: LineEdit
var _send_button: Button
var _active_tab := "world"
var _collapsed := false
var _touch_layout := false
var _timestamps := false
var _world_unread := false
var _system_unread := false
var _social_unread := false
var _journal_entries: Array = []
var _social_peers: Dictionary = {}
var _social_order: Array = []
var _social_target := ""
var _social_peer_unread: Dictionary = {}
var _icon_cache: Dictionary = {}

func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	Loc.locale_changed.connect(_on_locale_changed)

	_panel = PanelContainer.new()
	_panel.name = "ChatPanel"
	_panel.anchor_left = 0.0
	_panel.anchor_right = 0.0
	_panel.anchor_top = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = 10
	_panel.offset_right = 322
	_panel.offset_top = -204
	_panel.offset_bottom = -10
	_panel.add_theme_stylebox_override(
		"panel", UI.glass_style(UI.INK, 11, UI.BORDER, 1, 0)
	)
	_panel.mouse_filter = MOUSE_FILTER_STOP
	add_child(_panel)
	UI.scale_hud(_panel, Vector2(0.0, 1.0))
	UI.add_bw_frame_overlay(_panel)
	var panel_margin := UI.add_panel_content(_panel, 8, 6)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	panel_margin.add_child(box)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	box.add_child(header)

	_world_tab = _make_tab("World")
	_world_tab.pressed.connect(_set_tab.bind("world"))
	header.add_child(_world_tab)

	_system_tab = _make_tab("System")
	_system_tab.pressed.connect(_set_tab.bind("system"))
	header.add_child(_system_tab)

	_social_tab = _make_tab("Social")
	_social_tab.pressed.connect(_set_tab.bind("social"))
	header.add_child(_social_tab)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = MOUSE_FILTER_IGNORE
	header.add_child(spacer)

	_collapse_button = _make_icon_button("chevron_down.svg", Vector2(20, 20), 14)
	Loc.bind_tooltip(_collapse_button, "Collapse chat")
	_collapse_button.pressed.connect(_toggle_collapsed)
	header.add_child(_collapse_button)

	_social_bar = HBoxContainer.new()
	_social_bar.add_theme_constant_override("separation", 5)
	_social_bar.visible = false
	box.add_child(_social_bar)
	var to_label := Loc.make_label("TO", 8, UI.MUTED)
	_social_bar.add_child(to_label)
	_social_picker = OptionButton.new()
	_social_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_social_picker.custom_minimum_size = Vector2(0, 22)
	_social_picker.focus_mode = Control.FOCUS_NONE
	_social_picker.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var picker_normal := UI.button_style(Color(1.0, 1.0, 1.0, 0.055), 6)
	var picker_hover := UI.button_style(Color(1.0, 1.0, 1.0, 0.11), 6)
	var picker_pressed := UI.button_style(Color(1.0, 1.0, 1.0, 0.16), 6)
	for picker_style in [picker_normal, picker_hover, picker_pressed]:
		picker_style.content_margin_left = 6
		picker_style.content_margin_right = 6
		picker_style.content_margin_top = 1
		picker_style.content_margin_bottom = 1
	_social_picker.add_theme_stylebox_override("normal", picker_normal)
	_social_picker.add_theme_stylebox_override("hover", picker_hover)
	_social_picker.add_theme_stylebox_override("pressed", picker_pressed)
	_social_picker.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_social_picker.add_theme_color_override("font_color", UI.TEXT)
	_social_picker.add_theme_color_override("font_hover_color", UI.ACCENT)
	UI.apply_font(_social_picker, 9)
	_style_social_popup()
	Loc.bind_tooltip(_social_picker, "Choose a trainer to message")
	_social_picker.item_selected.connect(_on_social_picker_selected)
	_social_bar.add_child(_social_picker)

	_log_area = Control.new()
	_log_area.custom_minimum_size = Vector2(0, 84)
	_log_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log_area.clip_contents = true
	_log_area.mouse_filter = MOUSE_FILTER_IGNORE
	box.add_child(_log_area)

	_world_log = _make_log()
	_system_log = _make_log()
	_social_log = _make_log()
	_system_log.visible = false
	_social_log.visible = false
	_log_area.add_child(_world_log)
	_log_area.add_child(_system_log)
	_log_area.add_child(_social_log)

	var input_row := HBoxContainer.new()
	input_row.add_theme_constant_override("separation", 4)
	box.add_child(input_row)

	_input = LineEdit.new()
	_input.max_length = 200
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UI.style_line_edit(_input, true)
	Loc.bind(_input, "Press Enter to chat...")
	_input.custom_minimum_size = Vector2(0, 30)
	_input.text_submitted.connect(_on_text_submitted)
	_input.gui_input.connect(_on_input_gui)
	_input.focus_entered.connect(_on_focus_changed.bind(true))
	_input.focus_exited.connect(_on_focus_changed.bind(false))
	input_row.add_child(_input)

	_send_button = _make_icon_button("send.svg", Vector2(30, 30), 14)
	Loc.bind_tooltip(_send_button, "Send (Enter)")
	_send_button.pressed.connect(_on_send_pressed)
	input_row.add_child(_send_button)

	_refresh_tabs()
	_set_tab("world")
	_world_log.append_text(
		"[color=#7f94ad][i]%s[/i][/color]\n" % Loc.t("Welcome to Unova. Press Enter to chat.")
	)

func _icon(file: String) -> Texture2D:
	var path := "%s/%s" % [ICON_ROOT, file]
	if _icon_cache.has(path):
		return _icon_cache[path]
	var texture: Texture2D = null
	if ResourceLoader.exists(path):
		texture = load(path) as Texture2D
	_icon_cache[path] = texture
	return texture

func _make_tab(text: String) -> Button:
	var button := Button.new()
	button.text = Loc.t(text)
	button.set_meta("loc_tab_key", text)
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0, 20)
	UI.apply_font(button, 11)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	return button

func _make_icon_button(icon_file: String, button_size: Vector2, icon_size: int) -> Button:
	var button := Button.new()
	button.icon = _icon(icon_file)
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = button_size
	button.add_theme_constant_override("icon_max_width", icon_size)
	var normal := UI.button_style(Color(1.0, 1.0, 1.0, 0.045), 8)
	normal.content_margin_left = 2
	normal.content_margin_right = 2
	normal.content_margin_top = 2
	normal.content_margin_bottom = 2
	var hover := UI.button_style(Color(1.0, 1.0, 1.0, 0.10), 8)
	hover.content_margin_left = 2
	hover.content_margin_right = 2
	hover.content_margin_top = 2
	hover.content_margin_bottom = 2
	var pressed := UI.button_style(Color(1.0, 1.0, 1.0, 0.16), 8)
	pressed.content_margin_left = 2
	pressed.content_margin_right = 2
	pressed.content_margin_top = 2
	pressed.content_margin_bottom = 2
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	button.modulate = Color(1.0, 1.0, 1.0, 0.78)
	return button

func _make_log() -> RichTextLabel:
	var log := RichTextLabel.new()
	log.bbcode_enabled = true
	log.scroll_following = true
	log.scroll_active = true
	log.fit_content = false
	log.custom_minimum_size = Vector2(0, 80)
	log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	log.add_theme_font_size_override("normal_font_size", UI.font_size(10))
	log.add_theme_font_size_override("bold_font_size", UI.font_size(10))
	log.add_theme_font_size_override("italics_font_size", UI.font_size(10))
	log.add_theme_font_override("normal_font", ThemeDB.fallback_font)
	log.add_theme_font_override("bold_font", ThemeDB.fallback_font)
	log.add_theme_font_override("italics_font", ThemeDB.fallback_font)
	log.add_theme_constant_override("line_separation", 2)
	log.add_theme_color_override("default_color", UI.TEXT)
	log.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	log.mouse_filter = MOUSE_FILTER_PASS
	return log

func _tab_style(active: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = UI.ACCENT_SOFT if active else Color(0.0, 0.0, 0.0, 0.0)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	style.content_margin_left = 9
	style.content_margin_right = 9
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	return style

func _refresh_tabs() -> void:
	_style_tab(_world_tab, _active_tab == "world", _world_unread)
	_style_tab(_system_tab, _active_tab == "system", _system_unread)
	_style_tab(_social_tab, _active_tab == "social", _social_unread)

func _style_tab(button: Button, active: bool, unread: bool) -> void:
	var key := str(button.get_meta("loc_tab_key", button.text))
	button.text = Loc.t(key) + (" *" if unread else "")
	button.add_theme_stylebox_override("normal", _tab_style(active))
	var hover := _tab_style(active)
	if not active:
		hover.bg_color = Color(1.0, 1.0, 1.0, 0.05)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", _tab_style(true))
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var color := UI.ACCENT if active else UI.MUTED
	if unread and not active:
		color = UI.GOLD
	button.add_theme_color_override("font_color", color)
	button.add_theme_color_override("font_hover_color", UI.ACCENT if not active else color)
	button.add_theme_color_override("font_pressed_color", color)

func _set_tab(tab: String) -> void:
	var changed := tab != _active_tab
	_active_tab = tab
	if changed and _input != null:
		_input.text = ""
	if tab == "system":
		_system_unread = false
	elif tab == "social":
		_social_unread = false
		if _social_target != "":
			_social_peer_unread.erase(_social_target)
	else:
		_world_unread = false
	_world_log.visible = tab == "world"
	_system_log.visible = tab == "system"
	_social_log.visible = tab == "social"
	_social_bar.visible = tab == "social" and not _collapsed
	if tab == "social":
		_refresh_social_picker()
		_sync_social_log()
	elif tab == "system":
		_rebuild_journal()
	_refresh_tabs()
	_update_placeholder()
	tab_changed.emit(tab)

func active_tab() -> String:
	return _active_tab

func _now_stamp() -> String:
	var now := Time.get_time_dict_from_system()
	return "%02d:%02d" % [int(now.get("hour", 0)), int(now.get("minute", 0))]

func _stamp_prefix(stamp: String) -> String:
	if not _timestamps or stamp == "":
		return ""
	return "[color=#6f839b]%s[/color] " % stamp

func add_message(speaker: String, text: String, color: Color = UI.GOLD) -> void:
	var hex := "#" + color.to_html(false)
	_world_log.append_text(
		"%s[color=%s]%s[/color]: %s\n" % [
			_stamp_prefix(_now_stamp()), hex, _escape(speaker), _escape(text)
		]
	)
	if _active_tab != "world":
		_world_unread = true
	_refresh_tabs()
	_mark_activity()

# --- Adventure journal (System tab) ---------------------------------------

func add_journal(entry: Dictionary) -> void:
	var item := {"entry": entry.duplicate(true), "stamp": _now_stamp()}
	_journal_entries.append(item)
	if _journal_entries.size() > MAX_JOURNAL_ENTRIES:
		_journal_entries.pop_front()
	if _active_tab == "system":
		_system_log.append_text(_journal_line(item))
	else:
		_system_unread = true
	_refresh_tabs()
	_mark_activity()

func _journal_line(item: Dictionary) -> String:
	var entry: Dictionary = item.get("entry", {})
	var kind := str(entry.get("kind", ""))
	var color := _journal_color(kind)
	return "%s[color=%s]%s[/color]\n" % [
		_stamp_prefix(str(item.get("stamp", ""))),
		color,
		_escape(_journal_text(entry))
	]

func _journal_text(entry: Dictionary) -> String:
	var kind := str(entry.get("kind", ""))
	var actor := str(entry.get("actor", ""))
	var target := str(entry.get("target", ""))
	var move := str(entry.get("move", ""))
	var item := str(entry.get("item", ""))
	var level := int(entry.get("level", 0))
	var count := int(entry.get("count", 0))
	var money := int(entry.get("money", 0))
	var text := str(entry.get("text", ""))
	match kind:
		"encounter":
			text = Loc.tf("%s ran into a wild %s!", [actor, target])
		"move":
			text = Loc.tf("%s used %s!", [actor, move])
		"faint":
			text = Loc.tf("%s fainted!", [actor])
		"switch":
			text = Loc.tf("Go, %s!", [target])
		"ball":
			text = Loc.tf("%s threw a %s!", [actor, item])
		"broke_free":
			text = Loc.tf("Wild %s broke free!", [target])
		"catch":
			text = Loc.tf("%s caught %s!", [actor, target])
		"defeat":
			if money > 0:
				text = Loc.tf("%s defeated wild %s! (+%d coins)", [actor, target, money])
			else:
				text = Loc.tf("%s defeated wild %s!", [actor, target])
		"blackout":
			text = Loc.tf("%s blacked out...", [actor])
		"flee":
			text = Loc.tf("%s got away safely.", [actor])
		"escape_failed":
			text = Loc.tf("%s couldn't escape!", [actor])
		"level_up":
			text = Loc.tf("%s reached Lv.%d!", [actor, level])
		"evolution":
			text = Loc.tf("%s evolved into %s!", [actor, target])
		"learn_move":
			text = Loc.tf("%s learned %s!", [actor, move])
		"forget_move":
			text = Loc.tf("%s forgot %s.", [actor, move])
		"heal":
			text = Loc.t("Your team was fully healed.")
		"item_used":
			text = Loc.tf("%s used %s.", [actor, item])
		"shop_buy":
			text = Loc.tf("Bought %dx %s for %d coins.", [count, item, money])
		"shop_sell":
			text = Loc.tf("Sold %dx %s for %d coins.", [count, item, money])
		"pc_deposit":
			text = Loc.tf("%s was stored in the PC.", [target])
		"pc_withdraw":
			text = Loc.tf("%s was withdrawn from the PC.", [target])
		"pc_swap":
			text = Loc.tf("%s and %s were swapped.", [actor, target])
	return text

func _journal_color(kind: String) -> String:
	match kind:
		"catch", "level_up", "evolution", "learn_move":
			return "#ffd166"
		"heal", "shop_buy", "shop_sell", "item_used":
			return "#8fd3a8"
		"blackout", "escape_failed", "broke_free", "faint":
			return "#e07a6a"
		"defeat", "flee":
			return "#9ec9a6"
	return "#8aa0b2"

func _rebuild_journal() -> void:
	_system_log.clear()
	for item in _journal_entries:
		_system_log.append_text(_journal_line(item))

# --- Social (Social tab) ---------------------------------------------------

func add_social_message(
	peer_id: String,
	peer_name: String,
	text: String,
	outgoing: bool
) -> void:
	if peer_id == "":
		return
	var peer := _ensure_peer(peer_id, peer_name)
	_touch_peer(peer_id)
	var message := {"text": text, "outgoing": outgoing, "stamp": _now_stamp()}
	(peer["messages"] as Array).append(message)
	if _active_tab == "social" and _social_target == peer_id:
		_social_log.append_text(_social_line(message, peer_name))
	else:
		_social_peer_unread[peer_id] = int(_social_peer_unread.get(peer_id, 0)) + 1
		_social_unread = true
		if _social_target == "":
			_social_target = peer_id
	_refresh_social_picker()
	_refresh_tabs()
	_mark_activity()

func open_social_conversation(peer_id: String, peer_name: String) -> void:
	if peer_id == "":
		return
	_ensure_peer(peer_id, peer_name)
	_social_target = peer_id
	_social_peer_unread.erase(peer_id)
	if _collapsed:
		_set_collapsed(false)
	_set_tab("social")
	_sync_social_log()
	open_input()

func _ensure_peer(peer_id: String, peer_name: String) -> Dictionary:
	if not _social_peers.has(peer_id):
		_social_peers[peer_id] = {"name": peer_name, "messages": []}
		_social_order.push_front(peer_id)
	else:
		_social_peers[peer_id]["name"] = peer_name
	return _social_peers[peer_id]

func _touch_peer(peer_id: String) -> void:
	_social_order.erase(peer_id)
	_social_order.push_front(peer_id)

func _peer_name(peer_id: String) -> String:
	if not _social_peers.has(peer_id):
		return ""
	return str(_social_peers[peer_id].get("name", ""))

func _style_social_popup() -> void:
	var popup := _social_picker.get_popup()
	popup.add_theme_font_override("font", UI.bw_font())
	popup.add_theme_font_size_override("font_size", UI.font_size(10))
	popup.add_theme_stylebox_override(
		"panel", UI.glass_style(UI.INK, 8, UI.BORDER, 1, 4)
	)
	popup.add_theme_stylebox_override("hover", UI.button_style(UI.ACCENT_SOFT, 5))
	popup.add_theme_color_override("font_color", UI.TEXT)
	popup.add_theme_color_override("font_hover_color", UI.ACCENT)

func _refresh_social_picker() -> void:
	if _social_picker == null:
		return
	_social_picker.clear()
	_social_picker.add_item(Loc.t("Select a chat"))
	_social_picker.set_item_metadata(0, "")
	var selected := 0
	for index in range(_social_order.size()):
		var peer_id := str(_social_order[index])
		var label := _peer_name(peer_id)
		var unread := int(_social_peer_unread.get(peer_id, 0))
		if unread > 0:
			label += " (%d)" % unread
		_social_picker.add_item(label)
		_social_picker.set_item_metadata(index + 1, peer_id)
		if peer_id == _social_target:
			selected = index + 1
	_social_picker.select(selected)

# Drop the previous account's chat history and DM sessions on logout.
func reset_session() -> void:
	_world_log.clear()
	_system_log.clear()
	_social_log.clear()
	_journal_entries = []
	_social_peers = {}
	_social_order = []
	_social_target = ""
	_social_peer_unread = {}
	_world_unread = false
	_system_unread = false
	_social_unread = false
	close_input()
	_refresh_social_picker()
	_refresh_tabs()

func _on_social_picker_selected(index: int) -> void:
	var peer_id := str(_social_picker.get_item_metadata(index))
	if peer_id == "":
		return
	_social_target = peer_id
	_social_peer_unread.erase(peer_id)
	_sync_social_log()
	_update_placeholder()
	open_input()

func _sync_social_log() -> void:
	_social_log.clear()
	if _social_target == "":
		_social_log.append_text(
			"[color=#7f94ad][i]%s[/i][/color]\n"
			% Loc.t("Choose a trainer in the Social panel to start chatting.")
		)
		return
	if not _social_peers.has(_social_target):
		return
	var messages: Array = _social_peers[_social_target].get("messages", [])
	for message in messages:
		_social_log.append_text(_social_line(message, _peer_name(_social_target)))

func _social_line(message: Dictionary, peer_name: String) -> String:
	var outgoing := bool(message.get("outgoing", false))
	var who := Loc.t("You") if outgoing else peer_name
	var color := ("#" + UI.GOLD.to_html(false)) if outgoing else "#8fd3a8"
	return "%s[color=%s]%s[/color]: %s\n" % [
		_stamp_prefix(str(message.get("stamp", ""))),
		color,
		_escape(who),
		_escape(str(message.get("text", "")))
	]

func _escape(text: String) -> String:
	return text.replace("[", "[lb]")

func _mark_activity() -> void:
	if _collapsed:
		_collapse_button.modulate = UI.ACCENT

func _toggle_collapsed() -> void:
	_set_collapsed(not _collapsed)

# Desktop keeps the chat log at the bottom-left. On touch the left thumb owns
# the D-pad there, so the log moves to the top-right, above the ABXY cluster.
func set_touch_layout(enabled: bool) -> void:
	if _panel == null:
		return
	_touch_layout = enabled
	if enabled:
		_panel.anchor_left = 1.0
		_panel.anchor_right = 1.0
		_panel.anchor_top = 0.0
		_panel.anchor_bottom = 0.0
		UI.set_hud_corner(_panel, Vector2(1.0, 0.0))
	else:
		_panel.anchor_left = 0.0
		_panel.anchor_right = 0.0
		_panel.anchor_top = 1.0
		_panel.anchor_bottom = 1.0
		UI.set_hud_corner(_panel, Vector2(0.0, 1.0))
	_apply_panel_offsets()
	_update_placeholder()


func _apply_panel_offsets() -> void:
	if _touch_layout:
		_panel.offset_left = -322
		_panel.offset_right = -10
		_panel.offset_top = 96
		_panel.offset_bottom = 158.0 if _collapsed else 290.0
	else:
		_panel.offset_left = 10
		_panel.offset_right = 322
		_panel.offset_top = -72.0 if _collapsed else -204.0
		_panel.offset_bottom = -10

func _set_collapsed(collapsed: bool) -> void:
	_collapsed = collapsed
	_log_area.visible = not collapsed
	_social_bar.visible = not collapsed and _active_tab == "social"
	_apply_panel_offsets()
	_collapse_button.icon = _icon("chevron_up.svg" if collapsed else "chevron_down.svg")
	_collapse_button.modulate = Color(1.0, 1.0, 1.0, 0.78)
	Loc.bind_tooltip(_collapse_button, "Expand chat" if collapsed else "Collapse chat")
	if collapsed:
		close_input()

func open_input() -> void:
	if _collapsed:
		_set_collapsed(false)
	_input.grab_focus()
	_input.caret_column = _input.text.length()

func close_input() -> void:
	_input.text = ""
	_input.release_focus()

func is_input_open() -> bool:
	return _input.has_focus()

func set_timestamps(enabled: bool) -> void:
	_timestamps = enabled
	_rebuild_journal()
	_sync_social_log()

func _update_placeholder() -> void:
	if _active_tab == "social":
		if _social_target != "":
			Loc.bind(_input, "Message %s...", [_peer_name(_social_target)])
		else:
			Loc.bind(_input, "Choose a trainer to message.")
	else:
		if _touch_layout:
			Loc.bind(_input, "Tap to chat...")
		else:
			Loc.bind(_input, "Press Enter to chat...")

func _on_focus_changed(focused: bool) -> void:
	if focused:
		if _active_tab == "social" and _social_target != "":
			Loc.bind(_input, "Message %s...", [_peer_name(_social_target)])
		else:
			Loc.bind(_input, "Say something...")
	else:
		_update_placeholder()

func _on_locale_changed(_code: String) -> void:
	Loc.refresh_all(self)
	_style_social_popup()
	_refresh_tabs()
	_rebuild_journal()
	_refresh_social_picker()
	_sync_social_log()
	_update_placeholder()

func _on_send_pressed() -> void:
	_on_text_submitted(_input.text)

func _on_text_submitted(text: String) -> void:
	var trimmed := text.strip_edges()
	if trimmed == "":
		close_input()
		return
	if _active_tab == "social":
		if _social_target == "":
			_social_picker.show_popup()
			return
		var target := _social_target
		close_input()
		social_message_submitted.emit(trimmed, target)
		return
	close_input()
	message_submitted.emit(trimmed)

func _on_input_gui(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close_input()
		accept_event()
