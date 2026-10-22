extends SceneTree

const WorldScript = preload("res://scripts/nuvema_online.gd")
const PC_B0 := "res://assets/bw/unova_outdoor/props/b0/p0_pc_01/pc_01.glb"
const DOOR_B0 := "res://assets/bw/unova_outdoor/props/b0/p0_pc_01/door_pc.glb"
const DOOR_B5 := "res://assets/bw/unova_outdoor/props/b5/p0_pc_01/door_pc.glb"

var failures := 0


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[doors] ok: %s" % message)
	else:
		push_error("[doors] FAILED: %s" % message)
		failures += 1


func _relative_transform(node: Node3D, ancestor: Node3D) -> Transform3D:
	var result := node.transform
	var current := node.get_parent()
	while current != null and current != ancestor:
		if current is Node3D:
			result = (current as Node3D).transform * result
		current = current.get_parent()
	return result


func _init() -> void:
	var world: Node3D = WorldScript.new()
	root.add_child(world)

	_check(world._building_door_file(PC_B0) == "door_pc.glb", "pc_01 maps to door_pc.glb")

	var pc_scene: PackedScene = load(PC_B0)
	_check(pc_scene != null, "Pokemon Center model loads")
	if pc_scene != null:
		var pc: Node = pc_scene.instantiate()
		root.add_child(pc)
		var mesh_instance: MeshInstance3D = null
		for node in pc.find_children("*", "MeshInstance3D", true, false):
			mesh_instance = node
			break
		_check(mesh_instance != null, "Pokemon Center has a mesh")
		if mesh_instance != null:
			var mesh_transform := _relative_transform(mesh_instance, pc)
			_check(
				mesh_transform.origin.is_zero_approx()
				and mesh_transform.basis.is_equal_approx(Basis.IDENTITY),
				"Pokemon Center mesh uses the prop's local space"
			)
			world._fix_mesh_instance(mesh_instance)
			var window_material := mesh_instance.get_surface_override_material(1) as BaseMaterial3D
			_check(window_material != null, "window surface gets a material override")
			if window_material != null:
				_check(window_material.texture_repeat, "window material enables UV repeat")
			var shadow_material := mesh_instance.get_surface_override_material(0) as BaseMaterial3D
			_check(
				shadow_material != null and shadow_material.texture_repeat,
				"ground shadow material enables UV repeat"
			)

	for path in [DOOR_B0, DOOR_B5]:
		var door_scene: PackedScene = load(path)
		_check(door_scene != null, "door loads: %s" % path.get_file())
		if door_scene == null:
			continue
		var door: Node = door_scene.instantiate()
		root.add_child(door)
		_check(
			not door.find_children("*", "MeshInstance3D", true, false).is_empty(),
			"door has mesh geometry: %s" % path.get_base_dir().get_file()
		)

	var door_scene_b0: PackedScene = load(DOOR_B0)
	var holder := Node3D.new()
	root.add_child(holder)
	world._attach_building_door(holder, PC_B0, {DOOR_B0: door_scene_b0})
	_check(holder.get_child_count() == 1, "door is attached to the building")
	if holder.get_child_count() > 0:
		var attached := holder.get_child(0) as Node3D
		_check(
			attached != null and attached.position.is_equal_approx(Vector3(0, 0, 18)),
			"door is offset to the entrance face"
		)
		if attached != null:
			_check(
				not attached.find_children("*", "MeshInstance3D", true, false).is_empty(),
				"attached door contains meshes"
			)

	var placements := {
		"mapFile": "map/map24_20.glb",
		"props": [
			{
				"file": "unova_outdoor/props/b0/p0_pc_01/pc_01.glb",
				"x": 0.0,
				"y": 0.0,
				"z": 0.0,
				"rotation": 0.0
			}
		]
	}
	var paths: Array = world._chunk_paths("unova_outdoor/cells/cell_24_20", placements)
	_check(paths.has(DOOR_B0), "chunk streaming preloads the door")

	var placements_b5 := {
		"mapFile": "map/map24_18.glb",
		"props": [
			{
				"file": "unova_outdoor/props/b5/p0_pc_01/pc_01.glb",
				"x": 0.0,
				"y": 0.0,
				"z": 0.0,
				"rotation": 0.0
			}
		]
	}
	var paths_b5: Array = world._chunk_paths("unova_outdoor/cells/cell_24_18", placements_b5)
	_check(paths_b5.has(DOOR_B5), "chunk streaming preloads the bundle-5 door")

	print("[doors] %s" % ("FAILED" if failures > 0 else "PASSED"))
	quit(1 if failures > 0 else 0)
