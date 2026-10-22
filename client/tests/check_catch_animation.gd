extends Node

# Headless smoke test for the catch presentation sequence. It uses two dummy
# battler Controls and drives the event player directly, so it does not need a
# real battle or server connection.

func _ready() -> void:
	var player := Control.new()
	player.position = Vector2(48, 145)
	player.size = Vector2(380, 260)
	add_child(player)
	var enemy := Control.new()
	enemy.position = Vector2(546, 56)
	enemy.size = Vector2(300, 190)
	add_child(enemy)

	var events = load("res://scripts/battle_event_player.gd").new()
	add_child(events)
	events.setup(null, null, player, enemy, null, null, null, func() -> bool: return true)

	await events._play_catch({
		"type": "catch",
		"itemId": "great_ball",
		"success": false,
		"shakes": 2
	})
	await get_tree().process_frame
	if not enemy.visible:
		push_error("wild creature did not pop back out after a failed catch")
	if player.get_parent().get_children().any(
		func(child: Node) -> bool: return child is TextureRect
	):
		push_error("ball was not removed after a failed catch")

	await events._play_catch({
		"type": "catch",
		"itemId": "poke_ball",
		"success": true,
		"shakes": 3
	})
	await get_tree().process_frame
	if enemy.visible:
		push_error("wild creature should stay hidden after a successful catch")

	print("[catch-animation] PASSED")
	get_tree().quit(0)
