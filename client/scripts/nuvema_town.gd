extends Node3D

const ASSET_ROOT := "res://assets/bw/nuvema"
const PLAYER_TEXTURE := "res://assets/bw/nuvema/player.png"
const HERO_ROOT := "res://assets/bw/nuvema/actors/hero"
const WALK_SPEED := 33.333
const RUN_SPEED := 66.667
# A 4-frame gait cycle has two footfalls, so it spans two 16-unit tiles:
# 0.96 s walking and 0.48 s running.
const WALK_ANIM_FPS := 4.167
const RUN_ANIM_FPS := 8.333
const GRAVITY := 320.0
const CAMERA_OFFSET := Vector3(0, 315, 280)

const PROP_FILES := {
	5: "t1_house_02.glb",
	6: "t1_labo_01.glb",
	69: "plant_01.glb",
	152: "sign02.glb",
	153: "sign03.glb",
	193: "t01_kira.glb"
}

const COLLIDING_PROPS := [5, 6]

var _player: CharacterBody3D
var _camera: Camera3D
var _screenshot_path := ""
var _time := 0.0
var _map_root: Node3D
var _player_sprite: AnimatedSprite3D
var _facing := "down"

func _ready() -> void:
	DisplayServer.window_set_title("Nuvema Town — BW map test")
	_parse_args()
	_build_environment()
	_build_map()
	_build_player()
	_build_camera()
	_build_hud()

func _parse_args() -> void:
	_screenshot_path = OS.get_environment("NUVEMA_SCREENSHOT")
	var args := OS.get_cmdline_args()
	for argument in OS.get_cmdline_user_args():
		if not args.has(argument):
			args.append(argument)
	for argument in args:
		if argument.begins_with("--screenshot="):
			_screenshot_path = argument.substr(13)

func _build_environment() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-52, -38, 0)
	light.light_energy = 1.25
	light.shadow_enabled = true
	add_child(light)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-22, 150, 0)
	fill.light_energy = 0.55
	add_child(fill)

	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.045, 0.070, 0.115)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.76, 0.82, 0.92)
	environment.ambient_light_energy = 0.95
	environment.fog_enabled = false
	env.environment = environment
	add_child(env)

func _build_map() -> void:
	_map_root = Node3D.new()
	_map_root.name = "NuvemaMap"
	add_child(_map_root)

	var placements_data: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("%s/placements.json" % ASSET_ROOT)
	)
	var map_file := str(placements_data.get("mapFile", "map/map24_23.glb"))
	var map_scene: PackedScene = load("%s/%s" % [ASSET_ROOT, map_file])
	if map_scene == null:
		push_error("Missing Nuvema map GLB. Run tools/rom/extract_nuvema.py first.")
		return
	var map := map_scene.instantiate()
	_map_root.add_child(map)

	var prop_files: Dictionary = placements_data.get("propFiles", {})
	var props: Array = placements_data.get("props", [])
	for placement in props:
		var prop_id := int(placement.get("prop", 0))
		var filename := str(prop_files.get(str(prop_id), PROP_FILES.get(prop_id, "")))
		if filename == "":
			continue
		var path := "%s/props/%s" % [ASSET_ROOT, filename]
		if not ResourceLoader.exists(path):
			push_warning("Missing prop asset: %s" % path)
			continue
		var packed: PackedScene = load(path)
		if packed == null:
			continue
		var prop := packed.instantiate()
		prop.position = Vector3(
			float(placement.get("x", 0)),
			float(placement.get("y", 0)),
			float(placement.get("z", 0))
		)
		prop.rotation_degrees.y = float(placement.get("rotation", 0))
		_map_root.add_child(prop)
		if prop_id in COLLIDING_PROPS:
			_add_prop_collider(prop)

	_add_ground()
	_add_bounds()

func _add_prop_collider(prop: Node3D) -> void:
	var box := AABB()
	var found := false
	for mesh_node in prop.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := mesh_node as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		var local_aabb := mesh_instance.get_aabb()
		var transformed := mesh_instance.global_transform * local_aabb
		if not found:
			box = transformed
			found = true
		else:
			box = box.merge(transformed)
	if not found:
		return
	var body := StaticBody3D.new()
	body.position = box.get_center()
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(box.size.x * 0.92, maxf(box.size.y, 8.0), box.size.z * 0.92)
	shape.shape = box_shape
	body.add_child(shape)
	_map_root.add_child(body)

func _add_ground() -> void:
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(560, 4, 560)
	shape.shape = box
	ground.position = Vector3(0, -2, 0)
	ground.add_child(shape)
	_map_root.add_child(ground)

func _add_bounds() -> void:
	var walls := [
		[Vector3(0, 80, -270), Vector3(560, 160, 4)],
		[Vector3(0, 80, 270), Vector3(560, 160, 4)],
		[Vector3(-270, 80, 0), Vector3(4, 160, 560)],
		[Vector3(270, 80, 0), Vector3(4, 160, 560)]
	]
	for entry in walls:
		var body := StaticBody3D.new()
		body.position = entry[0]
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = entry[1]
		shape.shape = box
		body.add_child(shape)
		_map_root.add_child(body)

func _build_player() -> void:
	_player = CharacterBody3D.new()
	_player.name = "Player"
	_player.position = Vector3(0, 2, 60)
	var collision := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 7.0
	capsule.height = 30.0
	collision.shape = capsule
	collision.position.y = 15.0
	_player.add_child(collision)
	add_child(_player)

	_build_player_sprite()

	var shadow := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(23, 23)
	shadow.mesh = plane
	var shadow_material := StandardMaterial3D.new()
	shadow_material.albedo_color = Color(0, 0, 0, 0.32)
	shadow_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shadow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shadow.material_override = shadow_material
	shadow.rotation_degrees.x = -90.0
	shadow.position = Vector3(0, 0.35, 0)
	_player.add_child(shadow)

func _build_player_sprite() -> void:
	var hero_file := "%s/actor.json" % HERO_ROOT
	if FileAccess.file_exists(hero_file):
		var hero: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(hero_file))
		var frames := SpriteFrames.new()
		frames.remove_animation("default")
		var animations: Dictionary = hero.get("animations", {})
		var loaded := false
		for animation_name in animations.keys():
			var list: Array = animations[animation_name]
			frames.add_animation(str(animation_name))
			frames.set_animation_loop(str(animation_name), true)
			frames.set_animation_speed(
				str(animation_name),
				RUN_ANIM_FPS if str(animation_name).begins_with("run_") else WALK_ANIM_FPS
			)
			for frame_index in list:
				var path := "%s/frames/frame_%02d.png" % [HERO_ROOT, int(frame_index)]
				if not ResourceLoader.exists(path):
					continue
				frames.add_frame(str(animation_name), load(path))
				loaded = true
		if loaded:
			_player_sprite = AnimatedSprite3D.new()
			_player_sprite.sprite_frames = frames
			_player_sprite.animation = "idle_down"
			_player_sprite.pixel_size = 1.0
			_player_sprite.position = Vector3(0, 16, 0)
			_player_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			_player_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			_player_sprite.no_depth_test = false
			_player_sprite.play("idle_down")
			_player.add_child(_player_sprite)
			return
	push_warning("Hero frames missing; falling back to the trainer portrait")
	var sprite := Sprite3D.new()
	var texture: Texture2D = load(PLAYER_TEXTURE)
	if texture != null:
		sprite.texture = texture
	sprite.pixel_size = 0.55
	sprite.position = Vector3(0, 31, 0)
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.no_depth_test = false
	_player.add_child(sprite)

func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.current = true
	_camera.fov = 42.0
	_camera.near = 1.0
	_camera.far = 4000.0
	add_child(_camera)
	_camera.position = _player.position + CAMERA_OFFSET
	_camera.look_at(_player.position + Vector3(0, 26, -26), Vector3.UP)

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.anchor_left = 0.0
	panel.anchor_right = 0.0
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = 16
	panel.offset_right = 330
	panel.offset_top = -104
	panel.offset_bottom = -16
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.05, 0.075, 0.86)
	style.corner_radius_top_left = 10
	style.corner_radius_top_right = 10
	style.corner_radius_bottom_left = 10
	style.corner_radius_bottom_right = 10
	style.content_margin_left = 14
	style.content_margin_top = 10
	style.content_margin_right = 14
	style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)
	layer.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	panel.add_child(box)
	var title := Label.new()
	title.text = TranslationServer.translate("NUVEMA TOWN  -  BW ROM MAP TEST")
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(0.482, 0.847, 0.561))
	box.add_child(title)
	var hint := Label.new()
	hint.text = TranslationServer.translate("WASD / Arrows to walk\nMultiplayer sync is the next step")
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.541, 0.627, 0.698))
	box.add_child(hint)

func _process(delta: float) -> void:
	_time += delta
	if _camera != null and _player != null:
		var desired := _player.position + CAMERA_OFFSET
		_camera.position = _camera.position.lerp(desired, clampf(delta * 6.0, 0.0, 1.0))
		_camera.look_at(_player.position + Vector3(0, 26, -26), Vector3.UP)
	if _screenshot_path != "" and _time > 1.8:
		var path := _screenshot_path
		_screenshot_path = ""
		_capture(path)

func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var err := image.save_png(path)
	print("[nuvema] screenshot saved to %s (error %d)" % [path, err])
	get_tree().quit()

func _physics_process(delta: float) -> void:
	if _player == null:
		return
	var direction := Vector3.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		direction.z -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		direction.z += 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		direction.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		direction.x += 1.0
	var moving := direction.length_squared() > 0.0
	var running := moving and Input.is_key_pressed(KEY_SHIFT)
	if moving:
		direction = direction.normalized()
		if absf(direction.x) > absf(direction.z):
			_facing = "right" if direction.x > 0.0 else "left"
		else:
			_facing = "down" if direction.z > 0.0 else "up"
	var speed := RUN_SPEED if running else WALK_SPEED
	_player.velocity.x = direction.x * speed
	_player.velocity.z = direction.z * speed
	_player.velocity.y -= GRAVITY * delta
	_player.move_and_slide()
	_update_player_animation(moving, running)

func _update_player_animation(moving: bool, running: bool = false) -> void:
	if _player_sprite == null:
		return
	var animation_name := ("run_" if running else "walk_" if moving else "idle_") + _facing
	if not _player_sprite.sprite_frames.has_animation(animation_name):
		animation_name = ("walk_" if moving else "idle_") + _facing
	if not _player_sprite.sprite_frames.has_animation(animation_name):
		return
	if _player_sprite.animation != animation_name:
		_player_sprite.play(animation_name)
