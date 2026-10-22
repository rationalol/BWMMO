extends Node2D

const PlayerSpriteScript = preload("res://scripts/player_sprite.gd")
const TILE := 32

const GRASS_A := Color(0.416, 0.682, 0.353)
const GRASS_B := Color(0.447, 0.714, 0.384)
const GRASS_DARK := Color(0.310, 0.565, 0.286)
const PATH_A := Color(0.800, 0.722, 0.502)
const PATH_B := Color(0.769, 0.690, 0.471)
const WATER_A := Color(0.263, 0.490, 0.831)
const WATER_B := Color(0.239, 0.459, 0.804)
const WATER_LIGHT := Color(0.541, 0.741, 0.953)
const TREE_TRUNK := Color(0.353, 0.251, 0.157)
const TREE_DARK := Color(0.145, 0.396, 0.220)
const TREE_LIGHT := Color(0.224, 0.502, 0.286)
const HOUSE_A := Color(0.663, 0.420, 0.365)
const HOUSE_B := Color(0.612, 0.380, 0.333)
const HOUSE_DARK := Color(0.435, 0.259, 0.243)
const BRIDGE_A := Color(0.663, 0.482, 0.298)
const BRIDGE_DARK := Color(0.494, 0.337, 0.196)
const PORTAL_DARK := Color(0.435, 0.275, 0.847)
const PORTAL_LIGHT := Color(0.678, 0.522, 1.0)
const SIGN_BOARD := Color(0.780, 0.643, 0.424)

var map_data: Dictionary = {}
var self_sprite = null
var self_grid := Vector2i.ZERO
var peers: Dictionary = {}
var npc_sprites: Dictionary = {}
var camera: Camera2D
var _sprites: Array = []

func _ready() -> void:
	y_sort_enabled = true
	camera = Camera2D.new()
	camera.position_smoothing_enabled = true
	camera.position_smoothing_speed = 9.0
	add_child(camera)
	camera.make_current()

func set_active(active: bool) -> void:
	visible = active
	if active and camera != null:
		camera.make_current()

func setup_map(map_info: Dictionary, self_info: Dictionary, players: Array) -> void:
	for sprite in _sprites:
		if is_instance_valid(sprite):
			remove_child(sprite)
			sprite.queue_free()
	_sprites.clear()
	peers.clear()
	npc_sprites.clear()
	self_sprite = null
	map_data = map_info
	queue_redraw()

	self_grid = Vector2i(int(self_info["x"]), int(self_info["y"]))
	self_sprite = _spawn_player(self_info, true)
	for player in players:
		if player is Dictionary:
			add_player(player)
	var npc_list: Array = map_info.get("npcs", [])
	for npc in npc_list:
		if npc is Dictionary:
			_spawn_npc(npc)

	var width := int(map_info["width"]) * TILE
	var height := int(map_info["height"]) * TILE
	camera.limit_left = 0
	camera.limit_top = 0
	camera.limit_right = width
	camera.limit_bottom = height
	camera.position = self_sprite.position + Vector2(0, -14)
	camera.reset_smoothing()

func local_count() -> int:
	return 1 + peers.size()

func _spawn_player(data: Dictionary, is_self: bool) -> Node2D:
	var sprite = PlayerSpriteScript.new()
	add_child(sprite)
	sprite.setup(
		str(data["id"]),
		str(data["name"]),
		Color(str(data["color"])),
		"player",
		is_self,
		int(data.get("sprite", 0))
	)
	sprite.set_grid(Vector2i(int(data["x"]), int(data["y"])), true)
	sprite.set_facing(str(data.get("dir", "down")))
	_sprites.append(sprite)
	return sprite

func _spawn_npc(data: Dictionary) -> void:
	var sprite = PlayerSpriteScript.new()
	add_child(sprite)
	var trainer_sprite := -1
	var raw_sprite: Variant = data.get("sprite", null)
	if raw_sprite is int or raw_sprite is float:
		trainer_sprite = int(raw_sprite)
	sprite.setup(
		str(data["id"]),
		str(data["name"]),
		Color(str(data["color"])),
		str(data.get("kind", "npc")),
		false,
		trainer_sprite
	)
	sprite.set_grid(Vector2i(int(data["x"]), int(data["y"])), true)
	sprite.set_facing("down")
	npc_sprites[str(data["id"])] = sprite
	_sprites.append(sprite)

func add_player(data: Dictionary) -> void:
	var id := str(data["id"])
	if peers.has(id):
		var existing = peers[id]
		existing.move_to_grid(
			Vector2i(int(data["x"]), int(data["y"])),
			str(data.get("dir", "down"))
		)
		return
	peers[id] = _spawn_player(data, false)

func move_player(id: String, x: int, y: int, direction: String) -> void:
	if not peers.has(id):
		return
	var sprite = peers[id]
	sprite.move_to_grid(Vector2i(x, y), direction)

func remove_player(id: String) -> void:
	if not peers.has(id):
		return
	var sprite = peers[id]
	peers.erase(id)
	_sprites.erase(sprite)
	if is_instance_valid(sprite):
		remove_child(sprite)
		sprite.queue_free()

func show_bubble(id: String, text: String) -> void:
	if self_sprite != null and self_sprite.entity_id == id:
		self_sprite.show_bubble(text)
		return
	if peers.has(id):
		var sprite = peers[id]
		sprite.show_bubble(text)

func is_self_moving() -> bool:
	return self_sprite != null and self_sprite.is_moving()

func self_facing() -> String:
	if self_sprite == null:
		return "down"
	return self_sprite.facing

func turn_self(direction: String) -> void:
	if self_sprite == null:
		return
	self_sprite.set_facing(direction)

func turn_player(id: String, direction: String) -> void:
	if not peers.has(id):
		return
	peers[id].set_facing(direction)

func predict_self_move(direction: String) -> bool:
	if self_sprite == null:
		return false
	var target := self_grid + _direction_delta(direction)
	if not is_walkable(target.x, target.y):
		self_sprite.set_facing(direction)
		return false
	self_grid = target
	self_sprite.move_to_grid(target, direction)
	return true

func correct_self(x: int, y: int, direction: String) -> void:
	if self_sprite == null:
		return
	var target := Vector2i(x, y)
	if target != self_grid:
		self_grid = target
		self_sprite.set_grid(target, false)
	self_sprite.set_facing(direction)

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
	queue_redraw()

func tile_char(x: int, y: int) -> String:
	if map_data.is_empty():
		return ""
	if x < 0 or y < 0 or x >= int(map_data["width"]) or y >= int(map_data["height"]):
		return ""
	var tile_x := int(map_data.get("tileX", 0))
	var tile_y := int(map_data.get("tileY", 0))
	var tile_width := int(map_data.get("tileWidth", map_data.get("width", 0)))
	var tile_height := int(map_data.get("tileHeight", map_data.get("height", 0)))
	if x < tile_x or y < tile_y or x >= tile_x + tile_width or y >= tile_y + tile_height:
		return ""
	var tiles: Array = map_data["tiles"]
	var row_index := y - tile_y
	if row_index < 0 or row_index >= tiles.size():
		return ""
	var row: String = str(tiles[row_index])
	var column := x - tile_x
	if column < 0 or column >= row.length():
		return ""
	return row[column]

func is_walkable(x: int, y: int) -> bool:
	var tile := tile_char(x, y)
	if not (tile in [".", ",", "g", "f", "=", "P"]):
		return false
	var npcs: Array = map_data.get("npcs", [])
	for npc in npcs:
		if npc is Dictionary and int(npc["x"]) == x and int(npc["y"]) == y:
			return false
	return true

func on_portal_tile() -> bool:
	if self_sprite == null:
		return false
	return tile_char(self_grid.x, self_grid.y) == "P"

func try_portal_push(direction: String) -> bool:
	if self_sprite == null:
		return false
	if not on_portal_tile():
		return false
	var target := self_grid + _direction_delta(direction)
	return not is_walkable(target.x, target.y)

func nearest_npc(max_distance: int) -> Dictionary:
	var best: Dictionary = {}
	var best_distance := 999
	var npcs: Array = map_data.get("npcs", [])
	for npc in npcs:
		if not (npc is Dictionary):
			continue
		var distance: int = abs(int(npc["x"]) - self_grid.x) + abs(int(npc["y"]) - self_grid.y)
		if distance <= max_distance and distance < best_distance:
			best = npc
			best_distance = distance
	return best

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

func _process(_delta: float) -> void:
	if self_sprite != null and camera != null:
		camera.position = self_sprite.position + Vector2(0, -14)

func _draw() -> void:
	if map_data.is_empty():
		return
	var tiles: Array = map_data["tiles"]
	var tile_x := int(map_data.get("tileX", 0))
	var tile_y := int(map_data.get("tileY", 0))
	var tile_height := int(map_data.get("tileHeight", map_data.get("height", 0)))
	for row_index in range(mini(tile_height, tiles.size())):
		var row := str(tiles[row_index])
		for column in range(row.length()):
			_draw_tile(row[column], tile_x + column, tile_y + row_index)

func _draw_tile(tile: String, x: int, y: int) -> void:
	var pos := Vector2(x * TILE, y * TILE)
	var base := GRASS_A if (x + y) % 2 == 0 else GRASS_B
	match tile:
		",":
			base = PATH_A if (x + y) % 2 == 0 else PATH_B
		"g":
			base = GRASS_DARK
		"~":
			base = WATER_A if (x + y) % 2 == 0 else WATER_B
		"H":
			base = HOUSE_A if (x + y) % 2 == 0 else HOUSE_B
		"=":
			base = BRIDGE_A
		"P":
			base = PATH_A
	draw_rect(Rect2(pos, Vector2(TILE, TILE)), base)

	match tile:
		"#":
			_draw_tree(pos)
		"~":
			draw_line(pos + Vector2(5, 10), pos + Vector2(16, 10), WATER_LIGHT, 1.5)
			draw_line(pos + Vector2(15, 22), pos + Vector2(27, 22), WATER_LIGHT, 1.5)
		"H":
			draw_line(pos + Vector2(0, 8), pos + Vector2(32, 8), HOUSE_DARK, 2.0)
			draw_line(pos + Vector2(0, 20), pos + Vector2(32, 20), HOUSE_DARK, 2.0)
			if (x + y) % 2 == 0:
				draw_rect(Rect2(pos + Vector2(11, 24), Vector2(10, 7)), Color(0.87, 0.80, 0.62))
		"g":
			for i in range(4):
				var bx := pos.x + 5.0 + i * 7.0 + float((x * 3 + y * 5 + i * 7) % 4)
				var height := 8.0 + float((x + y * 2 + i * 3) % 5)
				draw_line(
					Vector2(bx, pos.y + 28),
					Vector2(bx + 2, pos.y + 28 - height),
					Color(0.239, 0.514, 0.220),
					1.6
				)
		"f":
			for i in range(3):
				var point := pos + Vector2(8 + i * 8, 12 + ((i * 7 + x) % 8))
				draw_circle(point, 2.2, Color(0.96, 0.94, 0.85))
				draw_circle(point, 0.9, Color(1.0, 0.82, 0.40))
		"P":
			draw_circle(pos + Vector2(16, 16), 12, PORTAL_DARK)
			draw_circle(pos + Vector2(16, 16), 8, PORTAL_LIGHT)
			draw_circle(pos + Vector2(16, 16), 4, Color(0.96, 0.95, 1.0))
		"=":
			for i in range(4):
				draw_line(
					pos + Vector2(0, 7 + i * 7),
					pos + Vector2(32, 7 + i * 7),
					BRIDGE_DARK,
					1.0
				)
		"S":
			draw_rect(Rect2(pos + Vector2(14, 19), Vector2(4, 10)), TREE_TRUNK)
			draw_rect(Rect2(pos + Vector2(8, 8), Vector2(16, 12)), SIGN_BOARD)
			draw_rect(Rect2(pos + Vector2(8, 8), Vector2(16, 12)), Color(0.35, 0.27, 0.18), false, 1.0)
		".":
			if (x * 13 + y * 7) % 17 == 0:
				draw_circle(pos + Vector2(10, 22), 1.2, Color(0.36, 0.60, 0.30))

func _draw_tree(pos: Vector2) -> void:
	draw_circle(pos + Vector2(16, 24), 8.0, Color(0, 0, 0, 0.16))
	draw_rect(Rect2(pos + Vector2(13, 20), Vector2(6, 9)), TREE_TRUNK)
	draw_circle(pos + Vector2(16, 14), 12.0, TREE_DARK)
	draw_circle(pos + Vector2(11, 11), 7.0, TREE_LIGHT)
	draw_circle(pos + Vector2(22, 12), 6.0, TREE_LIGHT)
	draw_circle(pos + Vector2(16, 18), 7.0, TREE_LIGHT)
