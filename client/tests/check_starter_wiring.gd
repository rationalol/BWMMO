extends Node

# Wiring test: the protocol's starter choice must open the gift-box scene and
# the generic three-button card must stay out of the way. Run with:
#   godot --headless --path client res://tests/StarterWiringTest.tscn

var failures: Array[String] = []

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var packed := load("res://scenes/Main.tscn") as PackedScene
	_check(packed != null, "Main scene loads")
	if packed == null:
		_finish()
		return
	var main = packed.instantiate()
	add_child(main)
	await get_tree().process_frame
	await get_tree().process_frame

	var message := {
		"type": "story_choice",
		"kind": "starter",
		"sceneId": "prologue_bedroom_intro",
		"step": 4,
		"prompt": ["Which Pokémon will you choose?"],
		"options": [
			{"id": "snivy", "name": "Snivy", "types": ["Grass"], "level": 5},
			{"id": "tepig", "name": "Tepig", "types": ["Fire"], "level": 5},
			{"id": "oshawott", "name": "Oshawott", "types": ["Water"], "level": 5}
		]
	}
	main._on_story_choice(message)
	await get_tree().process_frame
	_check(main.starter_choice_ui != null, "starter scene exists")
	_check(main.starter_choice_ui.visible, "starter scene opens for kind=starter")
	_check(main.starter_choice_ui.option_count() == 3, "starter scene receives three options")
	_check(not main.story_choice_ui.visible, "generic choice card stays hidden")

	main._on_story_choice({
		"type": "story_choice",
		"sceneId": "some_other_scene",
		"step": 1,
		"prompt": ["Pick one."],
		"options": [{"id": "a", "name": "A", "level": 1}]
	})
	await get_tree().process_frame
	_check(not main.starter_choice_ui.visible, "generic choice closes the gift box")
	_check(main.story_choice_ui.visible, "generic choice still uses the standard card")

	main._on_story_end({"sceneId": "some_other_scene"})
	await get_tree().process_frame
	_check(not main.story_choice_ui.visible, "story_end closes the generic card")

	main.queue_free()
	await get_tree().process_frame
	_finish()

func _finish() -> void:
	if failures.is_empty():
		print("starter wiring checks passed")
		get_tree().quit(0)
	else:
		print("starter wiring checks failed: ", failures.size())
		get_tree().quit(1)

func _check(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	print("FAIL: ", message)
