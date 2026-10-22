extends Control

signal login_requested(username: String, password: String, server_url: String)
signal register_requested(username: String, password: String, server_url: String)

const UI = preload("res://scripts/ui_theme.gd")
const DEFAULT_URL := "ws://127.0.0.1:2567"

var server_input: LineEdit
var user_input: LineEdit
var pass_input: LineEdit
var status_label: Label
var login_button: Button
var register_button: Button
var locale_picker: OptionButton

func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_STOP
	Loc.locale_changed.connect(_on_locale_changed)

	var background := ColorRect.new()
	background.color = UI.BG
	background.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	background.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(background)

	var top_stripe := ColorRect.new()
	top_stripe.color = UI.ACCENT
	top_stripe.anchor_right = 1.0
	top_stripe.offset_bottom = 4.0
	top_stripe.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(top_stripe)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UI.panel_style(UI.PANEL, 18))
	panel.custom_minimum_size = Vector2(650, 0)
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 36)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_right", 36)
	margin.add_theme_constant_override("margin_bottom", 14)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)

	var title := UI.make_label("BWMMO", 40, UI.ACCENT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var subtitle := Loc.make_label("UNOVA ONLINE  -  PROTOTYPE", 13, UI.MUTED)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(subtitle)

	var blurb := Loc.make_label(
		"One shared town, one route, real other players, and a server that owns the battle.",
		12,
		UI.TEXT
	)
	blurb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(blurb)

	var divider := ColorRect.new()
	divider.color = UI.BORDER
	divider.custom_minimum_size = Vector2(0, 1)
	box.add_child(divider)

	box.add_child(Loc.make_label("Server", 12, UI.MUTED))
	server_input = LineEdit.new()
	server_input.text = DEFAULT_URL
	server_input.placeholder_text = "ws://127.0.0.1:2567"
	UI.style_line_edit(server_input)
	box.add_child(server_input)

	box.add_child(Loc.make_label("Username", 12, UI.MUTED))
	user_input = LineEdit.new()
	UI.style_line_edit(user_input)
	Loc.bind(user_input, "3-20 letters, numbers, or underscores")
	user_input.max_length = 20
	box.add_child(user_input)

	box.add_child(Loc.make_label("Password", 12, UI.MUTED))
	pass_input = LineEdit.new()
	UI.style_line_edit(pass_input)
	Loc.bind(pass_input, "at least 4 characters")
	pass_input.secret = true
	pass_input.max_length = 72
	pass_input.text_submitted.connect(_on_password_submitted)
	box.add_child(pass_input)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	box.add_child(buttons)

	login_button = Button.new()
	login_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UI.style_button(login_button, true)
	Loc.bind(login_button, "Log in")
	login_button.pressed.connect(_on_login_pressed)
	buttons.add_child(login_button)

	register_button = Button.new()
	register_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UI.style_button(register_button)
	Loc.bind(register_button, "Create account")
	register_button.pressed.connect(_on_register_pressed)
	buttons.add_child(register_button)

	status_label = UI.make_label("", 12, UI.MUTED)
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.custom_minimum_size = Vector2(0, 28)
	box.add_child(status_label)

	var language_row := HBoxContainer.new()
	language_row.alignment = BoxContainer.ALIGNMENT_CENTER
	language_row.add_theme_constant_override("separation", 8)
	box.add_child(language_row)
	language_row.add_child(Loc.make_label("Language", 10, UI.MUTED))
	locale_picker = OptionButton.new()
	locale_picker.focus_mode = Control.FOCUS_NONE
	UI.style_button(locale_picker, false, true)
	for code in Loc.SUPPORTED:
		locale_picker.add_item(Loc.locale_label(code))
		locale_picker.set_item_metadata(locale_picker.item_count - 1, code)
	locale_picker.item_selected.connect(_on_locale_selected)
	language_row.add_child(locale_picker)
	_select_current_locale()

	var footer := Loc.make_label(
		"Placeholder art only. This is a technical prototype, not an official game.",
		9,
		Color(UI.MUTED.r, UI.MUTED.g, UI.MUTED.b, 0.7)
	)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(footer)

func _on_locale_selected(index: int) -> void:
	Loc.set_locale(str(locale_picker.get_item_metadata(index)))

func _on_locale_changed(_code: String) -> void:
	Loc.refresh_all(self)
	_select_current_locale()
	set_status("", false)

func _select_current_locale() -> void:
	if locale_picker == null:
		return
	for index in range(locale_picker.item_count):
		if str(locale_picker.get_item_metadata(index)) == Loc.locale:
			locale_picker.select(index)
			return

func _on_login_pressed() -> void:
	_submit(false)

func _on_register_pressed() -> void:
	_submit(true)

func _on_password_submitted(_text: String) -> void:
	_submit(false)

func _submit(register: bool) -> void:
	var url := server_input.text.strip_edges()
	var username := user_input.text.strip_edges()
	var password := pass_input.text
	if not (url.begins_with("ws://") or url.begins_with("wss://")):
		set_status(Loc.t("Server URL must start with ws:// or wss://."), true)
		return
	if username.length() < 3:
		set_status(Loc.t("Username must be at least 3 characters."), true)
		return
	if password.length() < 4:
		set_status(Loc.t("Password must be at least 4 characters."), true)
		return
	if register:
		register_requested.emit(username, password, url)
	else:
		login_requested.emit(username, password, url)

func set_status(text: String, is_error: bool = true) -> void:
	status_label.text = text
	status_label.add_theme_color_override("font_color", UI.DANGER if is_error else UI.MUTED)

func set_busy(busy: bool) -> void:
	login_button.disabled = busy
	register_button.disabled = busy
	server_input.editable = not busy
	user_input.editable = not busy
	pass_input.editable = not busy

func show_connecting(text: String = "") -> void:
	set_busy(true)
	set_status(Loc.t("Connecting...") if text == "" else text, false)

func set_server_url(url: String) -> void:
	server_input.text = url

func set_username(username: String) -> void:
	user_input.text = username

func focus_username() -> void:
	user_input.grab_focus()
