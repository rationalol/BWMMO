extends Node

# Headless test for the gift-box starter cutscene. Run with:
#   godot --headless --path client res://tests/StarterChoiceTest.tscn

const StarterUIScript = preload("res://scripts/starter_choice_ui.gd")

const STARTERS := [
	{"id": "snivy", "name": "Snivy", "types": ["Grass"], "level": 5},
	{"id": "tepig", "name": "Tepig", "types": ["Fire"], "level": 5},
	{"id": "oshawott", "name": "Oshawott", "types": ["Water"], "level": 5}
]

var failures: Array[String] = []
var _original_locale := "en"

func _ready() -> void:
	_original_locale = Loc.locale
	Loc.set_locale("en")
	call_deferred("_run")

func _run() -> void:
	get_tree().root.size = Vector2i(960, 540)
	await get_tree().process_frame

	var ui = StarterUIScript.new()
	add_child(ui)
	await get_tree().process_frame
	_check(not ui.visible, "starter scene starts hidden")

	var received: Array[String] = []
	ui.chosen.connect(func(option_id: String) -> void: received.append(option_id))
	ui.show_choice(["Which Pokémon will you choose?"], STARTERS)
	await get_tree().create_timer(0.5).timeout

	_check(ui.visible, "starter scene opens")
	_check(ui.option_count() == 3, "three starter options")
	_check(ui.selected_index() == -1, "no partner is selected before a ball is clicked")
	_check(ui._confirm_button.disabled, "confirm starts disabled")
	_check(ui._prompt_label.text == "Which Pokémon will you choose?", "prompt is shown")
	_check(ui._buttons.size() == 3, "three Poké Ball buttons are built")
	_check(ui._background.texture != null, "room backdrop loaded")
	_check(ui._box.texture != null, "gift box art loaded")
	_check(ui._ball_icons[0].texture != null, "Poké Ball art loaded")
	var box_rect: Rect2 = ui._box.get_global_rect()
	for index in range(ui._buttons.size()):
		var ball: Control = ui._buttons[index]
		var rect := ball.get_global_rect()
		_check(
			rect.position.x >= 0.0 and rect.position.y >= 0.0
			and rect.end.x <= 960.5 and rect.end.y <= 540.5,
			"ball %d stays inside the viewport" % index
		)
		_check(
			rect.end.y < ui._prompt_label.get_global_rect().position.y,
			"ball %d sits above the dialogue box" % index
		)
		_check(
			box_rect.has_point(rect.get_center()),
			"ball %d rests inside the gift box opening" % index
		)
	var detail_rect: Rect2 = ui._detail_label.get_global_rect()
	var confirm_rect: Rect2 = ui._confirm_button.get_global_rect()
	_check(detail_rect.end.x <= confirm_rect.position.x + 0.5, "detail text clears the confirm button")
	_check(confirm_rect.end.x <= 870.5, "confirm button stays inside the dialogue panel")
	_check(confirm_rect.end.y <= 522.5, "confirm button stays inside the dialogue panel vertically")
	var dialog_rect: Rect2 = ui._prompt_label.get_global_rect()
	_check(dialog_rect.position.x > 60.0, "dialogue box is centred")
	_check(ui._hint_label.is_visible_in_tree(), "control hint is visible")

	var right := InputEventKey.new()
	right.keycode = KEY_RIGHT
	right.pressed = true
	Input.parse_input_event(right)
	await get_tree().process_frame
	_check(ui._hovered == 0, "right arrow inspects the first ball")
	var left := InputEventKey.new()
	left.keycode = KEY_LEFT
	left.pressed = true
	Input.parse_input_event(left)
	await get_tree().process_frame
	_check(ui._hovered == 2, "left arrow wraps to the last ball")

	ui.select_for_test(1)
	await get_tree().create_timer(0.55).timeout
	_check(ui.selected_index() == 1, "clicking a ball selects that partner")
	_check(not ui._confirm_button.disabled, "confirm enables after a selection")
	_check(ui._confirm_button.text == "Choose Tepig", "confirm names the partner")
	_check(ui._name_label.text.contains("Tepig"), "partner name is shown above the box")
	_check(ui._types_row.get_child_count() == 1, "one type chip for Tepig")
	_check(ui._detail_label.text.contains("Fire"), "detail line shows the Fire type")
	var tepig_texture = load("res://assets/bw/pokemon/tepig_front.png")
	if ResourceLoader.exists("res://assets/bw/pokemon/tepig_front.png"):
		_check(ui._pokemon.texture == tepig_texture, "Tepig portrait is displayed")
	_check(ui._pokemon_holder.visible, "partner portrait animates above the gift box")
	_check(ui._pokemon_holder.modulate.a > 0.9, "partner portrait fades in")

	ui.select_for_test(2)
	await get_tree().create_timer(0.55).timeout
	_check(ui.selected_index() == 2, "another ball can be inspected before confirming")
	_check(ui._name_label.text.contains("Oshawott"), "name follows the new selection")

	ui.confirm_for_test()
	_check(received == ["oshawott"], "confirm emits the chosen species")
	_check(not ui._accepting, "scene stops accepting input after confirming")
	ui.confirm_for_test()
	_check(received.size() == 1, "confirm cannot fire twice")
	ui.close()
	await get_tree().process_frame
	_check(not ui.visible, "scene closes after the server continues")

	Loc.set_locale("zh_CN")
	ui.show_choice(["你要选择哪只宝可梦？"], STARTERS)
	await get_tree().process_frame
	_check(ui._confirm_button.text == "选择", "Chinese confirm label")
	ui.select_for_test(0)
	await get_tree().create_timer(0.55).timeout
	_check(ui._name_label.text.contains("藤藤蛇"), "Chinese partner name")
	_check(ui._confirm_button.text == "选择藤藤蛇", "Chinese confirm names the partner")
	_check(ui._types_row.get_child_count() == 1, "Chinese type chip built")
	ui.queue_free()

	Loc.set_locale(_original_locale)
	if failures.is_empty():
		print("starter choice checks passed")
		get_tree().quit(0)
	else:
		print("starter choice checks failed: ", failures.size())
		get_tree().quit(1)

func _check(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	print("FAIL: ", message)
