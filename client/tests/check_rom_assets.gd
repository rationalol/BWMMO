extends SceneTree

const MAPS := ["nuvema", "route1_south", "route1_north"]

func _pump_chunks(world: Node3D, limit: int = 500) -> void:
	for _i in range(limit):
		world._poll_chunks()
		if world.pending_chunks.is_empty():
			return
		OS.delay_msec(10)

func _init() -> void:
	var failures := 0
	for map_id in MAPS:
		var root := "res://assets/bw/%s" % map_id
		var manifest_path := "%s/placements.json" % root
		if not FileAccess.file_exists(manifest_path):
			push_error("missing manifest: %s" % manifest_path)
			failures += 1
			continue
		var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
		var map_file := str(manifest.get("mapFile", ""))
		var map_scene: PackedScene = load("%s/%s" % [root, map_file])
		if map_scene == null:
			push_error("missing map scene: %s/%s" % [root, map_file])
			failures += 1
		else:
			var node := map_scene.instantiate()
			node.free()
		var props: Array = manifest.get("props", [])
		var prop_files: Dictionary = manifest.get("propFiles", {})
		for placement in props:
			var filename := str(prop_files.get(str(int(placement.get("prop", 0))), ""))
			if filename == "":
				push_error("%s: no model for prop %s" % [map_id, placement.get("prop")])
				failures += 1
				continue
			var prop_scene: PackedScene = load("%s/props/%s" % [root, filename])
			if prop_scene == null:
				push_error("missing prop scene: %s/props/%s" % [root, filename])
				failures += 1
				continue
			var prop := prop_scene.instantiate()
			prop.free()
		print("[rom-assets] %s ok (%d props)" % [map_id, props.size()])

	var actor_root := "res://assets/bw/nuvema/actors/hero/actor.json"
	if not FileAccess.file_exists(actor_root):
		push_error("missing actor manifest: %s" % actor_root)
		failures += 1
	else:
		var actor: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(actor_root))
		if not actor.get("animations", {}).has("run_down"):
			push_error("hero actor has no run_down animation")
			failures += 1

	var outdoor_library_path := "res://assets/bw/unova_outdoor/library.json"
	var outdoor_library: Dictionary = {}
	if not FileAccess.file_exists(outdoor_library_path):
		push_error("missing outdoor world library")
		failures += 1
	else:
		outdoor_library = JSON.parse_string(FileAccess.get_file_as_string(outdoor_library_path))
	var outdoor_cells: Array = outdoor_library.get("cells", [])
	if outdoor_cells.size() != 109:
		push_error("expected 109 outdoor cells, got %d" % outdoor_cells.size())
		failures += 1
	var stream_chunks: Array = []
	for cell in outdoor_cells:
		var cell_x := int(cell.get("x", -1))
		var cell_y := int(cell.get("y", -1))
		var map_file := str(cell.get("mapFile", ""))
		var cell_dir := "res://assets/bw/unova_outdoor/cells/cell_%02d_%02d" % [cell_x, cell_y]
		if not FileAccess.file_exists(cell_dir + "/placements.json"):
			push_error("missing cell placements: %s" % cell_dir)
			failures += 1
		if not ResourceLoader.exists("res://assets/bw/unova_outdoor/%s" % map_file):
			push_error("missing cell map: %s" % map_file)
			failures += 1
		if cell_x == 24 and cell_y in [21, 22, 23]:
			stream_chunks.append({
				"asset": "unova_outdoor/cells/cell_%02d_%02d" % [cell_x, cell_y],
				"cellX": cell_x,
				"cellY": cell_y,
				"offsetX": cell_x * 512,
				"offsetZ": cell_y * 512
			})
	if stream_chunks.size() != 3:
		push_error("expected three sample chunks around Nuvema")
		failures += 1
	var unova_visual := {
		"originX": -248,
		"originZ": -248,
		"tile": 16,
		"cellSize": 32,
		"chunks": stream_chunks
	}
	print("[rom-assets] full outdoor library ok (%d cells)" % outdoor_cells.size())

	var world_script: GDScript = load("res://scripts/nuvema_online.gd")
	if world_script == null:
		push_error("could not load nuvema_online.gd")
		failures += 1
	else:
		var world: Node3D = world_script.new()
		root.add_child(world)
		for map_id in ["route1_south", "route1_north"]:
			var map_info := {
				"id": map_id,
				"name": "Route 1",
				"width": 32,
				"height": 32,
				"tiles": ["#".repeat(32)],
				"npcs": []
			}
			var self_info := {
				"id": "test",
				"name": "Test",
				"color": "#ffffff",
				"sprite": 0,
				"mapId": map_id,
				"x": 20,
				"y": 30,
				"dir": "up"
			}
			world.setup_map(map_info, self_info, [])
			print("[rom-assets] %s online view built" % map_id)

		var unova_info := {
			"id": "unova_full",
			"name": "Unova",
			"width": 928,
			"height": 864,
			"tiles": ["#".repeat(928)],
			"npcs": [],
			"visual": unova_visual
		}
		var unova_self := {
			"id": "test",
			"name": "Test",
			"color": "#ffffff",
			"sprite": 0,
			"mapId": "unova_full",
			"x": 784,
			"y": 753,
			"dir": "down"
		}
		world.setup_map(unova_info, unova_self, [])
		_pump_chunks(world)
		if world.loaded_chunks.size() != 2:
			push_error("unova world should preload the own and neighbouring chunk")
			failures += 1
		else:
			print("[rom-assets] unova initial stream loaded 2 chunks")

		world.self_grid = Vector2i(788, 722)
		world._refresh_chunks()
		_pump_chunks(world)
		if not world.loaded_chunks.has("unova_outdoor/cells/cell_24_21"):
			push_error("crossing into Route 1 south should stream the north chunk")
			failures += 1
		else:
			print("[rom-assets] unova streamed the third chunk while walking north")

		world.self_grid = Vector2i(788, 690)
		world._refresh_chunks()
		if world.loaded_chunks.has("unova_outdoor/cells/cell_24_23"):
			push_error("Nuvema chunk should unload far behind the player")
			failures += 1
		else:
			print("[rom-assets] unova unloaded the Nuvema chunk behind the player")

		var indoor_library_path := "res://assets/bw/unova_indoor/library.json"
		var lab_scene: Dictionary = {}
		if not FileAccess.file_exists(indoor_library_path):
			push_error("missing indoor world library")
			failures += 1
		else:
			var indoor_library: Dictionary = JSON.parse_string(
				FileAccess.get_file_as_string(indoor_library_path)
			)
			for scene in indoor_library.get("scenes", []):
				if int(scene.get("zone", -1)) == 396:
					lab_scene = scene
					break
		if lab_scene.is_empty():
			push_error("indoor library is missing the Nuvema lab")
			failures += 1
		else:
			var lab_chunks: Array = []
			var lab_assets_ok := true
			var lab_height_values := PackedInt32Array()
			lab_height_values.resize(32 * 32)
			lab_height_values.fill(0)
			lab_height_values[11 * 32 + 3] = 64
			var lab_height_bytes := PackedByteArray()
			lab_height_bytes.resize(lab_height_values.size() * 2)
			for index in range(lab_height_values.size()):
				lab_height_bytes.encode_s16(index * 2, lab_height_values[index])
			var lab_height_data := Marshalls.raw_to_base64(lab_height_bytes)
			for cell in lab_scene.get("cells", []):
				var map_file := str(cell.get("mapFile", ""))
				if not ResourceLoader.exists("res://assets/bw/unova_indoor/%s" % map_file):
					push_error("missing indoor map scene: %s" % map_file)
					failures += 1
					lab_assets_ok = false
				var lab_props: Array = []
				for prop in cell.get("props", []):
					var prop_file := str(prop.get("file", ""))
					if prop_file == "" or not ResourceLoader.exists("res://assets/bw/unova_indoor/%s" % prop_file):
						push_error("missing indoor prop scene: %s" % prop_file)
						failures += 1
						lab_assets_ok = false
						continue
					lab_props.append({
						"x": prop.get("x", 0.0),
						"y": prop.get("y", 0.0),
						"z": prop.get("z", 0.0),
						"rotation": prop.get("rotation", 0.0),
						"file": "unova_indoor/%s" % prop_file
					})
				lab_chunks.append({
					"asset": "unova_indoor/zone_396/%d_%d" % [
						int(cell.get("x", 0)), int(cell.get("y", 0))
					],
					"cellX": int(cell.get("x", 0)),
					"cellY": int(cell.get("y", 0)),
					"offsetX": int(cell.get("x", 0)) * 512,
					"offsetZ": int(cell.get("y", 0)) * 512,
					"mapFile": "unova_indoor/%s" % map_file,
					"heights": lab_height_data,
					"props": lab_props
				})
			if lab_assets_ok:
				var lab_info := {
					"id": "unova_in_396",
					"name": "Professor Juniper's Lab",
					"width": 32,
					"height": 32,
					"tiles": ["#".repeat(32)],
					"npcs": [],
					"visual": {
						"originX": -248,
						"originZ": -248,
						"tile": 16,
						"cellSize": 32,
						"heightScale": 16,
						"chunks": lab_chunks
					}
				}
				var lab_self := {
					"id": "test",
					"name": "Test",
					"color": "#ffffff",
					"sprite": 0,
					"mapId": "unova_in_396",
					"x": 3,
					"y": 11,
					"dir": "down"
				}
				world.setup_map(lab_info, lab_self, [])
				_pump_chunks(world)
				var lab_chunk_id := str(lab_chunks[0].get("asset", ""))
				if world.loaded_chunks.size() != 1 or not world.loaded_chunks.has(lab_chunk_id):
					push_error("indoor lab should load its inline visual chunk")
					failures += 1
				elif int(world.loaded_chunks[lab_chunk_id]["root"].get_child_count()) == 0:
					push_error("indoor lab chunk instantiated no nodes")
					failures += 1
				else:
					if absf(world._height_at(Vector2i(3, 11)) - 4.0) > 0.001:
						push_error("indoor heightmap decode should return 4.0 at the lab door")
						failures += 1
					elif absf(world.self_actor["root"].position.y - 4.0) > 0.001:
						push_error("actor should stand on the decoded indoor height")
						failures += 1
					else:
						print("[rom-assets] Nuvema lab indoor chunk loaded at height 4.0")

		world._clear_map_scene()
		world.free()

	print("[rom-assets] %s" % ("FAILED" if failures > 0 else "PASSED"))
	quit(1 if failures > 0 else 0)
