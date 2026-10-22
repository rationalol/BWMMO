extends Control

signal map_pressed

const UI = preload("res://scripts/ui_theme.gd")

const TILE_COLORS := {
	"#": Color(0.078, 0.176, 0.133),
	"g": Color(0.169, 0.322, 0.165),
	".": Color(0.596, 0.518, 0.341),
	",": Color(0.510, 0.451, 0.302),
	"~": Color(0.145, 0.380, 0.553),
	"P": Color(0.925, 0.749, 0.333),
	"=": Color(0.404, 0.353, 0.263),
	"f": Color(0.192, 0.365, 0.184)
}

var map_info: Dictionary = {}
var map_name := ""
var self_grid := Vector2i.ZERO
var self_dir := "down"
var nearby_npc_id := ""
var large := false

func _ready() -> void:
	mouse_filter = MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	clip_contents = true

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()

func configure(
	info: Dictionary,
	name: String,
	grid: Vector2i,
	direction: String,
	nearby_id: String = ""
) -> void:
	map_info = info
	map_name = name
	self_grid = grid
	self_dir = direction
	nearby_npc_id = nearby_id
	queue_redraw()

func set_self_position(grid: Vector2i, direction: String) -> void:
	self_grid = grid
	self_dir = direction
	queue_redraw()

func set_nearby_npc(npc_id: String) -> void:
	if nearby_npc_id == npc_id:
		return
	nearby_npc_id = npc_id
	queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		map_pressed.emit()
		accept_event()
	elif event is InputEventScreenTouch and event.pressed:
		map_pressed.emit()
		accept_event()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.015, 0.043, 0.075, 0.98))
	draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.05), false, 1.0)

	var tiles: Array = map_info.get("tiles", [])
	if tiles.is_empty():
		_draw_empty()
		return

	var rows := tiles.size()
	var cols := str(tiles[0]).length()
	if cols <= 0:
		_draw_empty()
		return

	var tile_x := int(map_info.get("tileX", 0))
	var tile_y := int(map_info.get("tileY", 0))
	var map_width := int(map_info.get("width", cols))
	var map_height := int(map_info.get("height", rows))
	var indoor := _is_indoor(map_width, map_height)
	var layout := _layout(indoor, cols, rows, tile_x, tile_y)

	_draw_tiles(tiles, layout, tile_x, tile_y)
	_draw_npcs(layout)
	_draw_self(layout)
	_draw_compass()

func _is_indoor(map_width: int, map_height: int) -> bool:
	if str(map_info.get("id", "")).begins_with("unova_in_"):
		return true
	return not bool(map_info.get("windowed", false)) and map_width <= 52 and map_height <= 44

func _layout(indoor: bool, cols: int, rows: int, tile_x: int, tile_y: int) -> Dictionary:
	if indoor:
		var tile_px := minf((size.x - 16.0) / float(cols), (size.y - 16.0) / float(rows))
		tile_px = clampf(tile_px, 2.0, 13.0)
		var origin := (size - Vector2(cols, rows) * tile_px) * 0.5
		var local := Vector2(self_grid.x - tile_x, self_grid.y - tile_y) + Vector2(0.5, 0.5)
		return {
			"tile": tile_px,
			"origin": origin,
			"tile_origin": Vector2(tile_x, tile_y),
			"self": origin + local * tile_px
		}
	var visible := Vector2(65.0, 32.0) if large else Vector2(40.0, 32.0)
	var tile_px := minf(size.x / visible.x, size.y / visible.y)
	var self_local := Vector2(self_grid.x - tile_x, self_grid.y - tile_y)
	var origin := size * 0.5 - (self_local + Vector2(0.5, 0.5)) * tile_px
	return {
		"tile": tile_px,
		"origin": origin,
		"tile_origin": Vector2(tile_x, tile_y),
		"self": size * 0.5
	}

func _draw_tiles(tiles: Array, layout: Dictionary, tile_x: int, tile_y: int) -> void:
	var tile_px: float = layout["tile"]
	var origin: Vector2 = layout["origin"]
	var rows := tiles.size()
	var cols := str(tiles[0]).length()
	var inset := tile_px + 1.0
	var min_x := maxi(0, int(floor((-origin.x - inset) / tile_px)))
	var max_x := mini(cols - 1, int(ceil((size.x - origin.x + inset) / tile_px)))
	var min_y := maxi(0, int(floor((-origin.y - inset) / tile_px)))
	var max_y := mini(rows - 1, int(ceil((size.y - origin.y + inset) / tile_px)))

	if tile_px < 2.0:
		min_x = 0
		max_x = cols - 1
		min_y = 0
		max_y = rows - 1

	for local_y in range(min_y, max_y + 1):
		var row := str(tiles[local_y])
		if row.length() < cols:
			cols = row.length()
		for local_x in range(min_x, max_x + 1):
			if local_x >= row.length():
				continue
			var glyph := row[local_x]
			var color := _tile_color(glyph, tile_x + local_x, tile_y + local_y)
			var position := origin + Vector2(local_x, local_y) * tile_px
			draw_rect(Rect2(position, Vector2(tile_px + 0.55, tile_px + 0.55)), color)
			if tile_px >= 3.2:
				_draw_tile_detail(glyph, position, tile_px, tile_x + local_x, tile_y + local_y)

func _draw_tile_detail(
	glyph: String,
	position: Vector2,
	tile_px: float,
	grid_x: int,
	grid_y: int
) -> void:
	var noise := absi(grid_x * 928371 + grid_y * 123457) % 97
	if glyph == "g" and noise % 5 == 0:
		var dot := maxf(1.0, tile_px * 0.18)
		draw_rect(
			Rect2(position + Vector2(tile_px * 0.36, tile_px * 0.38), Vector2(dot, dot)),
			Color(0.43, 0.68, 0.32, 0.75)
		)
	elif glyph == "#" and noise % 4 == 0:
		var center := position + Vector2(tile_px * 0.5, tile_px * 0.5)
		draw_circle(center, tile_px * 0.18, Color(0.16, 0.31, 0.22, 0.8))
	elif glyph == "~" and noise % 6 == 0:
		draw_line(
			position + Vector2(tile_px * 0.18, tile_px * 0.58),
			position + Vector2(tile_px * 0.78, tile_px * 0.58),
			Color(0.38, 0.66, 0.82, 0.55),
			maxf(1.0, tile_px * 0.12)
		)

func _tile_color(glyph: String, grid_x: int, grid_y: int) -> Color:
	var base: Color = TILE_COLORS.get(glyph, TILE_COLORS["#"])
	var noise := absi(grid_x * 3191 + grid_y * 7919) % 101
	var shift := (float(noise) / 101.0 - 0.5) * 0.07
	return Color(
		clampf(base.r + shift, 0.0, 1.0),
		clampf(base.g + shift, 0.0, 1.0),
		clampf(base.b + shift * 0.6, 0.0, 1.0),
		base.a
	)

func _draw_npcs(layout: Dictionary) -> void:
	var tile_px: float = layout["tile"]
	var origin: Vector2 = layout["origin"]
	var tile_origin: Vector2 = layout["tile_origin"]
	for entry in map_info.get("npcs", []):
		if not (entry is Dictionary):
			continue
		var npc: Dictionary = entry
		var grid := Vector2i(int(npc.get("x", 0)), int(npc.get("y", 0)))
		var position := (
			origin
			+ (Vector2(grid.x, grid.y) - tile_origin + Vector2(0.5, 0.5)) * tile_px
		)
		if not Rect2(Vector2(-4, -4), size + Vector2(8, 8)).has_point(position):
			continue
		var highlighted := str(npc.get("id", "")) == nearby_npc_id
		if highlighted:
			draw_arc(position, maxf(5.6, tile_px * 1.35), 0.0, TAU, 20, UI.GOLD, 1.5)
		draw_circle(position, 3.8, Color(0.02, 0.06, 0.10, 0.95))
		var marker_color := (
			Color(0.973, 0.800, 0.400) if highlighted else Color(0.855, 0.906, 0.961)
		)
		draw_circle(position, 3.0, marker_color)
		draw_arc(position, 3.0, PI, TAU, 10, Color(0.925, 0.420, 0.310), 1.7)
		draw_circle(position, 1.0, Color(0.06, 0.10, 0.15))

func _draw_self(layout: Dictionary) -> void:
	var center: Vector2 = layout["self"]
	var direction := Vector2.ZERO
	match self_dir:
		"up":
			direction = Vector2(0, -1)
		"left":
			direction = Vector2(-1, 0)
		"right":
			direction = Vector2(1, 0)
		_:
			direction = Vector2(0, 1)
	var side := Vector2(-direction.y, direction.x)
	var tip := center + direction * 8.5
	var back := center - direction * 4.5
	var left := back + side * 6.0
	var right := back - side * 6.0
	var halo := PackedVector2Array([
		tip + direction * 1.4, left + side * 1.4, left, right, right + side * 1.4
	])
	draw_colored_polygon(halo, Color(0.02, 0.05, 0.09, 0.9))
	var arrow := PackedVector2Array([tip, left, back, right])
	draw_colored_polygon(arrow, UI.TEXT)
	var inner_tip := center + direction * 6.2
	var inner_back := center - direction * 2.6
	var inner := PackedVector2Array([
		inner_tip,
		inner_back + side * 3.8,
		inner_back,
		inner_back - side * 3.8
	])
	draw_colored_polygon(inner, Color(0.224, 0.639, 0.965))

func _draw_compass() -> void:
	var center := Vector2(15, 18)
	draw_circle(center, 10.5, Color(0.024, 0.067, 0.110, 0.92))
	draw_arc(center, 10.5, 0.0, TAU, 28, Color(1, 1, 1, 0.16), 1.0)
	var needle := PackedVector2Array([
		center + Vector2(0, -7.5),
		center + Vector2(3.4, 0.5),
		center + Vector2(0, 2.2),
		center + Vector2(-3.4, 0.5)
	])
	draw_colored_polygon(needle, Color(0.957, 0.384, 0.353))
	var tail := PackedVector2Array([
		center + Vector2(0, 7.0),
		center + Vector2(3.0, 0.5),
		center + Vector2(0, 2.2),
		center + Vector2(-3.0, 0.5)
	])
	draw_colored_polygon(tail, Color(0.898, 0.929, 0.961))
	draw_circle(center, 1.2, Color(0.024, 0.067, 0.110, 1.0))
	draw_string(
		ThemeDB.fallback_font,
		center + Vector2(-3.5, -14.0),
		"N",
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		7,
		Color(0.745, 0.804, 0.871, 0.9)
	)

func _draw_empty() -> void:
	var font := ThemeDB.fallback_font
	var text := TranslationServer.translate("NO MAP DATA")
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
	draw_string(
		font,
		(size - Vector2(width, 0)) * 0.5 + Vector2(0, 3),
		text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		9,
		UI.FAINT
	)
