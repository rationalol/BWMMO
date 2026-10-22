extends Control

signal requested(message: Dictionary)
signal closed

const UI = preload("res://scripts/ui_theme.gd")

var _panel: PanelContainer
var _title: Label
var _money_label: Label
var _subtitle: Label
var _rows: VBoxContainer
var _buy_tab: Button
var _sell_tab: Button
var _state: Dictionary = {}
var _mode := "buy"
var _items: Array = []
var _inventory: Dictionary = {}
var _icon_cache: Dictionary = {}

func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_STOP
	visible = false
	Loc.locale_changed.connect(_on_locale_changed)

	var dim := ColorRect.new()
	dim.color = Color(0.008, 0.024, 0.043, 0.68)
	dim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	dim.mouse_filter = MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	center.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(center)

	_panel = PanelContainer.new()
	_panel.name = "ShopPanel"
	_panel.custom_minimum_size = Vector2(720, 470)
	_panel.add_theme_stylebox_override(
		"panel", UI.glass_style(UI.INK, 14, UI.BORDER_STRONG, 1, 0)
	)
	_panel.mouse_filter = MOUSE_FILTER_STOP
	center.add_child(_panel)
	UI.add_bw_frame_overlay(_panel)
	var margin := UI.add_panel_content(_panel, 12, 10)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	box.add_child(header)

	var title_col := VBoxContainer.new()
	title_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_col.add_theme_constant_override("separation", 0)
	header.add_child(title_col)
	_title = UI.make_bold_label("", 18, UI.TEXT)
	title_col.add_child(_title)
	_subtitle = UI.make_label("", 9, UI.MUTED)
	_subtitle.clip_text = true
	_subtitle.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_col.add_child(_subtitle)

	var money_col := VBoxContainer.new()
	money_col.add_theme_constant_override("separation", 0)
	header.add_child(money_col)
	var money_row := HBoxContainer.new()
	money_row.alignment = BoxContainer.ALIGNMENT_END
	money_row.add_theme_constant_override("separation", 4)
	money_col.add_child(money_row)
	var coin := TextureRect.new()
	coin.texture = _icon("coin.svg")
	coin.custom_minimum_size = Vector2(14, 14)
	coin.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	coin.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	coin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	coin.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	coin.mouse_filter = MOUSE_FILTER_IGNORE
	money_row.add_child(coin)
	_money_label = UI.make_bold_label("$0", 16, UI.GOLD)
	money_row.add_child(_money_label)

	var close_button := Button.new()
	close_button.custom_minimum_size = Vector2(24, 24)
	close_button.focus_mode = Control.FOCUS_NONE
	Loc.bind_tooltip(close_button, "Close (Esc)")
	close_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	close_button.add_theme_stylebox_override(
		"normal", UI.button_style(Color(1, 1, 1, 0.045), 7)
	)
	close_button.add_theme_stylebox_override(
		"hover", UI.button_style(Color(1, 1, 1, 0.10), 7)
	)
	close_button.add_theme_stylebox_override(
		"pressed", UI.button_style(Color(1, 1, 1, 0.16), 7)
	)
	close_button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	close_button.pressed.connect(close)
	var close_icon := TextureRect.new()
	close_icon.texture = _icon("close.svg")
	close_icon.custom_minimum_size = Vector2(12, 12)
	close_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	close_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	close_icon.mouse_filter = MOUSE_FILTER_IGNORE
	close_icon.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	close_icon.offset_left = 6
	close_icon.offset_top = 6
	close_icon.offset_right = -6
	close_icon.offset_bottom = -6
	close_button.add_child(close_icon)
	header.add_child(close_button)

	var divider := ColorRect.new()
	divider.color = Color(1, 1, 1, 0.06)
	divider.custom_minimum_size = Vector2(0, 1)
	divider.mouse_filter = MOUSE_FILTER_IGNORE
	box.add_child(divider)

	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	box.add_child(tabs)
	_buy_tab = _make_tab("BUY")
	_buy_tab.pressed.connect(_set_mode.bind("buy"))
	tabs.add_child(_buy_tab)
	_sell_tab = _make_tab("SELL")
	_sell_tab.pressed.connect(_set_mode.bind("sell"))
	tabs.add_child(_sell_tab)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(scroll)
	_rows = VBoxContainer.new()
	_rows.name = "ShopRows"
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", 4)
	scroll.add_child(_rows)

	var footer := Loc.make_label("Buy and sell items. ESC to close.", 8, UI.FAINT)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(footer)

func _make_tab(key: String) -> Button:
	var button := Button.new()
	Loc.bind(button, key)
	button.custom_minimum_size = Vector2(92, 26)
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	UI.apply_font(button, 10)
	return button

func _icon(file: String) -> Texture2D:
	var path := "res://assets/ui/icons/%s" % file
	if _icon_cache.has(path):
		return _icon_cache[path]
	var texture: Texture2D = null
	if ResourceLoader.exists(path):
		texture = load(path) as Texture2D
	_icon_cache[path] = texture
	return texture

func _item_icon(item: Dictionary) -> Texture2D:
	var icon := str(item.get("icon", "poke_ball"))
	var candidates := [
		"res://assets/bw/ui/items/%s.png" % icon,
		"res://assets/ui/icons/item_%s.svg" % icon,
		"res://assets/ui/icons/%s.svg" % icon
	]
	for path in candidates:
		if not ResourceLoader.exists(path):
			continue
		if _icon_cache.has(path):
			return _icon_cache[path]
		var texture := load(path) as Texture2D
		if texture != null:
			_icon_cache[path] = texture
			return texture
	return _icon("bag.svg")

func show_shop(state: Dictionary) -> void:
	_state = state
	_mode = "buy"
	_apply_state()
	visible = true
	_build_rows()

func update_shop(state: Dictionary) -> void:
	_state = state
	_apply_state()
	if visible:
		_build_rows()

func _on_locale_changed(_code: String) -> void:
	Loc.refresh_all(self)
	_apply_state()
	if visible:
		_build_rows()

func _apply_state() -> void:
	var shop_value: Variant = _state.get("shop", {})
	var shop: Dictionary = shop_value if shop_value is Dictionary else {}
	_items = shop.get("items", []) if shop.get("items", []) is Array else []
	_title.text = str(shop.get("name", Loc.t("Shop")))
	var inventory_value: Variant = _state.get("inventory", {})
	var inventory: Dictionary = inventory_value if inventory_value is Dictionary else {}
	var items_value: Variant = inventory.get("items", {})
	_inventory = items_value if items_value is Dictionary else {}
	_money_label.text = UI.format_money(int(_state.get("money", 0)))
	_subtitle.text = Loc.tf("%d GOODS IN STOCK", [_items.size()])
	_subtitle.add_theme_color_override("font_color", UI.MUTED)
	_refresh_tabs()

func show_error(text: String) -> void:
	_subtitle.text = text.to_upper()
	_subtitle.add_theme_color_override("font_color", UI.DANGER)

func _set_mode(mode: String) -> void:
	_mode = mode
	_refresh_tabs()
	_build_rows()

func _refresh_tabs() -> void:
	for pair in [["buy", _buy_tab], ["sell", _sell_tab]]:
		var button: Button = pair[1]
		var active: bool = str(pair[0]) == _mode
		var style := UI.button_style(
			UI.ACCENT_SOFT if active else Color(1, 1, 1, 0.035), 5
		)
		style.content_margin_left = 9
		style.content_margin_right = 9
		style.content_margin_top = 3
		style.content_margin_bottom = 3
		style.border_width_left = 1
		style.border_width_top = 1
		style.border_width_right = 1
		style.border_width_bottom = 1
		style.border_color = (
			Color(UI.ACCENT_DIM.r, UI.ACCENT_DIM.g, UI.ACCENT_DIM.b, 0.9)
			if active
			else Color(1, 1, 1, 0.06)
		)
		button.add_theme_stylebox_override("normal", style)
		button.add_theme_stylebox_override("hover", style)
		button.add_theme_stylebox_override("pressed", style)
		button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		var color := UI.ACCENT if active else UI.MUTED
		button.add_theme_color_override("font_color", color)
		button.add_theme_color_override("font_hover_color", UI.ACCENT)
		button.add_theme_color_override("font_pressed_color", color)

func _owned(item_id: String) -> int:
	return int(_inventory.get(item_id, 0))

func _build_rows() -> void:
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	if _items.is_empty():
		_rows.add_child(Loc.make_label("This shop has nothing in stock.", 12, UI.MUTED))
		return
	var shown := 0
	for value in _items:
		if not (value is Dictionary):
			continue
		var item: Dictionary = value
		if _mode == "sell" and _owned(str(item.get("id", ""))) <= 0:
			continue
		_rows.add_child(_make_row(item))
		shown += 1
	if shown == 0:
		_rows.add_child(
			Loc.make_label(
				"You have nothing to sell." if _mode == "sell" else "Nothing in stock.",
				12,
				UI.MUTED
			)
		)

func _make_row(item: Dictionary) -> PanelContainer:
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0, 54)
	var style := StyleBoxFlat.new()
	style.bg_color = UI.CARD
	style.corner_radius_top_left = 7
	style.corner_radius_top_right = 7
	style.corner_radius_bottom_left = 7
	style.corner_radius_bottom_right = 7
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = Color(1, 1, 1, 0.05)
	style.content_margin_left = 7
	style.content_margin_top = 4
	style.content_margin_right = 7
	style.content_margin_bottom = 4
	row.add_theme_stylebox_override("panel", style)

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 7)
	row.add_child(line)

	var icon := TextureRect.new()
	icon.texture = _item_icon(item)
	icon.custom_minimum_size = Vector2(32, 32)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = MOUSE_FILTER_IGNORE
	line.add_child(icon)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 0)
	line.add_child(info)
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 6)
	info.add_child(name_row)
	var name_label := UI.make_bold_label(str(item.get("name", "Item")), 12, UI.TEXT)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	name_row.add_child(name_label)
	var owned := _owned(str(item.get("id", "")))
	if owned > 0:
		name_row.add_child(
			UI.make_label(Loc.tf("x %d", [owned]), 10, UI.GOLD)
		)
	var desc := UI.make_label(str(item.get("description", "")), 9, UI.MUTED)
	desc.clip_text = true
	desc.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info.add_child(desc)

	var price_text := (
		"%d" % int(item.get("sellPrice", maxi(1, int(item.get("price", 0)) / 2)))
		if _mode == "sell"
		else "%d" % int(item.get("price", 0))
	)
	var price := UI.make_bold_label(price_text, 13, UI.GOLD)
	price.custom_minimum_size = Vector2(58, 0)
	price.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	price.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(price)

	if _mode == "buy":
		var buy_price := int(item.get("price", 0))
		var one := _make_action("BUY 1", false)
		one.disabled = buy_price > int(_state.get("money", 0)) or owned + 1 > 99
		one.pressed.connect(_on_buy.bind(item, 1))
		line.add_child(one)
		var five := _make_action("x5", true)
		five.disabled = buy_price * 5 > int(_state.get("money", 0)) or owned + 5 > 99
		five.pressed.connect(_on_buy.bind(item, 5))
		line.add_child(five)
	else:
		var one := _make_action("SELL 1", false)
		one.pressed.connect(_on_sell.bind(item, 1))
		line.add_child(one)
		var all := _make_action("ALL", true)
		all.pressed.connect(_on_sell.bind(item, _owned(str(item.get("id", "")))))
		line.add_child(all)
	return row

func _make_action(key: String, compact: bool) -> Button:
	var button := Button.new()
	Loc.bind(button, key)
	button.custom_minimum_size = Vector2(52 if compact else 68, 26)
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	UI.apply_font(button, 9)
	var normal := UI.button_style(UI.ACCENT_SOFT, 5)
	normal.content_margin_left = 4
	normal.content_margin_right = 4
	normal.content_margin_top = 1
	normal.content_margin_bottom = 1
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(UI.ACCENT.r, UI.ACCENT.g, UI.ACCENT.b, 0.24)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(UI.ACCENT.r, UI.ACCENT.g, UI.ACCENT.b, 0.30)
	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(1, 1, 1, 0.03)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("disabled", disabled)
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	button.add_theme_color_override("font_color", UI.ACCENT)
	button.add_theme_color_override("font_hover_color", UI.TEXT)
	button.add_theme_color_override("font_pressed_color", UI.TEXT)
	button.add_theme_color_override("font_disabled_color", UI.FAINT)
	return button

func _on_buy(item: Dictionary, qty: int) -> void:
	var item_id := str(item.get("id", ""))
	var cost := int(item.get("price", 0)) * qty
	if cost > int(_state.get("money", 0)):
		return
	if _owned(item_id) + qty > 99:
		return
	requested.emit({
		"type": "shop_buy",
		"shopId": str(_state.get("shop", {}).get("id", "")),
		"itemId": item_id,
		"qty": qty
	})

func _on_sell(item: Dictionary, qty: int) -> void:
	if qty <= 0:
		return
	requested.emit({
		"type": "shop_sell",
		"shopId": str(_state.get("shop", {}).get("id", "")),
		"itemId": str(item.get("id", "")),
		"qty": qty
	})

func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			close()
			get_viewport().set_input_as_handled()
