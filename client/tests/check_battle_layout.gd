extends SceneTree

const BattleUIScript = preload("res://scripts/battle_ui.gd")
const FONT_3X_PATH := "res://assets/bw/ui/bw_font_3x.fnt"

func _failures(failures: int, message: String) -> int:
	push_error(message)
	return failures + 1

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures := 0
	if not ResourceLoader.exists(FONT_3X_PATH):
		failures = _failures(failures, "missing battle font %s" % FONT_3X_PATH)
	root.size = Vector2i(960, 540)
	var labels: Array[String] = []
	var battle_ui: Control = BattleUIScript.new()
	root.add_child(battle_ui)
	battle_ui.set_items([
		{"id": "poke_ball", "name": "Poké Ball", "category": "ball", "price": 200, "ballBonus": 1.0},
		{"id": "great_ball", "name": "Great Ball", "category": "ball", "price": 600, "ballBonus": 1.5},
		{"id": "potion", "name": "Potion", "category": "medicine", "price": 300, "heal": 20},
		{"id": "full_heal", "name": "Full Heal", "category": "medicine", "price": 600, "cureStatus": true}
	])
	battle_ui.set_environment("spring", false)
	var moves := [
		{"name": "Tackle", "type": "Normal", "power": 40, "pp": 35, "currentPp": 35, "maxPp": 35},
		{"name": "Vine Whip", "type": "Grass", "power": 35, "pp": 15, "currentPp": 15, "maxPp": 15},
		{"name": "Quick Attack", "type": "Normal", "power": 40, "pp": 30, "currentPp": 30, "maxPp": 30}
	]
	var party := [
		{
			"species": "snivy", "name": "Snivy", "level": 5,
			"types": ["Grass"], "hp": 7, "maxHp": 19,
			"xp": 30, "xpToNext": 80, "gender": "female", "moves": moves
		},
		{
			"species": "tepig", "name": "Tepig", "level": 4,
			"types": ["Fire"], "hp": 18, "maxHp": 18,
			"xp": 0, "xpToNext": 60, "gender": "male", "moves": []
		}
	]
	var battle := {
		"wild": {
			"species": "purrloin", "name": "Purrloin", "level": 4,
			"types": ["Dark"], "hp": 17, "maxHp": 17, "gender": "female"
		},
		"player": party[0],
		"party": party,
		"activeIndex": 0,
		"turn": 1,
		"status": "active",
		"awaitingAction": true,
		"mustSwitch": false,
		"inventory": {
			"items": {"poke_ball": 10, "great_ball": 2, "potion": 1, "full_heal": 1}
		},
		"maxParty": 6,
		"log": ["A wild Purrloin appeared!", "Go! Snivy!"]
	}
	battle_ui.show_battle(battle)
	await process_frame
	battle_ui._cancel_entry()
	battle_ui._set_awaiting(true)
	battle_ui.set_world_time(12.0)
	var day_sprite: Color = battle_ui._enemy_creature.modulate
	battle_ui.set_world_time(23.0)
	var night_sprite: Color = battle_ui._enemy_creature.modulate
	if night_sprite.get_luminance() >= day_sprite.get_luminance():
		failures = _failures(failures, "battle sprites do not darken at night")
	if battle_ui._arena._tint.is_equal_approx(Color(1, 1, 1, 1)):
		failures = _failures(failures, "battle arena tint did not react to night")
	if not is_equal_approx(battle_ui._arena._hours, 23.0):
		failures = _failures(failures, "battle arena did not receive the world hour")
	if not battle_ui._battle_clock.text.begins_with("Night"):
		failures = _failures(failures, "battle clock is %s" % battle_ui._battle_clock.text)
	battle_ui.set_world_time(12.0)
	await process_frame

	if not battle_ui.visible:
		failures = _failures(failures, "battle UI is not visible")
	if battle_ui._font_huge == null or battle_ui._huge_font_size() != 45:
		failures = _failures(failures, "battle font 3x is not active")
	elif battle_ui._font_huge.get_height(45) < 43.0:
		failures = _failures(failures, "battle font line height is wrong")
	if battle_ui._player_plate._huge_size != 45:
		failures = _failures(failures, "battle plate is not using the 3x font")
	if battle_ui._message_primary.get_theme_font_size("font_size") != 45:
		failures = _failures(failures, "message box is not using the 3x font")
	if battle_ui._message_primary.get_combined_minimum_size().y > battle_ui._message_panel.size.y - 6.0:
		failures = _failures(failures, "message text is taller than the box")
	if battle_ui._command_row == null:
		failures = _failures(failures, "command row missing")
	else:
		labels = []
		for child in battle_ui._command_row.get_children():
			if child is Button:
				labels.append((child as Button).text)
		if labels != ["FIGHT", "BAG", "POKéMON", "RUN"]:
			failures = _failures(failures, "command labels are %s" % str(labels))
		for child in battle_ui._command_row.get_children():
			if child is Button and (child as Button).disabled:
				failures = _failures(failures, "command %s should be enabled" % (child as Button).text)
			if child is Button:
				var button := child as Button
				var text_width: float = battle_ui._font_huge.get_string_size(
					button.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 45
				).x
				if text_width > button.size.x - 12.0:
					failures = _failures(failures, "command %s does not fit its button" % button.text)

	var message_rect: Rect2 = battle_ui._message_panel.get_global_rect()
	var command_rect: Rect2 = battle_ui._command_panel.get_global_rect()
	if message_rect.position.y < 300.0 or message_rect.end.y > 540.0:
		failures = _failures(failures, "message box outside the lower battle area: %s" % str(message_rect))
	if command_rect.position.y < message_rect.end.y:
		failures = _failures(failures, "command panel overlaps the message box")
	if command_rect.end.y > 540.0:
		failures = _failures(failures, "command panel is clipped at the bottom: %s" % str(command_rect))
	if battle_ui._player_plate.get_global_rect().end.y > message_rect.position.y:
		failures = _failures(failures, "player plate overlaps the message box")
	if battle_ui._enemy_plate.get_global_rect().end.x > battle_ui._enemy_creature.get_global_rect().position.x:
		failures = _failures(failures, "enemy plate overlaps the wild Pokémon")
	var plate_font: Font = battle_ui._player_plate._font_huge
	var name_width: float = plate_font.get_string_size(
		"Purrloin", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 45
	).x
	var level_width: float = plate_font.get_string_size(
		"♀ Lv.100", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 45
	).x
	if name_width + level_width + 32.0 > battle_ui._player_plate.size.x:
		failures = _failures(failures, "plate name and level do not fit")

	battle_ui._on_fight_pressed()
	await process_frame
	labels.clear()
	for child in battle_ui._command_row.get_children():
		if child is Button:
			labels.append((child as Button).text)
	if labels.size() != 4:
		failures = _failures(failures, "move menu should show 4 buttons, got %s" % str(labels))
	elif not labels[0].begins_with("Tackle"):
		failures = _failures(failures, "first move button is %s" % labels[0])
	elif not labels[0].contains("35/35"):
		failures = _failures(failures, "move button does not show PP: %s" % labels[0])
	elif labels[3] != "BACK":
		failures = _failures(failures, "move menu has no Back button")
	for child in battle_ui._command_row.get_children():
		if not (child is Button):
			continue
		var button := child as Button
		var button_font := button.get_theme_font("font")
		var button_font_size := button.get_theme_font_size("font_size")
		var width: float = button_font.get_string_size(
			button.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, button_font_size
		).x
		if width > button.size.x - 12.0:
			failures = _failures(failures, "move button %s does not fit" % button.text)

	battle_ui._on_back_pressed()
	await process_frame
	battle_ui._on_bag_pressed()
	await process_frame
	labels.clear()
	for child in battle_ui._command_row.get_children():
		if child is Button:
			labels.append((child as Button).text)
	if (
		labels.size() != 4
		or not labels[0].begins_with("Poké Ball")
		or not labels[1].begins_with("Great Ball")
		or not labels[2].begins_with("ITEMS")
		or labels[3] != "BACK"
	):
		failures = _failures(failures, "bag menu is wrong: %s" % str(labels))

	battle_ui._open_item_menu()
	await process_frame
	if not battle_ui._item_overlay.visible:
		failures = _failures(failures, "medicine menu did not open")
	if battle_ui._item_list.get_child_count() != 2:
		failures = _failures(failures, "medicine menu should list two medicines")
	battle_ui._open_item_targets({
		"id": "potion", "name": "Potion", "category": "medicine", "heal": 20
	})
	await process_frame
	if not battle_ui._switch_overlay.visible:
		failures = _failures(failures, "medicine target menu did not open")
	if battle_ui._switch_list.get_child_count() != 2:
		failures = _failures(failures, "medicine target menu should list the party")
	var capture := []
	battle_ui.item_used.connect(func(item_id: String, index: int) -> void:
		capture.append([item_id, index])
	)
	battle_ui._on_party_selected(0)
	if capture.size() != 1 or capture[0][0] != "potion" or capture[0][1] != 0:
		failures = _failures(failures, "medicine use did not emit item_used: %s" % str(capture))
	battle_ui._hide_switch_menu()
	battle_ui._on_back_pressed()
	await process_frame

	battle_ui._set_awaiting(false)
	await process_frame
	for child in battle_ui._command_row.get_children():
		if child is Button and not (child as Button).disabled:
			failures = _failures(failures, "button %s should be disabled while waiting" % (child as Button).text)

	print("[battle-layout] %s" % ("FAILED" if failures > 0 else "PASSED"))
	quit(1 if failures > 0 else 0)
