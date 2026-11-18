extends Node

# Headless touch-layout test for the NDS-style pad. Run with:
#   .tools/Godot_v4.4.1-stable_win64_console.exe --headless --path client \
#     res://tests/TouchControlsTest.tscn

const TouchControlsScript = preload("res://scripts/touch_controls.gd")

var failures := 0

func _ready() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		print("[touch] FAIL: %s" % message)
	else:
		print("[touch] ok: %s" % message)

func _run() -> void:
	get_tree().root.size = Vector2i(960, 540)
	await get_tree().process_frame

	var touch = TouchControlsScript.new()
	add_child(touch)
	await get_tree().process_frame

	touch.set_mode("world")
	await get_tree().process_frame
	_check(touch.mode == "world", "world mode")
	_check(touch.visible, "controls visible in world mode")

	var dpad: Control = touch.get_node("DPad")
	var plate: Control = touch.get_node("FacePlate")
	var a: Button = touch.get_node("TouchA")
	var b: Button = touch.get_node("TouchB")
	var x: Button = touch.get_node("TouchX")
	var y: Button = touch.get_node("TouchY")
	_check(dpad.visible and plate.visible, "left D-pad and right face plate visible")
	_check(a.visible and b.visible and x.visible and y.visible,
		"ABXY visible in world mode")
	_check(touch.get_node_or_null("TouchRun") == null, "no Run button in ABXY layout")
	_check(touch.get_node_or_null("TouchChat") == null, "no Chat button in ABXY layout")
	_check(dpad.get_global_rect().position.x < 300.0,
		"D-pad is on the left (%s)" % str(dpad.get_global_rect()))
	for button in [a, b, x, y]:
		_check(button.get_global_rect().position.x >= 740.0,
			"%s is on the right (%s)" % [button.name, str(button.get_global_rect())])

	var view := Rect2(Vector2.ZERO, Vector2(960, 540))
	for button in [dpad, a, b, x, y]:
		var rect: Rect2 = button.get_global_rect()
		_check(view.encloses(rect), "%s fits in the viewport (%s)" % [
			button.name, str(rect)
		])

	var seen: Array = []
	touch.dir_changed.connect(func(direction: String) -> void: seen.append(direction))
	var up: Button = null
	for child in dpad.get_children():
		if child is Button and str(child.get("direction")) == "up":
			up = child
			break
	_check(up != null, "up button exists")
	if up != null:
		up.emit_signal("button_down")
		_check(seen.size() == 1 and seen[0] == "up", "d-pad press emits up")
		up.emit_signal("button_up")
		_check(seen.size() == 2 and seen[1] == "", "d-pad release clears direction")

	var confirmed: Array = []
	touch.interact_pressed.connect(func() -> void: confirmed.append(true))
	a.emit_signal("pressed")
	_check(confirmed.size() == 1, "A emits interact")

	var cancelled: Array = []
	touch.cancel_pressed.connect(func() -> void: cancelled.append(true))
	b.emit_signal("pressed")
	_check(cancelled.size() == 1, "B emits cancel")

	var held: Array = []
	touch.b_held.connect(func(value: bool) -> void: held.append(value))
	b.emit_signal("button_down")
	b.emit_signal("button_up")
	_check(held == [true, false], "B reports hold for running")

	var extras: Array = []
	touch.extra_pressed.connect(func(button: String) -> void: extras.append(button))
	x.emit_signal("pressed")
	y.emit_signal("pressed")
	_check(extras == ["x", "y"], "X/Y report their reserved buttons")

	# The chat log has to leave the bottom-left corner for the D-pad.
	var chat = load("res://scripts/chat_ui.gd").new()
	add_child(chat)
	await get_tree().process_frame
	chat.set_touch_layout(true)
	await get_tree().process_frame
	var panel: Control = chat._panel
	var panel_rect := panel.get_global_rect()
	_check(panel_rect.position.x > 600.0 and panel_rect.position.y < 300.0,
		"touch chat panel moves to the top-right (%s)" % str(panel_rect))
	_check(not panel_rect.intersects(dpad.get_global_rect()),
		"touch chat panel clears the left D-pad")
	_check(not panel_rect.intersects(plate.get_global_rect()),
		"touch chat panel clears the right ABXY cluster")
	chat.set_touch_layout(false)
	await get_tree().process_frame
	_check(chat._panel.get_global_rect().position.x < 100.0,
		"desktop chat returns to the bottom-left")
	chat.queue_free()

	touch.set_mode("dialogue")
	await get_tree().process_frame
	_check(touch.mode == "dialogue", "dialogue mode")
	_check(not dpad.visible and not plate.visible, "D-pad/face plate hidden in dialogue")
	_check(not x.visible and not y.visible, "X/Y hidden in dialogue")
	_check(a.visible and b.visible, "A/B stay visible in dialogue")
	_check(a.get_global_rect().position.x >= 780.0,
		"dialogue A sits right of the text panel (%s)" % str(a.get_global_rect()))
	_check(b.get_global_rect().position.x >= 780.0,
		"dialogue B sits right of the text panel")

	touch.set_mode("hidden")
	await get_tree().process_frame
	_check(not touch.visible, "hidden mode hides the layer")

	print("[touch] %s" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
	get_tree().quit(1 if failures > 0 else 0)
