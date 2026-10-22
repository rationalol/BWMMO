extends SceneTree

const ViewScript = preload("res://scripts/nuvema_online.gd")
const FoliageShader = preload("res://shaders/foliage_wind.gdshader")

func _init() -> void:
	var failures := 0
	var world: Node3D = ViewScript.new()
	root.add_child(world)
	if world.world_environment == null:
		world._build_environment()

	var map_info := {
		"id": "unova_full",
		"name": "Unova",
		"width": 928,
		"height": 864,
		"tiles": [],
		"npcs": [],
		"visual": {
			"originX": -248,
			"originZ": -248,
			"tile": 16,
			"cellSize": 32,
			"chunks": [{
				"asset": "unova_outdoor/cells/cell_24_22",
				"cellX": 24,
				"cellY": 22,
				"offsetX": 12288,
				"offsetZ": 11264
			}]
		}
	}
	var self_info := {
		"id": "visual-test",
		"name": "VisualTest",
		"color": "#ffffff",
		"sprite": 0,
		"x": 784,
		"y": 720,
		"dir": "down",
		"mapId": "unova_full"
	}
	world.setup_map(map_info, self_info, [])
	world._process(0.016)

	if world.loaded_chunks.size() != 1:
		push_error("Route 1 chunk was not loaded")
		failures += 1
	world.set_world_time(12.0, false)
	var day_energy: float = world.world_environment.ambient_light_energy
	var day_sky: Color = world._sky_material.sky_top_color
	world.set_world_time(23.0, false)
	var night_energy: float = world.world_environment.ambient_light_energy
	var night_sky: Color = world._sky_material.sky_top_color
	if night_energy >= day_energy:
		push_error("night ambient is not darker than day ambient")
		failures += 1
	if night_sky.get_luminance() >= day_sky.get_luminance():
		push_error("night sky is not darker than day sky")
		failures += 1
	world.set_world_time(23.0, true)
	if world.world_environment.ambient_light_energy < 0.4:
		push_error("indoor night ambient is too dark")
		failures += 1
	world.set_world_time(12.0, false)

	var actor_frames: SpriteFrames = world._frames_for("hero")
	if actor_frames == null or actor_frames.get_frame_count("run_down") != 4:
		push_error("run cycle should keep the four extracted frames")
		failures += 1
	elif not is_equal_approx(actor_frames.get_animation_speed("run_down"), 8.0):
		push_error("run cycle should play at 8 fps (two tiles per cycle)")
		failures += 1
	elif not is_equal_approx(actor_frames.get_animation_speed("walk_down"), 4.0):
		push_error("walk cycle should play at 4 fps (two tiles per cycle)")
		failures += 1

	var mesh_count := 0
	var shader_surfaces := 0
	var static_surfaces := 0
	var foliage_with_tex_size := 0
	var stack: Array[Node] = [world]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			mesh_count += 1
			for surface in range(node.mesh.get_surface_count()):
				var material: Material = node.get_surface_override_material(surface)
				if material is ShaderMaterial:
					shader_surfaces += 1
					var shader_material := material as ShaderMaterial
					if shader_material.shader == FoliageShader:
						var tex_size: Variant = shader_material.get_shader_parameter("tex_size")
						if tex_size is Vector2 and (tex_size as Vector2).x > 0.0:
							foliage_with_tex_size += 1
				elif material != null:
					static_surfaces += 1
		for child in node.get_children():
			stack.append(child)

	print("[visuals] meshes=%d shader_surfaces=%d static_overrides=%d foliage_tex_size=%d" % [
		mesh_count, shader_surfaces, static_surfaces, foliage_with_tex_size
	])
	if mesh_count == 0 or shader_surfaces == 0:
		push_error("Route 1 materials were not processed")
		failures += 1
	if foliage_with_tex_size == 0:
		push_error("foliage materials did not receive their texture size")
		failures += 1

	# Held run input must chain into the next tile without dropping a step.
	var training_tiles: Array[String] = []
	for row in range(7):
		training_tiles.append(".......")
	world.map_data["tiles"] = training_tiles
	world.map_data["tileX"] = 781
	world.map_data["tileY"] = 717
	world.map_data["tileWidth"] = 7
	world.map_data["tileHeight"] = 7
	world.self_actor["grid"] = Vector2i(784, 720)
	world.self_grid = Vector2i(784, 720)
	world.self_actor["moving"] = false
	world.self_actor["root"].position = world._grid_position(Vector2i(784, 720))
	var first_step: bool = world.predict_self_move("right")
	var step_target: Vector3 = world.self_actor["target"]
	world.self_actor["root"].position = step_target - Vector3(1.5, 0.0, 0.0)
	var chained_step: bool = world.predict_self_move("right")
	if not first_step or not chained_step:
		push_error("held movement did not chain while the previous tile was finishing")
		failures += 1
	if world.self_grid != Vector2i(786, 720):
		push_error("chained movement ended on %s" % str(world.self_grid))
		failures += 1
	if not world.is_self_moving():
		push_error("chained movement did not start the next animation")
		failures += 1

	world._clear_map_scene()
	world.free()
	print("[visuals] %s" % ("FAILED" if failures > 0 else "PASSED"))
	quit(1 if failures > 0 else 0)
