extends SceneTree

const MainScript = preload("res://scripts/main.gd")
const ViewScript = preload("res://scripts/world_view.gd")

var failures := 0

func _expect(actual: String, expected: String, label: String) -> void:
	if actual != expected:
		push_error("%s: expected '%s', got '%s'" % [label, expected, actual])
		failures += 1

func _check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failures += 1

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var main = MainScript.new()
	# A new direction only turns; the same press must not take a step.
	_expect(main._movement_input_action("up", "down", false, 1000, 0), "turn", "new direction")
	# A second press while already facing the direction steps.
	_expect(main._movement_input_action("up", "up", false, 1000, 1000), "move", "facing match")
	# The step interval still rate-limits held movement.
	_expect(main._movement_input_action("up", "up", false, 999, 1000), "", "step gate")
	# Turning waits until the current step animation finishes.
	_expect(main._movement_input_action("up", "down", true, 1000, 0), "", "mid-step turn")
	_expect(main._movement_input_action("", "down", false, 1000, 0), "", "no input")
	main.free()

	var view = ViewScript.new()
	root.add_child(view)
	await process_frame
	view.setup_map(
		{
			"id": "turn-test",
			"width": 5,
			"height": 5,
			"tiles": [".....", ".....", ".....", ".....", "....."],
			"npcs": []
		},
		{"id": "self", "name": "Self", "color": "#ffffff", "x": 2, "y": 2, "dir": "down"},
		[]
	)
	view.turn_self("up")
	_expect(view.self_facing(), "up", "world turn facing")
	_check(view.self_grid == Vector2i(2, 2), "turning in place must not move the character")
	_check(view.predict_self_move("up"), "a step after turning should be predicted")
	_check(view.self_grid == Vector2i(2, 1), "the predicted step should advance one tile")
	view.free()

	print("[turn] %s" % ("FAILED" if failures > 0 else "PASSED"))
	quit(1 if failures > 0 else 0)
