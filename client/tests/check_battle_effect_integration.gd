extends SceneTree

const BattleUIScript = preload("res://scripts/battle_ui.gd")

func _init() -> void:
	call_deferred("_run")

func _make_battle(events: Array, hp: int, awaiting: bool, status: String) -> Dictionary:
	var player := {
		"species": "snivy", "name": "Snivy", "level": 5,
		"types": ["Grass"], "hp": 19, "maxHp": 19,
		"xp": 30, "xpToNext": 80, "gender": "female",
		"moves": [{
			"name": "Pound", "type": "Normal", "power": 40,
			"pp": 35, "currentPp": 35, "maxPp": 35
		}]
	}
	var wild := {
		"species": "patrat", "name": "Patrat", "level": 4,
		"types": ["Normal"], "hp": hp, "maxHp": 16, "gender": "male",
		"moves": [{
			"name": "Tackle", "type": "Normal", "power": 40,
			"pp": 35, "currentPp": 35, "maxPp": 35
		}]
	}
	return {
		"wild": wild,
		"player": player,
		"party": [player],
		"activeIndex": 0,
		"turn": 2,
		"status": status,
		"awaitingAction": awaiting,
		"mustSwitch": false,
		"inventory": {"items": {"poke_ball": 10}},
		"maxParty": 6,
		"events": events,
		"log": ["A wild Patrat appeared!", "Go! Snivy!"]
	}

func _run() -> void:
	var failures := 0
	root.size = Vector2i(960, 540)
	var battle_ui: Control = BattleUIScript.new()
	root.add_child(battle_ui)
	battle_ui.set_environment("spring", false)
	battle_ui.set_items([])
	var battle := _make_battle([], 16, true, "active")
	battle_ui.show_battle(battle)
	await process_frame
	battle_ui._cancel_entry()
	battle_ui._set_awaiting(true)

	var events := [
		{
			"type": "move", "side": "player", "moveId": 1, "moveName": "Pound",
			"moveType": "Normal", "moveCategory": "physical", "target": "wild"
		},
		{"type": "damage", "side": "wild", "amount": 5, "hp": 11, "maxHp": 16}
	]
	var next := _make_battle(events, 11, true, "active")
	battle_ui.update_battle(next)
	await process_frame
	if not battle_ui._turn_animating:
		push_error("battle UI did not enter the animation lock")
		failures += 1
	var started := Time.get_ticks_msec()
	while battle_ui._turn_animating and Time.get_ticks_msec() - started < 8000:
		await process_frame
	if battle_ui._turn_animating:
		push_error("battle UI animation lock did not clear")
		failures += 1
	if not battle_ui._awaiting:
		push_error("battle UI did not return to the command menu")
		failures += 1
	if int(battle_ui._enemy_plate._target_hp) != 11:
		push_error("enemy plate did not receive the event HP")
		failures += 1
	if battle_ui._enemy_creature.position != battle_ui._actor_fx.actor_home["wild"]:
		push_error("enemy sprite was left displaced after the turn")
		failures += 1

	var final_events := [
		{
			"type": "move", "side": "player", "moveId": 1, "moveName": "Pound",
			"moveType": "Normal", "moveCategory": "physical", "target": "wild"
		},
		{"type": "damage", "side": "wild", "amount": 11, "hp": 0, "maxHp": 16},
		{"type": "faint", "side": "wild"}
	]
	var final_battle := _make_battle(final_events, 0, false, "won")
	battle_ui.update_battle(final_battle)
	battle_ui.show_result("won", "You won 60 coins!")
	await process_frame
	if battle_ui._end_overlay.visible:
		push_error("result overlay appeared before the move animation finished")
		failures += 1
	started = Time.get_ticks_msec()
	while battle_ui._turn_animating and Time.get_ticks_msec() - started < 8000:
		await process_frame
	if not battle_ui._end_overlay.visible:
		push_error("result overlay did not appear after the animation")
		failures += 1
	print("[battle-effects-ui] %s" % ("FAILED" if failures > 0 else "PASSED"))
	quit(1 if failures > 0 else 0)
