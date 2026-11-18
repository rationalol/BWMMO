extends Control

# Dust motes drifting through the light around the gift box. They are drawn
# instead of using particles so the scene works identically in headless tests
# and with software rendering.

const SPECK_COUNT := 34
const UI = preload("res://scripts/ui_theme.gd")

var _specks: Array = []
var _time := 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5EED
	for index in range(SPECK_COUNT):
		_specks.append({
			"base": Vector2(
				rng.randf_range(120.0, 840.0),
				rng.randf_range(40.0, 372.0)
			),
			"phase": rng.randf_range(0.0, TAU),
			"speed": rng.randf_range(0.35, 0.85),
			"radius": rng.randf_range(0.8, 2.2),
			"drift": rng.randf_range(4.0, 13.0),
			"warm": rng.randf() < 0.72,
			"delay": rng.randf_range(0.0, 1.0)
		})

func _process(delta: float) -> void:
	if not visible:
		return
	_time += delta
	queue_redraw()

func _draw() -> void:
	for index in range(_specks.size()):
		var speck: Dictionary = _specks[index]
		var phase := float(speck["phase"])
		var speed := float(speck["speed"])
		var base: Vector2 = speck["base"]
		var drift := float(speck["drift"])
		var position := base + Vector2(
			sin(_time * speed * 0.55 + phase) * drift,
			cos(_time * speed * 0.42 + phase * 1.3) * drift * 0.55
		)
		var twinkle := 0.5 + 0.5 * sin(_time * speed * 1.6 + phase * 2.0)
		var alpha := (0.18 + 0.5 * twinkle) * (0.6 + 0.4 * float(speck["delay"]))
		var color := Color(1.0, 0.87, 0.58, alpha)
		if not bool(speck["warm"]):
			color = Color(0.84, 0.78, 1.0, alpha * 0.8)
		var radius := float(speck["radius"])
		draw_circle(position, radius, color)
		if twinkle > 0.8:
			var arm := radius * 3.0
			draw_line(
				position - Vector2(arm, 0.0),
				position + Vector2(arm, 0.0),
				Color(color.r, color.g, color.b, color.a * 0.65),
				1.0,
				true
			)
			draw_line(
				position - Vector2(0.0, arm),
				position + Vector2(0.0, arm),
				Color(color.r, color.g, color.b, color.a * 0.65),
				1.0,
				true
			)
