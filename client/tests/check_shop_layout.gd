extends SceneTree

const ShopUIScript = preload("res://scripts/shop_ui.gd")

var failures := 0

func _fail(message: String) -> void:
	push_error(message)
	failures += 1

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(960, 540)
	var shop = ShopUIScript.new()
	root.add_child(shop)
	var state := {
		"shop": {
			"id": "nuvema_mart",
			"name": "Nuvema Mart",
			"items": [
				{"id": "poke_ball", "name": "Poké Ball", "category": "ball", "price": 200,
					"sellPrice": 100, "description": "A device for catching wild Pokémon.",
					"icon": "poke_ball"},
				{"id": "great_ball", "name": "Great Ball", "category": "ball", "price": 600,
					"sellPrice": 300, "description": "A good, high-performance Ball.",
					"icon": "great_ball"},
				{"id": "potion", "name": "Potion", "category": "medicine", "price": 300,
					"sellPrice": 150, "description": "Restores 20 HP.", "icon": "potion"},
				{"id": "super_potion", "name": "Super Potion", "category": "medicine", "price": 700,
					"sellPrice": 350, "description": "Restores 60 HP.", "icon": "super_potion"},
				{"id": "full_heal", "name": "Full Heal", "category": "medicine", "price": 600,
					"sellPrice": 300, "description": "Cures status.", "icon": "full_heal"},
				{"id": "revive", "name": "Revive", "category": "medicine", "price": 1500,
					"sellPrice": 750, "description": "Revives a fainted Pokémon.", "icon": "revive"}
			]
		},
		"money": 500,
		"inventory": {"items": {"poke_ball": 3, "potion": 1}}
	}
	shop.show_shop(state)
	await process_frame
	await process_frame

	_expect(shop.visible, "shop should be visible")
	var panel: Control = shop._panel
	_expect(panel != null, "shop panel missing")
	if panel != null:
		var rect := panel.get_global_rect()
		print("[shop-layout] panel %s" % str(rect))
		_expect(rect.position.x >= -0.5 and rect.position.y >= -0.5, "shop panel starts off-screen")
		_expect(rect.end.x <= 960.5 and rect.end.y <= 540.5, "shop panel is larger than the viewport")
	_expect(shop._rows.get_child_count() == 6, "buy tab should list six goods")
	_expect(shop._money_label.text == "$500", "money label is %s" % shop._money_label.text)
	_expect(shop._title.text == "Nuvema Mart", "shop title is %s" % shop._title.text)

	var captured: Array = []
	shop.requested.connect(func(message: Dictionary) -> void: captured.append(message))
	shop._on_buy({"id": "potion", "price": 300}, 1)
	_expect(captured.size() == 1, "buy should emit one request")
	if captured.size() == 1:
		_expect(captured[0].get("type", "") == "shop_buy", "buy request type is wrong")
		_expect(captured[0].get("itemId", "") == "potion", "buy request item is wrong")
		_expect(captured[0].get("qty", 0) == 1, "buy request quantity is wrong")

	shop._set_mode("sell")
	await process_frame
	_expect(shop._rows.get_child_count() == 2, "sell tab should list two owned goods")

	state["money"] = 0
	shop._set_mode("buy")
	shop.update_shop(state)
	await process_frame
	var enabled := 0
	for child in shop._rows.get_children():
		for node in child.get_children():
			if node is HBoxContainer:
				for entry in node.get_children():
					if entry is Button and not (entry as Button).disabled:
						enabled += 1
	_expect(enabled == 0, "BUY buttons should be disabled without money")

	shop.close()
	_expect(not shop.visible, "shop should close")
	print("[shop-layout] %s" % ("FAILED" if failures > 0 else "PASSED"))
	quit(1 if failures > 0 else 0)
