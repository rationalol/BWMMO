extends Node

# Headless UI checks for the growth-service panels. Run with:
#   godot --headless --path client res://tests/GrowthUITest.tscn

const MoveServiceUIScript = preload("res://scripts/move_service_ui.gd")
const TradeServiceUIScript = preload("res://scripts/trade_service_ui.gd")
const AbilityServiceUIScript = preload("res://scripts/ability_service_ui.gd")
const BattleUIScript = preload("res://scripts/battle_ui.gd")
const PcUIScript = preload("res://scripts/pc_ui.gd")

var failures: Array[String] = []

func _ready() -> void:
	Loc.set_locale("en")
	await get_tree().process_frame
	await _check_move_service()
	await _check_reminder()
	await _check_trade_service()
	await _check_ability_service()
	await _check_ability_battle_banner()
	await _check_pc_dialogs()
	if failures.is_empty():
		print("[growth-ui] PASSED")
		get_tree().quit(0)
	else:
		for failure in failures:
			push_error(failure)
		print("[growth-ui] FAILED")
		get_tree().quit(1)

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

func _creature(name: String, species: String, moves: Array = []) -> Dictionary:
	return {
		"species": species,
		"name": name,
		"level": 5,
		"hp": 20,
		"maxHp": 20,
		"moves": moves
	}

func _check_move_service() -> void:
	var ui = MoveServiceUIScript.new()
	add_child(ui)
	await get_tree().process_frame
	var seen: Array = []
	ui.teach_requested.connect(func(index: int, move_id: String) -> void: seen.append([index, move_id]))
	ui.show_state({
		"service": "tutor",
		"npcName": "Move Tutor",
		"party": [
			_creature("Ivy", "snivy", [{"id": "tackle", "name": "Tackle", "type": "Normal"}])
		],
		"moves": [
			{"id": "workup", "name": "Work Up", "type": "Normal", "power": 0, "pp": 20},
			{"id": "tackle", "name": "Tackle", "type": "Normal", "power": 40, "pp": 35}
		]
	})
	await get_tree().process_frame
	_check(ui.visible, "tutor panel should be visible")
	var teach_buttons := _find_buttons(ui, "TEACH")
	_check(teach_buttons.size() == 1, "tutor should offer one TEACH button for the unknown move")
	_check(_find_label(ui, "KNOWN") != null, "known tutor move should be marked KNOWN")
	if teach_buttons.size() == 1:
		teach_buttons[0].pressed.emit()
	_check(seen.size() == 1, "TEACH should emit one request")
	_check(seen.size() == 1 and seen[0][0] == 0 and seen[0][1] == "workup", "TEACH should send party index and move id")
	_check(not ui.visible, "tutor panel should close after choosing a move")
	ui.queue_free()

func _check_reminder() -> void:
	var ui = MoveServiceUIScript.new()
	add_child(ui)
	await get_tree().process_frame
	var seen: Array = []
	ui.teach_requested.connect(func(index: int, move_id: String) -> void: seen.append([index, move_id]))
	ui.show_state({
		"service": "reminder",
		"npcName": "Move Reminder",
		"party": [{
			"species": "snivy",
			"name": "Ivy",
			"level": 17,
			"hp": 40,
			"maxHp": 40,
			"moves": [{"id": "tackle", "name": "Tackle", "type": "Normal"}],
			"relearn": [
				{"id": "growth", "name": "Growth", "type": "Normal", "power": 0, "pp": 40}
			]
		}]
	})
	await get_tree().process_frame
	var remember := _find_buttons(ui, "REMEMBER")
	_check(remember.size() == 1, "reminder should offer one REMEMBER button")
	if remember.size() == 1:
		remember[0].pressed.emit()
	_check(seen.size() == 1 and seen[0][1] == "growth", "REMEMBER should emit the relearnable move")
	ui.queue_free()

func _check_trade_service() -> void:
	var ui = TradeServiceUIScript.new()
	add_child(ui)
	await get_tree().process_frame
	var seen: Array = []
	ui.trade_requested.connect(func(index: int) -> void: seen.append(index))
	ui.show_state({
		"npcName": "Link Trade",
		"party": [
			{"species": "kadabra", "name": "Kadabra", "level": 16, "hp": 30, "maxHp": 30, "tradeable": true},
			{"species": "snivy", "name": "Ivy", "level": 5, "hp": 20, "maxHp": 20, "tradeable": false}
		]
	})
	await get_tree().process_frame
	var trade := _find_buttons(ui, "TRADE")
	_check(trade.size() == 1, "trade panel should have one TRADE button")
	if trade.size() == 1:
		trade[0].pressed.emit()
	_check(seen == [0], "TRADE should emit the selected party index")
	_check(not ui.visible, "trade panel should close after trading")
	ui.queue_free()

func _check_ability_service() -> void:
	var ui = AbilityServiceUIScript.new()
	add_child(ui)
	await get_tree().process_frame
	var seen: Array = []
	ui.ability_requested.connect(
		func(index: int, ability_id: String) -> void:
			seen.append([index, ability_id])
	)
	var party_entry := {
		"species": "snivy",
		"name": "Ivy",
		"level": 5,
		"hp": 20,
		"maxHp": 20,
		"ability": "overgrow",
		"abilitySlot": 0,
		"abilityName": "Overgrow",
		"abilityDescription": "Powers up Grass-type moves in a pinch.",
		"abilities": [
			{
				"id": "overgrow", "name": "Overgrow", "slot": 0, "hidden": false,
				"description": "Powers up Grass-type moves in a pinch."
			},
			{
				"id": "contrary", "name": "Contrary", "slot": 2, "hidden": true,
				"description": "Makes stat changes reverse."
			}
		]
	}
	ui.show_state({"npcName": "Ability Expert", "party": [party_entry]})
	await get_tree().process_frame
	_check(ui.visible, "ability panel should be visible")
	_check(_find_label(ui, "CURRENT") != null, "current ability should be marked")
	_check(_find_label(ui, "Contrary") != null, "hidden ability should be listed")
	var switch_buttons := _find_buttons(ui, "SWITCH")
	_check(switch_buttons.size() == 1, "one SWITCH button for the non-current ability")
	if switch_buttons.size() == 1:
		switch_buttons[0].pressed.emit()
	_check(
		seen == [[0, "contrary"]],
		"SWITCH should emit the party index and ability id"
	)
	_check(ui.visible, "ability panel should stay open for more switches")
	var updated := party_entry.duplicate(true)
	updated["ability"] = "contrary"
	updated["abilitySlot"] = 2
	updated["abilityName"] = "Contrary"
	updated["abilityDescription"] = "Makes stat changes reverse."
	ui.update_state({"npcName": "Ability Expert", "party": [updated]})
	await get_tree().process_frame
	_check(
		_find_buttons(ui, "SWITCH").size() == 1,
		"the old ability should now be switchable"
	)
	ui.close()
	_check(not ui.visible, "ability panel should close")
	ui.queue_free()

func _check_ability_battle_banner() -> void:
	var battle_ui = BattleUIScript.new()
	add_child(battle_ui)
	await get_tree().process_frame
	battle_ui.visible = true
	battle_ui._show_ability_banner("Intimidate", "Lowers the foe's Attack.")
	await get_tree().process_frame
	_check(battle_ui._ability_banner.visible, "battle ability banner should open")
	_check(
		battle_ui._ability_name_label.text == "Intimidate",
		"battle ability banner should name the ability"
	)
	_check(
		battle_ui._ability_desc_label.text == "Lowers the foe's Attack.",
		"battle ability banner should show the description"
	)
	battle_ui.queue_free()

func _check_pc_dialogs() -> void:
	var ui = PcUIScript.new()
	add_child(ui)
	await get_tree().process_frame
	var requested: Array = []
	ui.requested.connect(func(message: Dictionary) -> void: requested.append(message.duplicate(true)))
	var party := _creature("Ivy", "snivy", [])
	var boxed := _creature("Patrat", "patrat", [])
	ui.show_pc({"party": [party], "box": [boxed], "maxParty": 6, "maxBox": 30})
	await get_tree().process_frame

	var names := _find_buttons(ui, "NAME")
	_check(names.size() == 2, "party and box rows should both offer NAME")
	if names.size() == 2:
		names[0].pressed.emit()
		var input := _find_line_edit(ui)
		_check(input != null, "rename dialog should contain a LineEdit")
		if input != null:
			input.text = "Ivy Jr"
			_press(ui, "SAVE")
		_check(requested.size() == 1, "SAVE should emit a rename request")
		if requested.size() == 1:
			_check(
				requested[0].get("type") == "rename_creature"
				and requested[0].get("source") == "party"
				and requested[0].get("index") == 0
				and requested[0].get("name") == "Ivy Jr",
				"rename request should carry source/index/name"
			)

	var free := _find_buttons(ui, "FREE")
	_check(free.size() == 1, "box rows should offer FREE")
	if free.size() == 1:
		free[0].pressed.emit()
		_press(ui, "RELEASE")
		_check(requested.size() == 2, "RELEASE should emit a release request")
		if requested.size() == 2:
			_check(
				requested[1].get("type") == "pc_release"
				and requested[1].get("boxIndex") == 0,
				"release request should carry the box index"
			)
	ui.close()
	ui.queue_free()

func _press(root: Node, text: String) -> void:
	var buttons := _find_buttons(root, text)
	if not buttons.is_empty():
		buttons[0].pressed.emit()

func _find_buttons(node: Node, text: String) -> Array:
	var result: Array = []
	if node is Button and (node as Button).text == text:
		result.append(node)
	for child in node.get_children():
		result.append_array(_find_buttons(child, text))
	return result

func _find_label(node: Node, text: String) -> Label:
	if node is Label and (node as Label).text == text:
		return node
	for child in node.get_children():
		var found := _find_label(child, text)
		if found != null:
			return found
	return null

func _find_line_edit(node: Node) -> LineEdit:
	if node is LineEdit:
		return node
	for child in node.get_children():
		var found := _find_line_edit(child)
		if found != null:
			return found
	return null
