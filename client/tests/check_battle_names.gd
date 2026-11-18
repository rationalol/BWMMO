extends SceneTree

# Trainer battles must never describe the opponent's creature as wild. The
# server already drops the prefix for `mode == "trainer"`, but the event
# narration built its own name and kept "Wild Snivy used Tackle!" alive.

func _init() -> void:
	var failures := 0
	var events = load("res://scripts/battle_event_player.gd").new()
	root.add_child(events)

	var wild := {"name": "Oshawott"}
	events.battle = {
		"mode": "trainer",
		"opponentName": "Bianca",
		"wild": wild,
		"player": {"name": "Tepig"}
	}
	if events._side_name("wild") != "Foe Oshawott":
		push_error("trainer battle named the creature %s" % events._side_name("wild"))
		failures += 1
	if events._side_name("player") != "Tepig":
		push_error("player side should keep its own name")
		failures += 1

	events.battle["mode"] = "duel"
	if events._side_name("wild") != "Bianca's Oshawott":
		push_error("duel battle should use the opponent's name")
		failures += 1

	events.battle["mode"] = "wild"
	if events._side_name("wild") != "Wild Oshawott":
		push_error("wild encounters should still say Wild")
		failures += 1

	events.free()
	if failures == 0:
		print("[battle-names] PASSED")
	quit(0 if failures == 0 else 1)
