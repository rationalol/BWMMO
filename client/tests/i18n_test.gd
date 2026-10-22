extends Node

# Headless localization smoke test. Run with:
#   godot --headless --path client res://tests/I18nTest.tscn

const UI = preload("res://scripts/ui_theme.gd")

var failures: Array[String] = []
var _original_locale := "en"

func _ready() -> void:
	_original_locale = Loc.locale
	Loc.set_locale("zh_CN")
	_check(TranslationServer.translate("Log in") == "登录", "PO lookup for Log in")
	_check(TranslationServer.translate("Victory!") == "胜利！", "PO lookup for Victory!")
	_check(UI.type_label("Fire") == "火", "type label")
	_check(UI.status_label("PAR") == "麻痹", "status label")
	_check(UI.nature_label("Adamant") == "固执", "nature label")
	_check(UI.season_label("autumn") == "秋", "season label")
	_check(UI.font_size(12) == 12, "CJK font size keeps requested size")
	var font := UI.bw_font()
	_check(font != null and font.has_char("藤".unicode_at(0)), "CJK font covers Chinese")

	var login = load("res://scripts/login_ui.gd").new()
	add_child(login)
	await get_tree().process_frame
	_check(login.login_button.text == "登录", "login button translated")
	_check(login.register_button.text == "创建账号", "register button translated")
	_check(login.user_input.placeholder_text == "3-20 个字母、数字或下划线", "username placeholder translated")
	_check(login.locale_picker != null, "login language picker exists")
	login.queue_free()

	var create = load("res://scripts/create_character_ui.gd").new()
	add_child(create)
	await get_tree().process_frame
	_check(create.create_button.text == "进入合众", "create button translated")
	_check(create._starter_hint.text.contains("撞击"), "starter hint uses translated moves")
	create.queue_free()

	var hud = load("res://scripts/hud.gd").new()
	add_child(hud)
	await get_tree().process_frame
	_check(hud._party_title_label.text == "队伍", "HUD party title translated")
	hud.set_map("合众", 1, "诺文镇")
	await get_tree().process_frame
	_check(hud._location_label.text.contains("诺文镇"), "HUD shows town name")
	_check(hud._minimap_title.text == "诺文镇", "minimap shows town name")
	hud.set_location("1号道路")
	_check(hud._minimap_title.text == "1号道路", "minimap updates route name")
	hud._open_menu("settings")
	await get_tree().process_frame
	_check(hud._menu_title.text == "设置", "HUD settings title translated")
	_check(hud._locale_picker != null, "HUD language picker exists")
	var en_index := -1
	var zh_index := -1
	for index in range(hud._locale_picker.item_count):
		var code := str(hud._locale_picker.get_item_metadata(index))
		if code == "en":
			en_index = index
		elif code == "zh_CN":
			zh_index = index
	_check(en_index >= 0 and zh_index >= 0, "language picker offers English and Chinese")
	hud._on_locale_picker_selected(en_index)
	await get_tree().process_frame
	_check(Loc.locale == "en", "language picker switches to English")
	_check(hud._menu_title.text == "Settings", "HUD refreshes to English")
	hud._on_locale_picker_selected(zh_index)
	await get_tree().process_frame
	_check(Loc.locale == "zh_CN", "language picker switches to Chinese")
	_check(hud._party_title_label.text == "队伍", "HUD refreshes back to Chinese")
	hud.show_capture_card({
		"species": "snivy", "name": "藤藤蛇", "level": 5,
		"types": ["Grass"], "hp": 19, "maxHp": 19,
		"atk": 9, "def": 9, "spAtk": 9, "spDef": 9, "speed": 11,
		"xp": 0, "xpToNext": 80, "nature": "Serious", "heldItem": "",
		"moves": [{
			"id": "tackle", "name": "撞击", "type": "Normal",
			"power": 50, "pp": 35, "currentPp": 35, "maxPp": 35
		}]
	})
	await get_tree().process_frame
	_check(hud._capture_overlay != null, "capture card is shown")
	hud._close_capture_card(false)
	hud.queue_free()

	var shop = load("res://scripts/shop_ui.gd").new()
	add_child(shop)
	await get_tree().process_frame
	shop.show_shop({
		"shop": {"id": "test", "name": "商店", "items": []},
		"inventory": {"items": {}},
		"money": 0
	})
	await get_tree().process_frame
	_check(shop._buy_tab.text == "购买", "shop buy tab translated")
	_check(shop._sell_tab.text == "出售", "shop sell tab translated")
	shop.queue_free()

	var pc = load("res://scripts/pc_ui.gd").new()
	add_child(pc)
	await get_tree().process_frame
	pc.show_pc({"party": [], "box": [], "maxParty": 6, "maxBox": 30})
	await get_tree().process_frame
	_check(pc._subtitle.text == "队伍 0/6   -   盒子 0/30", "PC subtitle translated")
	pc.queue_free()

	var chat = load("res://scripts/chat_ui.gd").new()
	add_child(chat)
	await get_tree().process_frame
	_check(chat._world_tab.text == "世界", "chat world tab translated")
	_check(chat._system_tab.text == "系统", "chat system tab translated")
	chat.queue_free()

	var dialogue = load("res://scripts/dialogue_ui.gd").new()
	add_child(dialogue)
	await get_tree().process_frame
	dialogue.show_dialogue("Bianca", ["Line one", "Line two"])
	_check(dialogue._hint_label.text == "E / 空格 / 点击继续", "dialogue hint translated")
	dialogue.queue_free()

	var battle = load("res://scripts/battle_ui.gd")
	_check(battle != null, "battle UI script compiles")
	_check(UI.cjk_locale() and UI.font_size(15) == 15, "battle CJK font size path")

	var plate = load("res://scripts/battle_plate.gd").new()
	add_child(plate)
	await get_tree().process_frame
	_check(plate._font_name == UI.cjk_font(), "battle plate uses CJK name font")
	_check(plate._name_size == 30, "battle plate CJK name size")
	plate.queue_free()

	Loc.set_locale("en")
	_check(TranslationServer.translate("Log in") == "Log in", "English falls back to msgid")
	Loc.set_locale(_original_locale)
	if failures.is_empty():
		print("i18n checks passed")
		get_tree().quit(0)
	else:
		print("i18n checks failed: ", failures.size())
		get_tree().quit(1)

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		print("FAIL: ", message)
