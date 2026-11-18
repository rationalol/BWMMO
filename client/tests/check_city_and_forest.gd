extends SceneTree

const ViewScript = preload("res://scripts/nuvema_online.gd")
const MinimapScript = preload("res://scripts/minimap_ui.gd")

var failures := 0


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[world-content] ok: %s" % message)
	else:
		push_error("[world-content] FAILED: %s" % message)
		failures += 1


func _pump(world: Node3D, limit: int = 400) -> void:
	for _i in range(limit):
		world._poll_chunks()
		if world.pending_chunks.is_empty():
			return
		OS.delay_msec(10)


func _mesh_count(node: Node) -> int:
	var count := 0
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current is MeshInstance3D:
			count += 1
		for child in current.get_children():
			stack.append(child)
	return count


func _material_names(node: Node) -> Array[String]:
	var names: Array[String] = []
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current is MeshInstance3D:
			var mesh_instance := current as MeshInstance3D
			var mesh: Mesh = mesh_instance.mesh
			if mesh != null:
				for surface in range(mesh.get_surface_count()):
					var material := mesh_instance.get_active_material(surface)
					if material is ShaderMaterial:
						var texture: Variant = (material as ShaderMaterial).get_shader_parameter("albedo_texture")
						if texture is Texture2D:
							names.append((texture as Texture2D).resource_path.get_file().get_basename().to_lower())
					elif material is BaseMaterial3D:
						var base := material as BaseMaterial3D
						if base.albedo_texture != null:
							names.append(base.albedo_texture.resource_path.get_file().get_basename().to_lower())
		for child in current.get_children():
			stack.append(child)
	return names


func _setup_world(map_info: Dictionary, grid: Vector2i) -> Node3D:
	var world: Node3D = ViewScript.new()
	root.add_child(world)
	if world.world_environment == null:
		world._build_environment()
	var self_info := {
		"id": "content-test",
		"name": "ContentTest",
		"color": "#ffffff",
		"sprite": 0,
		"x": grid.x,
		"y": grid.y,
		"dir": "down",
		"mapId": str(map_info.get("id", ""))
	}
	world.setup_map(map_info, self_info, [])
	return world


func _init() -> void:
	# Nacrene City is the first city with bundle-specific buildings. The cell
	# used to load with bundle 5 and silently dropped the museum, café and rows
	# of houses.
	var nacrene := {
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
				"asset": "unova_outdoor/cells/cell_19_18",
				"cellX": 19,
				"cellY": 18,
				"offsetX": 9728,
				"offsetZ": 9216
			}]
		}
	}
	var city := _setup_world(nacrene, Vector2i(19 * 32 + 8, 18 * 32 + 12))
	var asset := "unova_outdoor/cells/cell_19_18"
	_check(city.loaded_chunks.has(asset), "Nacrene cell loads")
	var city_meshes := 0
	if city.loaded_chunks.has(asset):
		var city_root: Node3D = city.loaded_chunks[asset]["root"]
		# Terrain plus the 19 props (five bundle-2 buildings, café furniture,
		# Pokémon Center and sign) should all instantiate.
		_check(city_root.get_child_count() >= 15, "Nacrene cell instantiates its props")
		city_meshes = _mesh_count(city_root)
	_check(city_meshes >= 20, "Nacrene has terrain and building meshes")
	_check(city.minimap_viewport != null, "minimap viewport exists")
	_check(city.minimap_texture() != null, "minimap viewport exposes a texture")
	_check(city.minimap_chunks.has(asset), "minimap mirrors the current chunk")
	var mirror: Node3D = city.minimap_chunks.get(asset, null)
	_check(
		mirror != null and mirror.get_child_count() >= 15,
		"minimap mirror contains the cell props"
	)
	_check(
		city.minimap_camera != null and city.minimap_camera.current,
		"minimap camera is active"
	)
	_check(
		city.self_actor.get("minimap_root", null) != null,
		"minimap mirrors the player actor"
	)
	if city.minimap_camera != null:
		city._process(0.016)
		var close_camera_y: float = city.minimap_camera.position.y
		city.set_minimap_large(true)
		city._process(0.016)
		_check(
			city.minimap_camera.position.y > close_camera_y,
			"large minimap zooms the camera out"
		)
		city.set_minimap_large(false)
	var widget = MinimapScript.new()
	root.add_child(widget)
	widget.set_preview_texture(city.minimap_texture())
	widget.configure({"id": "unova_full"}, "Unova", Vector2i.ZERO, "down")
	_check(widget._use_preview(), "3D maps use the rendered minimap preview")
	widget.configure({"id": "town"}, "Town", Vector2i.ZERO, "down")
	_check(not widget._use_preview(), "legacy 2D maps keep the tile minimap")
	root.remove_child(widget)
	widget.free()
	city._clear_map_scene()
	city.free()

	# Pinwheel Forest is a separate 4x3 matrix. It must use the outdoor camera
	# (sky, no indoor room framing) and its path/walkway materials must load.
	var forest_chunks: Array = []
	for cell_x in range(4):
		for cell_y in range(3):
			forest_chunks.append({
				"asset": "unova_indoor/zone_155/%d_%d" % [cell_x, cell_y],
				"cellX": cell_x,
				"cellY": cell_y,
				"offsetX": cell_x * 512,
				"offsetZ": cell_y * 512,
				"mapFile": "unova_indoor/mapsets/tex_106/m_dun0201_%02d_%02d.glb" % [cell_x, cell_y],
				"props": []
			})
	var forest := {
		"id": "unova_in_155",
		"name": "Pinwheel Forest",
		"zone": 155,
		"outdoor": true,
		"width": 128,
		"height": 96,
		"tiles": [],
		"npcs": [],
		"visual": {
			"originX": -248,
			"originZ": -248,
			"tile": 16,
			"cellSize": 32,
			"chunks": forest_chunks
		}
	}
	var forest_world := _setup_world(forest, Vector2i(85, 73))
	_check(not forest_world.indoor_view, "Pinwheel Forest uses the outdoor camera")
	_pump(forest_world)
	_check(forest_world.loaded_chunks.size() >= 5, "Pinwheel streams its neighbouring cells")
	var forest_meshes := 0
	var forest_materials: Array[String] = []
	for entry in forest_world.loaded_chunks.values():
		var chunk_root: Node3D = entry["root"]
		forest_meshes += _mesh_count(chunk_root)
		forest_materials.append_array(_material_names(chunk_root))
	_check(forest_meshes > 0, "Pinwheel has terrain meshes")
	var has_path := false
	for material_name in forest_materials:
		if (
			material_name.contains("michi")
			or material_name.begins_with("dansa")
			or material_name.begins_with("kaidan")
			or material_name.begins_with("d2michi")
		):
			has_path = true
			break
	_check(has_path, "Pinwheel path/walkway materials are present")
	print(
		"[world-content] Nacrene meshes=%d, Pinwheel chunks=%d meshes=%d"
		% [city_meshes, forest_world.loaded_chunks.size(), forest_meshes]
	)
	forest_world._clear_map_scene()
	forest_world.free()
	print("[world-content] %s" % ("FAILED" if failures > 0 else "PASSED"))
	quit(1 if failures > 0 else 0)
