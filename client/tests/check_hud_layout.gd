extends SceneTree

const HudScript = preload("res://scripts/hud.gd")
const ChatUIScript = preload("res://scripts/chat_ui.gd")

var failures := 0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(960, 540)
	await process_frame
	var viewport_size := root.size
	print("[hud] viewport %s" % str(viewport_size))

	var chat = ChatUIScript.new()
	chat.visible = true
	root.add_child(chat)
	var speaker_color := Color(0.961, 0.769, 0.318)
	chat.add_message("Hilbert", "Anyone found a wild Roggenrola here?", speaker_color)
	chat.add_message("Bianca", "I just caught a Lillipup! So cute!", speaker_color)
	chat.add_message("Cheren", "Route 1 has great encounters today.", speaker_color)
	chat.add_message("Hilbert", "The autumn colors look amazing.", speaker_color)
	chat.add_message("Bianca", "Let's go to the next town soon!", speaker_color)

	var hud = HudScript.new()
	root.add_child(hud)
	hud.set_items([
		{"id": "poke_ball", "name": "Poké Ball", "category": "ball", "price": 200,
			"description": "A device for catching wild Pokémon.", "icon": "poke_ball", "ballBonus": 1.0},
		{"id": "great_ball", "name": "Great Ball", "category": "ball", "price": 600,
			"description": "A good, high-performance Ball.", "icon": "great_ball", "ballBonus": 1.5},
		{"id": "potion", "name": "Potion", "category": "medicine", "price": 300,
			"description": "Restores 20 HP to one Pokémon.", "icon": "potion", "heal": 20},
		{"id": "revive", "name": "Revive", "category": "medicine", "price": 1500,
			"description": "Revives a fainted Pokémon.", "icon": "revive", "revive": true}
	])

	var self_info := {
		"id": "layout-test",
		"name": "Hilbert",
		"color": "#e76f51",
		"sprite": 0,
		"mapId": "unova_full",
		"x": 782,
		"y": 753,
		"dir": "down",
		"money": 1240,
		"wins": 3,
		"party": [],
		"inventory": {"items": {"poke_ball": 10, "great_ball": 2, "potion": 2, "revive": 1}}
	}
	var party := [
		_make_creature("snivy", "Snivy", 14, ["Grass"], 42, 42, "male"),
		_make_creature("pikachu", "Pikachu", 13, ["Electric"], 36, 36, "female"),
		_make_creature("starly", "Starly", 12, ["Normal", "Flying"], 34, 34, "male"),
		_make_creature("petilil", "Petilil", 11, ["Grass"], 28, 28, "female"),
		_make_creature("zorua", "Zorua", 12, ["Dark"], 6, 36, "male")
	]
	var map_info := _make_map()

	hud.set_self("Hilbert", 1240, 3, self_info)
	hud.set_map("Route 1", 2)
	hud.set_party(party, 6)
	hud.set_inventory({"items": {"poke_ball": 10, "great_ball": 2, "potion": 2, "revive": 1}})
	hud.set_pokedex(
		[495, 504, 506],
		[495, 506],
		[
			{"dex": 495, "id": "snivy", "name": "Snivy", "types": ["Grass"],
			 "evolutions": [{"to": "servine", "name": "Servine", "method": "level", "level": 17}]},
			{"dex": 504, "id": "patrat", "name": "Patrat", "types": ["Normal"],
			 "evolutions": [{"to": "watchog", "name": "Watchog", "method": "level", "level": 20}]},
			{"dex": 506, "id": "lillipup", "name": "Lillipup", "types": ["Normal"],
			 "evolutions": [{"to": "herdier", "name": "Herdier", "method": "level", "level": 16}]}
		],
		649
	)
	hud.set_map_data(map_info, self_info)
	hud.set_season("autumn")
	hud.set_world_time(18.5)
	if hud._clock_label == null or hud._clock_label.text != "Dusk 18:30":
		push_error("HUD world clock is %s" % (hud._clock_label.text if hud._clock_label != null else "missing"))
		failures += 1
	hud.set_connection("ONLINE", true)
	hud.set_ping(12)
	hud.set_hint("WASD move  ·  Shift run  ·  E talk  ·  T chat")
	hud.set_nearby_npc(_nearby_bianca())

	await process_frame
	await process_frame

	var card: Control = _find(hud, "TrainerCard")
	var party_panel: Control = _find(hud, "PartyPanel")
	var chat_panel: Control = _find(chat, "ChatPanel")
	var minimap_panel: Control = _find(hud, "MinimapPanel")
	var prompt: Control = _find(hud, "InteractPrompt")
	var nav: Control = _find(hud, "NavButtons")

	_expect(card != null, "trainer card missing")
	_expect(party_panel != null, "party panel missing")
	_expect(chat_panel != null, "chat panel missing")
	_expect(minimap_panel != null, "minimap panel missing")
	_expect(prompt != null, "interact prompt missing")
	_expect(nav != null and nav.get_child_count() == 5, "five navigation buttons expected")
	_expect(_find(hud, "NavDex") != null, "Dex navigation button missing")

	if party_panel != null:
		var stack: Control = _find(party_panel, "PartySlots")
		_expect(stack != null, "party slot stack missing")
		_expect(stack != null and stack.get_child_count() == 6, "six party slots expected")
		if stack != null and stack.get_child_count() == 6:
			var last: Control = stack.get_child(5)
			print("[hud] last party slot bottom %.1f panel bottom %.1f" % [
				last.get_global_rect().end.y, party_panel.get_global_rect().end.y
			])
			_expect(
				last.get_global_rect().end.y <= party_panel.get_global_rect().end.y + 0.5,
				"party rows overflow the party panel"
			)
			var empty_script: Script = last.get_script()
			_expect(
				empty_script != null
				and str(empty_script.resource_path).ends_with("ui_dashed_slot.gd"),
				"sixth party slot should be the dashed empty slot"
			)

	if party_panel != null and chat_panel != null:
		print("[hud] party bottom %.1f chat top %.1f" % [
			party_panel.get_global_rect().end.y, chat_panel.get_global_rect().position.y
		])
		_expect(
			party_panel.get_global_rect().end.y < chat_panel.get_global_rect().position.y,
			"party panel overlaps chat"
		)

	var party_slots: Control = _find(hud, "PartySlots")
	if party_slots != null and party_panel != null:
		var party_rail: Control = _find(hud, "PartyRail")
		hud._toggle_party_collapsed()
		await process_frame
		_expect(not party_slots.visible, "party list should hide when collapsed")
		_expect(party_rail != null and party_rail.visible, "avatar rail should show when collapsed")
		_expect(
			party_panel.get_global_rect().size.x <= 70.0,
			"collapsed party panel should shrink to an avatar rail"
		)
		_expect(party_rail != null and party_rail.get_child_count() == party.size(), "one avatar per party member")
		hud._toggle_party_collapsed()
		await process_frame
		_expect(party_slots.visible, "party list should return when expanded")
		_expect(party_rail != null and not party_rail.visible, "avatar rail should hide when expanded")
		_expect(
			party_panel.get_global_rect().size.x > 200.0,
			"expanded party panel should show the full list"
		)

	for raw_control in [card, party_panel, chat_panel, minimap_panel, nav]:
		if raw_control == null:
			continue
		var control: Control = raw_control
		var rect := control.get_global_rect()
		_expect(
			rect.position.x >= -0.5 and rect.position.y >= -0.5
			and rect.end.x <= viewport_size.x + 0.5 and rect.end.y <= viewport_size.y + 0.5,
			"%s outside viewport: %s" % [control.name, str(rect)]
		)

	if prompt != null:
		print("[hud] prompt rect %s" % str(prompt.get_global_rect()))
		_expect(prompt.is_visible_in_tree(), "interact prompt should be visible near an NPC")
		var prompt_label: Label = _find_label(prompt, "Talk to Bianca")
		_expect(prompt_label != null, "prompt should name Bianca")

	_dump_tree(hud, "res://.tmp_hud_layout.json")
	_dump_tree(chat, "res://.tmp_chat_layout.json")
	var map_file := FileAccess.open("res://.tmp_hud_map.json", FileAccess.WRITE)
	if map_file != null:
		map_file.store_string(JSON.stringify({"map": map_info, "self": self_info}, "  "))
		map_file.close()

	hud._toggle_menu("party")
	await process_frame
	var menu_panel: Control = _find(hud, "MenuPanel")
	_expect(hud.menu_open, "party menu should open")
	_expect(menu_panel != null and menu_panel.is_visible_in_tree(), "party menu panel hidden")
	if menu_panel != null:
		var menu_rect := menu_panel.get_global_rect()
		print("[hud] party menu rect %s" % str(menu_rect))
		_expect(
			menu_rect.size.x <= viewport_size.x and menu_rect.size.y <= viewport_size.y,
			"party menu larger than viewport"
		)
	_dump_tree(hud, "res://.tmp_hud_menu_party.json")
	var menu_body: Control = _find(hud, "MenuBody")
	if menu_body != null and menu_panel != null:
		print("[hud] party menu body %s panel bottom %.1f" % [
			str(menu_body.get_global_rect()), menu_panel.get_global_rect().end.y
		])
		_expect(
			menu_body.get_global_rect().end.y <= menu_panel.get_global_rect().end.y + 0.5,
			"party menu body overflows the menu panel"
		)
	hud.close_menu()
	_expect(not hud.menu_open, "party menu should close")

	hud._open_menu("bag")
	await process_frame
	var ball_items: Array = hud._bag_items()
	_expect(ball_items.size() == 2, "ball pocket should list Poké and Great Balls")
	hud._select_bag_pocket("medicine")
	await process_frame
	var medicine_items: Array = hud._bag_items()
	_expect(medicine_items.size() == 2, "medicine pocket should list Potion and Revive")
	var use_label: Label = _find_label(hud, "USE ON")
	_expect(use_label != null, "medicine detail should offer party targets")
	var use_buttons := 0
	var buttons: Array = []
	_find_buttons(hud, buttons)
	for node in buttons:
		var button := node as Button
		if button.text == "USE":
			use_buttons += 1
	_expect(use_buttons >= 1, "medicine detail should have USE buttons")
	var menu_panel_rect: Control = _find(hud, "MenuPanel")
	if menu_panel_rect != null:
		_expect(
			menu_panel_rect.get_global_rect().size.x <= viewport_size.x
			and menu_panel_rect.get_global_rect().size.y <= viewport_size.y,
			"bag menu with use panel larger than viewport"
		)
	hud.close_menu()

	for kind in ["bag", "dex", "map", "settings"]:
		hud._open_menu(kind)
		await process_frame
		var panel: Control = _find(hud, "MenuPanel")
		if panel != null:
			var rect := panel.get_global_rect()
			print("[hud] %s menu rect %s" % [kind, str(rect)])
			_expect(
				rect.size.x <= viewport_size.x and rect.size.y <= viewport_size.y,
				"%s menu larger than viewport" % kind
			)
		_expect(hud.menu_open, "%s menu should open" % kind)
		if kind == "dex":
			_expect(_find(hud, "DexEntry495") != null, "dex entry 495 should be on the first page")
			_expect(_find_label(hud, "Snivy") != null, "dex detail should name the selected species")
			var dex_body: Control = _find(hud, "MenuBody")
			if dex_body != null and panel != null:
				_expect(
					dex_body.get_global_rect().end.y <= panel.get_global_rect().end.y + 0.5,
					"dex menu body overflows the menu panel"
				)
		_dump_tree(hud, "res://.tmp_hud_menu_%s.json" % kind)
		hud.close_menu()
		await process_frame

	hud.show_move_learn({
		"source": "party",
		"index": 0,
		"moveId": "growth",
		"move": {"name": "Growth", "type": "Normal", "power": 0, "pp": 20, "category": "status"},
		"moves": party[0]["moves"],
		"creatureName": "Snivy",
		"creatureLevel": 13
	})
	await process_frame
	_expect(hud.menu_open and hud._menu_kind == "learn_move", "move learn menu should open")
	_expect(not hud.close_menu(), "move learn menu should require a decision")
	var learn_buttons: Array = []
	_find_buttons(hud, learn_buttons)
	var has_replace := false
	for button_value in learn_buttons:
		if button_value is Button and (button_value as Button).text == "REPLACE":
			has_replace = true
			break
	_expect(has_replace, "move learn menu should offer a replacement slot")
	var learn_panel: Control = _find(hud, "MenuPanel")
	var learn_body: Control = _find(hud, "MenuBody")
	if learn_panel != null and learn_body != null:
		_expect(
			learn_body.get_global_rect().end.y <= learn_panel.get_global_rect().end.y + 0.5,
			"move learn body overflows the menu panel"
		)
	hud._choose_move_learn(-1)
	await process_frame
	_expect(not hud.menu_open, "move learn menu should close after a decision")

	print("[hud] %s" % ("FAILED" if failures > 0 else "PASSED"))
	quit(1 if failures > 0 else 0)

func _make_creature(
	species: String,
	display_name: String,
	level: int,
	types: Array,
	hp: int,
	max_hp: int,
	gender: String = "male"
) -> Dictionary:
	return {
		"species": species,
		"name": display_name,
		"gender": gender,
		"level": level,
		"types": types,
		"xp": 0,
		"maxHp": max_hp,
		"hp": hp,
		"atk": 20,
		"def": 20,
		"spAtk": 22,
		"spDef": 21,
		"speed": 20,
		"xpToNext": 20 + level * 12,
		"ivs": {"hp": 31, "atk": 24, "def": 18, "spAtk": 29, "spDef": 20, "speed": 27},
		"evs": {"hp": 0, "atk": 4, "def": 0, "spAtk": 12, "spDef": 0, "speed": 8},
		"nature": "Timid",
		"heldItem": null,
		"moves": [
			{"name": "Tackle", "type": "Normal", "power": 40, "pp": 35},
			{"name": "Growl", "type": "Normal", "power": 0, "pp": 40},
			{"name": "Vine Whip", "type": "Grass", "power": 35, "pp": 15},
			{"name": "Quick Attack", "type": "Normal", "power": 40, "pp": 30}
		],
		"status": "PSN" if species == "zorua" else ""
	}

func _nearby_bianca() -> Dictionary:
	for entry in _make_map().get("npcs", []):
		if entry is Dictionary and str(entry.get("id", "")) == "bianca":
			return entry
	return {"id": "bianca", "name": "Bianca", "x": 786, "y": 753}

func _make_map() -> Dictionary:
	var project_dir := ProjectSettings.globalize_path("res://").get_base_dir()
	var root_dir := project_dir.get_base_dir()
	var real_path := root_dir.path_join("server/content/maps/unova_full.json")
	if FileAccess.file_exists(real_path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(real_path))
		if parsed is Dictionary and parsed.has("tiles"):
			var map: Dictionary = parsed
			var spawn: Dictionary = map.get("spawn", {"x": 784, "y": 753})
			var spawn_x := int(spawn.get("x", 784))
			var spawn_y := int(spawn.get("y", 753))
			var radius := 32
			var window_rows: Array = []
			for row_index in range(spawn_y - radius, spawn_y + radius + 1):
				var row := str(map["tiles"][row_index])
				window_rows.append(row.substr(spawn_x - radius, radius * 2 + 1))
			var nearby: Array = []
			for entry in map.get("npcs", []):
				if not (entry is Dictionary):
					continue
				var npc: Dictionary = entry
				if (
					absi(int(npc.get("x", 0)) - spawn_x) <= radius
					and absi(int(npc.get("y", 0)) - spawn_y) <= radius
				):
					nearby.append(npc)
			return {
				"id": "unova_full",
				"name": "Route 1",
				"width": int(map.get("width", 928)),
				"height": int(map.get("height", 864)),
				"tiles": window_rows,
				"tileX": spawn_x - radius,
				"tileY": spawn_y - radius,
				"tileWidth": radius * 2 + 1,
				"tileHeight": radius * 2 + 1,
				"windowed": true,
				"npcs": nearby,
				"visual": {}
			}
	var rows: Array = []
	for y in range(65):
		var row := ""
		for x in range(65):
			var glyph := "#"
			if x >= 24 and x <= 42 and y >= 20 and y <= 44:
				glyph = "."
			elif x >= 10 and x <= 53 and y >= 30 and y <= 36:
				glyph = "."
			elif x >= 34 and x <= 44 and y >= 8 and y <= 20:
				glyph = "g"
			elif x >= 40 and x <= 50 and y >= 4 and y <= 14:
				glyph = "~"
			row += glyph
		rows.append(row)
	return {
		"id": "unova_full",
		"name": "Route 1",
		"width": 928,
		"height": 864,
		"tiles": rows,
		"tileX": 752,
		"tileY": 721,
		"tileWidth": 65,
		"tileHeight": 65,
		"windowed": true,
		"npcs": [
			{"id": "bianca", "name": "Bianca", "x": 786, "y": 753, "sprite": 1},
			{"id": "cheren", "name": "Cheren", "x": 790, "y": 748, "sprite": 0}
		],
		"visual": {}
	}

func _find(node: Node, target: String) -> Control:
	if node is Control and node.name == target:
		return node
	for child in node.get_children():
		var found := _find(child, target)
		if found != null:
			return found
	return null

func _find_label(node: Node, text: String) -> Label:
	if node is Label and node.text == text:
		return node
	for child in node.get_children():
		var found := _find_label(child, text)
		if found != null:
			return found
	return null

func _find_buttons(node: Node, out: Array) -> void:
	if node is Button:
		out.append(node)
	for child in node.get_children():
		_find_buttons(child, out)

func _dump_tree(node: Node, path: String) -> void:
	var entries: Array = []
	_collect(node, entries)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("could not write %s" % path)
		return
	file.store_string(JSON.stringify({"viewport": [root.size.x, root.size.y], "nodes": entries}, "  "))
	file.close()
	print("[hud] dumped %s (%d nodes)" % [path, entries.size()])

func _collect(node: Node, entries: Array) -> void:
	if node is Control:
		var control: Control = node
		if control.is_visible_in_tree():
			var rect := control.get_global_rect()
			var entry := {
				"name": String(control.name),
				"type": control.get_class(),
				"rect": [rect.position.x, rect.position.y, rect.size.x, rect.size.y]
			}
			if control is Label:
				var label := control as Label
				entry["text"] = label.text
				entry["font_size"] = label.get_theme_font_size("font_size")
				entry["color"] = _color_array(label.get_theme_color("font_color"))
				entry["halign"] = label.horizontal_alignment
				entry["valign"] = label.vertical_alignment
				var label_font := label.get_theme_font("font")
				entry["bold"] = label_font is FontVariation
				entry["font"] = _font_path(label_font)
				entry["clip"] = label.clip_text
			elif control is Button:
				var button := control as Button
				entry["text"] = button.text
				entry["font_size"] = button.get_theme_font_size("font_size")
				entry["color"] = _color_array(button.get_theme_color("font_color"))
				entry["font"] = _font_path(button.get_theme_font("font"))
				if button.icon != null:
					entry["icon"] = button.icon.resource_path
				var normal_style := button.get_theme_stylebox("normal")
				if normal_style is StyleBoxFlat:
					entry["bg"] = _color_array((normal_style as StyleBoxFlat).bg_color)
					entry["border"] = _color_array((normal_style as StyleBoxFlat).border_color)
					entry["radius"] = (normal_style as StyleBoxFlat).corner_radius_top_left
					entry["border_width"] = (normal_style as StyleBoxFlat).border_width_left
			elif control is RichTextLabel:
				entry["text"] = (control as RichTextLabel).get_parsed_text()
				entry["font_size"] = (control as RichTextLabel).get_theme_font_size("normal_font_size")
				entry["color"] = _color_array(
					(control as RichTextLabel).get_theme_color("default_color")
				)
			elif control is LineEdit:
				entry["placeholder"] = (control as LineEdit).placeholder_text
				entry["font_size"] = (control as LineEdit).get_theme_font_size("font_size")
				entry["font"] = _font_path((control as LineEdit).get_theme_font("font"))
				var line_style := (control as LineEdit).get_theme_stylebox("normal")
				if line_style is StyleBoxFlat:
					entry["bg"] = _color_array((line_style as StyleBoxFlat).bg_color)
					entry["radius"] = (line_style as StyleBoxFlat).corner_radius_top_left
			elif control is ColorRect:
				entry["color"] = _color_array((control as ColorRect).color)
			elif control is TextureRect:
				var texture_rect := control as TextureRect
				if texture_rect.texture != null:
					entry["texture"] = texture_rect.texture.resource_path
				entry["modulate"] = _color_array(texture_rect.modulate)
				entry["stretch"] = texture_rect.stretch_mode
			elif control is ProgressBar:
				entry["value"] = (control as ProgressBar).value
				entry["max"] = (control as ProgressBar).max_value
				var fill := (control as ProgressBar).get_theme_stylebox("fill")
				if fill is StyleBoxFlat:
					entry["fill"] = _color_array((fill as StyleBoxFlat).bg_color)
			var script: Script = control.get_script()
			if script != null:
				entry["script"] = script.resource_path
			if control.has_meta("types"):
				entry["types"] = control.get_meta("types")
			if control.has_meta("label"):
				entry["label"] = control.get_meta("label")
			if not entry.has("bg"):
				var style := control.get_theme_stylebox("panel")
				if style is StyleBoxFlat:
					entry["bg"] = _color_array((style as StyleBoxFlat).bg_color)
					entry["border"] = _color_array((style as StyleBoxFlat).border_color)
					entry["radius"] = (style as StyleBoxFlat).corner_radius_top_left
					entry["border_width"] = (style as StyleBoxFlat).border_width_left
				elif style is StyleBoxTexture:
					var texture_style := style as StyleBoxTexture
					entry["style"] = "texture"
					entry["texture"] = texture_style.texture.resource_path
					entry["tex_margin"] = [
						texture_style.texture_margin_left,
						texture_style.texture_margin_top,
						texture_style.texture_margin_right,
						texture_style.texture_margin_bottom
					]
					entry["content_margin"] = [
						texture_style.content_margin_left,
						texture_style.content_margin_top,
						texture_style.content_margin_right,
						texture_style.content_margin_bottom
					]
					entry["stretch"] = [
						texture_style.axis_stretch_horizontal,
						texture_style.axis_stretch_vertical
					]
			entries.append(entry)
	for child in node.get_children():
		_collect(child, entries)

func _font_path(font: Font) -> String:
	if font == null:
		return ""
	if font is FontVariation:
		var variation := font as FontVariation
		if variation.base_font != null and variation.base_font.resource_path != "":
			return variation.base_font.resource_path
		return ""
	return font.resource_path

func _color_array(color: Color) -> Array:
	return [color.r, color.g, color.b, color.a]

func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("[hud] " + message)
