extends Node

enum GameState { LOGIN, CREATE, ENTERING, WORLD, DIALOGUE, BATTLE, RECONNECTING, SHOP, PC, CAPTURE_CARD }

const NetClientScript = preload("res://scripts/net_client.gd")
const WorldViewScript = preload("res://scripts/world_view.gd")
const NuvemaOnlineScript = preload("res://scripts/nuvema_online.gd")
const LoginUIScript = preload("res://scripts/login_ui.gd")
const CreateUIScript = preload("res://scripts/create_character_ui.gd")
const DialogueUIScript = preload("res://scripts/dialogue_ui.gd")
const ChatUIScript = preload("res://scripts/chat_ui.gd")
const HudScript = preload("res://scripts/hud.gd")
const TouchControlsScript = preload("res://scripts/touch_controls.gd")
const BattleUIScript = preload("res://scripts/battle_ui.gd")
const ShopUIScript = preload("res://scripts/shop_ui.gd")
const PcUIScript = preload("res://scripts/pc_ui.gd")
const WorldTimeScript = preload("res://scripts/world_time.gd")
const UI = preload("res://scripts/ui_theme.gd")

const SESSION_PATH := "user://session.cfg"
const DEFAULT_SERVER := "ws://127.0.0.1:2567"
const STEP_INTERVAL_MS := 500
const RUN_STEP_INTERVAL_MS := 250
const BLOCKED_STEP_RETRY_MS := 100
const TURN_CONFIRM_MS := 150
const PING_INTERVAL_MS := 5000

var state: int = GameState.LOGIN
var ui_layer: CanvasLayer
var net
var world
var world3d
var login_ui
var create_ui
var dialogue_ui
var chat_ui
var hud
var touch_ui
var battle_ui
var pending_capture: Dictionary = {}
var shop_ui
var pc_ui
var loading_overlay: Control
var loading_label: Label
var reconnect_overlay: Control
var reconnect_label: Label

var server_url := DEFAULT_SERVER
var token := ""
var starter_options: Array = []
var max_party := 6
var account_username := ""
var pending_auth: Dictionary = {}
var self_data: Dictionary = {}
var self_name := ""
var self_id := ""
var current_map_name := ""
var current_location := ""
var current_map_id := ""
var current_battle: Dictionary = {}
var pending_learn_request: Dictionary = {}
var item_catalog: Array = []
var max_box := 30

var move_seq := 0
var last_move_seq := 0
var next_step_at := 0
var next_portal_push_at := 0
var touch_dir := ""

var reconnect_attempts := 0
var next_reconnect_at := 0
var has_world := false
var welcome_sent := false
var reconnect_succeeded := false
var _world_tint_layer: CanvasLayer
var _world_tint_rect: ColorRect
var _next_world_time_at := 0

var next_ping_at := 0
var next_npc_poll_at := 0

var force_touch := false
var auto_mode := false
var auto_route1 := false
var auto_run_capture := false
var auto_capture_at := 0
var auto_sequence := false
var auto_sequence_dir := ""
var auto_sequence_next_at := 0
var auto_sequence_index := 0
var auto_sequence_count := 24
var auto_sequence_interval := 80
var auto_role := "A"
var auto_username := ""
var auto_character := ""
var auto_path: Array = []
var auto_moving := false
var auto_step_at := 0
var auto_step_index := 0
var auto_finish_at := 0
var auto_done := false
var auto_chat_sent := false
var auto_battle := false
var auto_dialogue := false
var auto_reconnect := false
var auto_grove := false
var auto_indoor := false
var auto_house := false
var auto_cliff := false
var auto_run := false
var auto_ui_create := false
var auto_ui_submit_at := 0
var auto_reconnect_phase := 0
var auto_reconnect_at := 0
var auto_battle_phase := 0
var auto_battle_at := 0
var auto_login_fallback := false
var screenshot_path := ""
var capture_login := false
var auto_create_only := false
var debug_keep := false
var debug_shot_path := ""
var debug_shot_at := 0
var debug_foreground_set := false

func _ready() -> void:
	_load_session()
	_parse_debug_args()
	WorldTimeScript.configure_from_args()
	_build_ui()
	if capture_login:
		_capture_login_screenshot()
	elif auto_mode:
		_start_auto()
	elif token != "":
		login_ui.visible = true
		login_ui.show_connecting(Loc.t("Restoring session..."))
		_begin_auth("resume", "", "", server_url)
	else:
		login_ui.focus_username()

func _build_ui() -> void:
	world = WorldViewScript.new()
	world.visible = false
	add_child(world)

	world3d = NuvemaOnlineScript.new()
	world3d.visible = false
	add_child(world3d)

	_world_tint_layer = CanvasLayer.new()
	_world_tint_layer.layer = 5
	_world_tint_layer.visible = false
	add_child(_world_tint_layer)
	_world_tint_rect = ColorRect.new()
	_world_tint_rect.color = Color(1, 1, 1, 1)
	_world_tint_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_world_tint_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tint_material := CanvasItemMaterial.new()
	tint_material.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL
	_world_tint_rect.material = tint_material
	_world_tint_layer.add_child(_world_tint_rect)

	ui_layer = CanvasLayer.new()
	ui_layer.layer = 10
	add_child(ui_layer)

	chat_ui = ChatUIScript.new()
	chat_ui.visible = false
	ui_layer.add_child(chat_ui)
	chat_ui.message_submitted.connect(_on_chat_submitted)

	hud = HudScript.new()
	hud.visible = false
	ui_layer.add_child(hud)
	hud.interact_pressed.connect(_on_touch_interact)
	hud.menu_state_changed.connect(_on_hud_menu_state)
	hud.chat_timestamps_requested.connect(_on_chat_timestamps_changed)

	touch_ui = TouchControlsScript.new()
	touch_ui.visible = false
	ui_layer.add_child(touch_ui)
	touch_ui.dir_changed.connect(_on_touch_dir)
	touch_ui.interact_pressed.connect(_on_touch_interact)
	touch_ui.chat_pressed.connect(_on_touch_chat)

	dialogue_ui = DialogueUIScript.new()
	ui_layer.add_child(dialogue_ui)
	dialogue_ui.closed.connect(_on_dialogue_closed)

	battle_ui = BattleUIScript.new()
	ui_layer.add_child(battle_ui)
	battle_ui.action_selected.connect(_on_battle_action)
	battle_ui.item_used.connect(_on_battle_item)
	battle_ui.closed.connect(_on_battle_closed)
	hud.capture_card_closed.connect(_on_capture_card_closed)

	shop_ui = ShopUIScript.new()
	ui_layer.add_child(shop_ui)
	shop_ui.requested.connect(_on_shop_requested)
	shop_ui.closed.connect(_on_shop_closed)

	pc_ui = PcUIScript.new()
	ui_layer.add_child(pc_ui)
	pc_ui.requested.connect(_on_pc_requested)
	pc_ui.closed.connect(_on_pc_closed)
	hud.item_use_requested.connect(_on_hud_item_use)
	hud.pokedex_requested.connect(_on_pokedex_requested)
	hud.move_learn_choice.connect(_on_move_learn_choice)
	hud.forget_move_requested.connect(_on_forget_move_requested)

	var loading := _make_overlay("Entering Unova...")
	loading_overlay = loading[0]
	loading_label = loading[1]

	var reconnect := _make_overlay("Connection lost. Reconnecting...")
	reconnect_overlay = reconnect[0]
	reconnect_label = reconnect[1]
	Loc.locale_changed.connect(_on_locale_changed)

	login_ui = LoginUIScript.new()
	login_ui.visible = false
	ui_layer.add_child(login_ui)
	login_ui.login_requested.connect(_on_login_requested)
	login_ui.register_requested.connect(_on_register_requested)

	create_ui = CreateUIScript.new()
	create_ui.visible = false
	ui_layer.add_child(create_ui)
	create_ui.create_requested.connect(_on_create_requested)

	net = NetClientScript.new()
	add_child(net)
	net.connected.connect(_on_net_connected)
	net.disconnected.connect(_on_net_disconnected)
	net.connect_failed.connect(_on_connect_failed)
	net.message_received.connect(_on_message)

	if not auto_mode and token == "":
		login_ui.visible = true

func _make_overlay(message: String) -> Array:
	var layer := Control.new()
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.visible = false
	var background := ColorRect.new()
	background.color = Color(0.02, 0.03, 0.045, 0.92)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(background)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UI.panel_style(UI.PANEL, 14))
	center.add_child(panel)
	var label := Loc.make_label(message, 18, UI.TEXT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(label)
	ui_layer.add_child(layer)
	return [layer, label]

func _on_locale_changed(_code: String) -> void:
	Loc.refresh_all(self)
	if net != null and net.is_open():
		net.send_message({"type": "set_locale", "locale": Loc.locale})
	if state == GameState.WORLD and hud != null and not hud.menu_open and not dialogue_ui.visible:
		hud.set_hint(_default_hint())

func _parse_debug_args() -> void:
	var args := OS.get_cmdline_args()
	for argument in OS.get_cmdline_user_args():
		if not args.has(argument):
			args.append(argument)
	for argument in args:
		if argument == "--auto":
			auto_mode = true
		elif argument == "--auto-b":
			auto_mode = true
			auto_role = "B"
		elif argument == "--auto-battle":
			auto_mode = true
			auto_role = "A"
			auto_battle = true
		elif argument == "--auto-create":
			auto_mode = true
			auto_role = "A"
			auto_create_only = true
		elif argument == "--auto-dialogue":
			auto_mode = true
			auto_role = "A"
			auto_dialogue = true
		elif argument == "--auto-reconnect":
			auto_mode = true
			auto_role = "A"
			auto_reconnect = true
		elif argument == "--auto-grove":
			auto_mode = true
			auto_role = "A"
			auto_grove = true
		elif argument == "--auto-indoor":
			auto_mode = true
			auto_role = "A"
			auto_indoor = true
		elif argument == "--auto-house":
			auto_mode = true
			auto_role = "A"
			auto_house = true
		elif argument == "--auto-cliff":
			auto_mode = true
			auto_role = "A"
			auto_cliff = true
		elif argument == "--auto-run":
			auto_mode = true
			auto_role = "A"
			auto_run = true
		elif argument == "--auto-route1":
			auto_mode = true
			auto_role = "A"
			auto_route1 = true
		elif argument == "--auto-run-shot":
			auto_mode = true
			auto_role = "A"
			auto_run = true
			auto_run_capture = true
		elif argument == "--auto-sequence":
			auto_mode = true
			auto_role = "A"
			auto_run = true
			auto_sequence = true
		elif argument == "--auto-sequence-walk":
			auto_mode = true
			auto_role = "A"
			auto_sequence = true
		elif argument.begins_with("--sequence-dir="):
			auto_sequence_dir = argument.substr(15)
		elif argument == "--auto-ui-create":
			auto_mode = true
			auto_role = "A"
			auto_ui_create = true
		elif argument == "--debug-keep":
			debug_keep = true
		elif argument.begins_with("--debug-shot="):
			debug_shot_path = argument.substr(13)
		elif argument == "--touch":
			force_touch = true
		elif argument.begins_with("--server="):
			server_url = argument.substr(9)
		elif argument.begins_with("--screenshot="):
			screenshot_path = argument.substr(13)
		elif argument == "--capture-login":
			capture_login = true
			token = ""

func _load_session() -> void:
	var config := ConfigFile.new()
	if config.load(SESSION_PATH) != OK:
		return
	server_url = str(config.get_value("session", "server_url", server_url))
	token = str(config.get_value("session", "token", ""))

func _save_session() -> void:
	var config := ConfigFile.new()
	config.set_value("session", "server_url", server_url)
	config.set_value("session", "token", token)
	config.save(SESSION_PATH)

func _clear_session() -> void:
	token = ""
	_save_session()

func _touch_enabled() -> bool:
	return force_touch or OS.has_feature("mobile")

func _default_hint() -> String:
	if _touch_enabled():
		return Loc.t("D-pad move  -  Talk  -  Chat")
	return Loc.t("WASD move  -  Shift run  -  E talk  -  T chat")

func _start_auto() -> void:
	var suffix := str(Time.get_ticks_msec() % 1000000) + str(randi_range(100, 999))
	auto_username = ("autoa" if auto_role == "A" else "autob") + suffix
	auto_character = ("Scout" + auto_role + suffix).substr(0, 16)
	if auto_reconnect:
		auto_path = []
	elif auto_indoor:
		auto_path = [
			"left", "left", "left", "left", "left",
			"up",
			"left", "left",
			"up", "up", "up", "up", "up", "up", "up", "up", "up", "up", "up"
		]
	elif auto_house:
		auto_path = ["left", "left", "up", "up", "up", "up"]
	elif auto_cliff:
		auto_path = [
			"left", "up", "up", "right", "right", "right",
			"up", "up", "up", "up", "up", "up", "up", "up", "up", "up",
			"up", "up", "up", "up", "up", "up", "up", "up", "up", "up",
			"up", "up", "up", "up", "up", "up", "up", "up", "up", "up", "up"
		]
	elif auto_grove:
		auto_path = ["down", "down"]
		for i in range(22):
			auto_path.append("up")
		auto_path.append_array(["up", "up", "up"])
	elif auto_sequence:
		auto_path = ["down", "down", "down", "down", "down", "down", "down", "down", "down", "down", "down", "down"]
	elif auto_run_capture:
		auto_path = ["down", "down", "down", "down", "down", "down", "down", "down"]
	elif auto_route1:
		auto_path = [
			"left",
			"up", "up", "up", "up", "right", "right",
			"up", "up", "up", "up", "up", "up", "up", "up", "up",
			"right",
			"up", "up", "up", "up", "up", "up", "up", "up",
			"up", "up", "up", "up", "up", "up", "up", "up", "up",
			"right", "right"
		]
	elif auto_dialogue:
		auto_path = ["left", "left", "left"]
	elif auto_battle:
		auto_path = [
			"down", "down",
			"up", "up", "up", "up",
			"right", "right", "right", "right", "right", "right",
			"up"
		]
	elif auto_role == "A":
		auto_path = ["left", "left", "up", "up"]
	else:
		auto_path = ["right", "right", "up", "up"]
	login_ui.visible = false
	create_ui.visible = false
	loading_overlay.visible = true
	Loc.bind(loading_label, "Auto-connecting...")
	print("[auto] role %s user %s character %s" % [auto_role, auto_username, auto_character])
	_begin_auth("register", auto_username, "demopass", server_url)

func _begin_auth(mode: String, username: String, password: String, url: String) -> void:
	server_url = url
	pending_auth = {
		"mode": mode,
		"username": username,
		"password": password,
		"token": token
	}
	if net.is_open():
		if login_ui.visible:
			login_ui.show_connecting(Loc.t("Logging in..."))
		_send_pending_auth()
	elif not net.is_connecting():
		if login_ui.visible:
			login_ui.show_connecting(Loc.t("Connecting..."))
		if auto_mode:
			loading_overlay.visible = true
			Loc.bind(loading_label, "Connecting...")
		net.connect_to(server_url)

func _send_pending_auth() -> void:
	var mode := str(pending_auth.get("mode", ""))
	match mode:
		"register":
			net.send_message({
				"type": "register",
				"username": str(pending_auth.get("username", "")),
				"password": str(pending_auth.get("password", "")),
				"locale": Loc.locale
			})
		"login":
			net.send_message({
				"type": "login",
				"username": str(pending_auth.get("username", "")),
				"password": str(pending_auth.get("password", "")),
				"locale": Loc.locale
			})
		"resume":
			net.send_message({
				"type": "resume",
				"token": str(pending_auth.get("token", token)),
				"locale": Loc.locale
			})

func _on_login_requested(username: String, password: String, url: String) -> void:
	_begin_auth("login", username, password, url)

func _on_register_requested(username: String, password: String, url: String) -> void:
	_begin_auth("register", username, password, url)

func _on_net_connected() -> void:
	_send_pending_auth()

func _on_connect_failed(reason: String) -> void:
	if auto_mode:
		print("[auto] connection failed: %s" % reason)
		get_tree().quit(1)
		return
	if state == GameState.RECONNECTING:
		Loc.bind(reconnect_label, "%s Retrying...", [reason])
		next_reconnect_at = Time.get_ticks_msec() + 2000
		return
	state = GameState.LOGIN
	pending_auth.clear()
	loading_overlay.visible = false
	create_ui.visible = false
	login_ui.visible = true
	login_ui.set_busy(false)
	login_ui.set_status("%s %s" % [reason, Loc.t("Is the server running?")], true)
	login_ui.set_server_url(server_url)

func _on_net_disconnected() -> void:
	if token == "" or state == GameState.LOGIN:
		if state == GameState.CREATE:
			create_ui.set_busy(false)
			create_ui.set_status(Loc.t("Disconnected from server."), true)
		else:
			state = GameState.LOGIN
			create_ui.visible = false
			login_ui.visible = true
			login_ui.set_busy(false)
			login_ui.set_status(Loc.t("Disconnected from server."), true)
		return
	_start_reconnect()

func _start_reconnect() -> void:
	if state == GameState.RECONNECTING:
		return
	state = GameState.RECONNECTING
	reconnect_attempts = 0
	next_reconnect_at = Time.get_ticks_msec() + 500
	pending_auth = {"mode": "resume", "token": token}
	reconnect_overlay.visible = true
	Loc.bind(reconnect_label, "Connection lost. Reconnecting...")
	loading_overlay.visible = false
	login_ui.visible = false
	create_ui.visible = false
	battle_ui.visible = false
	dialogue_ui.close()
	if shop_ui != null and shop_ui.visible:
		shop_ui.close()
	if pc_ui != null and pc_ui.visible:
		pc_ui.close()
	chat_ui.close_input()
	chat_ui.visible = false
	touch_ui.visible = false
	touch_dir = ""
	if hud != null:
		hud.close_menu()
		hud.set_dialogue_mode(false)
		hud.set_nearby_npc({})
		hud.set_connection("OFFLINE", false)
		hud.set_hint("")

func _on_message(message: Dictionary) -> void:
	match str(message.get("type", "")):
		"hello":
			pass
		"auth_ok":
			_on_auth_ok(message)
		"character_created":
			_on_character_created(message)
		"map_state":
			_on_map_state(message)
		"map_window":
			_on_map_window(message)
		"player_joined":
			_on_player_joined(message)
		"player_left":
			_on_player_left(message)
		"player_moved":
			_on_player_moved(message)
		"player_turned":
			_on_player_turned(message)
		"move_ack":
			_on_move_ack(message)
		"chat":
			_on_chat(message)
		"dialogue":
			_on_dialogue(message)
		"party_state":
			_on_party_state(message)
		"pokedex_state":
			_on_pokedex_state(message)
		"move_learn_request":
			_on_move_learn_request(message)
		"shop_state":
			_on_shop_state(message)
		"pc_state":
			_on_pc_state(message)
		"battle_start":
			_on_battle_start(message)
		"battle_turn":
			_on_battle_turn(message)
		"battle_end":
			_on_battle_end(message)
		"notice":
			_on_notice(message)
		"pong":
			_on_pong(message)
		"error":
			_on_error(message)
		_:
			print("[net] unhandled message: %s" % str(message.get("type", "?")))

func _default_starter_id() -> String:
	if starter_options.is_empty():
		return "snivy"
	var first: Variant = starter_options[0]
	if first is Dictionary:
		return str(first.get("id", "snivy"))
	return "snivy"

func _on_auth_ok(message: Dictionary) -> void:
	var was_reconnecting: bool = state == GameState.RECONNECTING
	token = str(message.get("token", token))
	account_username = str(message.get("username", ""))
	_save_session()
	pending_auth.clear()
	reconnect_attempts = 0
	next_ping_at = 0
	login_ui.set_busy(false)
	reconnect_overlay.visible = false
	starter_options = message.get("starters", [])
	max_party = int(message.get("maxParty", 6))
	max_box = int(message.get("maxBox", max_box))
	item_catalog = message.get("items", [])
	hud.set_items(item_catalog)
	battle_ui.set_items(item_catalog)
	var character: Variant = message.get("character", null)
	if character == null:
		if auto_mode:
			if auto_create_only:
				_show_create_screen()
				create_ui.name_input.text = auto_character
				_capture_screen_and_quit()
			elif auto_ui_create:
				_show_create_screen()
				create_ui.name_input.text = auto_character
				create_ui.select_starter_for_test("tepig")
				auto_ui_submit_at = Time.get_ticks_msec() + 900
			else:
				_auto_create_character()
		else:
			_show_create_screen()
		return
	self_data = character
	self_name = str(character.get("name", ""))
	self_id = str(character.get("id", ""))
	login_ui.visible = false
	create_ui.visible = false
	state = GameState.ENTERING
	reconnect_succeeded = was_reconnecting
	loading_overlay.visible = true
	Loc.bind(loading_label, "Entering Unova...")

func _show_create_screen() -> void:
	state = GameState.CREATE
	loading_overlay.visible = false
	reconnect_overlay.visible = false
	login_ui.visible = false
	create_ui.visible = true
	create_ui.set_starters(starter_options)
	var hint := account_username
	if hint.length() > 16:
		hint = hint.substr(0, 16)
	create_ui.reset(hint)
	create_ui.set_status("", false)

func _on_create_requested(character_name: String, color: String, starter_id: String) -> void:
	if not net.is_open():
		create_ui.set_busy(false)
		create_ui.set_status(Loc.t("Not connected to the server."), true)
		return
	net.send_message({
		"type": "create_character",
		"name": character_name,
		"color": color,
		"starter": starter_id
	})

func _on_character_created(message: Dictionary) -> void:
	var character: Dictionary = message["character"]
	self_data = character
	self_name = str(character.get("name", ""))
	self_id = str(character.get("id", ""))
	create_ui.visible = false
	state = GameState.ENTERING
	loading_overlay.visible = true
	Loc.bind(loading_label, "Entering Unova...")
	if auto_mode:
		print("[auto] character created")

func _auto_create_character() -> void:
	loading_overlay.visible = true
	Loc.bind(loading_label, "Creating trainer...")
	create_ui.visible = false
	var color := "#e76f51" if auto_role == "A" else "#2a9d8f"
	net.send_message({
		"type": "create_character",
		"name": auto_character,
		"color": color,
		"starter": _default_starter_id(),
		"sprite": 0 if auto_role == "A" else 1
	})

func _on_map_state(message: Dictionary) -> void:
	max_party = int(message.get("maxParty", max_party))
	max_box = int(message.get("maxBox", max_box))
	if shop_ui != null and shop_ui.visible:
		shop_ui.close()
	if pc_ui != null and pc_ui.visible:
		pc_ui.close()
	var map_info: Dictionary = message["map"]
	var self_info: Dictionary = message["self"]
	var players: Array = message.get("players", [])
	var battle_open: bool = battle_ui.visible
	var was_reconnecting: bool = state == GameState.RECONNECTING or reconnect_succeeded
	reconnect_succeeded = false
	var previous_map_id := current_map_id
	var map_changed: bool = has_world and previous_map_id != "" and previous_map_id != str(map_info.get("id", ""))

	self_data = self_info
	self_name = str(self_info.get("name", self_name))
	self_id = str(self_info.get("id", self_id))
	current_map_name = str(map_info.get("name", ""))
	current_location = str(message.get("location", current_map_name))
	current_map_id = str(map_info.get("id", ""))
	if map_changed:
		loading_overlay.visible = true
		Loc.bind(loading_label, "Entering %s...", [current_map_name])
	if _is_rom_map(current_map_id):
		world.visible = false
		world.set_active(false)
		world3d.visible = true
		world3d.setup_map(map_info, self_info, players)
		world3d.set_active(true)
	else:
		world3d.set_active(false)
		world3d.visible = false
		world.setup_map(map_info, self_info, players)
		world.set_active(true)
	has_world = true

	if map_changed:
		await get_tree().create_timer(0.35).timeout
	loading_overlay.visible = false
	reconnect_overlay.visible = false
	login_ui.visible = false
	create_ui.visible = false
	hud.visible = true
	hud.set_self(
		self_name,
		int(self_info.get("money", 0)),
		int(self_info.get("wins", 0)),
		self_info
	)
	hud.set_map(current_map_name, _local_count(), current_location)
	hud.set_party(self_info.get("party", []), max_party)
	hud.set_inventory(self_info.get("inventory", {}))
	var pokedex: Dictionary = (
		self_info.get("pokedex", {})
		if self_info.get("pokedex", {}) is Dictionary
		else {}
	)
	hud.set_pokedex(
		pokedex.get("seen", []),
		pokedex.get("caught", []),
		[],
		int(message.get("pokedexTotal", 649))
	)
	hud.set_map_data(map_info, self_info)
	hud.set_season(world3d.season if _is_rom_map(current_map_id) else "autumn")
	hud.set_touch_layout(_touch_enabled())
	hud.set_dialogue_mode(false)
	hud.set_nearby_npc({})
	hud.set_connection("ONLINE", true)
	next_npc_poll_at = 0
	get_viewport().gui_release_focus()

	if battle_open:
		state = GameState.BATTLE
		chat_ui.visible = false
		touch_ui.visible = false
		hud.set_hint("")
	else:
		dialogue_ui.close()
		state = GameState.WORLD
		battle_ui.visible = false
		chat_ui.visible = true
		touch_ui.visible = _touch_enabled()
		hud.set_hint(_default_hint())
		if not welcome_sent:
			welcome_sent = true
			chat_ui.add_system("Connected as %s. This is the prototype slice." % self_name)
		if was_reconnecting:
			chat_ui.add_system("Reconnected to the server.")
			print("[net] reconnected")
	if auto_mode and not auto_moving and not auto_reconnect:
		auto_moving = true
		auto_step_at = Time.get_ticks_msec() + 1200
		auto_step_index = 0
		if auto_run_capture:
			auto_capture_at = Time.get_ticks_msec() + 2000
		if auto_sequence:
			auto_sequence_next_at = Time.get_ticks_msec() + 1600
	_show_pending_learn_if_ready()

func _on_map_window(message: Dictionary) -> void:
	if str(message.get("mapId", "")) != current_map_id:
		return
	if _is_rom_map(current_map_id):
		world3d.update_tiles(message)
	else:
		world.update_tiles(message)
	hud.update_map_window(message)

func _on_player_joined(message: Dictionary) -> void:
	var player: Variant = message.get("player", null)
	if player is Dictionary:
		if _is_rom_map(current_map_id):
			world3d.add_player(player)
		else:
			world.add_player(player)
		hud.set_map(current_map_name, _local_count(), current_location)

func _on_player_left(message: Dictionary) -> void:
	if _is_rom_map(current_map_id):
		world3d.remove_player(str(message.get("playerId", "")))
	else:
		world.remove_player(str(message.get("playerId", "")))
	hud.set_map(current_map_name, _local_count(), current_location)

func _local_count() -> int:
	if _is_rom_map(current_map_id):
		return world3d.local_count()
	return world.local_count()

func _is_rom_map(map_id: String) -> bool:
	return map_id == "unova_full" or map_id.begins_with("unova_in_")

func _on_player_moved(message: Dictionary) -> void:
	if _is_rom_map(current_map_id):
		world3d.move_player(
			str(message.get("playerId", "")),
			int(message.get("x", 0)),
			int(message.get("y", 0)),
			str(message.get("dir", "down")),
			bool(message.get("run", false))
		)
	else:
		world.move_player(
			str(message.get("playerId", "")),
			int(message.get("x", 0)),
			int(message.get("y", 0)),
			str(message.get("dir", "down"))
		)

func _on_player_turned(message: Dictionary) -> void:
	var id := str(message.get("playerId", ""))
	var dir := str(message.get("dir", "down"))
	if _is_rom_map(current_map_id):
		world3d.turn_player(id, dir)
	else:
		world.turn_player(id, dir)

func _on_move_ack(message: Dictionary) -> void:
	var seq := int(message.get("seq", 0))
	if seq < last_move_seq:
		return
	var x := int(message.get("x", 0))
	var y := int(message.get("y", 0))
	var dir := str(message.get("dir", "down"))
	if _is_rom_map(current_map_id):
		world3d.correct_self(x, y, dir)
	else:
		if bool(message.get("accepted", false)):
			world.correct_self(x, y, dir)
		elif str(message.get("reason", "")) != "too_fast":
			world.correct_self(x, y, dir)
	hud.update_self_position(x, y, dir)
	if bool(message.get("accepted", false)) and message.has("location"):
		current_location = str(message.get("location", current_location))
		hud.set_location(current_location)

func _on_chat(message: Dictionary) -> void:
	var speaker_id := str(message.get("playerId", ""))
	var color := Color(str(self_data.get("color", "#ffd166"))) if speaker_id == self_id else UI.GOLD
	var text := str(message.get("text", ""))
	chat_ui.add_message(str(message.get("name", "?")), text, color)
	if _is_rom_map(current_map_id):
		world3d.show_bubble(speaker_id, text)
	else:
		world.show_bubble(speaker_id, text)

func _on_dialogue(message: Dictionary) -> void:
	if state == GameState.BATTLE or state == GameState.RECONNECTING:
		return
	state = GameState.DIALOGUE
	touch_dir = ""
	touch_ui.visible = false
	hud.close_menu()
	hud.set_dialogue_mode(true)
	hud.set_nearby_npc({})
	hud.set_hint("")
	chat_ui.visible = false
	dialogue_ui.show_dialogue(
		str(message.get("npcName", "?")),
		message.get("lines", []),
		str(message.get("kind", "npc"))
	)

func _on_party_state(message: Dictionary) -> void:
	if message.has("party"):
		self_data["party"] = message["party"]
	if message.has("box"):
		self_data["box"] = message["box"]
	if message.has("money"):
		self_data["money"] = message["money"]
	if message.has("wins"):
		self_data["wins"] = message["wins"]
	if message.has("inventory"):
		self_data["inventory"] = message["inventory"]
	if message.has("pokedex") and message["pokedex"] is Dictionary:
		self_data["pokedex"] = message["pokedex"]
		var pokedex: Dictionary = message["pokedex"]
		hud.set_pokedex(pokedex.get("seen", []), pokedex.get("caught", []))
	max_party = int(message.get("maxParty", max_party))
	max_box = int(message.get("maxBox", max_box))
	_refresh_progress()

func _on_pokedex_state(message: Dictionary) -> void:
	var seen: Array = message.get("seen", []) if message.get("seen", []) is Array else []
	var caught: Array = message.get("caught", []) if message.get("caught", []) is Array else []
	var entries: Array = (
		message.get("entries", [])
		if message.get("entries", []) is Array
		else []
	)
	self_data["pokedex"] = {"seen": seen, "caught": caught}
	hud.set_pokedex(seen, caught, entries, int(message.get("total", 649)))

func _on_pokedex_requested() -> void:
	if net != null and net.is_open() and state == GameState.WORLD:
		net.send_message({"type": "pokedex_request"})

func _on_move_learn_request(message: Dictionary) -> void:
	pending_learn_request = message.duplicate(true)
	_show_pending_learn_if_ready()

func _show_pending_learn_if_ready() -> void:
	if pending_learn_request.is_empty():
		return
	if state != GameState.WORLD or battle_ui.visible:
		return
	if hud == null or hud.menu_open:
		return
	var request := pending_learn_request
	pending_learn_request = {}
	chat_ui.close_input()
	touch_dir = ""
	hud.show_move_learn(request)

func _on_move_learn_choice(
	source: String,
	index: int,
	move_id: String,
	replace_index: int
) -> void:
	if net == null or not net.is_open():
		return
	var message := {
		"type": "learn_move",
		"source": source,
		"index": index,
		"moveId": move_id,
		"replaceIndex": replace_index
	}
	net.send_message(message)

func _on_forget_move_requested(party_index: int, move_index: int) -> void:
	if state != GameState.WORLD or net == null or not net.is_open():
		return
	net.send_message({
		"type": "forget_move",
		"partyIndex": party_index,
		"moveIndex": move_index
	})

func _refresh_progress() -> void:
	hud.set_self(
		self_name,
		int(self_data.get("money", 0)),
		int(self_data.get("wins", 0)),
		self_data
	)
	hud.set_party(self_data.get("party", []), max_party)
	hud.set_inventory(self_data.get("inventory", {}))

func _on_shop_state(message: Dictionary) -> void:
	if message.has("money"):
		self_data["money"] = message["money"]
	if message.has("inventory"):
		self_data["inventory"] = message["inventory"]
	_refresh_progress()
	if shop_ui.visible and state == GameState.SHOP:
		shop_ui.update_shop(message)
		return
	if state == GameState.DIALOGUE:
		dialogue_ui.close()
	state = GameState.SHOP
	touch_dir = ""
	touch_ui.visible = false
	chat_ui.close_input()
	chat_ui.visible = false
	hud.close_menu()
	hud.set_dialogue_mode(false)
	hud.set_nearby_npc({})
	hud.set_hint("")
	shop_ui.show_shop(message)

func _on_pc_state(message: Dictionary) -> void:
	if message.has("party"):
		self_data["party"] = message["party"]
	if message.has("box"):
		self_data["box"] = message["box"]
	max_party = int(message.get("maxParty", max_party))
	max_box = int(message.get("maxBox", max_box))
	_refresh_progress()
	if pc_ui.visible and state == GameState.PC:
		pc_ui.update_pc(message)
		return
	if state == GameState.DIALOGUE:
		dialogue_ui.close()
	state = GameState.PC
	touch_dir = ""
	touch_ui.visible = false
	chat_ui.close_input()
	chat_ui.visible = false
	hud.close_menu()
	hud.set_dialogue_mode(false)
	hud.set_nearby_npc({})
	hud.set_hint("")
	pc_ui.show_pc(message)

func _on_shop_requested(message: Dictionary) -> void:
	if net.is_open():
		net.send_message(message)

func _on_pc_requested(message: Dictionary) -> void:
	if net.is_open():
		net.send_message(message)

func _on_hud_item_use(item_id: String, party_index: int) -> void:
	if state != GameState.WORLD or not net.is_open():
		return
	net.send_message({
		"type": "use_item",
		"itemId": item_id,
		"partyIndex": party_index
	})

func _on_shop_closed() -> void:
	if state != GameState.SHOP:
		return
	state = GameState.WORLD
	chat_ui.visible = true
	touch_ui.visible = _touch_enabled()
	hud.set_hint(_default_hint())
	_show_pending_learn_if_ready()

func _on_pc_closed() -> void:
	if state != GameState.PC:
		return
	state = GameState.WORLD
	chat_ui.visible = true
	touch_ui.visible = _touch_enabled()
	hud.set_hint(_default_hint())
	_show_pending_learn_if_ready()

func _on_battle_start(message: Dictionary) -> void:
	current_battle = message["battle"]
	max_party = int(current_battle.get("maxParty", max_party))
	var battle_season := "autumn"
	if world3d != null and str(world3d.season) != "":
		battle_season = str(world3d.season)
	var battle_indoor := _is_rom_map(current_map_id) and current_map_id.begins_with("unova_in_")
	battle_ui.set_environment(battle_season, battle_indoor)
	battle_ui.show_battle(current_battle)
	state = GameState.BATTLE
	if auto_battle:
		auto_battle_phase = 1
		auto_battle_at = Time.get_ticks_msec() + 900
	chat_ui.close_input()
	chat_ui.visible = false
	touch_ui.visible = false
	touch_dir = ""
	dialogue_ui.close()
	hud.close_menu()
	hud.set_dialogue_mode(false)
	hud.set_nearby_npc({})
	hud.set_hint("")
	if shop_ui != null and shop_ui.visible:
		shop_ui.close()
	if pc_ui != null and pc_ui.visible:
		pc_ui.close()

func _on_battle_turn(message: Dictionary) -> void:
	current_battle = message["battle"]
	battle_ui.update_battle(current_battle)

func _on_battle_end(message: Dictionary) -> void:
	var player_info: Dictionary = message.get("player", {})
	for key in ["money", "wins", "party", "inventory", "pokedex", "mapId", "x", "y", "dir"]:
		if player_info.has(key):
			self_data[key] = player_info[key]
	if player_info.has("pokedex") and player_info["pokedex"] is Dictionary:
		var pokedex: Dictionary = player_info["pokedex"]
		hud.set_pokedex(pokedex.get("seen", []), pokedex.get("caught", []))
	var result := str(message.get("result", ""))
	if result == "caught":
		var snapshot: Dictionary = (
			message.get("battle", {})
			if message.get("battle", {}) is Dictionary
			else {}
		)
		var wild: Dictionary = (
			snapshot.get("wild", {})
			if snapshot.get("wild", {}) is Dictionary
			else {}
		)
		pending_capture = wild.duplicate(true)
		_refresh_progress()
		battle_ui.finish_caught()
		return
	if message.has("battle"):
		current_battle = message["battle"]
		battle_ui.update_battle(current_battle)
	_refresh_progress()
	battle_ui.show_result(result, str(message.get("message", "")))

func _on_battle_closed() -> void:
	current_battle.clear()
	battle_ui.visible = false
	get_viewport().gui_release_focus()
	chat_ui.visible = true
	touch_ui.visible = _touch_enabled()
	hud.set_hint(_default_hint())
	if not pending_capture.is_empty():
		var caught := pending_capture
		pending_capture = {}
		state = GameState.CAPTURE_CARD
		hud.show_capture_card(caught)
		return
	state = GameState.WORLD
	_show_pending_learn_if_ready()

func _on_capture_card_closed() -> void:
	state = GameState.WORLD
	hud.set_hint(_default_hint())
	_show_pending_learn_if_ready()

func _on_notice(message: Dictionary) -> void:
	var text := str(message.get("message", message.get("text", "")))
	if text == "":
		return
	hud.show_notice(text)
	if auto_mode:
		print("[auto] notice: %s" % text)

func _on_pong(message: Dictionary) -> void:
	var sent := int(message.get("t", 0))
	if sent > 0:
		var now := Time.get_ticks_msec()
		hud.set_ping(maxi(0, now - sent))

func _on_error(message: Dictionary) -> void:
	var error_text := str(message.get("message", "Server error."))
	print("[net] error: %s" % error_text)

	if error_text.contains("Signed in from another connection"):
		_clear_session()
		state = GameState.LOGIN
		net.close_socket()
		battle_ui.visible = false
		loading_overlay.visible = false
		reconnect_overlay.visible = false
		if shop_ui != null:
			shop_ui.visible = false
		if pc_ui != null:
			pc_ui.visible = false
		world.visible = false
		hud.visible = false
		chat_ui.visible = false
		touch_ui.visible = false
		create_ui.visible = false
		login_ui.visible = true
		login_ui.set_busy(false)
		login_ui.set_status(error_text, true)
		login_ui.set_server_url(server_url)
		return

	if auto_mode:
		if error_text.contains("already registered") and not auto_login_fallback:
			auto_login_fallback = true
			pending_auth["mode"] = "login"
			_send_pending_auth()
			return
		if error_text.contains("name is already taken"):
			auto_character = (auto_character + str(Time.get_ticks_msec() % 10)).substr(0, 16)
			_auto_create_character()
			return
		if state == GameState.LOGIN or state == GameState.CREATE or state == GameState.ENTERING:
			print("[auto] fatal auth error")
			get_tree().quit(1)
		return

	if state == GameState.RECONNECTING:
		_give_up_reconnect(error_text)
		return

	if state == GameState.BATTLE and battle_ui != null:
		battle_ui.reset_after_error()

	match state:
		GameState.LOGIN:
			login_ui.set_busy(false)
			login_ui.set_status(error_text, true)
		GameState.CREATE:
			create_ui.set_busy(false)
			create_ui.set_status(error_text, true)
		GameState.ENTERING:
			loading_overlay.visible = false
			state = GameState.LOGIN
			login_ui.visible = true
			login_ui.set_busy(false)
			login_ui.set_status(error_text, true)
		_:
			if state == GameState.SHOP and shop_ui != null:
				shop_ui.show_error(error_text)
			elif state == GameState.PC and pc_ui != null:
				pc_ui.show_error(error_text)
			hud.show_notice(error_text)
			chat_ui.add_system(error_text)

func _on_dialogue_closed() -> void:
	if state != GameState.DIALOGUE:
		return
	state = GameState.WORLD
	touch_ui.visible = _touch_enabled()
	chat_ui.visible = true
	hud.set_dialogue_mode(false)
	hud.set_hint(_default_hint())
	_show_pending_learn_if_ready()

func _on_chat_submitted(text: String) -> void:
	if state == GameState.WORLD and net.is_open():
		net.send_message({"type": "chat", "text": text})

func _on_touch_dir(direction: String) -> void:
	touch_dir = direction

func _on_touch_interact() -> void:
	if state == GameState.DIALOGUE:
		dialogue_ui.advance()
	elif state == GameState.WORLD:
		_interact()

func _on_touch_chat() -> void:
	if state == GameState.WORLD and not chat_ui.is_input_open():
		chat_ui.open_input()

func _on_hud_menu_state(open: bool) -> void:
	if open:
		touch_dir = ""
		chat_ui.close_input()
		touch_ui.visible = false
	elif state == GameState.WORLD and _touch_enabled():
		touch_ui.visible = true
	if not open:
		_show_pending_learn_if_ready()

func _on_chat_timestamps_changed(enabled: bool) -> void:
	chat_ui.set_timestamps(enabled)

func _on_battle_action(action: String, value: int, item_id: String = "") -> void:
	if state != GameState.BATTLE or current_battle.is_empty():
		return
	var message := {
		"type": "battle_action",
		"battleId": str(current_battle.get("id", "")),
		"action": action
	}
	if action == "move":
		message["moveIndex"] = value
	elif action == "switch":
		message["partyIndex"] = value
	elif action == "catch":
		message["itemId"] = item_id
	net.send_message(message)

func _on_battle_item(item_id: String, party_index: int) -> void:
	if state != GameState.BATTLE or current_battle.is_empty():
		return
	net.send_message({
		"type": "battle_action",
		"battleId": str(current_battle.get("id", "")),
		"action": "item",
		"itemId": item_id,
		"partyIndex": party_index
	})

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()

	var ui_create_ready := auto_ui_create and state == GameState.CREATE
	if ui_create_ready and auto_ui_submit_at > 0 and now >= auto_ui_submit_at:
		auto_ui_submit_at = 0
		create_ui.submit_for_test()

	if state == GameState.RECONNECTING and now >= next_reconnect_at:
		if not net.is_open() and not net.is_connecting():
			if reconnect_attempts >= 20:
				_give_up_reconnect(Loc.t("Could not reconnect to the server."))
				return
			reconnect_attempts += 1
			Loc.bind(reconnect_label, "Reconnecting... (attempt %d)", [reconnect_attempts])
			_begin_auth("resume", "", "", server_url)
			next_reconnect_at = now + 2000

	if state == GameState.WORLD and _can_control():
		var direction := _read_direction()
		var action := _movement_input_action(
			direction, _self_facing(), _self_is_moving(), now, next_step_at
		)
		if action == "turn":
			_turn_self(direction)
			# Turning is its own beat: a held direction starts walking once the
			# turn has registered, and a short tap stops here so the following
			# press is the one that moves.
			next_step_at = now + TURN_CONFIRM_MS
		elif action == "move":
			var running := _is_rom_map(current_map_id) and Input.is_key_pressed(KEY_SHIFT)
			var moved := _try_move(direction, running)
			if not moved:
				# A held direction should not wait a full movement interval
				# just because the previous tile is still finishing or the
				# character is facing a wall.
				next_step_at = now + (
					16 if _self_is_moving() else BLOCKED_STEP_RETRY_MS
				)
			else:
				next_step_at = now + (
					RUN_STEP_INTERVAL_MS if running else STEP_INTERVAL_MS
				)

	if net.is_open() and (state == GameState.WORLD or state == GameState.BATTLE):
		if now >= next_ping_at:
			next_ping_at = now + PING_INTERVAL_MS
			net.send_message({"type": "ping", "t": now})

	_update_hud_context(now)
	_update_world_time(now)
	_process_auto(now)
	_process_auto_battle(now)
	_process_auto_reconnect(now)
	_process_auto_sequence(now)
	_process_debug(now)

func _process_debug(now: int) -> void:
	if not debug_keep:
		return
	if not debug_foreground_set and state == GameState.WORLD:
		debug_foreground_set = true
		DisplayServer.window_move_to_foreground()
	if (
		debug_shot_path != ""
		and state == GameState.WORLD
		and now >= debug_shot_at
	):
		debug_shot_at = now + 2000
		var image := get_viewport().get_texture().get_image()
		var error := image.save_png(debug_shot_path)
		if error == OK:
			print("[debug] live shot saved to %s" % debug_shot_path)
		else:
			print("[debug] live shot failed: %d" % error)

func _update_world_time(now: int, force: bool = false) -> void:
	if not force and now < _next_world_time_at:
		return
	_next_world_time_at = now + 400
	var hours := WorldTimeScript.now_hours()
	var indoor := _is_rom_map(current_map_id) and current_map_id.begins_with("unova_in_")
	if _world_tint_rect != null:
		_world_tint_rect.color = WorldTimeScript.world_tint(hours, indoor)
	if _world_tint_layer != null:
		_world_tint_layer.visible = has_world
	if world3d != null:
		world3d.set_world_time(hours, indoor)
	if hud != null:
		hud.set_world_time(hours)
	if battle_ui != null and battle_ui.visible:
		battle_ui.set_world_time(hours)

func _update_hud_context(now: int) -> void:
	if hud == null or not hud.visible:
		return
	if state != GameState.WORLD:
		hud.set_nearby_npc({})
		return
	if now < next_npc_poll_at:
		return
	next_npc_poll_at = now + 140
	if chat_ui.is_input_open() or hud.menu_open:
		hud.set_nearby_npc({})
		return
	var npc: Dictionary = {}
	if _is_rom_map(current_map_id):
		npc = world3d.nearest_npc(2)
	else:
		npc = world.nearest_npc(2)
	hud.set_nearby_npc(npc)

func _can_control() -> bool:
	return (
		state == GameState.WORLD
		and not loading_overlay.visible
		and not chat_ui.is_input_open()
		and not dialogue_ui.visible
		and not battle_ui.visible
		and not (shop_ui != null and shop_ui.visible)
		and not (pc_ui != null and pc_ui.visible)
		and not (hud != null and hud.menu_open)
	)

func _read_direction() -> String:
	if touch_dir != "":
		return touch_dir
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		return "up"
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		return "down"
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		return "left"
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		return "right"
	return ""

# The original games make the first press of a direction turn in place and only
# step on the next press (or while the key stays held past the turn delay).
func _movement_input_action(
	direction: String,
	facing: String,
	moving: bool,
	now: int,
	step_at: int
) -> String:
	if direction == "":
		return ""
	if direction != facing:
		# Do not rotate in the middle of a step; the turn happens when it ends.
		return "" if moving else "turn"
	if now >= step_at:
		return "move"
	return ""

func _self_facing() -> String:
	if _is_rom_map(current_map_id):
		return world3d.self_facing
	return world.self_facing()

func _self_is_moving() -> bool:
	if _is_rom_map(current_map_id):
		return world3d.is_self_moving()
	return world.is_self_moving()

func _turn_self(direction: String) -> void:
	if _is_rom_map(current_map_id):
		world3d.turn_self(direction)
	else:
		world.turn_self(direction)
	if net.is_open():
		net.send_message({"type": "turn", "dir": direction})

func _try_move(direction: String, running: bool = false) -> bool:
	if not _can_control():
		return false
	var use_run := running and _is_rom_map(current_map_id)
	var predicted := false
	if _is_rom_map(current_map_id):
		predicted = world3d.predict_self_move(direction, use_run)
	else:
		predicted = world.predict_self_move(direction)
	if not predicted:
		# Standing in a doorway and pushing into the wall walks through the
		# door. Let the server decide; it knows which wide door tiles exist.
		var can_push := false
		if _is_rom_map(current_map_id):
			can_push = world3d.try_portal_push(direction)
		else:
			can_push = world.try_portal_push(direction)
		if not can_push:
			return false
		var now := Time.get_ticks_msec()
		if now < next_portal_push_at:
			return false
		next_portal_push_at = now + 400
	if _is_rom_map(current_map_id):
		hud.update_self_position(world3d.self_grid.x, world3d.self_grid.y, direction)
	else:
		hud.update_self_position(world.self_grid.x, world.self_grid.y, direction)
	move_seq += 1
	last_move_seq = move_seq
	net.send_message({"type": "move", "dir": direction, "seq": move_seq, "run": use_run})
	return true

func _interact() -> void:
	var npc: Dictionary = {}
	if _is_rom_map(current_map_id):
		npc = world3d.nearest_npc(2)
	else:
		npc = world.nearest_npc(2)
	if npc.is_empty():
		hud.show_notice("Nobody is close enough to talk to.")
		return
	net.send_message({"type": "interact", "npcId": str(npc.get("id", ""))})

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var key := (event as InputEventKey).keycode

	if key == KEY_ESCAPE:
		if state == GameState.CAPTURE_CARD and hud != null:
			hud.close_capture_card()
			get_viewport().set_input_as_handled()
			return
		if shop_ui != null and shop_ui.visible:
			shop_ui.close()
			get_viewport().set_input_as_handled()
		elif pc_ui != null and pc_ui.visible:
			pc_ui.close()
			get_viewport().set_input_as_handled()
		elif hud != null and hud.close_menu():
			get_viewport().set_input_as_handled()
		elif chat_ui.is_input_open():
			chat_ui.close_input()
			get_viewport().set_input_as_handled()
		elif dialogue_ui.visible:
			dialogue_ui.advance()
			get_viewport().set_input_as_handled()
		return

	if hud != null and hud.menu_open:
		return

	if state == GameState.DIALOGUE:
		if key == KEY_E or key == KEY_SPACE or key == KEY_ENTER:
			dialogue_ui.advance()
			get_viewport().set_input_as_handled()
		return

	if state != GameState.WORLD:
		return

	if chat_ui.is_input_open():
		return

	if key == KEY_T or key == KEY_ENTER:
		chat_ui.open_input()
		get_viewport().set_input_as_handled()
	elif key == KEY_E or key == KEY_SPACE:
		_interact()
		get_viewport().set_input_as_handled()

func _give_up_reconnect(message: String) -> void:
	_clear_session()
	state = GameState.LOGIN
	has_world = false
	reconnect_succeeded = false
	reconnect_overlay.visible = false
	loading_overlay.visible = false
	battle_ui.visible = false
	if shop_ui != null:
		shop_ui.visible = false
	if pc_ui != null:
		pc_ui.visible = false
	world.visible = false
	if hud != null:
		hud.close_menu()
		hud.set_nearby_npc({})
	hud.visible = false
	chat_ui.visible = false
	touch_ui.visible = false
	create_ui.visible = false
	login_ui.visible = true
	login_ui.set_busy(false)
	login_ui.set_status(message, true)
	login_ui.set_server_url(server_url)
	if account_username != "":
		login_ui.set_username(account_username)
	pending_auth.clear()

func _process_auto_reconnect(now: int) -> void:
	if not auto_mode or not auto_reconnect or auto_done:
		return
	if auto_reconnect_phase == 0 and state == GameState.WORLD:
		auto_reconnect_phase = 1
		auto_reconnect_at = now + 1500
	elif auto_reconnect_phase == 1 and now >= auto_reconnect_at:
		auto_reconnect_phase = 2
		auto_reconnect_at = now + 2500
		print("[auto] dropping the socket to test reconnect")
		net.debug_drop()
	elif auto_reconnect_phase == 2 and state == GameState.WORLD and now >= auto_reconnect_at:
		auto_reconnect_phase = 3
		auto_done = true
		_auto_finish()

func _process_auto_battle(now: int) -> void:
	if not auto_mode or not auto_battle or auto_done:
		return
	if auto_battle_phase == 1 and now >= auto_battle_at:
		auto_battle_phase = 2
		auto_battle_at = now + 1200
		if not current_battle.is_empty() and net.is_open():
			net.send_message({
				"type": "battle_action",
				"battleId": str(current_battle.get("id", "")),
				"action": "move",
				"moveIndex": 0
			})
	elif auto_battle_phase == 2 and now >= auto_battle_at:
		auto_done = true
		_auto_finish()

func _process_auto_sequence(now: int) -> void:
	if not auto_sequence or auto_done or state != GameState.WORLD:
		return
	if auto_sequence_next_at == 0 or now < auto_sequence_next_at:
		return
	if auto_sequence_index >= auto_sequence_count:
		auto_done = true
		print("[auto] sequence finished")
		get_tree().quit()
		return
	var directory := auto_sequence_dir if auto_sequence_dir != "" else "F:/AgentProject/BWMMO/.tools/run-seq"
	DirAccess.make_dir_recursive_absolute(directory)
	var path := "%s/run_%03d.png" % [directory, auto_sequence_index]
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	print("[auto] sequence frame %d -> %s (error %d)" % [auto_sequence_index, path, error])
	auto_sequence_index += 1
	auto_sequence_next_at = now + auto_sequence_interval

func _process_auto(now: int) -> void:
	if not auto_mode or not auto_moving or auto_done:
		return
	if (
		state != GameState.WORLD
		and not (auto_dialogue and state == GameState.DIALOGUE)
		and not (auto_route1 and state == GameState.BATTLE)
	):
		return
	if auto_run_capture and auto_capture_at > 0 and now >= auto_capture_at:
		auto_done = true
		if debug_keep:
			auto_moving = false
			print("[debug] staying in world after capture path")
		else:
			_auto_finish()
		return
	if auto_route1 and state == GameState.BATTLE:
		if auto_finish_at == 0:
			auto_finish_at = now + 2500
		elif now >= auto_finish_at:
			auto_done = true
			_auto_finish()
		return
	if now < auto_step_at:
		return
	if auto_step_index < auto_path.size():
		var auto_moved := _try_move(str(auto_path[auto_step_index]), auto_run)
		if not auto_moved and _self_is_moving():
			auto_step_at = now + 16
			return
		auto_step_index += 1
		auto_step_at = now + (RUN_STEP_INTERVAL_MS if auto_run else STEP_INTERVAL_MS) + 20
		return
	if auto_finish_at == 0:
		if not auto_chat_sent:
			auto_chat_sent = true
			if net.is_open():
				if auto_dialogue:
					net.send_message({"type": "interact", "npcId": "bianca"})
				elif auto_grove:
					net.send_message({"type": "chat", "text": "Whispering Grove is online!"})
				else:
					net.send_message({"type": "chat", "text": "Hello from the other client!"})
		auto_finish_at = now + 1600
		return
	if now >= auto_finish_at:
		auto_done = true
		if debug_keep:
			auto_moving = false
			print("[debug] staying in world at %s (%d,%d)" % [
				current_map_id, self_data.get("x", 0), self_data.get("y", 0)
			])
		else:
			_auto_finish()

func _capture_login_screenshot() -> void:
	login_ui.visible = true
	login_ui.focus_username()
	_capture_screen_and_quit("user://login.png")

func _capture_screen_and_quit(fallback_path: String = "user://capture.png") -> void:
	if DisplayServer.get_name() == "headless":
		print("[capture] headless mode: screenshot skipped")
		get_tree().quit()
		return
	await get_tree().create_timer(1.2).timeout
	await RenderingServer.frame_post_draw
	var path := screenshot_path if screenshot_path != "" else fallback_path
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	print("[capture] screenshot saved to %s (error %d)" % [path, error])
	get_tree().quit()

func _auto_finish() -> void:
	if debug_keep:
		auto_done = true
		auto_moving = false
		print("[debug] staying in world (auto finish suppressed)")
		return
	if DisplayServer.get_name() == "headless":
		print("[auto] headless mode: screenshot skipped")
		if world3d != null:
			var deadline := Time.get_ticks_msec() + 15000
			while not world3d.pending_chunks.is_empty() and Time.get_ticks_msec() < deadline:
				await get_tree().process_frame
			print(
				"[auto] map=%s chunks loaded=%d pending=%d"
				% [current_map_id, world3d.loaded_chunks.size(), world3d.pending_chunks.size()]
			)
		get_tree().quit()
		return
	if screenshot_path != "":
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image()
		var error := image.save_png(screenshot_path)
		print("[auto] screenshot saved to %s (error %d)" % [screenshot_path, error])
	print("[auto] finished")
	await get_tree().create_timer(0.2).timeout
	get_tree().quit()
