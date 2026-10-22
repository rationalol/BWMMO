extends Node2D

const TILE := 32
const STEP_SPEED := 32.0 / 0.16

var entity_id := ""
var display_name := ""
var body_color := Color.WHITE
var kind := "player"
var is_self := false
var facing := "down"
var grid := Vector2i.ZERO
var trainer_sprite_id := -1
var _trainer_texture: Texture2D = null

var _target_position := Vector2.ZERO
var _moving := false
var _name_label: Label
var _bubble_panel: PanelContainer
var _bubble_label: Label
var _bubble_timer: Timer

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_name_label = Label.new()
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.position = Vector2(-60, -54)
	_name_label.size = Vector2(120, 18)
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name_label.add_theme_font_size_override("font_size", 10)
	_name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_name_label.add_theme_constant_override("outline_size", 3)
	add_child(_name_label)

	_bubble_panel = PanelContainer.new()
	_bubble_panel.visible = false
	_bubble_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bubble_style := StyleBoxFlat.new()
	bubble_style.bg_color = Color(0.94, 0.96, 0.97, 0.96)
	bubble_style.corner_radius_top_left = 7
	bubble_style.corner_radius_top_right = 7
	bubble_style.corner_radius_bottom_left = 7
	bubble_style.corner_radius_bottom_right = 7
	bubble_style.content_margin_left = 7
	bubble_style.content_margin_top = 4
	bubble_style.content_margin_right = 7
	bubble_style.content_margin_bottom = 4
	_bubble_panel.add_theme_stylebox_override("panel", bubble_style)
	_bubble_label = Label.new()
	_bubble_label.add_theme_color_override("font_color", Color(0.06, 0.08, 0.10))
	_bubble_label.add_theme_font_size_override("font_size", 10)
	_bubble_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bubble_panel.add_child(_bubble_label)
	add_child(_bubble_panel)

	_bubble_timer = Timer.new()
	_bubble_timer.one_shot = true
	_bubble_timer.wait_time = 4.0
	_bubble_timer.timeout.connect(_hide_bubble)
	add_child(_bubble_timer)

func setup(
	id: String,
	shown_name: String,
	color: Color,
	entity_kind: String = "player",
	self_controlled: bool = false,
	trainer_sprite: int = -1
) -> void:
	entity_id = id
	display_name = shown_name
	body_color = color
	kind = entity_kind
	is_self = self_controlled
	trainer_sprite_id = trainer_sprite
	_trainer_texture = null
	if trainer_sprite_id >= 0:
		var path := "res://assets/bw/trainers/%d.png" % trainer_sprite_id
		if ResourceLoader.exists(path):
			_trainer_texture = load(path)
	_name_label.text = shown_name
	_name_label.add_theme_color_override(
		"font_color",
		Color(1.0, 0.82, 0.40) if is_self else Color(0.91, 0.95, 0.95)
	)
	queue_redraw()

func set_grid(value: Vector2i, snap: bool = true) -> void:
	grid = value
	_target_position = _grid_to_position(value)
	if snap:
		position = _target_position
		_moving = false
	else:
		_moving = true

func is_moving() -> bool:
	return _moving

func move_to_grid(value: Vector2i, direction: String) -> void:
	grid = value
	facing = direction
	_target_position = _grid_to_position(value)
	_moving = true
	queue_redraw()

func set_facing(direction: String) -> void:
	if facing != direction:
		facing = direction
		queue_redraw()

func show_bubble(text: String) -> void:
	var shortened := text
	if shortened.length() > 58:
		shortened = shortened.substr(0, 55) + "..."
	_bubble_label.text = shortened
	_bubble_panel.visible = true
	_bubble_panel.reset_size()
	_bubble_panel.size = _bubble_panel.get_combined_minimum_size()
	_bubble_panel.position = Vector2(-_bubble_panel.size.x * 0.5, -80)
	_bubble_timer.start()

func _hide_bubble() -> void:
	_bubble_panel.visible = false

func _process(delta: float) -> void:
	if not _moving:
		return
	position = position.move_toward(_target_position, STEP_SPEED * delta)
	if position.distance_to(_target_position) < 0.5:
		position = _target_position
		_moving = false

func _grid_to_position(value: Vector2i) -> Vector2:
	return Vector2(value.x * TILE + TILE * 0.5, value.y * TILE + TILE * 0.5)

func _draw_trainer_texture() -> void:
	draw_set_transform(Vector2(0, 13), 0.0, Vector2(1.0, 0.45))
	draw_circle(Vector2.ZERO, 10.0, Color(0, 0, 0, 0.28))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	var destination := Rect2(Vector2(-24, -38), Vector2(48, 48))
	if facing == "left":
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(-1.0, 1.0))
		draw_texture_rect(_trainer_texture, destination, false)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	else:
		draw_texture_rect(_trainer_texture, destination, false)

	if kind == "healer":
		draw_rect(Rect2(12, -20, 8, 3), Color(0.30, 0.72, 0.45))
		draw_rect(Rect2(14.5, -22.5, 3, 8), Color(0.30, 0.72, 0.45))
	elif kind == "guide":
		draw_circle(Vector2(0, -47), 3.0, Color(1.0, 0.82, 0.40))

func _draw() -> void:
	if _trainer_texture != null:
		_draw_trainer_texture()
		return

	# Soft shadow.
	draw_set_transform(Vector2(0, 13), 0.0, Vector2(1.0, 0.45))
	draw_circle(Vector2.ZERO, 10.0, Color(0, 0, 0, 0.28))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# Legs.
	draw_rect(Rect2(-6, 4, 5, 8), Color(0.13, 0.16, 0.20))
	draw_rect(Rect2(1, 4, 5, 8), Color(0.13, 0.16, 0.20))

	# Body.
	draw_circle(Vector2(0, 0), 10.0, Color(0.05, 0.07, 0.09))
	draw_rect(Rect2(-9, -3, 18, 11), body_color)
	draw_circle(Vector2(0, 0), 9.0, body_color)
	draw_circle(Vector2(-10, 0), 3.2, body_color.darkened(0.12))
	draw_circle(Vector2(10, 0), 3.2, body_color.darkened(0.12))
	draw_rect(Rect2(-9, 4, 18, 2), body_color.darkened(0.28))

	# Head.
	draw_circle(Vector2(0, -13), 9.0, Color(0.05, 0.07, 0.09))
	draw_circle(Vector2(0, -13), 8.2, Color(0.949, 0.788, 0.627))

	# Cap.
	var cap := body_color.darkened(0.2)
	draw_rect(Rect2(-8.4, -21, 16.8, 5), cap)
	draw_rect(Rect2(-10.0, -17, 20.0, 2.5), cap.darkened(0.12))

	# Face direction.
	var eye := Color(0.09, 0.11, 0.14)
	match facing:
		"up":
			pass
		"left":
			draw_circle(Vector2(-4, -12), 1.5, eye)
		"right":
			draw_circle(Vector2(4, -12), 1.5, eye)
		_:
			draw_circle(Vector2(-3.2, -12), 1.5, eye)
			draw_circle(Vector2(3.2, -12), 1.5, eye)

	if kind == "healer":
		draw_rect(Rect2(-2, -1, 4, 10), Color(0.95, 0.97, 0.98))
		draw_rect(Rect2(-5.5, 1.5, 11, 3.5), Color(0.95, 0.97, 0.98))
		draw_rect(Rect2(-2.6, -1.8, 5.2, 12), Color(0.30, 0.72, 0.45))
		draw_rect(Rect2(-6.2, 1.2, 12.4, 4.6), Color(0.30, 0.72, 0.45))
	elif kind == "guide":
		draw_circle(Vector2(0, -28), 3.0, Color(1.0, 0.82, 0.40))
		draw_circle(Vector2(0, -28), 1.2, Color(0.10, 0.13, 0.16))

	if is_self:
		draw_colored_polygon(
			PackedVector2Array([
				Vector2(-4, -34),
				Vector2(4, -34),
				Vector2(0, -28)
			]),
			Color(1.0, 0.82, 0.40)
		)
