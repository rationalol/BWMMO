extends Control

signal map_pressed
signal place_selected(place_name: String)

const UI = preload("res://scripts/ui_theme.gd")
const MAP_PATH := "res://assets/bw/ui/unova_map.png"
const MAP_BG := Color(0.012, 0.037, 0.067, 1.0)
const OUTLINE := Color(0.016, 0.039, 0.067, 0.95)

var _texture: Texture2D = null
var _map_width := 256
var _map_height := 168
var _places: Array = []
var _current_name := ""
var _last_current_name := ""
var _hovered := -1
var _selected := -1
var _pulse := 0.0

func _ready() -> void:
	mouse_filter = MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	clip_contents = true
	texture_filter = TEXTURE_FILTER_NEAREST
	if ResourceLoader.exists(MAP_PATH):
		_texture = load(MAP_PATH) as Texture2D
	set_process(false)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()
	elif what == NOTIFICATION_VISIBILITY_CHANGED:
		set_process(is_visible_in_tree())

func _process(delta: float) -> void:
	_pulse = fmod(_pulse + delta, TAU)
	queue_redraw()

func configure(data: Dictionary, current_name: String) -> void:
	_map_width = maxi(1, int(data.get("width", 256)))
	_map_height = maxi(1, int(data.get("height", 168)))
	_places.clear()
	var raw: Variant = data.get("places", [])
	if raw is Array:
		for entry in raw:
			if not (entry is Dictionary):
				continue
			var place: Dictionary = entry
			var place_name := str(place.get("name", "")).strip_edges()
			if place_name == "":
				continue
			_places.append({
				"name": place_name,
				"x": float(place.get("x", 0)),
				"y": float(place.get("y", 0)),
				"kind": str(place.get("kind", "landmark"))
			})
	_current_name = current_name
	if _has_place(current_name):
		_last_current_name = current_name
	_hovered = -1
	_selected = -1
	queue_redraw()

func set_current(place_name: String) -> void:
	if _current_name == place_name:
		return
	_current_name = place_name
	if _has_place(place_name):
		_last_current_name = place_name
	queue_redraw()

func place_count() -> int:
	return _places.size()

func has_map_texture() -> bool:
	return _texture != null

func current_place_name() -> String:
	return _effective_current()

func marker_position(place_name: String) -> Vector2:
	for place in _places:
		if str(place["name"]) == place_name:
			return _origin() + Vector2(float(place["x"]), float(place["y"])) * _scale()
	return Vector2(-1, -1)

func _has_place(place_name: String) -> bool:
	if place_name == "":
		return false
	for place in _places:
		if str(place["name"]) == place_name:
			return true
	return false

func _effective_current() -> String:
	if _has_place(_current_name):
		return _current_name
	if _has_place(_last_current_name):
		return _last_current_name
	return ""

func _scale() -> float:
	return minf(size.x / float(_map_width), size.y / float(_map_height))

func _origin() -> Vector2:
	var drawn := Vector2(_map_width, _map_height) * _scale()
	return (size - drawn) * 0.5

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), MAP_BG)
	var scale := _scale()
	var drawn := Vector2(_map_width, _map_height) * scale
	var origin := _origin()
	if _texture != null:
		draw_texture_rect(_texture, Rect2(origin, drawn), false)
	else:
		_draw_empty(origin, drawn)
	draw_rect(Rect2(origin, drawn), Color(1, 1, 1, 0.14), false, 1.0)

	var current := _effective_current()
	for index in range(_places.size()):
		var place: Dictionary = _places[index]
		if str(place["name"]) == current:
			continue
		_draw_place(place, origin, scale, index)
	for index in range(_places.size()):
		var place: Dictionary = _places[index]
		if str(place["name"]) != current:
			continue
		_draw_current(place, origin, scale)
		_draw_name_tag(
			origin + Vector2(float(place["x"]), float(place["y"])) * scale,
			current,
			origin,
			drawn
		)
	_draw_tooltip(origin, scale)

func _draw_empty(origin: Vector2, drawn: Vector2) -> void:
	draw_rect(Rect2(origin, drawn), Color(0.020, 0.051, 0.086, 0.94))
	# Without the ROM texture the marker list still forms a usable schematic
	# map; only a completely empty payload needs the no-data label.
	if not _places.is_empty():
		return
	var font := UI.bw_font()
	var font_size := UI.font_size(10)
	var text := TranslationServer.translate("NO MAP DATA")
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	draw_string(
		font,
		origin + (drawn - text_size) * 0.5 + Vector2(0, font.get_ascent(font_size)),
		text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		font_size,
		UI.FAINT
	)

func _draw_place(
	place: Dictionary,
	origin: Vector2,
	scale: float,
	index: int
) -> void:
	var center := origin + Vector2(float(place["x"]), float(place["y"])) * scale
	var kind := str(place["kind"])
	var radius := 3.6 if kind == "town" else 2.0 if kind == "route" else 2.6
	var fill := (
		UI.GOLD
		if kind == "town"
		else Color(0.820, 0.902, 0.973) if kind == "route" else UI.ACCENT
	)
	if kind == "landmark":
		var half := Vector2(radius, radius)
		draw_rect(Rect2(center - half, half * 2.0), OUTLINE)
		draw_rect(Rect2(center - half + Vector2.ONE, half * 2.0 - Vector2.ONE * 2.0), fill)
	else:
		draw_circle(center, radius + 1.2, OUTLINE)
		draw_circle(center, radius, fill)
	if index == _hovered or index == _selected:
		var ring := radius + 4.0
		draw_arc(center, ring, 0.0, TAU, 24, UI.ACCENT, 1.6)
		if index == _selected:
			draw_arc(center, ring + 2.4, 0.0, TAU, 24, Color(UI.ACCENT.r, UI.ACCENT.g, UI.ACCENT.b, 0.35), 1.4)

func _draw_current(place: Dictionary, origin: Vector2, scale: float) -> void:
	var center := origin + Vector2(float(place["x"]), float(place["y"])) * scale
	var pulse := 0.5 + 0.5 * sin(_pulse * 2.4)
	draw_arc(
		center,
		7.5 + pulse * 4.0,
		0.0,
		TAU,
		32,
		Color(UI.GOLD.r, UI.GOLD.g, UI.GOLD.b, 0.55 - pulse * 0.30),
		1.8
	)
	draw_circle(center, 6.8, OUTLINE)
	draw_circle(center, 5.4, UI.DANGER)
	draw_arc(center, 5.4, 0.0, TAU, 28, Color(1, 1, 1, 0.95), 1.4)
	draw_circle(center, 1.8, Color(1.0, 0.95, 0.86))

func _draw_name_tag(
	center: Vector2,
	text: String,
	origin: Vector2,
	drawn: Vector2
) -> void:
	var font := UI.bw_font()
	var font_size := UI.font_size(10)
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var pad := Vector2(6, 3)
	var box_size := text_size + pad * 2.0
	var box := Rect2(center + Vector2(-box_size.x * 0.5, -box_size.y - 12.0), box_size)
	box.position.x = clampf(box.position.x, origin.x + 2.0, origin.x + drawn.x - box_size.x - 2.0)
	box.position.y = clampf(box.position.y, origin.y + 2.0, origin.y + drawn.y - box_size.y - 2.0)
	draw_rect(box, Color(0.016, 0.039, 0.067, 0.90))
	draw_rect(box, Color(UI.GOLD.r, UI.GOLD.g, UI.GOLD.b, 0.55), false, 1.0)
	draw_string(
		font,
		box.position + pad + Vector2(0, font.get_ascent(font_size)),
		text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		font_size,
		UI.GOLD
	)

func _draw_tooltip(origin: Vector2, scale: float) -> void:
	var index := _selected if _selected >= 0 else _hovered
	if index < 0 or index >= _places.size():
		return
	var place: Dictionary = _places[index]
	var place_name := str(place["name"])
	if place_name == _effective_current():
		return
	var center := origin + Vector2(float(place["x"]), float(place["y"])) * scale
	var font := UI.bw_font()
	var font_size := UI.font_size(9)
	var text_size := font.get_string_size(place_name, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var pad := Vector2(5, 2)
	var box_size := text_size + pad * 2.0
	var box := Rect2(center + Vector2(-box_size.x * 0.5, -box_size.y - 10.0), box_size)
	box.position.x = clampf(box.position.x, origin.x + 2.0, size.x - origin.x - box_size.x - 2.0)
	box.position.y = clampf(box.position.y, origin.y + 2.0, size.y - origin.y - box_size.y - 2.0)
	draw_rect(box, Color(0.016, 0.039, 0.067, 0.94))
	draw_rect(box, Color(1, 1, 1, 0.16), false, 1.0)
	draw_string(
		font,
		box.position + pad + Vector2(0, font.get_ascent(font_size)),
		place_name,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		font_size,
		UI.TEXT
	)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var index := _place_at(event.position)
		if index != _hovered:
			_hovered = index
			queue_redraw()
	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
			_handle_press(button.position)
			accept_event()
	elif event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_handle_press(touch.position)
			accept_event()

func _handle_press(position: Vector2) -> void:
	var index := _place_at(position)
	if index < 0:
		map_pressed.emit()
		return
	_selected = index
	_hovered = index
	place_selected.emit(str(_places[index]["name"]))
	queue_redraw()

func _place_at(position: Vector2) -> int:
	var origin := _origin()
	var scale := _scale()
	var best := -1
	var best_distance := 12.0 * 12.0
	for index in range(_places.size()):
		var place: Dictionary = _places[index]
		var center := origin + Vector2(float(place["x"]), float(place["y"])) * scale
		var distance := center.distance_squared_to(position)
		if distance <= best_distance:
			best_distance = distance
			best = index
	return best
