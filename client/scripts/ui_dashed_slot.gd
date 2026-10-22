extends Control

const UI = preload("res://scripts/ui_theme.gd")

var text := "EMPTY"
var text_size := 8
var line_color := Color(1.0, 1.0, 1.0, 0.13)

func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(0, 38)

func _draw() -> void:
	if size.x <= 4.0 or size.y <= 4.0:
		return
	var inset := 0.5
	var radius := 6.0
	var dash := 4.0
	draw_dashed_line(
		Vector2(radius, inset), Vector2(size.x - radius, inset),
		line_color, 1.0, dash, true, true
	)
	draw_dashed_line(
		Vector2(radius, size.y - inset), Vector2(size.x - radius, size.y - inset),
		line_color, 1.0, dash, true, true
	)
	draw_dashed_line(
		Vector2(inset, radius), Vector2(inset, size.y - radius),
		line_color, 1.0, dash, true, true
	)
	draw_dashed_line(
		Vector2(size.x - inset, radius), Vector2(size.x - inset, size.y - radius),
		line_color, 1.0, dash, true, true
	)
	draw_arc(Vector2(radius, radius), radius, PI, PI * 1.5, 6, line_color, 1.0, true)
	draw_arc(Vector2(size.x - radius, radius), radius, PI * 1.5, TAU, 6, line_color, 1.0, true)
	draw_arc(Vector2(radius, size.y - radius), radius, PI * 0.5, PI, 6, line_color, 1.0, true)
	draw_arc(
		Vector2(size.x - radius, size.y - radius),
		radius, 0.0, PI * 0.5, 6, line_color, 1.0, true
	)
	if text == "":
		return
	var font := UI.bw_font()
	var draw_size := UI.font_size(text_size)
	var text_width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, draw_size).x
	draw_string(
		font,
		Vector2((size.x - text_width) * 0.5, size.y * 0.5 + draw_size * 0.36),
		text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		draw_size,
		Color(UI.MUTED.r, UI.MUTED.g, UI.MUTED.b, 0.46)
	)
