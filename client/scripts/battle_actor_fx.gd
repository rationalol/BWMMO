extends Node

# Applies the sprite/camera half of the ROM move-animation commands. The
# event player decides which commands arrived; this node owns the tweens so a
# new move can cancel the previous shake, tint or zoom without touching the
# battle HUD layout.

var field_root: Control
var player_actor: Control
var enemy_actor: Control
var actor_home: Dictionary = {}
var actor_tweens: Dictionary = {}
var field_tween: Tween = null
var sprite_tint := Color(1, 1, 1, 1)

func setup(
	p_field_root: Control,
	p_player_actor: Control,
	p_enemy_actor: Control,
	p_sprite_tint: Color
) -> void:
	field_root = p_field_root
	player_actor = p_player_actor
	enemy_actor = p_enemy_actor
	sprite_tint = p_sprite_tint
	actor_home = {
		"player": player_actor.position,
		"wild": enemy_actor.position
	}

func set_tint(tint: Color) -> void:
	sprite_tint = tint

func reset() -> void:
	if field_tween != null and field_tween.is_valid():
		field_tween.kill()
	field_tween = null
	if field_root != null:
		field_root.position = Vector2.ZERO
		field_root.scale = Vector2.ONE
	if actor_home.is_empty():
		return
	for side in ["player", "wild"]:
		var actor := actor_for(side)
		if actor == null:
			continue
		kill_tween(side)
		actor.position = actor_home[side]
		actor.pivot_offset = actor.size * 0.5
		actor.scale = Vector2.ONE
		actor.rotation = 0.0
		actor.modulate = sprite_tint
		actor.self_modulate = Color(1, 1, 1, 1)
		actor.visible = true
		if actor.has_method("set_frozen"):
			actor.set_frozen(false)

func actor_for(side: String) -> Control:
	if side == "player":
		return player_actor
	if side == "wild":
		return enemy_actor
	return null

func actors_for(side: String) -> Array:
	if side == "both":
		return [player_actor, enemy_actor]
	var actor := actor_for(side)
	return [actor] if actor != null else []

func kill_tween(side: String) -> void:
	var tween: Variant = actor_tweens.get(side, null)
	if tween is Tween and tween.is_valid():
		tween.kill()
	actor_tweens.erase(side)

func handle(side: String, kind: String, values: Array) -> void:
	for actor in actors_for(side):
		if actor == null:
			continue
		var actor_side := "player" if actor == player_actor else "wild"
		match kind:
			"shake":
				if values.size() >= 4:
					shake_actor(actor_side, actor, values)
			"move":
				if values.size() >= 3:
					move_actor(actor_side, actor, values)
			"distort":
				if values.size() >= 3:
					distort_actor(actor_side, actor, values)
			"opacity":
				if values.size() >= 2:
					opacity_actor(actor_side, actor, values)
			"freeze":
				if not values.is_empty() and actor.has_method("set_frozen"):
					actor.set_frozen(bool(values[0]))
			"colour":
				if values.size() >= 3:
					tint_actor(actor_side, actor, values)
			"visible":
				if not values.is_empty():
					actor.visible = bool(values[0])
			"tilt":
				if values.size() >= 2:
					tilt_actor(actor_side, actor, values)

func shake_actor(side: String, actor: Control, values: Array) -> void:
	kill_tween(side)
	var base: Vector2 = actor_home[side]
	var x := clampf(absf(float(values[0])) * 22.0, 1.5, 12.0)
	var y := clampf(absf(float(values[1])) * 22.0, 0.0, 8.0)
	var duration := clampf(float(values[2]), 0.08, 0.8)
	var count := maxi(1, int(values[3]))
	var step := duration / float(count * 2)
	var tween := create_tween()
	for index in range(count):
		var direction := 1.0 if index % 2 == 0 else -1.0
		tween.tween_property(
			actor, "position", base + Vector2(x * direction, y * direction), step
		)
		tween.tween_property(
			actor, "position", base + Vector2(-x * direction, -y * direction), step
		)
	tween.tween_property(actor, "position", base, 0.04)
	actor_tweens[side] = tween

func move_actor(side: String, actor: Control, values: Array) -> void:
	kill_tween(side)
	var base: Vector2 = actor_home[side]
	var target := base + Vector2(
		clampf(float(values[0]) * 14.0, -28.0, 28.0),
		clampf(-float(values[1]) * 14.0, -24.0, 24.0)
	)
	var duration := clampf(float(values[2]), 0.08, 0.8)
	var tween := create_tween()
	tween.tween_property(actor, "position", target, duration * 0.45)
	tween.tween_property(actor, "position", base, duration * 0.55)
	actor_tweens[side] = tween

func distort_actor(side: String, actor: Control, values: Array) -> void:
	kill_tween(side)
	actor.pivot_offset = actor.size * 0.5
	var scale_to := Vector2(
		clampf(1.0 + float(values[0]), 0.35, 1.7),
		clampf(1.0 + float(values[1]), 0.35, 1.7)
	)
	var duration := clampf(float(values[2]), 0.08, 0.9)
	var tween := create_tween()
	tween.tween_property(actor, "scale", scale_to, duration * 0.4)
	tween.tween_property(actor, "scale", Vector2.ONE, duration * 0.6)
	actor_tweens[side] = tween

func opacity_actor(side: String, actor: Control, values: Array) -> void:
	kill_tween(side)
	var alpha := clampf(float(values[0]), 0.0, 1.0)
	var duration := clampf(float(values[1]), 0.08, 0.8)
	var tween := create_tween()
	tween.tween_property(actor, "self_modulate:a", alpha, duration)
	actor_tweens[side] = tween

func tint_actor(side: String, actor: Control, values: Array) -> void:
	kill_tween(side)
	var colour: Color = values[0]
	var amount := clampf(float(values[1]), 0.0, 1.0)
	var duration := clampf(float(values[2]), 0.08, 0.8)
	var mixed := sprite_tint.lerp(colour, amount)
	var tween := create_tween()
	tween.tween_property(actor, "modulate", mixed, duration)
	actor_tweens[side] = tween

func tilt_actor(side: String, actor: Control, values: Array) -> void:
	kill_tween(side)
	actor.pivot_offset = actor.size * 0.5
	var duration := clampf(float(values[1]), 0.08, 0.8)
	var tween := create_tween()
	tween.tween_property(actor, "rotation", 0.10, duration * 0.4)
	tween.tween_property(actor, "rotation", 0.0, duration * 0.6)
	actor_tweens[side] = tween

func flash(side: String, colour: Color) -> void:
	var actor := actor_for(side)
	if actor == null:
		return
	kill_tween(side)
	var tween := create_tween()
	tween.tween_property(actor, "modulate", colour, 0.05)
	tween.tween_property(actor, "modulate", sprite_tint, 0.20)
	actor_tweens[side] = tween

func fade(side: String) -> void:
	var actor := actor_for(side)
	if actor == null:
		return
	kill_tween(side)
	var tween := create_tween()
	tween.tween_property(actor, "modulate:a", 0.18, 0.32)
	actor_tweens[side] = tween

func shake_screen(strength: float, duration: float) -> void:
	if field_root == null:
		return
	if field_tween != null and field_tween.is_valid():
		field_tween.kill()
	var base := field_root.position
	var tween := create_tween()
	var step := clampf(duration / 6.0, 0.02, 0.09)
	for index in range(3):
		var direction := 1.0 if index % 2 == 0 else -1.0
		tween.tween_property(
			field_root, "position", base + Vector2(strength * direction, 0.0), step
		)
	tween.tween_property(field_root, "position", base, step)
	field_tween = tween

func focus_camera(side: String, duration: float) -> void:
	if field_root == null:
		return
	if field_tween != null and field_tween.is_valid():
		field_tween.kill()
	field_root.pivot_offset = field_root.size * 0.5
	var tween := create_tween()
	if side == "center":
		tween.tween_property(field_root, "position", Vector2.ZERO, duration)
		tween.parallel().tween_property(field_root, "scale", Vector2.ONE, duration)
	else:
		var anchor := _player_camera_anchor() if side == "player" else _enemy_camera_anchor()
		var offset := (anchor - field_root.size * 0.5) * -0.018
		tween.tween_property(field_root, "position", offset, duration)
		tween.parallel().tween_property(field_root, "scale", Vector2(1.018, 1.018), duration)
	field_tween = tween

func _player_camera_anchor() -> Vector2:
	return player_actor.position + player_actor.size * 0.5

func _enemy_camera_anchor() -> Vector2:
	return enemy_actor.position + enemy_actor.size * 0.5
