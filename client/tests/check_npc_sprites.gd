extends SceneTree

const ViewScript = preload("res://scripts/nuvema_online.gd")

func _init() -> void:
	var failures := 0
	var world: Node3D = ViewScript.new()
	root.add_child(world)

	# Player character ids keep using the four shared field actors.
	if world._actor_key(0) != "hero":
		push_error("sprite 0 should use the hero actor")
		failures += 1
	if world._actor_key(1) != "heroine":
		push_error("sprite 1 should use the heroine actor")
		failures += 1
	if world._actor_key(2) != "boy4":
		push_error("sprite 2 should use the boy4 actor")
		failures += 1
	if world._actor_key(3) != "girl2":
		push_error("sprite 3 should use the girl2 actor")
		failures += 1
	if world._actor_key(-1) != "hero":
		push_error("missing sprite id should fall back to hero")
		failures += 1

	# NPC model ids resolve to extracted overworld sheets when they exist.
	# 12/135/110/109 are the prologue's Cheren/Bianca/Juniper/Cedric sheets;
	# they were the ones that silently rendered as floating name labels.
	for sprite_id in [12, 109, 110, 135, 83, 144]:
		var path := "res://assets/bw/overworld/npc_%d/actor.json" % sprite_id
		if not FileAccess.file_exists(path):
			print("SKIP npc_%d (extract assets first)" % sprite_id)
			continue
		var key: String = world._actor_key(sprite_id)
		if key != "npc_%d" % sprite_id:
			push_error("sprite %d should use %s, got %s" % [sprite_id, "npc_%d" % sprite_id, key])
			failures += 1
			continue
		# Extracted sheets usually have no .import yet; the loader must still be
		# able to decode the raw PNG (this is what broke the prologue NPCs).
		var raw_path := "res://assets/bw/overworld/npc_%d/frames/frame_01.png" % sprite_id
		if world._frame_texture(raw_path) == null:
			push_error("npc_%d frame_01.png could not be decoded" % sprite_id)
			failures += 1
			continue
		var frames: SpriteFrames = world._frames_for(key)
		if frames == null or not frames.has_animation("idle_down"):
			push_error("%s has no idle_down animation" % key)
			failures += 1
			continue
		# Every registered animation needs a real texture. The old loader added
		# the animation first and then skipped frames that had no .import, so
		# the sheet "loaded" while every animation stayed empty.
		for animation_name in frames.get_animation_names():
			if frames.get_frame_count(animation_name) < 1:
				push_error("%s animation %s has no frames" % [key, animation_name])
				failures += 1
				break
			var frame := frames.get_frame_texture(animation_name, 0)
			if frame == null or frame.get_size() != Vector2(32, 32):
				push_error("%s %s is not a 32x32 frame" % [key, animation_name])
				failures += 1
				break
		var actor: Dictionary = world._create_actor(key, "NPC", Color.WHITE, false)
		var sprite: AnimatedSprite3D = actor.get("sprite", null)
		if sprite == null or sprite.animation != "idle_down":
			push_error("%s actor does not start on idle_down" % key)
			failures += 1
		world._free_actor(actor)

	world.free()
	if failures == 0:
		print("NPC sprite checks passed")
	quit(0 if failures == 0 else 1)
