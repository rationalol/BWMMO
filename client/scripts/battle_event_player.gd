extends Node

# Walks the structured `battle.events` produced by the server. A move event
# hands control to the ROM-script player; damage/status/boost events update the
# plates and message box in the same order the server resolved them.

var battle: Dictionary = {}
var player_plate: Control
var enemy_plate: Control
var player_creature: Control
var enemy_creature: Control
var effects: Node
var actor_fx: Node
var message_label: Label
var should_continue: Callable

func setup(
	p_player_plate: Control,
	p_enemy_plate: Control,
	p_player_creature: Control,
	p_enemy_creature: Control,
	p_effects: Node,
	p_actor_fx: Node,
	p_message_label: Label,
	p_should_continue: Callable
) -> void:
	player_plate = p_player_plate
	enemy_plate = p_enemy_plate
	player_creature = p_player_creature
	enemy_creature = p_enemy_creature
	effects = p_effects
	actor_fx = p_actor_fx
	message_label = p_message_label
	should_continue = p_should_continue

func play(events: Array) -> void:
	for value in events:
		if not _active():
			return
		if not (value is Dictionary):
			continue
		var event: Dictionary = value
		match str(event.get("type", "")):
			"move":
				await _play_move(event)
			"damage":
				_apply_hp(event)
				var amount := int(event.get("amount", 0))
				_set_message("%s took %d damage." % [
					_side_name(str(event.get("side", "wild"))), amount
				])
				actor_fx.flash(str(event.get("side", "wild")), Color(1, 1, 1, 0.85))
				await _wait(0.16)
			"heal":
				_apply_hp(event)
				_set_message("%s recovered HP." % _side_name(
					str(event.get("side", "player"))
				))
				actor_fx.flash(str(event.get("side", "player")), Color(0.55, 1.0, 0.62, 0.55))
				await _wait(0.14)
			"effective":
				var multiplier := float(event.get("multiplier", 1))
				if multiplier >= 2.0:
					_set_message("It's super effective!")
				elif multiplier <= 0.0:
					_set_message("It doesn't affect the target...")
				elif multiplier < 1.0:
					_set_message("It's not very effective...")
				await _wait(0.12)
			"critical":
				_set_message("A critical hit!")
				await _wait(0.12)
			"faint":
				var fainted := str(event.get("side", "wild"))
				_set_message("%s fainted!" % _side_name(fainted))
				actor_fx.fade(fainted)
				await _wait(0.32)
			"miss":
				var missed := str(event.get("side", "wild"))
				_set_message("%s's attack missed!" % _side_name(missed))
				await _wait(0.14)
			"status":
				var status_side := str(event.get("side", "wild"))
				_set_message("%s was affected!" % _side_name(status_side))
				actor_fx.flash(status_side, Color(0.95, 0.55, 0.95, 0.50))
				await _wait(0.14)
			"curestatus":
				_set_message("%s was cured." % _side_name(str(event.get("side", "player"))))
				await _wait(0.12)
			"boost":
				var boost_side := str(event.get("side", "wild"))
				var stat := str(event.get("stat", "stat"))
				var stat_amount := int(event.get("amount", 0))
				_set_message("%s's %s %s!" % [
					_side_name(boost_side),
					stat.capitalize(),
					"rose" if stat_amount > 0 else "fell"
				])
				await _wait(0.14)
			"switch":
				_set_message("Go, %s!" % str(event.get("name", "Pokémon")))
				await _wait(0.18)
			"run":
				_set_message(
					"Got away safely!" if bool(event.get("success", false)) else "Couldn't escape!"
				)
				await _wait(0.16)
			"catch":
				await _play_catch(event)
			"item":
				_set_message("Used %s." % str(event.get("itemId", "item")).capitalize())
				await _wait(0.12)

func _play_move(event: Dictionary) -> void:
	var side := str(event.get("side", "player"))
	_set_message("%s used %s!" % [
		_side_name(side), str(event.get("moveName", "a move"))
	])
	if effects == null:
		await _wait(0.35)
		return
	var player_anchor: Vector2 = player_creature.position + Vector2(
		player_creature.size.x * 0.5, player_creature.size.y * 0.66
	)
	var enemy_anchor: Vector2 = enemy_creature.position + Vector2(
		enemy_creature.size.x * 0.5, enemy_creature.size.y * 0.66
	)
	effects.set_actor_anchors(player_anchor, enemy_anchor)
	await effects.play_move(
		int(event.get("moveId", 0)),
		side,
		str(event.get("moveType", "Normal")),
		str(event.get("moveCategory", "physical"))
	)

func _apply_hp(event: Dictionary) -> void:
	var side := str(event.get("side", ""))
	if side == "wild":
		var wild: Dictionary = battle.get("wild", {})
		var shown := wild.duplicate(true)
		shown["hp"] = int(event.get("hp", wild.get("hp", 0)))
		shown["maxHp"] = int(event.get("maxHp", wild.get("maxHp", 1)))
		enemy_plate.set_creature(shown)
	elif side == "player":
		var player: Dictionary = battle.get("player", {})
		var shown := player.duplicate(true)
		shown["hp"] = int(event.get("hp", shown.get("hp", 0)))
		shown["maxHp"] = int(event.get("maxHp", shown.get("maxHp", 1)))
		player_plate.set_creature(shown)

func _side_name(side: String) -> String:
	if side == "wild":
		var wild: Dictionary = battle.get("wild", {})
		return "Wild %s" % str(wild.get("name", "Pokémon"))
	var player: Dictionary = battle.get("player", {})
	return str(player.get("name", "Pokémon"))

func _set_message(text: String) -> void:
	if message_label != null:
		message_label.text = text

func _active() -> bool:
	return not should_continue.is_valid() or bool(should_continue.call())

func _wait(seconds: float) -> void:
	if seconds > 0.0:
		await get_tree().create_timer(seconds).timeout


const BALL_DIR := "res://assets/bw/ui/items"

func _play_catch(event: Dictionary) -> void:
	var success := bool(event.get("success", false))
	var shakes := clampi(
		int(event.get("shakes", 3 if success else 0)),
		0,
		3
	)
	var item_id := str(event.get("itemId", "poke_ball"))
	var ball_name := _ball_name(item_id)
	_set_message("You threw a %s!" % ball_name)
	if player_creature == null or enemy_creature == null:
		await _wait(0.35)
		return
	var parent: Node = enemy_creature.get_parent()
	if parent == null:
		await _wait(0.35)
		return
	enemy_creature.visible = true
	enemy_creature.scale = Vector2.ONE
	enemy_creature.modulate = Color.WHITE
	enemy_creature.pivot_offset = enemy_creature.size * 0.5

	var ball := TextureRect.new()
	ball.texture = _ball_texture(item_id)
	ball.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ball.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ball.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	ball.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ball.size = Vector2(48, 48)
	ball.pivot_offset = ball.size * 0.5
	ball.scale = Vector2(0.72, 0.72)
	ball.z_index = 100
	parent.add_child(ball)

	var start := player_creature.position + Vector2(
		player_creature.size.x * 0.72,
		player_creature.size.y * 0.42
	)
	var target := enemy_creature.position + enemy_creature.size * Vector2(0.5, 0.52)
	ball.position = start - ball.size * 0.5

	# Throw: a linear flight plus a parabolic arc, with a little spin.
	var throw_tween := create_tween()
	throw_tween.tween_method(
		func(t: float) -> void:
			var point := start.lerp(target, t)
			point.y -= sin(t * PI) * 74.0
			ball.position = point - ball.size * 0.5
			ball.rotation = t * TAU * 1.4,
		0.0,
		1.0,
		0.48
	)
	await throw_tween.finished
	ball.rotation = 0.0

	# Land, bounce once, then open.
	var ground := target + Vector2(0, 30)
	var bounce := create_tween()
	bounce.tween_property(ball, "position", ground, 0.14)
	bounce.tween_property(ball, "position", ground - Vector2(0, 9), 0.10)
	bounce.tween_property(ball, "position", ground, 0.10)
	await bounce.finished
	var open := create_tween()
	open.tween_property(ball, "scale", Vector2(1.25, 0.82), 0.10)
	open.tween_property(ball, "scale", Vector2(1.0, 1.0), 0.12)
	await open.finished

	# The wild creature is pulled into the ball.
	var shrink := create_tween()
	shrink.set_parallel(true)
	shrink.tween_property(enemy_creature, "scale", Vector2(0.08, 0.08), 0.22)
	shrink.tween_property(enemy_creature, "modulate:a", 0.0, 0.18)
	await shrink.finished
	enemy_creature.visible = false
	enemy_creature.scale = Vector2.ONE
	enemy_creature.modulate = Color.WHITE

	# One wobble per successful shake check.
	for index in range(shakes):
		var direction := 1.0 if index % 2 == 0 else -1.0
		var wobble := create_tween()
		wobble.tween_property(ball, "rotation", 0.35 * direction, 0.10)
		wobble.parallel().tween_property(
			ball, "position", ground + Vector2(5.0 * direction, 0.0), 0.10
		)
		wobble.tween_property(ball, "rotation", 0.0, 0.12)
		wobble.parallel().tween_property(ball, "position", ground, 0.12)
		await wobble.finished
		await _wait(0.10)

	if success:
		_set_message("Gotcha!")
		var caught := create_tween()
		caught.tween_property(ball, "scale", Vector2(1.18, 1.18), 0.12)
		caught.tween_property(ball, "scale", Vector2(1.0, 1.0), 0.14)
		await caught.finished
		if actor_fx != null:
			actor_fx.flash("wild", Color(1.0, 0.95, 0.45, 0.65))
		await _wait(0.28)
		ball.queue_free()
		return

	# The ball opens and the wild creature pops back out.
	_set_message("It broke free!")
	var broken := create_tween()
	broken.tween_property(ball, "scale", Vector2(1.32, 1.32), 0.10)
	broken.tween_property(ball, "scale", Vector2.ZERO, 0.18)
	broken.parallel().tween_property(ball, "modulate:a", 0.0, 0.18)
	await broken.finished
	ball.queue_free()

	enemy_creature.visible = true
	enemy_creature.scale = Vector2(0.08, 0.08)
	enemy_creature.modulate = Color(1.0, 1.0, 1.0, 0.0)
	var pop_out := create_tween()
	pop_out.set_parallel(true)
	pop_out.tween_property(enemy_creature, "scale", Vector2.ONE, 0.20)
	pop_out.tween_property(enemy_creature, "modulate:a", 1.0, 0.16)
	await pop_out.finished
	if actor_fx != null:
		actor_fx.flash("wild", Color(1.0, 1.0, 1.0, 0.8))
	await _wait(0.16)

func _ball_texture(item_id: String) -> Texture2D:
	var path := "%s/%s.png" % [BALL_DIR, item_id]
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	return load("%s/poke_ball.png" % BALL_DIR) as Texture2D

func _ball_name(item_id: String) -> String:
	match item_id:
		"great_ball":
			return "Great Ball"
		"ultra_ball":
			return "Ultra Ball"
		"master_ball":
			return "Master Ball"
		_:
			return "Poké Ball"

