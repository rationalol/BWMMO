extends SceneTree

const BattleCreatureScript = preload("res://scripts/battle_creature.gd")

func _init() -> void:
	var failures := 0
	for case in [
		{"id": "snivy", "name": "Snivy", "type": "Grass", "wild": true, "side": "front"},
		{"id": "snivy", "name": "Snivy", "type": "Grass", "wild": false, "side": "back"},
		{"id": "genesect", "name": "Genesect", "type": "Bug", "wild": true, "side": "front"}
	]:
		var creature: Control = BattleCreatureScript.new()
		root.add_child(creature)
		creature.setup(str(case["id"]), str(case["name"]), str(case["type"]), bool(case["wild"]))
		if creature.anim_sheet == null:
			push_error("%s %s animation sheet missing" % [case["id"], case["side"]])
			failures += 1
		elif creature.anim_frame_count <= 0:
			push_error("%s %s has no animation frames" % [case["id"], case["side"]])
			failures += 1
		else:
			var before: int = creature.anim_index
			creature._process(0.5)
			print("[battle-anim] %s %s frame=%d/%d sheet_ok" % [
				case["id"], case["side"], creature.anim_index, creature.anim_frame_count
			])
			if creature.anim_frame_count > 1 and creature.anim_index == before and creature.anim_elapsed == 0.0:
				push_error("%s %s did not advance" % [case["id"], case["side"]])
				failures += 1
		creature.free()
	print("[battle-anim] %s" % ("FAILED" if failures > 0 else "PASSED"))
	quit(1 if failures > 0 else 0)
