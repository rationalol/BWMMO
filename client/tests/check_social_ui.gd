extends Node

# Headless social panel smoke test. Run with:
#   godot --headless --path client res://tests/SocialUITest.tscn
#
# The scene wrapper matters: `--script` mode does not instantiate the Loc
# autoload, so hud.gd would fail to compile with that runner.

const HudScript = preload("res://scripts/hud.gd")
const ChatUIScript = preload("res://scripts/chat_ui.gd")
const BattleUIScript = preload("res://scripts/battle_ui.gd")

var failures := 0
var _original_locale := "en"

func _ready() -> void:
	_original_locale = Loc.locale
	Loc.set_locale("en")
	call_deferred("_run")

func _run() -> void:
	get_viewport().size = Vector2i(960, 540)
	await get_tree().process_frame

	var hud = HudScript.new()
	add_child(hud)
	await get_tree().process_frame
	hud.set_social_state({
		"friends": [
			{"id": "friend-online", "name": "FionaOnline", "online": true,
			 "mapId": "unova_full", "location": "Route 1"},
			{"id": "friend-offline", "name": "GrantOffline", "online": false}
		],
		"incomingRequests": [
			{"id": "req-in", "name": "NateIncoming", "online": true, "at": 2}
		],
		"outgoingRequests": [
			{"id": "req-out", "name": "HildaOutgoing", "online": true, "at": 1}
		],
		"nearby": [
			{"id": "req-in", "name": "NateIncoming", "distance": 3, "mapId": "unova_full",
			 "location": "Route 1", "friend": false, "requested": false, "incoming": true},
			{"id": "req-out", "name": "HildaOutgoing", "distance": 5, "mapId": "unova_full",
			 "location": "Route 1", "friend": false, "requested": true, "incoming": false},
			{"id": "friend-online", "name": "FionaOnline", "distance": 6, "mapId": "unova_full",
			 "location": "Route 1", "friend": true, "requested": false, "incoming": false},
			{"id": "nearby-add", "name": "AlderNearby", "distance": 9, "mapId": "unova_full",
			 "location": "Route 1", "friend": false, "requested": false, "incoming": false}
		],
		"maxFriends": 50
	})

	var events: Array = []
	hud.friend_requested.connect(
		func(player_id: String) -> void: events.append("request:" + player_id)
	)
	hud.friend_accept_requested.connect(
		func(player_id: String) -> void: events.append("accept:" + player_id)
	)
	hud.friend_decline_requested.connect(
		func(player_id: String) -> void: events.append("decline:" + player_id)
	)
	hud.friend_cancel_requested.connect(
		func(player_id: String) -> void: events.append("cancel:" + player_id)
	)
	hud.friend_remove_requested.connect(
		func(player_id: String) -> void: events.append("remove:" + player_id)
	)
	hud.social_chat_requested.connect(
		func(player_id: String, player_name: String) -> void:
			events.append("chat:%s:%s" % [player_id, player_name])
	)
	hud.duel_requested.connect(
		func(player_id: String) -> void: events.append("duel:" + player_id)
	)
	hud.duel_accept_requested.connect(
		func(player_id: String) -> void: events.append("duel_accept:" + player_id)
	)
	hud.duel_decline_requested.connect(
		func(player_id: String) -> void: events.append("duel_decline:" + player_id)
	)

	hud._open_menu("social")
	await get_tree().process_frame

	_expect(hud.menu_open and hud.current_menu() == "social", "social menu should open")
	_expect(_find_label(hud, "FRIEND REQUESTS 1") != null, "incoming request section missing")
	_expect(_find_label(hud, "SENT REQUESTS 1") != null, "outgoing request section missing")
	_expect(_find_label(hud, "FRIENDS 2/50") != null, "friend count missing")
	_expect(_find_label(hud, "NEARBY TRAINERS") != null, "nearby section missing")
	for expected_name in [
		"FionaOnline", "GrantOffline", "NateIncoming", "HildaOutgoing", "AlderNearby"
	]:
		_expect(_find_label(hud, expected_name) != null, "missing row %s" % expected_name)
	_expect(_find_label(hud, "Online - Route 1") != null, "online friend location missing")
	_expect(_find_label(hud, "Offline") != null, "offline friend status missing")
	_expect(_find_label(hud, "3 steps away - Route 1") != null, "nearby distance missing")
	_expect(_find_label(hud, "Wants to be your friend.") != null, "incoming status missing")
	_expect(_find_label(hud, "Waiting for a response.") != null, "outgoing status missing")

	var buttons: Array = []
	_find_buttons(hud, buttons)
	var button_counts: Dictionary = {}
	var by_text: Dictionary = {}
	for node in buttons:
		var button := node as Button
		button_counts[button.text] = int(button_counts.get(button.text, 0)) + 1
		if not by_text.has(button.text):
			by_text[button.text] = button
	for expected_button in ["ACCEPT", "DECLINE", "CANCEL", "CHAT", "REMOVE", "ADD", "DUEL"]:
		_expect(
			int(button_counts.get(expected_button, 0)) >= 1,
			"missing %s button" % expected_button
		)
	_expect(int(button_counts.get("REMOVE", 0)) == 2, "each friend should offer REMOVE")
	_expect(
		int(button_counts.get("CHAT", 0)) == 5,
		"online friends and nearby trainers should offer CHAT"
	)
	_expect(int(button_counts.get("DUEL", 0)) == 1, "the online friend should offer DUEL")
	for disabled_button in ["FRIEND", "REQUESTED", "PENDING"]:
		var button := by_text.get(disabled_button) as Button
		_expect(
			button != null and button.disabled,
			"%s should be a disabled state button" % disabled_button
		)

	(by_text["ACCEPT"] as Button).emit_signal("pressed")
	(by_text["DECLINE"] as Button).emit_signal("pressed")
	(by_text["CANCEL"] as Button).emit_signal("pressed")
	(by_text["REMOVE"] as Button).emit_signal("pressed")
	(by_text["CHAT"] as Button).emit_signal("pressed")
	(by_text["ADD"] as Button).emit_signal("pressed")
	(by_text["DUEL"] as Button).emit_signal("pressed")
	_expect(events.has("accept:req-in"), "ACCEPT should target the incoming request")
	_expect(events.has("decline:req-in"), "DECLINE should target the incoming request")
	_expect(events.has("cancel:req-out"), "CANCEL should target the outgoing request")
	_expect(events.has("remove:friend-online"), "REMOVE should target the friend")
	_expect(
		events.has("chat:friend-online:FionaOnline"),
		"CHAT should open the friend conversation"
	)
	_expect(events.has("request:nearby-add"), "ADD should target the nearby trainer")
	_expect(events.has("duel:friend-online"), "DUEL should target the online friend")

	# Direct messages render in the Social chat tab, and other peers get unread.
	var chat = ChatUIScript.new()
	chat.visible = true
	add_child(chat)
	await get_tree().process_frame
	chat.open_social_conversation("friend-online", "FionaOnline")
	chat.add_social_message("friend-online", "FionaOnline", "Want to trade later?", false)
	chat.add_social_message("friend-online", "FionaOnline", "Sure, after this battle.", true)
	chat.add_social_message("nearby-add", "AlderNearby", "Hello there", false)
	var social_log: String = chat._social_log.get_parsed_text()
	_expect(
		social_log.contains("FionaOnline: Want to trade later?"),
		"incoming direct message should appear in the conversation"
	)
	_expect(
		social_log.contains("You: Sure, after this battle."),
		"outgoing direct message should appear in the conversation"
	)
	_expect(
		int(chat._social_peer_unread.get("nearby-add", 0)) == 1,
		"a message from another peer should be counted as unread"
	)
	var picker_labels: Array[String] = []
	for index in range(chat._social_picker.item_count):
		picker_labels.append(chat._social_picker.get_item_text(index))
	_expect(
		picker_labels.has("AlderNearby (1)"),
		"the chat picker should show the unread count"
	)

	# Removing all friend/request rows should fall back to the empty states.
	hud.set_social_state({
		"friends": [],
		"incomingRequests": [],
		"outgoingRequests": [],
		"nearby": [],
		"maxFriends": 50
	})
	await get_tree().process_frame
	_expect(_find_label(hud, "FRIENDS 0/50") != null, "empty friend count missing")
	_expect(_find_label(hud, "No friends yet. Add a trainer from the nearby list.") != null,
		"empty friend hint missing")
	_expect(_find_label(hud, "Nobody nearby.") != null, "empty nearby hint missing")

	# An incoming duel opens a modal and emits accept/decline for the target.
	hud.show_duel_request({"fromId": "friend-online", "fromName": "FionaOnline"})
	await get_tree().process_frame
	_expect(hud.duel_request_open(), "duel request modal should open")
	_expect(_find_label(hud._duel_overlay, "Duel request") != null, "duel title missing")
	_expect(
		_find_label(hud._duel_overlay, "FionaOnline wants to duel!") != null,
		"duel request should name the challenger"
	)
	var modal_buttons: Array = []
	_find_buttons(hud._duel_overlay, modal_buttons)
	var modal_by_text: Dictionary = {}
	for node in modal_buttons:
		var button := node as Button
		if not modal_by_text.has(button.text):
			modal_by_text[button.text] = button
	(modal_by_text["ACCEPT"] as Button).emit_signal("pressed")
	_expect(events.has("duel_accept:friend-online"), "ACCEPT should accept the duel")
	_expect(not hud.duel_request_open(), "accepting should close the duel modal")

	hud.show_duel_request({"fromId": "friend-online", "fromName": "FionaOnline"})
	await get_tree().process_frame
	(modal_by_text["DECLINE"] as Button).emit_signal("pressed")
	_expect(events.has("duel_decline:friend-online"), "DECLINE should decline the duel")
	_expect(not hud.duel_request_open(), "declining should close the duel modal")

	Loc.set_locale("zh_CN")
	await get_tree().process_frame
	hud.show_duel_request({"fromId": "friend-online", "fromName": "FionaOnline"})
	await get_tree().process_frame
	_expect(_find_label(hud._duel_overlay, "决斗请求") != null, "duel title should localize")
	_expect(
		_find_label(hud._duel_overlay, "FionaOnline 想和你决斗！") != null,
		"duel body should localize"
	)
	hud.close_duel_request()
	Loc.set_locale("en")
	await get_tree().process_frame

	# A duel battle hides the bag and run commands and uses the duel result label.
	var battle_ui = BattleUIScript.new()
	add_child(battle_ui)
	await get_tree().process_frame
	var duel_state := {
		"id": "duel-ui-test",
		"mode": "duel",
		"playerName": "Hilbert",
		"opponentName": "FionaOnline",
		"party": [_make_creature("snivy", "Snivy", ["Grass"], 19, 19)],
		"activeIndex": 0,
		"player": _make_creature("snivy", "Snivy", ["Grass"], 19, 19),
		"wild": _make_creature("tepig", "Tepig", ["Fire"], 20, 20),
		"log": ["Hilbert and FionaOnline started a duel!"],
		"events": [],
		"turn": 0,
		"awaitingAction": true,
		"mustSwitch": false,
		"status": "active",
		"inventory": {"items": {}},
		"maxParty": 6
	}
	battle_ui.show_battle(duel_state)
	await get_tree().process_frame
	battle_ui._finish_entry()
	await get_tree().process_frame
	var commands: Array[String] = []
	for node in battle_ui._command_row.get_children():
		if node is Button and (node as Button).has_meta("command"):
			commands.append(str((node as Button).get_meta("command")))
	_expect(commands.has("fight"), "duel should offer FIGHT")
	_expect(commands.has("pokemon"), "duel should offer POKéMON")
	_expect(not commands.has("bag"), "duel must hide the bag")
	_expect(not commands.has("run"), "duel must hide RUN")
	battle_ui.show_result("lost", "You lost the duel against FionaOnline.")
	await get_tree().process_frame
	_expect(battle_ui._result_label.text == "Defeated...", "duel loss should not say blacked out")
	battle_ui.queue_free()

	Loc.set_locale(_original_locale)
	print("[social-ui] %s" % ("FAILED" if failures > 0 else "PASSED"))
	get_tree().quit(1 if failures > 0 else 0)

func _make_creature(
	species: String,
	display_name: String,
	types: Array,
	hp: int,
	max_hp: int
) -> Dictionary:
	return {
		"species": species,
		"name": display_name,
		"level": 5,
		"types": types,
		"hp": hp,
		"maxHp": max_hp,
		"gender": "male",
		"status": "",
		"moves": [{
			"id": "tackle",
			"name": "Tackle",
			"type": "Normal",
			"power": 40,
			"currentPp": 35,
			"maxPp": 35
		}]
	}

func _find_label(node: Node, text: String) -> Label:
	if node is Label and node.text == text:
		return node
	for child in node.get_children():
		var found := _find_label(child, text)
		if found != null:
			return found
	return null

func _find_buttons(node: Node, out: Array) -> void:
	if node is Button:
		out.append(node)
	for child in node.get_children():
		_find_buttons(child, out)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("[social-ui] " + message)
