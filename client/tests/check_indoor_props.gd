extends SceneTree

const ViewScript = preload("res://scripts/nuvema_online.gd")

var failures := 0

func _check(condition: bool, message: String) -> void:
	if condition:
		print("[indoor-props] ok: %s" % message)
	else:
		push_error("[indoor-props] %s" % message)
		failures += 1

func _init() -> void:
	var world: Node3D = ViewScript.new()
	root.add_child(world)
	world._build_environment()
	world._build_camera()

	world.indoor_view = true
	world.map_data = {"name": "Pokémon Center"}
	_check(
		world._is_indoor_structural_prop("unova_indoor/propsets/b6/pc_01.glb"),
		"Pokémon Center building shell is hidden indoors"
	)
	_check(
		world._is_indoor_structural_prop("unova_indoor/propsets/b6/c04_football_01.glb"),
		"football test prop is hidden indoors"
	)
	_check(
		world._is_indoor_structural_prop("unova_indoor/propsets/b6/searock_01.glb"),
		"town rock is hidden inside the Pokémon Center"
	)
	_check(
		world._is_indoor_structural_prop("unova_indoor/propsets/b6/buill_01.glb"),
		"existing building shell filter still works"
	)
	_check(
		not world._is_indoor_structural_prop("unova_indoor/propsets/b6/c04_001.glb"),
		"normal interior props are kept"
	)

	world.map_data = {"name": "Interior"}
	_check(
		not world._is_indoor_structural_prop("unova_indoor/propsets/b6/searock_01.glb"),
		"cave/interior rocks are kept"
	)

	world.indoor_view = false
	_check(
		not world._is_indoor_structural_prop("unova_indoor/propsets/b6/pc_01.glb"),
		"outdoor PC building is kept"
	)

	# Build the real Nuvema Pokémon Center and make sure the three scenery
	# props are not instantiated into the room.
	var path := "F:/AgentProject/BWMMO/server/content/maps/unova_in_398.json"
	var map_info: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	if map_info.is_empty():
		push_error("[indoor-props] could not read %s" % path)
		failures += 1
	else:
		world.indoor_view = true
		world.map_data = map_info
		world.self_grid = Vector2i(7, 14)
		world._build_map_scene(map_info, world.self_grid)
		var names: Array[String] = []
		var stack: Array[Node] = [world.map_root]
		while not stack.is_empty():
			var node: Node = stack.pop_back()
			names.append(str(node.name).to_lower())
			for child in node.get_children():
				stack.append(child)
		for unwanted in ["pc_01", "searock_01", "c04_football_01"]:
			_check(not names.has(unwanted), "center does not instantiate %s" % unwanted)
		_check(names.has("m_pc01_00_00"), "center map mesh is still instantiated")

	if failures == 0:
		print("[indoor-props] PASSED")
		quit(0)
	else:
		push_error("[indoor-props] FAILED (%d)" % failures)
		quit(1)
