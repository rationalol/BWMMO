extends Node

# Headless world-map smoke test. Run with:
#   godot --headless --path client res://tests/WorldMapTest.tscn
#
# The scene wrapper matters: `--script` mode does not instantiate the Loc
# autoload, so hud.gd would fail to compile with that runner.

const HudScript = preload("res://scripts/hud.gd")

var failures := 0
var _original_locale := "en"

func _ready() -> void:
	_original_locale = Loc.locale
	Loc.set_locale("en")
	call_deferred("_run")

func _run() -> void:
	get_tree().root.size = Vector2i(960, 540)
	await get_tree().process_frame

	var hud = HudScript.new()
	add_child(hud)
	var self_info := {
		"id": "world-map-test",
		"name": "Hilbert",
		"color": "#e76f51",
		"sprite": 0,
		"mapId": "unova_full",
		"x": 620,
		"y": 590,
		"dir": "down",
		"money": 0,
		"wins": 0,
		"party": [],
		"inventory": {"items": {}}
	}
	hud.set_self("Hilbert", 0, 0, self_info)
	hud.set_map("Unova", 1, "Nacrene City")
	hud.set_map_data(_make_map(), self_info)
	hud.set_world_map(_world_map_payload())
	hud.set_connection("ONLINE", true)
	await get_tree().process_frame
	await get_tree().process_frame

	var nav: Control = _find(hud, "NavButtons")
	_expect(nav != null and nav.get_child_count() == 7, "seven navigation buttons expected")
	_expect(_find(hud, "NavMap") != null, "area-map navigation button missing")
	_expect(_find(hud, "NavWorld") != null, "world-map navigation button missing")

	# The Map nav button is the area-map entry now that the HUD minimap is gone.
	hud._open_menu("map")
	await get_tree().process_frame
	_expect(hud.menu_open and hud._menu_kind == "map", "Map nav should open the area map")
	_expect(hud._big_minimap != null, "area map should keep the large map view")
	_expect(hud._world_map_view == null, "area map should not build the world map view")
	hud.close_menu()

	# The nav World button opens the independent Unova map.
	hud._open_menu("world")
	await get_tree().process_frame
	await get_tree().process_frame
	_expect(hud.menu_open and hud._menu_kind == "world", "World nav should open the world map")
	var panel: Control = _find(hud, "MenuPanel")
	var view: Control = _find(hud, "WorldMap")
	_expect(panel != null and view != null, "world map panel/view missing")
	if panel != null:
		var rect := panel.get_global_rect()
		print("[world-map] panel rect %s" % str(rect))
		_expect(
			rect.size.x <= get_tree().root.size.x and rect.size.y <= get_tree().root.size.y,
			"world map panel larger than viewport"
		)
	if view != null:
		print("[world-map] places %d texture %s" % [
			view.place_count(), str(view.has_map_texture())
		])
		_expect(view.place_count() == 40, "all forty outdoor areas should be on the map")
		_expect(
			view.current_place_name() == "Nacrene City",
			"current place should be Nacrene City"
		)
		var marker: Vector2 = view.marker_position("Nacrene City")
		var nuvema: Vector2 = view.marker_position("Nuvema Town")
		print("[world-map] Nacrene %s Nuvema %s size %s" % [
			str(marker), str(nuvema), str(view.size)
		])
		_expect(
			Rect2(Vector2.ZERO, view.size).has_point(marker),
			"Nacrene marker should be inside the map view"
		)
		_expect(
			marker.x < nuvema.x and marker.y < nuvema.y,
			"Nacrene should sit north-west of Nuvema on the map"
		)
		_expect(
			view.marker_position("Route 3").distance_to(marker) > 1.0,
			"route markers should use their own coordinates"
		)
		if not view.has_map_texture():
			print("[world-map] unova_map.png is not imported; run extract_town_map.py")

		# Walking to another area updates the marker without rebuilding the menu.
		hud.set_location("Route 3")
		await get_tree().process_frame
		_expect(
			view.current_place_name() == "Route 3",
			"current marker should follow the outdoor location"
		)
		# Indoor names keep the last outdoor marker instead of clearing it.
		hud.set_location("Nacrene Museum")
		await get_tree().process_frame
		_expect(
			view.current_place_name() == "Route 3",
			"indoor maps should keep the last outdoor marker"
		)
	hud.close_menu()
	_expect(not hud.menu_open, "world map should close")

	print("[world-map] failures %d" % failures)
	Loc.set_locale(_original_locale)
	hud.queue_free()
	await get_tree().process_frame
	get_tree().quit(1 if failures > 0 else 0)

func _world_map_payload() -> Dictionary:
	var path := _server_file("content/rom/world_map.json")
	if FileAccess.file_exists(path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary and parsed.get("places") is Array:
			var places: Array = []
			for entry in parsed["places"]:
				if not (entry is Dictionary):
					continue
				places.append({
					"name": str(entry.get("key", "")),
					"x": float(entry.get("x", 0)),
					"y": float(entry.get("y", 0)),
					"kind": str(entry.get("kind", "landmark"))
				})
			return {
				"width": int(parsed.get("image", {}).get("width", 256)),
				"height": int(parsed.get("image", {}).get("height", 168)),
				"places": places
			}
	return {
		"width": 256,
		"height": 168,
		"places": [
			{"name": "Nuvema Town", "x": 232, "y": 158, "kind": "town"},
			{"name": "Nacrene City", "x": 203, "y": 118, "kind": "town"},
			{"name": "Route 3", "x": 214, "y": 118, "kind": "route"},
			{"name": "Giant Chasm", "x": 198, "y": 31, "kind": "landmark"}
		]
	}

func _make_map() -> Dictionary:
	var rows: Array = []
	for y in range(65):
		var row := ""
		for x in range(65):
			var glyph := "#"
			if x >= 24 and x <= 42 and y >= 20 and y <= 44:
				glyph = "."
			elif x >= 34 and x <= 44 and y >= 8 and y <= 20:
				glyph = "g"
			elif x >= 40 and x <= 50 and y >= 4 and y <= 14:
				glyph = "~"
			row += glyph
		rows.append(row)
	return {
		"id": "unova_full",
		"name": "Unova",
		"width": 928,
		"height": 864,
		"tiles": rows,
		"tileX": 602,
		"tileY": 566,
		"tileWidth": 65,
		"tileHeight": 65,
		"windowed": true,
		"npcs": [],
		"visual": {}
	}

func _server_file(relative: String) -> String:
	var project_dir := ProjectSettings.globalize_path("res://").get_base_dir()
	return project_dir.get_base_dir().path_join("server").path_join(relative)

func _find(node: Node, target: String) -> Control:
	if node is Control and node.name == target:
		return node
	for child in node.get_children():
		var found := _find(child, target)
		if found != null:
			return found
	return null

func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	push_error("[world-map] " + message)
	failures += 1
