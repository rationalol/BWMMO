extends Control

# Plays the original Gen 5 move-animation scripts over the 2D battle stage.
#
# The scripts come from a/0/6/6: every move has one or two timed sequences of
# particle spawns, projectile paths, camera/sprite commands and waits. The
# particle textures come from a/0/0/6 (TPS alpha masks plus their BGR555
# palettes), exported by tools/rom/extract_battle_effects.py.
#
# The original engine renders the particles as billboards in a 3D battle scene.
# This player keeps the same data and timing but draws them on the 2D stage, so
# the effect selection, impact order and target side still match the ROM.

signal screen_shake_requested(strength: float, duration: float)
signal actor_effect_requested(side: String, kind: String, values: Array)
signal camera_focus_requested(side: String, duration: float)
signal move_finished

const MANIFEST_PATH := "res://assets/bw/battle_effects/manifest.json"
const ATLAS_ROOT := "res://assets/bw/battle_effects"

const TYPE_COLORS := {
	"Normal": Color("c8c8b8"),
	"Fighting": Color("c84838"),
	"Flying": Color("a890f0"),
	"Poison": Color("a040a0"),
	"Ground": Color("d8b060"),
	"Rock": Color("b8a038"),
	"Bug": Color("a8b820"),
	"Ghost": Color("705898"),
	"Steel": Color("b8b8d0"),
	"Fire": Color("ff7838"),
	"Water": Color("4890ff"),
	"Grass": Color("58c858"),
	"Electric": Color("ffd838"),
	"Psychic": Color("ff58a8"),
	"Ice": Color("78d8f8"),
	"Dragon": Color("7048f8"),
	"Dark": Color("685848")
}

static var _manifest: Dictionary = {}
static var _manifest_loaded := false
static var _atlas_cache: Dictionary = {}

var _player_anchor := Vector2(230.0, 330.0)
var _enemy_anchor := Vector2(700.0, 210.0)
var _particles: Array = []
var _playing := false
var _play_token := 0
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_rng.seed = 0x5A17
	_load_manifest()
	set_process(true)

func set_actor_anchors(player_anchor: Vector2, enemy_anchor: Vector2) -> void:
	_player_anchor = player_anchor
	_enemy_anchor = enemy_anchor

func is_playing() -> bool:
	return _playing

func has_manifest() -> bool:
	_load_manifest()
	return not _manifest.is_empty()

func move_effect(move_id: int) -> Dictionary:
	_load_manifest()
	var moves: Dictionary = _manifest.get("moves", {})
	var entry: Variant = moves.get(str(move_id), null)
	return entry if entry is Dictionary else {}

func stop() -> void:
	_play_token += 1
	_playing = false
	_particles.clear()
	queue_redraw()

static func _load_manifest() -> void:
	if _manifest_loaded:
		return
	_manifest_loaded = true
	if not FileAccess.file_exists(MANIFEST_PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	if parsed is Dictionary:
		_manifest = parsed

func _atlas_for(effect_id: int) -> Dictionary:
	_load_manifest()
	var effects: Dictionary = _manifest.get("effects", {})
	var entry: Variant = effects.get(str(effect_id), null)
	if not (entry is Dictionary):
		return {}
	var cache_key := str(effect_id)
	if _atlas_cache.has(cache_key):
		return _atlas_cache[cache_key]
	var path := "%s/%s" % [ATLAS_ROOT, str(entry.get("file", ""))]
	if not ResourceLoader.exists(path):
		return {}
	var texture := load(path) as Texture2D
	if texture == null:
		return {}
	var resolved := {
		"texture": texture,
		"frames": entry.get("frames", [])
	}
	_atlas_cache[cache_key] = resolved
	return resolved

func _particle_frame(effect_id: int, particle_id: int) -> Dictionary:
	var atlas := _atlas_for(effect_id)
	if atlas.is_empty():
		return {}
	var frames: Array = atlas.get("frames", [])
	if frames.is_empty():
		return {}
	var index := particle_id
	if index < 0:
		index = 0
	if index >= frames.size():
		# SPA effects may reuse a texture for several emitters; the ROM keeps
		# the emitter list separate from the atlas. Cycling is the closest
		# mapping without decoding the proprietary particle graph.
		index = index % frames.size()
	var frame: Array = frames[index]
	if frame.size() < 4:
		return {}
	return {
		"texture": atlas["texture"],
		"region": Rect2(float(frame[0]), float(frame[1]), float(frame[2]), float(frame[3]))
	}

func play_move(
	move_id: int,
	side: String,
	move_type: String = "Normal",
	move_category: String = "physical"
) -> void:
	_play_token += 1
	var token := _play_token
	_playing = true
	_particles.clear()
	queue_redraw()
	_load_manifest()
	var entry := move_effect(move_id)
	var sequences: Array = entry.get("sequences", [])
	if sequences.is_empty():
		await _fallback_effect(side, move_type, move_category)
	else:
		var sequence_index := 0
		if side == "wild" and sequences.size() > 1:
			sequence_index = 1
		var commands: Array = sequences[sequence_index]
		await _run_commands(commands, side, move_type, 0, token)
		# Give the last burst a moment to fade before the next message.
		await _wait(0.22, token)
	if token != _play_token:
		return
	_playing = false
	_particles.clear()
	queue_redraw()
	move_finished.emit()

func _run_commands(
	commands: Array,
	user_side: String,
	move_type: String,
	depth: int,
	token: int
) -> void:
	if depth > 4 or token != _play_token:
		return
	var started := Time.get_ticks_msec()
	for command in commands:
		if token != _play_token:
			return
		if Time.get_ticks_msec() - started > 4500:
			return
		if not (command is Array) or command.is_empty():
			continue
		var name := str(command[0])
		var args: Array = command.slice(1)
		match name:
			"LoadSPA":
				pass
			"PlaySPAAnimation":
				_spawn_burst(args, user_side, false)
			"PlaySPAAnimation2":
				_spawn_burst(args, user_side, true)
			"PlaySPAScreenAnimation":
				_spawn_screen(args)
			"PlaySPAProjectile":
				_spawn_projectile(args, user_side, 0)
			"PlaySPAProjectile2":
				_spawn_projectile(args, user_side, 1)
			"PlaySPAProjectile3":
				_spawn_projectile(args, user_side, 2)
			"PlaySPACircle":
				_spawn_circle(args, user_side)
			"ShakeScreen":
				var strength := 7.0
				if args.size() > 1:
					strength = clampf(absf(float(args[1]) / 4096.0) * 6.0 + 3.0, 2.0, 16.0)
				var duration := 0.25
				if args.size() > 4:
					duration = clampf(float(args[4]) / 60.0, 0.12, 0.7)
				screen_shake_requested.emit(strength, duration)
			"MoveCamera":
				if args.size() >= 3:
					var focus_code := int(args[1])
					var focus_side := "center"
					if focus_code != 8:
						focus_side = _actor_side(focus_code, user_side)
					var seconds := clampf(float(args[2]) / 60.0, 0.08, 0.8)
					camera_focus_requested.emit(focus_side, seconds)
			"AdjustCamera":
				pass
			"ShakeSprite":
				if args.size() >= 7:
					var side := _actor_side(int(args[0]), user_side)
					actor_effect_requested.emit(side, "shake", [
						float(args[2]) / 4096.0,
						float(args[3]) / 4096.0,
						clampf(float(args[5]) / 60.0, 0.08, 0.8),
						maxi(1, int(args[6]))
					])
			"MoveSprite":
				if args.size() >= 8:
					var side := _actor_side(int(args[0]), user_side)
					actor_effect_requested.emit(side, "move", [
						float(args[2]) / 4096.0,
						float(args[3]) / 4096.0,
						clampf(float(args[6]) / 60.0, 0.08, 0.8)
					])
			"DistortSprite":
				if args.size() >= 7:
					var side := _actor_side(int(args[0]), user_side)
					actor_effect_requested.emit(side, "distort", [
						float(args[2]) / 4096.0,
						float(args[3]) / 4096.0,
						clampf(float(args[5]) / 60.0, 0.08, 0.9)
					])
			"TiltSprite":
				if args.size() >= 5:
					var side := _actor_side(int(args[0]), user_side)
					actor_effect_requested.emit(side, "tilt", [
						float(args[2]) / 4096.0,
						clampf(float(args[4]) / 60.0, 0.08, 0.9)
					])
			"SpriteOpacity":
				if args.size() >= 5:
					var side := _actor_side(int(args[0]), user_side)
					actor_effect_requested.emit(side, "opacity", [
						clampf(float(args[2]) / 31.0, 0.0, 1.0),
						clampf(float(args[4]) / 60.0, 0.08, 0.8)
					])
			"FreezeSprite":
				if args.size() >= 2:
					var side := _actor_side(int(args[0]), user_side)
					actor_effect_requested.emit(side, "freeze", [bool(args[1])])
			"ChangeColor":
				if args.size() >= 5:
					var side := _actor_side(int(args[0]), user_side)
					actor_effect_requested.emit(side, "colour", [
						_color_from_bgr555(int(args[4])),
						clampf(float(args[2]) / 16.0, 0.0, 1.0),
						clampf(float(args[3]) / 60.0, 0.08, 0.8)
					])
			"ChangeVisibility":
				if args.size() >= 2:
					var side := _actor_side(int(args[0]), user_side)
					actor_effect_requested.emit(side, "visible", [int(args[1]) != 3])
			"Wait":
				var frames := 16.0
				if not args.is_empty():
					frames = float(args[0])
				await _wait(clampf(frames / 60.0, 0.03, 1.2), token)
			"WaitForCommands":
				await _wait(0.28, token)
			"CallMoveAnimation":
				if not args.is_empty():
					var called := move_effect(int(args[0]))
					var called_sequences: Array = called.get("sequences", [])
					if not called_sequences.is_empty():
						await _run_commands(
							called_sequences[0], user_side, move_type, depth + 1, token
						)
			"End":
				return
			_:
				# Sound/background commands were removed from the manifest;
				# unknown future commands are ignored rather than stalling.
				pass

func _wait(seconds: float, token: int) -> void:
	if seconds <= 0.0 or token != _play_token:
		return
	await get_tree().create_timer(seconds).timeout

func _actor_side(code: int, user_side: String) -> String:
	match code:
		14:
			return user_side
		16:
			return _opposite(user_side)
		18:
			return "both"
	return user_side

func _opposite(side: String) -> String:
	return "wild" if side == "player" else "player"

func _anchor(side: String) -> Vector2:
	return _player_anchor if side == "player" else _enemy_anchor

func _resolve_position(code: int, user_side: String) -> Vector2:
	if code == 11:
		return _anchor(_opposite(user_side))
	if code == 9:
		return _anchor(user_side)
	if code == 0:
		return _anchor("player")
	if code == 1:
		return _anchor("wild")
	return Vector2(size.x * 0.5, size.y * 0.45)

func _spawn_burst(args: Array, user_side: String, offsetted: bool) -> void:
	if args.size() < 10:
		return
	var effect_id := int(args[0])
	var particle_id := int(args[1])
	var frame := _particle_frame(effect_id, particle_id)
	if frame.is_empty():
		return
	var position_code := int(args[2])
	var origin := _resolve_position(position_code, user_side)
	var horizontal := 0.0
	var vertical := float(args[4]) / 4096.0
	if offsetted and args.size() >= 6:
		horizontal = float(args[3]) / 4096.0
		vertical = float(args[5]) / 4096.0
	var width_scale := maxf(0.15, float(args[7]) / 4096.0)
	var height_scale := maxf(0.15, float(args[9]) / 4096.0)
	var region: Rect2 = frame["region"]
	var base_size := Vector2(
		clampf(region.size.x * 2.2 * width_scale, 18.0, 380.0),
		clampf(region.size.y * 2.2 * height_scale, 18.0, 380.0)
	)
	var spread := 10.0 + base_size.x * 0.08
	var velocity := Vector2(
		_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)
	).normalized() * _rng.randf_range(18.0, 62.0)
	var life := 0.48 + float(particle_id % 4) * 0.09
	_particles.append({
		"texture": frame["texture"],
		"region": region,
		"position": origin + Vector2(horizontal * 52.0, -vertical * 20.0) + Vector2(
			_rng.randf_range(-spread, spread),
			_rng.randf_range(-spread, spread)
		),
		"velocity": velocity,
		"age": 0.0,
		"life": life,
		"start_size": base_size * 0.55,
		"end_size": base_size * 1.08,
		"rotation": _rng.randf_range(-0.4, 0.4),
		"spin": _rng.randf_range(-1.8, 1.8),
		"alpha": 1.0,
		"shape": ""
	})
	queue_redraw()

func _spawn_screen(args: Array) -> void:
	if args.size() < 14:
		return
	var frame := _particle_frame(int(args[0]), int(args[1]))
	if frame.is_empty():
		return
	var region: Rect2 = frame["region"]
	var x := float(args[2]) / 4096.0 * 34.0
	var y := float(args[3]) / 4096.0 * 26.0
	var base_size := Vector2(
		clampf(region.size.x * 2.0 * maxf(0.15, float(args[11]) / 4096.0), 18.0, 320.0),
		clampf(region.size.y * 2.0 * maxf(0.15, float(args[13]) / 4096.0), 18.0, 320.0)
	)
	_particles.append({
		"texture": frame["texture"],
		"region": region,
		"position": Vector2(size.x * 0.5 + x, size.y * 0.44 + y),
		"velocity": Vector2.ZERO,
		"age": 0.0,
		"life": 0.65,
		"start_size": base_size * 0.6,
		"end_size": base_size,
		"rotation": 0.0,
		"spin": 0.0,
		"alpha": 1.0,
		"shape": ""
	})
	queue_redraw()

func _spawn_projectile(args: Array, user_side: String, mode: int) -> void:
	if args.size() < 8:
		return
	var frame := _particle_frame(int(args[0]), int(args[1]))
	if frame.is_empty():
		return
	var source_code := 9
	var destination_code := 11
	if mode == 0:
		source_code = int(args[3])
		destination_code = int(args[4])
	elif mode == 1:
		source_code = 9
		destination_code = int(args[6])
	else:
		source_code = int(args[3])
		destination_code = int(args[4])
	var source := _resolve_position(source_code, user_side)
	var destination := _resolve_position(destination_code, user_side)
	var arc_units := float(args[7]) / 4096.0 if args.size() > 7 else 0.0
	var region: Rect2 = frame["region"]
	var base_size := Vector2(region.size.x * 2.0, region.size.y * 2.0)
	_particles.append({
		"texture": frame["texture"],
		"region": region,
		"position": source,
		"start_position": source,
		"end_position": destination,
		"arc": clampf(arc_units * 12.0, 0.0, 110.0),
		"velocity": Vector2.ZERO,
		"age": 0.0,
		"life": 0.55,
		"start_size": base_size * 0.9,
		"end_size": base_size * 1.15,
		"rotation": 0.0,
		"spin": 2.4,
		"alpha": 1.0,
		"shape": "",
		"projectile": true
	})
	queue_redraw()

func _spawn_circle(args: Array, user_side: String) -> void:
	if args.size() < 4:
		return
	var effect_id := int(args[0])
	var particle_id := int(args[1])
	var frame := _particle_frame(effect_id, particle_id)
	if frame.is_empty():
		return
	var origin := _resolve_position(11, user_side)
	var radius := clampf(absf(float(args[3]) / 4096.0) * 18.0 + 20.0, 20.0, 90.0)
	var count := 5
	var direction := 1.0 if int(args[2]) == 3 else -1.0
	var region: Rect2 = frame["region"]
	var base_size := Vector2(region.size.x * 1.7, region.size.y * 1.7)
	for index in range(count):
		var angle := TAU * float(index) / float(count)
		_particles.append({
			"texture": frame["texture"],
			"region": region,
			"position": origin + Vector2(cos(angle), sin(angle)) * radius,
			"orbit_center": origin,
			"orbit_radius": radius,
			"orbit_angle": angle,
			"orbit_speed": direction * 2.2,
			"velocity": Vector2.ZERO,
			"age": 0.0,
			"life": 0.7,
			"start_size": base_size * 0.55,
			"end_size": base_size,
			"rotation": 0.0,
			"spin": direction * 1.7,
			"alpha": 1.0,
			"shape": ""
		})
	queue_redraw()

func _process(delta: float) -> void:
	if _particles.is_empty():
		return
	var remove_indices: Array[int] = []
	for index in range(_particles.size()):
		var particle: Dictionary = _particles[index]
		particle["age"] = float(particle["age"]) + delta
		if float(particle["age"]) >= float(particle["life"]):
			remove_indices.append(index)
			continue
		var t := clampf(float(particle["age"]) / float(particle["life"]), 0.0, 1.0)
		if bool(particle.get("projectile", false)):
			var start: Vector2 = particle["start_position"]
			var finish: Vector2 = particle["end_position"]
			particle["position"] = start.lerp(finish, t) + Vector2(
				0.0, -sin(t * PI) * float(particle["arc"])
			)
		elif particle.has("orbit_center"):
			var angle := float(particle["orbit_angle"]) + float(particle["orbit_speed"]) * delta
			particle["orbit_angle"] = angle
			particle["position"] = particle["orbit_center"] + Vector2(
				cos(angle), sin(angle)
			) * float(particle["orbit_radius"])
		else:
			var position: Vector2 = particle["position"]
			particle["position"] = position + particle["velocity"] * delta
			particle["velocity"] = particle["velocity"] * (1.0 - 1.8 * delta)
		particle["rotation"] = float(particle["rotation"]) + float(particle["spin"]) * delta
		particle["fade"] = 1.0
		if t < 0.12:
			particle["fade"] = t / 0.12
		elif t > 0.62:
			particle["fade"] = maxf(0.0, 1.0 - (t - 0.62) / 0.38)
	for index in range(remove_indices.size() - 1, -1, -1):
		_particles.remove_at(remove_indices[index])
	queue_redraw()

func _draw() -> void:
	for particle in _particles:
		var t := clampf(float(particle["age"]) / float(particle["life"]), 0.0, 1.0)
		var fade := float(particle.get("fade", 1.0))
		var particle_size: Vector2 = particle["start_size"].lerp(particle["end_size"], t)
		var position: Vector2 = particle["position"]
		var rotation := float(particle["rotation"])
		draw_set_transform(position, rotation, Vector2.ONE)
		var texture: Texture2D = particle.get("texture", null)
		if texture != null:
			var rect := Rect2(-particle_size * 0.5, particle_size)
			draw_texture_rect_region(
				texture, rect, particle["region"], Color(1, 1, 1, fade)
			)
			# A faint larger copy keeps the original additive glow when the
			# 2D renderer uses normal alpha blending.
			var glow_rect := Rect2(-particle_size * 0.62, particle_size * 1.24)
			draw_texture_rect_region(
				texture, glow_rect, particle["region"], Color(1, 1, 1, fade * 0.16)
			)
		else:
			var colour: Color = particle.get("colour", Color.WHITE)
			colour.a *= fade
			if str(particle.get("shape", "")) == "diamond":
				var radius := particle_size.x * 0.35
				draw_colored_polygon(PackedVector2Array([
					Vector2(0.0, -radius),
					Vector2(radius * 0.7, 0.0),
					Vector2(0.0, radius),
					Vector2(-radius * 0.7, 0.0)
				]), colour)
			else:
				draw_circle(Vector2.ZERO, particle_size.x * 0.32, colour)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _fallback_effect(side: String, move_type: String, move_category: String) -> void:
	var user_side := side
	var target_side := _opposite(side)
	var colour: Color = TYPE_COLORS.get(move_type, Color.WHITE)
	var source := _anchor(user_side)
	var target := _anchor(target_side)
	if move_category == "status":
		for index in range(10):
			var angle := TAU * float(index) / 10.0
			_particles.append(_fallback_particle(
				_anchor(target_side) + Vector2(cos(angle), sin(angle)) * 26.0,
				Vector2(cos(angle), sin(angle)) * 26.0,
				colour, 0.55 + float(index % 3) * 0.08, "circle"
			))
	elif move_category == "special":
		for index in range(3):
			_particles.append({
				"texture": null,
				"position": source,
				"start_position": source,
				"end_position": target,
				"arc": 32.0 + float(index) * 10.0,
				"velocity": Vector2.ZERO,
				"age": -0.06 * float(index),
				"life": 0.55,
				"start_size": Vector2(44, 44),
				"end_size": Vector2(58, 58),
				"rotation": 0.0,
				"spin": 3.0,
				"alpha": 1.0,
				"colour": colour,
				"shape": "diamond",
				"projectile": true
			})
		for index in range(10):
			var angle := TAU * float(index) / 10.0
			_particles.append(_fallback_particle(
				target + Vector2(cos(angle), sin(angle)) * 8.0,
				Vector2(cos(angle), sin(angle)) * 54.0,
				colour.lightened(0.15), 0.48, "circle"
			))
	else:
		for index in range(16):
			var angle := TAU * float(index) / 16.0
			_particles.append(_fallback_particle(
				target + Vector2(cos(angle), sin(angle)) * 6.0,
				Vector2(cos(angle), sin(angle)) * _rng.randf_range(50.0, 90.0),
				colour, 0.5 + float(index % 2) * 0.08, "diamond"
			))
	queue_redraw()
	await _wait(0.7, _play_token)

func _fallback_particle(
	position: Vector2,
	velocity: Vector2,
	colour: Color,
	life: float,
	shape: String
) -> Dictionary:
	return {
		"texture": null,
		"position": position,
		"velocity": velocity,
		"age": 0.0,
		"life": life,
		"start_size": Vector2(26, 26),
		"end_size": Vector2(48, 48),
		"rotation": _rng.randf_range(0.0, TAU),
		"spin": _rng.randf_range(-3.0, 3.0),
		"alpha": 1.0,
		"fade": 1.0,
		"colour": colour,
		"shape": shape
	}

func _color_from_bgr555(value: int) -> Color:
	if value <= 0:
		return Color.WHITE
	var red := (value & 0x1F) << 3
	var green := ((value >> 5) & 0x1F) << 3
	var blue := ((value >> 10) & 0x1F) << 3
	return Color(
		(red | (red >> 5)) / 255.0,
		(green | (green >> 5)) / 255.0,
		(blue | (blue >> 5)) / 255.0
	)
