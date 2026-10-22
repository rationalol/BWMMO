extends Control

const UI = preload("res://scripts/ui_theme.gd")

var types: Array = []

func _ready() -> void:
	mouse_filter = MOUSE_FILTER_PASS
	custom_minimum_size = Vector2(7, 8)

func setup(type_names: Array) -> void:
	types = type_names.duplicate()
	custom_minimum_size = Vector2(maxi(1, types.size()) * 7, 8)
	var labels: Array = []
	for type_name in types:
		labels.append(str(type_name))
	tooltip_text = " / ".join(PackedStringArray(labels))
	queue_redraw()

func _draw() -> void:
	for index in range(types.size()):
		var center := Vector2(3.5 + float(index) * 7.0, size.y * 0.5)
		var outline := PackedVector2Array([
			center + Vector2(0, -3.4),
			center + Vector2(3.4, 0),
			center + Vector2(0, 3.4),
			center + Vector2(-3.4, 0)
		])
		var inner := PackedVector2Array([
			center + Vector2(0, -2.5),
			center + Vector2(2.5, 0),
			center + Vector2(0, 2.5),
			center + Vector2(-2.5, 0)
		])
		draw_colored_polygon(outline, Color(0.015, 0.043, 0.075, 0.9))
		draw_colored_polygon(inner, UI.type_color(str(types[index])))
