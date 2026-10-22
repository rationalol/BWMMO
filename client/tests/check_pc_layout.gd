extends SceneTree

const PcUIScript = preload("res://scripts/pc_ui.gd")

var failures := 0

func _expect(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failures += 1

func _init() -> void:
	call_deferred("_run")

func _creature(
	display_name: String,
	species: String,
	level: int,
	hp: int,
	max_hp: int,
	status: String = ""
) -> Dictionary:
	return {
		"species": species, "name": display_name, "level": level,
		"types": ["Normal"], "hp": hp, "maxHp": max_hp, "status": status,
		"xp": 0, "xpToNext": 80, "moves": []
	}

func _find_button(node: Node, text: String) -> Button:
	if node is Button and (node as Button).text == text:
		return node
	for child in node.get_children():
		var found := _find_button(child, text)
		if found != null:
			return found
	return null

func _run() -> void:
	root.size = Vector2i(960, 540)
	var pc = PcUIScript.new()
	root.add_child(pc)
	var state := {
		"party": [
			_creature("Snivy", "snivy", 9, 24, 27),
			_creature("Tepig", "tepig", 8, 0, 25, "PSN")
		],
		"box": [
			_creature("Patrat", "patrat", 4, 14, 14),
			_creature("Lillipup", "lillipup", 5, 18, 18)
		],
		"maxParty": 6,
		"maxBox": 30
	}
	pc.show_pc(state)
	await process_frame
	await process_frame

	_expect(pc.visible, "PC should be visible")
	var panel: Control = pc._panel
	_expect(panel != null, "PC panel missing")
	if panel != null:
		var rect := panel.get_global_rect()
		print("[pc-layout] panel %s" % str(rect))
		_expect(rect.position.x >= -0.5 and rect.position.y >= -0.5, "PC panel starts off-screen")
		_expect(rect.end.x <= 960.5 and rect.end.y <= 540.5, "PC panel is larger than the viewport")
	_expect(pc._party_list.get_child_count() == 2, "party list should show two creatures")
	_expect(pc._box_list.get_child_count() == 2, "box list should show two creatures")

	var captured: Array = []
	pc.requested.connect(func(message: Dictionary) -> void: captured.append(message))

	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	pc._on_party_input(event, 1)
	await process_frame
	_expect(pc._selected_party == 1, "clicking a party row should select it")

	var swap := _find_button(pc._box_list, "SWAP")
	_expect(swap != null, "box rows should have a SWAP button")
	if swap != null:
		swap.emit_signal("pressed")
		_expect(captured.size() == 1, "SWAP should emit one request")
		if captured.size() == 1:
			_expect(captured[0].get("type", "") == "pc_swap", "swap request type is wrong")
			_expect(captured[0].get("partyIndex", -1) == 1, "swap party index is wrong")
			_expect(captured[0].get("boxIndex", -1) == 0, "swap box index is wrong")

	captured.clear()
	var take := _find_button(pc._box_list, "TAKE")
	if take != null:
		take.emit_signal("pressed")
		_expect(captured.size() == 1 and captured[0].get("type", "") == "pc_withdraw",
			"TAKE should emit a withdraw request")

	pc.update_pc({
		"party": [_creature("Snivy", "snivy", 9, 24, 27)],
		"box": state["box"],
		"maxParty": 6,
		"maxBox": 30
	})
	await process_frame
	var store := _find_button(pc._party_list, "STORE")
	_expect(store != null, "party rows should have a STORE button")
	if store != null:
		_expect(store.disabled, "STORE must be disabled when only one creature remains")

	pc.close()
	_expect(not pc.visible, "PC should close")
	print("[pc-layout] %s" % ("FAILED" if failures > 0 else "PASSED"))
	quit(1 if failures > 0 else 0)
