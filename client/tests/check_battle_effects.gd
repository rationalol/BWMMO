extends SceneTree

const BattleEffectsScript = preload("res://scripts/battle_effects.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures := 0
	root.size = Vector2i(960, 540)
	var effects: Control = BattleEffectsScript.new()
	root.add_child(effects)
	effects.set_actor_anchors(Vector2(230, 330), Vector2(700, 210))
	await process_frame
	if not effects.has_manifest():
		push_error("battle effect manifest missing; run tools/rom/extract_battle_effects.py")
		failures += 1
	else:
		var pound: Dictionary = effects.move_effect(1)
		if pound.get("sequences", []).is_empty():
			push_error("Pound has no animation sequence")
			failures += 1
		var frame: Dictionary = effects._particle_frame(161, 0)
		if frame.is_empty() or frame.get("texture") == null:
			push_error("effect 161/particle 0 texture missing")
			failures += 1
		else:
			print("[battle-effects] Pound particle region=%s" % str(frame.get("region")))
		effects._spawn_burst(
			[213, 0, 11, 8, 8192, 0, 0, 4096, 4096, 4096, 4096], "player", false
		)
		if effects._particles.is_empty():
			push_error("Ember burst did not spawn a particle")
			failures += 1
		effects._particles.clear()
		effects._spawn_projectile(
			[516, 0, 2, 11, 9, 8192, 188416, 16384, 4096, 4096, 0], "wild", 0
		)
		if effects._particles.is_empty():
			push_error("Covet projectile did not spawn")
			failures += 1
		effects._particles.clear()

		if failures == 0:
			effects.play_move(1, "player", "Normal", "physical")
			var saw_particles := false
			var started := Time.get_ticks_msec()
			while effects.is_playing() and Time.get_ticks_msec() - started < 6000:
				if not effects._particles.is_empty():
					saw_particles = true
				await process_frame
			if not saw_particles:
				push_error("Pound spawned no particles")
				failures += 1
			if effects.is_playing():
				push_error("Pound animation did not finish")
				failures += 1
			else:
				print("[battle-effects] Pound completed")
				effects.play_move(9999, "wild", "Fire", "special")
				saw_particles = false
				started = Time.get_ticks_msec()
				while effects.is_playing() and Time.get_ticks_msec() - started < 3000:
					if not effects._particles.is_empty():
						saw_particles = true
					await process_frame
				if not saw_particles:
					push_error("fallback effect spawned no particles")
					failures += 1
				if effects.is_playing():
					push_error("fallback animation did not finish")
					failures += 1
	print("[battle-effects] %s" % ("FAILED" if failures > 0 else "PASSED"))
	quit(1 if failures > 0 else 0)
