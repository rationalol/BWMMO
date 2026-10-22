extends Node3D

const ACTOR_ROOT := "res://assets/bw/nuvema/actors"
const ASSET_ROOT := "res://assets/bw"
const TILE := 16.0
const CELL_SIZE := 32
const CHUNK_RADIUS := 1
const WALK_SPEED := 32.0
const RUN_SPEED := 64.0
# The extracted walk/run animations are a 4-frame cycle containing two
# footfalls (neutral, left stride, neutral, right stride), so one cycle spans
# two tiles. At 32 units/s a walk tile takes 0.5 s and a run tile (64 units/s)
# takes 0.25 s, which puts the cycles at 1 s (4 fps) and 0.5 s (8 fps).
const WALK_ANIM_FPS := 4.0
const RUN_ANIM_FPS := 8.0
const CAMERA_OFFSET := Vector3(0, 270, 310)
const CAMERA_TARGET := Vector3(0, 22, -22)
const INDOOR_CAMERA_OFFSET := Vector3(0, 220, 165)
const INDOOR_CAMERA_TARGET := Vector3(0, 10, -20)
const MAX_STEP_UP := 24.0
const MAX_STEP_DOWN := 128.0
const CHAIN_SNAP_DISTANCE := 3.0
const NAME_HEIGHT := 46.0
const BUBBLE_HEIGHT := 74.0
# Building meshes are shells; their doors live in separate ROM props authored
# at the building origin, so they are instantiated alongside the building.
const BUILDING_DOORS := {
	"pc_01.glb": "door_pc.glb",
}
# The building origin is at its center, while the ROM places the door at the
# front of the entrance. This offset puts the door flush with the arch face.
const BUILDING_DOOR_OFFSETS := {
	"pc_01.glb": Vector3(0, 0, 18),
}
const FOLIAGE_SHADER = preload("res://shaders/foliage_wind.gdshader")
const MAP_LIT_SHADER = preload("res://shaders/map_lit.gdshader")
const WATER_SHADER = preload("res://shaders/water_flow.gdshader")
const SEASONAL_FLOWER_SHADER = preload("res://shaders/seasonal_flower.gdshader")
const WorldTimeScript = preload("res://scripts/world_time.gd")
const SHADOW_TEXTURE = preload("res://assets/effects/blob_shadow.png")

var map_data: Dictionary = {}
var self_data: Dictionary = {}
var self_id := ""
var self_grid := Vector2i.ZERO
var self_facing := "down"
var self_actor: Dictionary = {}
var peers: Dictionary = {}
var npcs: Dictionary = {}
var camera: Camera3D
var world_environment: Environment
var _sun_light: DirectionalLight3D = null
var _fill_light: DirectionalLight3D = null
var _sky_material: ProceduralSkyMaterial = null
var map_root: Node3D
var asset_root := ""
var map_origin := Vector2(-248, -248)
var world_tile := TILE
var world_cell_size := CELL_SIZE
var world_chunks: Array = []
var world_chunk_radius := CHUNK_RADIUS
var loaded_chunks: Dictionary = {}
var pending_chunks: Dictionary = {}
var chunk_heights: Dictionary = {}
var height_scale := 16.0
var season := "autumn"
var seasonal_props: Dictionary = {}
var indoor_view := false
var indoor_room_fixed := false
var indoor_room_center := Vector3.ZERO
var self_cell := Vector2i(-1, -1)
var _frame_cache: Dictionary = {}

func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--season="):
			season = argument.substr(9).to_lower()
			if not season in ["spring", "summer", "autumn", "winter"]:
				season = "autumn"
	_load_seasonal_props()
	_build_environment()
	_build_camera()

func _season_index() -> int:
	match season:
		"spring":
			return 0
		"summer":
			return 1
		"winter":
			return 3
		_:
			return 2

func set_active(active: bool) -> void:
	visible = active
	if active and camera != null:
		camera.make_current()

func _load_seasonal_props() -> void:
	var path := "res://assets/bw/unova_outdoor/seasonal_props.json"
	if FileAccess.file_exists(path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary:
			seasonal_props = parsed

func _resolve_seasonal_prop(filename: String) -> String:
	var base := filename.get_file().get_basename().to_lower()
	for suffix in ["_spring", "_summer", "_autumn", "_winter"]:
		if not base.ends_with(suffix):
			continue
		var family := base.substr(0, base.length() - suffix.length())
		var variants = seasonal_props.get(family)
		if variants is Dictionary and variants.has(season):
			return str(variants[season])
		break
	return filename

func _build_environment() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-52, 105, 0)
	light.light_energy = 0.65
	light.shadow_enabled = false
	light.shadow_blur = 1.5
	light.shadow_bias = 0.06
	light.shadow_normal_bias = 1.6
	light.directional_shadow_max_distance = 900.0
	add_child(light)
	_sun_light = light
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-22, 150, 0)
	fill.light_energy = 0.18
	fill.shadow_enabled = false
	add_child(fill)
	_fill_light = fill
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.36, 0.58, 0.82)
	sky_material.sky_horizon_color = Color(0.74, 0.84, 0.78)
	sky_material.ground_bottom_color = Color(0.18, 0.28, 0.18)
	sky_material.ground_horizon_color = Color(0.62, 0.72, 0.58)
	sky.sky_material = sky_material
	_sky_material = sky_material
	environment.sky = sky
	environment.fog_enabled = false
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.74, 0.80, 0.92)
	environment.ambient_light_energy = 0.4
	env.environment = environment
	world_environment = environment
	add_child(env)
	set_world_time(WorldTimeScript.now_hours(), false)

func set_world_time(hours: float, indoor: bool = false) -> void:
	var sky := WorldTimeScript.sky_colors(hours)
	if _sky_material != null and not indoor:
		_sky_material.sky_top_color = sky["sky_top"]
		_sky_material.sky_horizon_color = sky["sky_horizon"]
		_sky_material.ground_horizon_color = sky["ground_horizon"]
		_sky_material.ground_bottom_color = sky["ground_bottom"]
	if world_environment != null:
		if indoor:
			var darkness := WorldTimeScript.darkness(hours)
			world_environment.ambient_light_color = Color(0.92, 0.84, 0.70)
			world_environment.ambient_light_energy = lerpf(0.72, 0.58, darkness)
		else:
			world_environment.ambient_light_color = sky["ambient"]
			world_environment.ambient_light_energy = sky["ambient_energy"]
	if _sun_light != null and not indoor:
		_sun_light.light_color = sky["sun"]
		_sun_light.light_energy = sky["sun_energy"]
		_sun_light.rotation_degrees = Vector3(sky["pitch"], sky["yaw"], 0.0)
	if _fill_light != null and not indoor:
		_fill_light.light_color = sky["fill"]
		_fill_light.light_energy = sky["fill_energy"]

func _clear_map_scene() -> void:
	if map_root != null and is_instance_valid(map_root):
		remove_child(map_root)
		map_root.queue_free()
	map_root = null
	loaded_chunks.clear()
	pending_chunks.clear()
	chunk_heights.clear()
	indoor_room_fixed = false
	indoor_room_center = Vector3.ZERO
	world_chunks.clear()
	asset_root = ""
	map_origin = Vector2(-248, -248)
	world_tile = TILE
	world_cell_size = CELL_SIZE
	height_scale = 16.0
	world_chunk_radius = CHUNK_RADIUS
	self_cell = Vector2i(-1, -1)

func _build_map_scene(map_info: Dictionary, grid: Vector2i) -> void:
	_clear_map_scene()
	map_root = Node3D.new()
	map_root.name = "RomMap"
	add_child(map_root)

	var visual: Dictionary = map_info.get("visual", {})
	if not visual.is_empty():
		map_origin = Vector2(
			float(visual.get("originX", -248)),
			float(visual.get("originZ", -248))
		)
		world_tile = float(visual.get("tile", TILE))
		world_cell_size = int(visual.get("cellSize", CELL_SIZE))
		height_scale = float(visual.get("heightScale", 16))
		if height_scale <= 0.0:
			height_scale = 16.0
		world_chunks = visual.get("chunks", [])
		if not world_chunks.is_empty():
			world_chunk_radius = 2 if world_chunks.size() > 20 else CHUNK_RADIUS
			self_cell = _chunk_cell()
		_refresh_chunks(true)
		return

	var map_id := str(map_info.get("id", ""))
	asset_root = "%s/%s" % [ASSET_ROOT, map_id]
	var placements_path := "%s/placements.json" % asset_root
	if not FileAccess.file_exists(placements_path):
		push_error("Map assets missing: %s" % placements_path)
		return
	var placements: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(placements_path))
	var map_file := str(placements.get("mapFile", ""))
	if map_file != "":
		var packed: PackedScene = load("%s/%s" % [asset_root, map_file])
		if packed != null:
			var map_instance: Node = packed.instantiate()
			map_root.add_child(map_instance)
			_fix_mesh_tree(map_instance)
	var prop_files: Dictionary = placements.get("propFiles", {})
	for placement in placements.get("props", []):
		var prop_id := int(placement.get("prop", 0))
		var filename := str(prop_files.get(str(prop_id), ""))
		if filename == "":
			continue
		var path := "%s/props/%s" % [asset_root, filename]
		if not ResourceLoader.exists(path):
			continue
		var prop_packed: PackedScene = load(path)
		if prop_packed == null:
			continue
		var prop := prop_packed.instantiate()
		prop.position = Vector3(
			float(placement.get("x", 0)),
			float(placement.get("y", 0)),
			float(placement.get("z", 0))
		)
		prop.rotation_degrees.y = float(placement.get("rotation", 0))
		_attach_building_door(prop, path, {})
		map_root.add_child(prop)
		_fix_mesh_tree(prop)

func _chunk_cell() -> Vector2i:
	return Vector2i(
		int(floor(float(self_grid.x) / float(maxi(1, world_cell_size)))),
		int(floor(float(self_grid.y) / float(maxi(1, world_cell_size))))
	)

func _chunk_coords(chunk: Dictionary) -> Vector2i:
	if chunk.has("cellX") or chunk.has("cellY"):
		return Vector2i(int(chunk.get("cellX", 0)), int(chunk.get("cellY", 0)))
	return Vector2i(0, int(chunk.get("cell", 0)))

func _prop_path(asset: String, filename: String) -> String:
	if filename.begins_with("res://"):
		return filename
	if filename.contains("/"):
		return "%s/%s" % [ASSET_ROOT, filename]
	return "%s/%s/props/%s" % [ASSET_ROOT, asset, filename]

func _building_door_file(filename: String) -> String:
	return str(BUILDING_DOORS.get(filename.get_file(), ""))

func _building_door_offset(filename: String) -> Vector3:
	return BUILDING_DOOR_OFFSETS.get(filename.get_file(), Vector3.ZERO)

func _attach_building_door(prop: Node3D, building_path: String, resources: Dictionary) -> void:
	var door_file := _building_door_file(building_path)
	if door_file == "":
		return
	var door_path := "%s/%s" % [building_path.get_base_dir(), door_file]
	var door_packed: PackedScene = resources.get(door_path)
	if door_packed == null and ResourceLoader.exists(door_path):
		door_packed = load(door_path)
	if door_packed == null:
		push_warning("Missing building door asset: %s" % door_path)
		return
	var door := door_packed.instantiate() as Node3D
	if door == null:
		return
	door.position = _building_door_offset(building_path)
	prop.add_child(door)

func _is_indoor_structural_prop(filename: String) -> bool:
	# Interior chunks also carry the building shell used to frame the room.
	# Rendering it from the indoor camera hides the floor and NPCs, so skip it.
	if not indoor_view:
		return false
	var base := filename.get_file().to_lower()
	if (
		base.begins_with("buill")
		or base.begins_with("thouse")
		or base.begins_with("r4_build")
		or base.begins_with("r5_build")
	):
		return true
	# Pokémon Center rooms also carry the center's own exterior shell, the
	# town scenery rock, and a test football pitch from the surrounding mapset.
	# The raised indoor camera sees all three inside the room (the shell and
	# pitch cover most of the screen), so they are structural for this view too.
	if base.begins_with("pc_01") or base.begins_with("c04_football"):
		return true
	return base.begins_with("searock") and str(map_data.get("name", "")).contains("Center")

func _refresh_chunks(immediate: bool = false) -> void:
	if world_chunks.is_empty():
		return
	var cell := _chunk_cell()
	self_cell = cell
	for chunk in world_chunks:
		var chunk_cell := _chunk_coords(chunk)
		var asset := str(chunk.get("asset", ""))
		if asset == "":
			continue
		var distance := maxi(absi(chunk_cell.x - cell.x), absi(chunk_cell.y - cell.y))
		if distance <= world_chunk_radius:
			if loaded_chunks.has(asset) or pending_chunks.has(asset):
				continue
			if chunk_cell == cell:
				_load_chunk_now(chunk)
			else:
				_request_chunk(chunk)
		else:
			_unload_chunk(asset)

func _chunk_placement(chunk: Dictionary) -> Dictionary:
	if chunk.has("mapFile"):
		var inline: Dictionary = chunk.duplicate(true)
		inline["_inline"] = true
		return inline
	var asset := str(chunk.get("asset", ""))
	var path := "%s/%s/placements.json" % [ASSET_ROOT, asset]
	if not FileAccess.file_exists(path):
		push_error("Chunk manifest missing: %s" % path)
		return {}
	return JSON.parse_string(FileAccess.get_file_as_string(path))

func _map_asset_path(asset: String, placements: Dictionary, map_file: String) -> String:
	if bool(placements.get("_inline", false)):
		return "%s/%s" % [ASSET_ROOT, map_file]
	return "%s/%s/%s" % [ASSET_ROOT, asset, map_file]

func _chunk_paths(asset: String, placements: Dictionary) -> Array:
	var paths: Array = []
	var map_file := str(placements.get("mapFile", ""))
	if map_file == "":
		return paths
	paths.append(_map_asset_path(asset, placements, map_file))
	var prop_files: Dictionary = placements.get("propFiles", {})
	for placement in placements.get("props", []):
		var filename := str(placement.get("file", ""))
		if filename == "":
			var prop_id := int(placement.get("prop", 0))
			filename = str(prop_files.get(str(prop_id), ""))
		filename = _resolve_seasonal_prop(filename)
		if filename == "" or _is_indoor_structural_prop(filename):
			continue
		var path := _prop_path(asset, filename)
		if not paths.has(path):
			paths.append(path)
		var door_file := _building_door_file(filename)
		if door_file != "":
			var door_path := "%s/%s" % [path.get_base_dir(), door_file]
			if not paths.has(door_path):
				paths.append(door_path)
	return paths

func _load_chunk_now(chunk: Dictionary) -> void:
	var asset := str(chunk.get("asset", ""))
	var placements := _chunk_placement(chunk)
	if placements.is_empty():
		return
	var resources := {}
	for path in _chunk_paths(asset, placements):
		resources[path] = load(path)
	_instantiate_chunk(asset, chunk, placements, resources)

func _request_chunk(chunk: Dictionary) -> void:
	var asset := str(chunk.get("asset", ""))
	var placements := _chunk_placement(chunk)
	if placements.is_empty():
		return
	var paths := _chunk_paths(asset, placements)
	if paths.is_empty():
		return
	var loaded := {}
	for path in paths:
		if ResourceLoader.load_threaded_request(path, "PackedScene") != OK:
			push_error("Could not stream chunk asset: %s" % path)
	pending_chunks[asset] = {
		"chunk": chunk,
		"placements": placements,
		"paths": paths,
		"loaded": loaded
	}

func _poll_chunks() -> void:
	for asset in pending_chunks.keys():
		var entry: Dictionary = pending_chunks[asset]
		var loaded: Dictionary = entry["loaded"]
		var failed := false
		var ready := true
		for path in entry["paths"]:
			if loaded.has(path):
				continue
			var status := ResourceLoader.load_threaded_get_status(path)
			if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				ready = false
			elif status == ResourceLoader.THREAD_LOAD_LOADED:
				var resource = ResourceLoader.load_threaded_get(path)
				if resource == null:
					failed = true
					break
				loaded[path] = resource
			else:
				failed = true
				break
		if failed:
			push_error("Failed to stream chunk %s" % asset)
			pending_chunks.erase(asset)
			continue
		if not ready:
			continue
		var chunk: Dictionary = entry["chunk"]
		var chunk_cell := _chunk_coords(chunk)
		var distance := maxi(
			absi(chunk_cell.x - self_cell.x),
			absi(chunk_cell.y - self_cell.y)
		)
		if distance <= world_chunk_radius:
			_instantiate_chunk(asset, chunk, entry["placements"], loaded)
		pending_chunks.erase(asset)

func _instantiate_chunk(asset: String, chunk: Dictionary, placements: Dictionary, resources: Dictionary) -> void:
	if loaded_chunks.has(asset):
		return
	var root := Node3D.new()
	root.name = asset
	root.position = Vector3(
		float(chunk.get("offsetX", 0)),
		0,
		float(chunk.get("offsetZ", 0))
	)
	map_root.add_child(root)

	var map_file := str(placements.get("mapFile", ""))
	var map_path := _map_asset_path(asset, placements, map_file)
	var map_packed: PackedScene = resources.get(map_path)
	if map_packed != null:
		var map_instance: Node = map_packed.instantiate()
		root.add_child(map_instance)
		_fix_mesh_tree(map_instance)

	var prop_files: Dictionary = placements.get("propFiles", {})
	for placement in placements.get("props", []):
		var filename := str(placement.get("file", ""))
		if filename == "":
			var prop_id := int(placement.get("prop", 0))
			filename = str(prop_files.get(str(prop_id), ""))
		filename = _resolve_seasonal_prop(filename)
		if filename == "" or _is_indoor_structural_prop(filename):
			continue
		var path := _prop_path(asset, filename)
		var prop_packed: PackedScene = resources.get(path)
		if prop_packed == null:
			continue
		var prop := prop_packed.instantiate()
		prop.position = Vector3(
			float(placement.get("x", 0)),
			float(placement.get("y", 0)),
			float(placement.get("z", 0))
		)
		prop.rotation_degrees.y = float(placement.get("rotation", 0))
		_attach_building_door(prop, path, resources)
		root.add_child(prop)
		_fix_mesh_tree(prop)
	_fix_mesh_tree(root)

	var heights_text := str(chunk.get("heights", ""))
	if heights_text != "":
		var raw := Marshalls.base64_to_raw(heights_text)
		var heights := PackedInt32Array()
		heights.resize(raw.size() / 2)
		for index in range(heights.size()):
			heights[index] = raw.decode_s16(index * 2)
		chunk_heights[_chunk_coords(chunk)] = heights
		_reheight_actors()

	loaded_chunks[asset] = {"root": root, "cell": int(chunk.get("cell", 0))}

func _fix_mesh_tree(node: Node) -> void:
	if node is MeshInstance3D:
		_fix_mesh_instance(node)
	for child in node.get_children():
		_fix_mesh_tree(child)

func _is_foliage_material(material_name: String) -> bool:
	return (
		material_name.begins_with("ki")
		or material_name.begins_with("hana")
		or material_name.begins_with("kusa")
		or material_name.begins_with("r01_")
		or material_name.contains("leaf")
	)

func _is_soft_shadow_material(material_name: String) -> bool:
	return (
		material_name.contains("kage")
		or material_name.begins_with("ki02c")
		or material_name.begins_with("ki02dx")
	)

func _is_water_material(material_name: String) -> bool:
	return material_name.begins_with("sea_mizu") or material_name.begins_with("mizu_sita")

func _fix_mesh_instance(mesh_instance: MeshInstance3D) -> void:
	var mesh: Mesh = mesh_instance.mesh
	if mesh == null:
		return
	for surface in range(mesh.get_surface_count()):
		var source := mesh_instance.get_active_material(surface) as BaseMaterial3D
		if source == null:
			continue
		var material_name := source.resource_name.to_lower()
		if material_name == "" and source.albedo_texture != null:
			material_name = source.albedo_texture.resource_path.get_file().get_basename().to_lower()
		if (
			(
				material_name.begins_with("kisetu_hana")
				or material_name.begins_with("hana")
				or material_name.begins_with("r01_")
			)
			and source.albedo_texture != null
		):
			var flowers := ShaderMaterial.new()
			flowers.shader = SEASONAL_FLOWER_SHADER
			flowers.set_shader_parameter("albedo_texture", source.albedo_texture)
			flowers.set_shader_parameter("tex_size", source.albedo_texture.get_size())
			flowers.set_shader_parameter("season", _season_index())
			mesh_instance.set_surface_override_material(surface, flowers)
		elif _is_soft_shadow_material(material_name) and source.albedo_texture != null:
			var shadow_copy := source.duplicate() as BaseMaterial3D
			if shadow_copy != null:
				shadow_copy.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				shadow_copy.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				shadow_copy.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
				shadow_copy.texture_repeat = true
				shadow_copy.albedo_color.a = min(
					shadow_copy.albedo_color.a, 0.28 if material_name.contains("kage") else 0.55
				)
				mesh_instance.set_surface_override_material(surface, shadow_copy)
		elif _is_water_material(material_name) and source.albedo_texture != null:
			var water := ShaderMaterial.new()
			water.shader = WATER_SHADER
			water.set_shader_parameter("albedo_texture", source.albedo_texture)
			mesh_instance.set_surface_override_material(surface, water)
		elif _is_foliage_material(material_name) and source.albedo_texture != null:
			var wind := ShaderMaterial.new()
			wind.shader = FOLIAGE_SHADER
			wind.set_shader_parameter("albedo_texture", source.albedo_texture)
			wind.set_shader_parameter("tex_size", source.albedo_texture.get_size())
			if material_name.begins_with("r01_"):
				wind.set_shader_parameter("sway_strength", 0.55)
				wind.set_shader_parameter("sway_height", 8.0)
			elif material_name.begins_with("ki"):
				wind.set_shader_parameter("sway_strength", 0.32)
				wind.set_shader_parameter("sway_height", 18.0)
			else:
				wind.set_shader_parameter("sway_strength", 0.18)
				wind.set_shader_parameter("sway_height", 5.0)
			mesh_instance.set_surface_override_material(surface, wind)
		elif (
			source.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED
			and source.albedo_texture != null
		):
			var lit := ShaderMaterial.new()
			lit.shader = MAP_LIT_SHADER
			lit.set_shader_parameter("albedo_texture", source.albedo_texture)
			mesh_instance.set_surface_override_material(surface, lit)
		else:
			# Transparent/blended materials such as window glass keep their
			# baseColor alpha and blend mode.
			var copy := source.duplicate() as BaseMaterial3D
			if copy != null:
				copy.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
				# ROM window strips tile their UVs well outside 0..1; Godot's
				# glTF importer leaves repeat off, flattening them to one edge
				# texel. Repeat is harmless for the untiled UVs elsewhere.
				copy.texture_repeat = true
				mesh_instance.set_surface_override_material(surface, copy)
	# The map uses baked vertex shading like the original DS renderer; real
	# shadow maps made trees and building sides much harsher than BW.
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _unload_chunk(asset: String) -> void:
	if loaded_chunks.has(asset):
		var root: Node3D = loaded_chunks[asset]["root"]
		if root != null and is_instance_valid(root):
			map_root.remove_child(root)
			root.queue_free()
		loaded_chunks.erase(asset)
	pending_chunks.erase(asset)

func _build_camera() -> void:
	camera = Camera3D.new()
	camera.current = true
	camera.fov = 42.0
	camera.near = 1.0
	camera.far = 4000.0
	add_child(camera)

func _actor_key(sprite_id: int) -> String:
	match sprite_id:
		1:
			return "heroine"
		2:
			return "boy4"
		3:
			return "girl2"
		_:
			return "hero"

func _frames_for(key: String) -> SpriteFrames:
	if _frame_cache.has(key):
		return _frame_cache[key]
	var path := "%s/%s/actor.json" % [ACTOR_ROOT, key]
	if not FileAccess.file_exists(path):
		path = "%s/hero/actor.json" % ACTOR_ROOT
	if not FileAccess.file_exists(path):
		push_error("Actor frames missing: %s" % key)
		return null
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var frames := SpriteFrames.new()
	frames.remove_animation("default")
	var animations: Dictionary = data.get("animations", {})
	var folder := path.get_base_dir()
	for animation_name in animations.keys():
		frames.add_animation(str(animation_name))
		frames.set_animation_loop(str(animation_name), true)
		var frame_ids: Array = animations[animation_name].duplicate()
		frames.set_animation_speed(
			str(animation_name),
			RUN_ANIM_FPS if str(animation_name).begins_with("run_") else WALK_ANIM_FPS
		)
		for frame_number in frame_ids:
			var frame_path := "%s/frames/frame_%02d.png" % [folder, int(frame_number)]
			if ResourceLoader.exists(frame_path):
				frames.add_frame(str(animation_name), load(frame_path))
	if frames.get_animation_names().is_empty():
		push_error("No frames loaded for actor %s" % key)
		return null
	_frame_cache[key] = frames
	return frames

func _create_actor(key: String, display_name: String, color: Color, is_self: bool) -> Dictionary:
	var root := Node3D.new()
	add_child(root)
	var sprite := AnimatedSprite3D.new()
	var frames := _frames_for(key)
	sprite.sprite_frames = frames
	sprite.animation = (
		"idle_down"
		if frames.has_animation("idle_down")
		else str(frames.get_animation_names()[0])
	)
	sprite.pixel_size = 1.0
	sprite.position = Vector3(0, 15, 0)
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	sprite.no_depth_test = false
	sprite.play()
	root.add_child(sprite)

	var label := Label3D.new()
	label.text = display_name
	label.font_size = 28
	label.pixel_size = 0.11
	label.position = Vector3(0, NAME_HEIGHT, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = false
	label.outline_size = 8
	label.outline_modulate = Color(0.03, 0.04, 0.06, 0.9)
	label.modulate = Color(1.0, 0.82, 0.40) if is_self else color
	root.add_child(label)

	var bubble := Label3D.new()
	bubble.text = ""
	bubble.font_size = 24
	bubble.pixel_size = 0.11
	bubble.position = Vector3(0, BUBBLE_HEIGHT, 0)
	bubble.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	bubble.no_depth_test = false
	bubble.outline_size = 10
	bubble.outline_modulate = Color(0.03, 0.04, 0.06, 0.95)
	bubble.visible = false
	root.add_child(bubble)

	var shadow := MeshInstance3D.new()
	var shadow_quad := QuadMesh.new()
	shadow_quad.size = Vector2(30, 18)
	var shadow_material := StandardMaterial3D.new()
	shadow_material.albedo_texture = SHADOW_TEXTURE
	shadow_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shadow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shadow_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	shadow_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	shadow_material.no_depth_test = true
	shadow_material.render_priority = -1
	shadow_quad.material = shadow_material
	shadow.mesh = shadow_quad
	shadow.rotation_degrees = Vector3(-90, 0, 0)
	shadow.position = Vector3(0, 0.15, 0)
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(shadow)

	return {
		"sprite": sprite,
		"label": label,
		"bubble": bubble,
		"grid": Vector2i.ZERO,
		"facing": "down",
		"target": Vector3.ZERO,
		"moving": false,
		"speed": WALK_SPEED,
		"running": false,
		"stop_anim_at": 0,
		"bubble_until": 0,
		"root": root,
		"key": key
	}

func _height_at(grid: Vector2i) -> float:
	var cell_size := maxi(1, world_cell_size)
	var cell := Vector2i(
		int(floor(float(grid.x) / float(cell_size))),
		int(floor(float(grid.y) / float(cell_size)))
	)
	var heights: PackedInt32Array = chunk_heights.get(cell, PackedInt32Array())
	if heights.is_empty():
		return 0.0
	var local_x := grid.x - cell.x * cell_size
	var local_y := grid.y - cell.y * cell_size
	var index := local_y * cell_size + local_x
	if index < 0 or index >= heights.size():
		return 0.0
	return float(heights[index]) / height_scale

func _height_known(grid: Vector2i) -> bool:
	var cell_size := maxi(1, world_cell_size)
	var cell := Vector2i(
		int(floor(float(grid.x) / float(cell_size))),
		int(floor(float(grid.y) / float(cell_size)))
	)
	return chunk_heights.has(cell)

func _can_step(from: Vector2i, to: Vector2i) -> bool:
	# Until the destination chunk streams in, let the server arbitrate rather
	# than blocking movement at a cell seam on a false height of 0.
	if not _height_known(from) or not _height_known(to):
		return true
	var delta := _height_at(to) - _height_at(from)
	return delta <= MAX_STEP_UP and delta >= -MAX_STEP_DOWN

func _reheight_actors() -> void:
	for actor in _all_actors():
		var target: Vector3 = actor["target"]
		var height := _height_at(actor["grid"])
		target.y = height
		actor["target"] = target
		if not actor["moving"]:
			var root: Node3D = actor["root"]
			root.position.y = height

func _grid_position(grid: Vector2i) -> Vector3:
	return Vector3(
		map_origin.x + grid.x * world_tile,
		_height_at(grid),
		map_origin.y + grid.y * world_tile
	)

func _place_actor(actor: Dictionary, grid: Vector2i, snap: bool = true) -> void:
	actor["grid"] = grid
	actor["target"] = _grid_position(grid)
	var root: Node3D = actor["root"]
	if snap:
		root.position = actor["target"]
		actor["moving"] = false
		actor["stop_anim_at"] = 0
	else:
		actor["moving"] = true
		actor["stop_anim_at"] = 0

func _set_animation(actor: Dictionary, moving: bool, direction: String, running: bool = false) -> void:
	var sprite: AnimatedSprite3D = actor["sprite"]
	var frames := sprite.sprite_frames
	var anim := ""
	if moving:
		anim = ("run_" if running else "walk_") + direction
		if not frames.has_animation(anim):
			anim = "walk_" + direction
	else:
		anim = "idle_" + direction
	if not frames.has_animation(anim):
		anim = "idle_down"
	if not frames.has_animation(anim):
		anim = str(frames.get_animation_names()[0])
	actor["facing"] = direction
	actor["running"] = moving and running and frames.has_animation("run_" + direction)
	if moving:
		actor["stop_anim_at"] = 0
	if sprite.animation != anim:
		sprite.play(anim)

func setup_map(map_info: Dictionary, self_info: Dictionary, players: Array) -> void:
	_clear_actors()
	map_data = map_info
	indoor_view = str(map_info.get("id", "")).begins_with("unova_in_")
	if world_environment != null:
		world_environment.ambient_light_energy = 0.72 if indoor_view else 0.4
		world_environment.ambient_light_color = (
			Color(0.92, 0.84, 0.70) if indoor_view else Color(0.70, 0.78, 0.90)
		)
		if indoor_view:
			world_environment.background_mode = Environment.BG_COLOR
			world_environment.background_color = Color(0.035, 0.032, 0.030)
		else:
			world_environment.background_mode = Environment.BG_SKY
	set_world_time(WorldTimeScript.now_hours(), indoor_view)
	self_data = self_info
	self_id = str(self_info.get("id", ""))
	self_grid = Vector2i(int(self_info.get("x", 0)), int(self_info.get("y", 0)))
	self_facing = str(self_info.get("dir", "down"))
	_build_map_scene(map_info, self_grid)
	_compute_indoor_room()
	var sprite_id := int(self_info.get("sprite", 0))
	self_actor = _create_actor(
		_actor_key(sprite_id),
		str(self_info.get("name", "")),
		Color(str(self_info.get("color", "#ffd166"))),
		true
	)
	_place_actor(self_actor, self_grid, true)
	_set_animation(self_actor, false, self_facing)
	var self_label: Label3D = self_actor["label"]
	self_label.visible = false

	npcs.clear()
	for npc in map_info.get("npcs", []):
		if not (npc is Dictionary):
			continue
		var npc_id := str(npc.get("id", ""))
		var npc_actor := _create_actor(
			_actor_key(int(npc.get("sprite", -1)) if npc.get("sprite") != null else -1),
			str(npc.get("name", "")),
			Color(str(npc.get("color", "#e8f1f2"))),
			false
		)
		_place_actor(npc_actor, Vector2i(int(npc.get("x", 0)), int(npc.get("y", 0))), true)
		npcs[npc_id] = {"actor": npc_actor, "data": npc}
		# NPC labels are muted unless they're a healer/guide.
		var label: Label3D = npc_actor["label"]
		label.modulate = Color(0.72, 0.82, 0.88)

	peers.clear()
	for player in players:
		if player is Dictionary:
			add_player(player)
	_snap_camera()

func _clear_actors() -> void:
	for actor in peers.values():
		_free_actor(actor["actor"])
	for npc in npcs.values():
		_free_actor(npc["actor"])
	if not self_actor.is_empty():
		_free_actor(self_actor)
	peers.clear()
	npcs.clear()
	self_actor = {}

func _free_actor(actor: Dictionary) -> void:
	var root: Node3D = actor.get("root")
	if root != null and is_instance_valid(root):
		remove_child(root)
		root.queue_free()

func _compute_indoor_room() -> void:
	indoor_room_fixed = false
	indoor_room_center = Vector3.ZERO
	if not indoor_view:
		return
	var tiles: Array = map_data.get("tiles", [])
	if tiles.is_empty():
		return
	var base_x := int(map_data.get("tileX", 0))
	var base_y := int(map_data.get("tileY", 0))
	var min_x := 1 << 30
	var min_y := 1 << 30
	var max_x := -1
	var max_y := -1
	var walkable := 0
	for row_index in range(tiles.size()):
		var row := str(tiles[row_index])
		for column in range(row.length()):
			if not (row[column] in ".,gP"):
				continue
			walkable += 1
			min_x = mini(min_x, column)
			max_x = maxi(max_x, column)
			min_y = mini(min_y, row_index)
			max_y = maxi(max_y, row_index)
	if walkable < 20:
		return
	var width := max_x - min_x + 1
	var height := max_y - min_y + 1
	if width > 26 or height > 26:
		return
	var center_x := float(base_x + min_x) + float(width) * 0.5
	var center_y := float(base_y + min_y) + float(height) * 0.5
	var height_y := _height_at(Vector2i(int(floor(center_x)), int(floor(center_y))))
	if height_y == 0.0:
		height_y = _height_at(self_grid)
	indoor_room_center = Vector3(
		map_origin.x + center_x * world_tile,
		height_y,
		map_origin.y + center_y * world_tile
	)
	indoor_room_fixed = true

func _camera_focus(root: Node3D) -> Vector3:
	if not indoor_room_fixed:
		return root.position
	# Keep the room framed, but lean toward the player so the doorway does
	# not sit directly behind the chat panel.
	var focus := indoor_room_center.lerp(root.position, 0.35)
	focus.y = indoor_room_center.y
	return focus

func _current_camera_offset() -> Vector3:
	return INDOOR_CAMERA_OFFSET if indoor_view else CAMERA_OFFSET

func _current_camera_target() -> Vector3:
	return INDOOR_CAMERA_TARGET if indoor_view else CAMERA_TARGET

func _snap_camera() -> void:
	if camera == null or self_actor.is_empty():
		return
	var root: Node3D = self_actor["root"]
	var focus := _camera_focus(root)
	camera.position = focus + _current_camera_offset()
	camera.look_at(focus + _current_camera_target(), Vector3.UP)
	camera.make_current()

func add_player(data: Dictionary) -> void:
	var id := str(data.get("id", ""))
	if id == "" or id == self_id or peers.has(id):
		return
	var actor := _create_actor(
		_actor_key(int(data.get("sprite", 0))),
		str(data.get("name", "")),
		Color(str(data.get("color", "#e8f1f2"))),
		false
	)
	_place_actor(actor, Vector2i(int(data.get("x", 0)), int(data.get("y", 0))), true)
	_set_animation(actor, false, str(data.get("dir", "down")))
	peers[id] = {"actor": actor, "data": data}

func move_player(id: String, x: int, y: int, direction: String, running: bool = false) -> void:
	if not peers.has(id):
		return
	var actor: Dictionary = peers[id]["actor"]
	var target := Vector2i(x, y)
	if target == actor["grid"]:
		_set_animation(actor, false, direction)
		return
	actor["grid"] = target
	actor["target"] = _grid_position(target)
	actor["speed"] = RUN_SPEED if running else WALK_SPEED
	actor["moving"] = true
	actor["stop_anim_at"] = 0
	_set_animation(actor, true, direction, running)

func remove_player(id: String) -> void:
	if not peers.has(id):
		return
	var actor: Dictionary = peers[id]["actor"]
	peers.erase(id)
	_free_actor(actor)

func correct_self(x: int, y: int, direction: String) -> void:
	if self_actor.is_empty():
		return
	var target := Vector2i(x, y)
	self_grid = target
	if target != self_actor["grid"]:
		_place_actor(self_actor, target, true)
		_set_animation(self_actor, false, direction)
		self_facing = direction
	elif not self_actor["moving"]:
		_set_animation(self_actor, false, direction)
		self_facing = direction
	else:
		# The ack for a predicted step arrives while the actor is still
		# travelling; keep the walk animation running instead of snapping
		# back to the idle frame mid-slide.
		self_facing = direction

func is_self_moving() -> bool:
	return not self_actor.is_empty() and bool(self_actor["moving"])

func turn_self(direction: String) -> void:
	if self_actor.is_empty() or self_actor["moving"]:
		return
	if self_facing == direction:
		return
	self_facing = direction
	_set_animation(self_actor, false, direction)

func turn_player(id: String, direction: String) -> void:
	if not peers.has(id):
		return
	var actor: Dictionary = peers[id]["actor"]
	# A peer that is mid-step keeps its walk animation and adopts the new
	# facing when the step ends.
	actor["facing"] = direction
	if not actor["moving"]:
		_set_animation(actor, false, direction)

func predict_self_move(direction: String, running: bool = false) -> bool:
	if self_actor.is_empty():
		return false
	if self_actor["moving"]:
		# Held movement asks for the next tile while the current one is still
		# finishing. The step length and the input interval are both 250 ms, so
		# the leftover is only a fraction of a tile; finish it and chain the next
		# step instead of rejecting the input and waiting another interval.
		var root: Node3D = self_actor["root"]
		var target: Vector3 = self_actor["target"]
		if root.position.distance_to(target) > CHAIN_SNAP_DISTANCE:
			return false
		root.position = target
		self_actor["moving"] = false
		self_actor["stop_anim_at"] = 0
	var delta := _direction_delta(direction)
	var target: Vector2i = self_actor["grid"] + delta
	if not _is_walkable(target.x, target.y) or not _can_step(self_actor["grid"], target):
		_set_animation(self_actor, false, direction)
		self_facing = direction
		return false
	self_actor["grid"] = target
	self_grid = target
	self_actor["target"] = _grid_position(target)
	self_actor["speed"] = RUN_SPEED if running else WALK_SPEED
	self_actor["moving"] = true
	self_actor["stop_anim_at"] = 0
	self_facing = direction
	_set_animation(self_actor, true, direction, running)
	return true

func _direction_delta(direction: String) -> Vector2i:
	match direction:
		"up":
			return Vector2i(0, -1)
		"down":
			return Vector2i(0, 1)
		"left":
			return Vector2i(-1, 0)
		"right":
			return Vector2i(1, 0)
		_:
			return Vector2i.ZERO

func update_tiles(window: Dictionary) -> void:
	if str(window.get("mapId", "")) != str(map_data.get("id", "")):
		return
	if not window.has("tiles"):
		return
	map_data["tiles"] = window["tiles"]
	map_data["tileX"] = int(window.get("x", 0))
	map_data["tileY"] = int(window.get("y", 0))
	map_data["tileWidth"] = int(window.get("width", 0))
	map_data["tileHeight"] = int(window.get("height", 0))

func _tile_char(x: int, y: int) -> String:
	if map_data.is_empty():
		return ""
	if x < 0 or y < 0 or x >= int(map_data.get("width", 0)) or y >= int(map_data.get("height", 0)):
		return ""
	var tile_x := int(map_data.get("tileX", 0))
	var tile_y := int(map_data.get("tileY", 0))
	var tile_width := int(map_data.get("tileWidth", map_data.get("width", 0)))
	var tile_height := int(map_data.get("tileHeight", map_data.get("height", 0)))
	if x < tile_x or y < tile_y or x >= tile_x + tile_width or y >= tile_y + tile_height:
		return ""
	var tiles: Array = map_data.get("tiles", [])
	var row_index := y - tile_y
	if row_index < 0 or row_index >= tiles.size():
		return ""
	var row := str(tiles[row_index])
	var column := x - tile_x
	if column < 0 or column >= row.length():
		return ""
	return row[column]

func _is_walkable(x: int, y: int) -> bool:
	var tile := _tile_char(x, y)
	if not (tile in [".", ",", "g", "f", "=", "P"]):
		return false
	for npc in npcs.values():
		var data: Dictionary = npc["data"]
		if int(data.get("x", 0)) == x and int(data.get("y", 0)) == y:
			return false
	return true

func on_portal_tile() -> bool:
	if self_actor.is_empty():
		return false
	var grid: Vector2i = self_actor["grid"]
	return _tile_char(grid.x, grid.y) == "P"

func try_portal_push(direction: String) -> bool:
	if self_actor.is_empty() or self_actor["moving"]:
		return false
	if not on_portal_tile():
		return false
	var target: Vector2i = self_actor["grid"] + _direction_delta(direction)
	return not _is_walkable(target.x, target.y)

func nearest_npc(max_distance: int) -> Dictionary:
	var best: Dictionary = {}
	var best_distance := 999
	for npc in npcs.values():
		var data: Dictionary = npc["data"]
		var distance: int = (
			abs(int(data.get("x", 0)) - self_grid.x)
			+ abs(int(data.get("y", 0)) - self_grid.y)
		)
		if distance <= max_distance and distance < best_distance:
			best = data
			best_distance = distance
	return best

func local_count() -> int:
	return 1 + peers.size()

func show_bubble(id: String, text: String) -> void:
	var actor: Dictionary = {}
	if id == self_id:
		actor = self_actor
	elif peers.has(id):
		actor = peers[id]["actor"]
	else:
		return
	if actor.is_empty():
		return
	var bubble: Label3D = actor["bubble"]
	var shortened := text
	if shortened.length() > 42:
		shortened = shortened.substr(0, 39) + "..."
	bubble.text = shortened
	bubble.visible = true
	actor["bubble_until"] = Time.get_ticks_msec() + 4000

func _process(delta: float) -> void:
	var now := Time.get_ticks_msec()
	if not world_chunks.is_empty():
		var cell := _chunk_cell()
		if cell != self_cell:
			_refresh_chunks()
		_poll_chunks()
	for actor in _all_actors():
		if actor["moving"]:
			var root: Node3D = actor["root"]
			var speed := float(actor.get("speed", WALK_SPEED))
			root.position = root.position.move_toward(actor["target"], speed * delta)
			if root.position.distance_to(actor["target"]) < 0.5:
				root.position = actor["target"]
				actor["moving"] = false
				actor["running"] = false
				# Continuous held movement starts the next step before this
				# grace expires, so the walk/run cycle never flashes idle
				# between tiles.
				actor["stop_anim_at"] = now + 80
		elif int(actor.get("stop_anim_at", 0)) != 0 and now >= int(actor["stop_anim_at"]):
			actor["stop_anim_at"] = 0
			_set_animation(actor, false, actor["facing"])
		var bubble: Label3D = actor["bubble"]
		if bubble.visible and now >= int(actor["bubble_until"]):
			bubble.visible = false
	if not self_actor.is_empty():
		var origin: Vector2i = self_actor["grid"]
		for npc in npcs.values():
			var data: Dictionary = npc["data"]
			var distance := maxi(
				absi(int(data.get("x", 0)) - origin.x),
				absi(int(data.get("y", 0)) - origin.y)
			)
			var label: Label3D = npc["actor"]["label"]
			label.visible = distance <= 8
			if label.visible:
				label.modulate.a = clampf(1.0 - float(maxi(0, distance - 4)) * 0.16, 0.35, 1.0)
		for peer in peers.values():
			var peer_actor: Dictionary = peer["actor"]
			var peer_grid: Vector2i = peer_actor["grid"]
			var distance := maxi(absi(peer_grid.x - origin.x), absi(peer_grid.y - origin.y))
			var label: Label3D = peer_actor["label"]
			label.visible = distance <= 12
	if not self_actor.is_empty() and camera != null:
		var root: Node3D = self_actor["root"]
		var focus := _camera_focus(root)
		var desired := focus + _current_camera_offset()
		camera.position = camera.position.lerp(desired, clampf(delta * 6.0, 0.0, 1.0))
		camera.look_at(focus + _current_camera_target(), Vector3.UP)

func _all_actors() -> Array:
	var result: Array = []
	if not self_actor.is_empty():
		result.append(self_actor)
	for peer in peers.values():
		result.append(peer["actor"])
	for npc in npcs.values():
		result.append(npc["actor"])
	return result
