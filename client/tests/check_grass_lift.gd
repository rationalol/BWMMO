extends SceneTree

const ViewScript = preload("res://scripts/nuvema_online.gd")
const CELL := 32

var failures := 0

func _check(condition: bool, message: String) -> void:
	if condition:
		print("[grass-lift] ok: %s" % message)
	else:
		push_error("[grass-lift] %s" % message)
		failures += 1

func _flat_heights() -> PackedInt32Array:
	var heights := PackedInt32Array()
	heights.resize(CELL * CELL)
	return heights

func _grass_card(height: float, tile: Vector2i) -> MeshInstance3D:
	# Tile k is centred at -248 + k * 16, so its 16-unit span starts half a tile
	# earlier, at -256 + k * 16.
	var left := -256.0 + float(tile.x) * 16.0
	var top := -256.0 + float(tile.y) * 16.0
	var right := left + 16.0
	var bottom := top + 16.0
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(left, height, top),
		Vector3(right, height, top),
		Vector3(right, height, bottom),
		Vector3(left, height, bottom),
	])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := StandardMaterial3D.new()
	material.resource_name = "kusa_ec1"
	mesh.surface_set_material(0, material)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	return instance

func _init() -> void:
	var world: Node3D = ViewScript.new()
	root.add_child(world)
	world.map_origin = Vector2(-248, -248)
	world.world_tile = 16.0
	world.world_cell_size = CELL
	world.height_scale = 16.0
	world.chunk_heights[Vector2i.ZERO] = _flat_heights()

	var card := _grass_card(10.0, Vector2i(2, 3))
	world.add_child(card)
	world._fix_mesh_instance(card)
	world._collect_grass_lift(card, Vector2i.ZERO)

	_check(world._height_at(Vector2i(2, 3)) == 0.0, "terrain height stays at the ROM floor")
	_check(
		is_equal_approx(world._stand_height(Vector2i(2, 3)), 10.0),
		"actor stands on the raised grass card"
	)
	_check(
		is_equal_approx(world._grid_position(Vector2i(2, 3)).y, 10.0),
		"grid position uses the grass surface"
	)
	_check(
		world._stand_height(Vector2i(6, 6)) == 0.0,
		"tiles without a grass card keep the terrain height"
	)
	if not world._can_step(Vector2i(2, 3), Vector2i(2, 4)):
		_check(false, "grass lift must not affect step validation")
	else:
		_check(true, "grass lift must not affect step validation")

	# Indoors the height grid is sampled from the room mesh and already contains
	# the card; the lift must then collapse to zero instead of lifting twice.
	var sampled := _flat_heights()
	sampled[3 * CELL + 2] = 160
	world.chunk_heights[Vector2i.ZERO] = sampled
	world._collect_grass_lift(card, Vector2i.ZERO)
	_check(
		is_equal_approx(world._stand_height(Vector2i(2, 3)), 10.0),
		"GLB-sampled grass heights are not lifted twice"
	)

	# A card from a ledge far above the tile must not fling the actor upward.
	var high := _grass_card(200.0, Vector2i(5, 5))
	world.add_child(high)
	world._fix_mesh_instance(high)
	world.chunk_heights[Vector2i.ZERO] = _flat_heights()
	world._collect_grass_lift(high, Vector2i.ZERO)
	_check(
		world._stand_height(Vector2i(5, 5)) <= ViewScript.GRASS_LIFT_LIMIT,
		"grass lift is clamped to a sane height"
	)

	world.free()
	print("[grass-lift] %s" % ("FAILED" if failures > 0 else "PASSED"))
	quit(1 if failures > 0 else 0)
