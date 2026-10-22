extends Control

signal message_submitted(text: String)

const UI = preload("res://scripts/ui_theme.gd")
const ICON_ROOT := "res://assets/ui/icons"

var _panel: PanelContainer
var _log_area: Control
var _world_log: RichTextLabel
var _system_log: RichTextLabel
var _world_tab: Button
var _system_tab: Button
var _collapse_button: Button
var _input: LineEdit
var _send_button: Button
var _active_tab := "world"
var _collapsed := false
var _timestamps := false
var _world_unread := false
var _system_unread := false
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
	_panel.offset_top = -184
	_panel.offset_bottom = -10
	_panel.add_theme_stylebox_override(
		"panel", UI.glass_style(UI.INK, 11, UI.BORDER, 1, 0)
	)
	_panel.mouse_filter = MOUSE_FILTER_STOP
	add_child(_panel)
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

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = MOUSE_FILTER_IGNORE
	header.add_child(spacer)

	_collapse_button = _make_icon_button("chevron_down.svg", Vector2(20, 20), 14)
	Loc.bind_tooltip(_collapse_button, "Collapse chat")
	_collapse_button.pressed.connect(_toggle_collapsed)
	header.add_child(_collapse_button)

	_log_area = Control.new()
	_log_area.custom_minimum_size = Vector2(0, 84)
	_log_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log_area.clip_contents = true
	_log_area.mouse_filter = MOUSE_FILTER_IGNORE
	box.add_child(_log_area)

	_world_log = _make_log()
	_system_log = _make_log()
	_system_log.visible = false
	_log_area.add_child(_world_log)
	_log_area.add_child(_system_log)

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
	_active_tab = tab
	if tab == "system":
		_system_unread = false
		_world_log.visible = false
		_system_log.visible = true
	else:
		_world_unread = false
		_world_log.visible = true
		_system_log.visible = false
	_refresh_tabs()

func _timestamp_prefix() -> String:
	if not _timestamps:
		return ""
	var now := Time.get_time_dict_from_system()
	return "[color=#6f839b]%02d:%02d[/color] " % [
		int(now.get("hour", 0)), int(now.get("minute", 0))
	]

func add_message(speaker: String, text: String, color: Color = UI.GOLD) -> void:
	var hex := "#" + color.to_html(false)
	_world_log.append_text(
		"%s[color=%s]%s[/color]: %s\n" % [
			_timestamp_prefix(), hex, _escape(speaker), _escape(text)
		]
	)
	if _active_tab != "world":
		_world_unread = true
	_refresh_tabs()
	_mark_activity()

func add_system(text: String) -> void:
	_system_log.append_text(
		"%s[color=#8aa0b2][i]%s[/i][/color]\n" % [_timestamp_prefix(), _escape(text)]
	)
	if _active_tab != "system":
		_system_unread = true
	_refresh_tabs()
	_mark_activity()

func add_world_notice(text: String) -> void:
	_world_log.append_text(
		"%s[color=#7f94ad][i]%s[/i][/color]\n" % [_timestamp_prefix(), _escape(text)]
	)
	_refresh_tabs()
	_mark_activity()

func _escape(text: String) -> String:
	return text.replace("[", "[lb]")

func _mark_activity() -> void:
	if _collapsed:
		_collapse_button.modulate = UI.ACCENT

func _toggle_collapsed() -> void:
	_set_collapsed(not _collapsed)

func _set_collapsed(collapsed: bool) -> void:
	_collapsed = collapsed
	_log_area.visible = not collapsed
	_panel.offset_top = -72.0 if collapsed else -184.0
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

func _on_focus_changed(focused: bool) -> void:
	Loc.bind(_input, "Say something..." if focused else "Press Enter to chat...")

func _on_locale_changed(_code: String) -> void:
	Loc.refresh_all(self)
	_refresh_tabs()
	_on_focus_changed(_input != null and _input.has_focus())

func _on_send_pressed() -> void:
	_on_text_submitted(_input.text)

func _on_text_submitted(text: String) -> void:
	var trimmed := text.strip_edges()
	close_input()
	if trimmed != "":
		message_submitted.emit(trimmed)

func _on_input_gui(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close_input()
		accept_event()
