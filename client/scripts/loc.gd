extends Node

# Runtime locale state for the client. Translation lookups use Godot's
# TranslationServer; this node adds persistence, locale normalisation and a
# small binding API so procedurally built UI can refresh after a language change.

signal locale_changed(locale: String)

const UI = preload("res://scripts/ui_theme.gd")
const SETTINGS_PATH := "user://settings.cfg"
const DEFAULT_LOCALE := "en"
const SUPPORTED := ["en", "zh_CN"]
const LOCALE_LABELS := {
	"en": "English",
	"zh_CN": "简体中文",
	"zh_TW": "繁體中文",
	"ja": "日本語",
	"ko": "한국어"
}

var locale := DEFAULT_LOCALE

func _ready() -> void:
	var config := ConfigFile.new()
	var saved := ""
	if config.load(SETTINGS_PATH) == OK:
		saved = str(config.get_value("display", "locale", ""))
	var target := normalize_locale(saved) if saved != "" else normalize_locale(OS.get_locale())
	_apply_locale(target, false)

func set_locale(code: String) -> void:
	var target := normalize_locale(code)
	if target == locale and TranslationServer.get_locale() == target:
		return
	_apply_locale(target, true)

func normalize_locale(code: String) -> String:
	var value := code.strip_edges().replace("-", "_")
	if value.begins_with("zh"):
		if value.contains("TW") or value.contains("HK") or value.contains("Hant"):
			return "zh_TW"
		return "zh_CN"
	if value.begins_with("ja"):
		return "ja"
	if value.begins_with("ko"):
		return "ko"
	return DEFAULT_LOCALE

func locale_label(code: String) -> String:
	return str(LOCALE_LABELS.get(code, code))

func is_cjk() -> bool:
	return locale.begins_with("zh") or locale == "ja" or locale == "ko"

func t(key: String) -> String:
	return TranslationServer.translate(key)

func tf(key: String, args: Array = []) -> String:
	var template := t(key)
	if args.is_empty():
		return template
	return template % args

func make_label(key: String, size: int = 15, color: Color = UI.TEXT, args: Array = []) -> Label:
	var label := UI.make_label("", size, color)
	bind(label, key, args)
	return label

func make_bold_label(key: String, size: int = 15, color: Color = UI.TEXT, args: Array = []) -> Label:
	var label := UI.make_bold_label("", size, color)
	bind(label, key, args)
	return label

# Binds a node to a translation key and keeps the key/arguments for later
# refreshes. Labels, buttons and line-edit placeholders are handled directly;
# tooltips are bound separately through bind_tooltip().
func bind(node: Object, key: String, args: Array = []) -> void:
	if node == null:
		return
	node.set_meta("loc_key", key)
	node.set_meta("loc_args", args)
	apply(node)

func bind_tooltip(node: Object, key: String) -> void:
	if node == null:
		return
	node.set_meta("loc_tooltip_key", key)
	apply(node)

func apply(node: Object) -> void:
	if node == null:
		return
	if node.has_meta("loc_key"):
		var key := str(node.get_meta("loc_key"))
		var args: Array = node.get_meta("loc_args", [])
		var text := tf(key, args)
		if node is Label or node is Button or node is RichTextLabel:
			node.text = text
		elif node is LineEdit:
			node.placeholder_text = text
		elif node is Window:
			node.title = text
	if node.has_meta("loc_tooltip_key") and node is Control:
		node.tooltip_text = t(str(node.get_meta("loc_tooltip_key")))

func refresh_tree(root: Node) -> void:
	if root == null:
		return
	apply(root)
	for child in root.get_children():
		refresh_tree(child)

func refresh_all(root: Node) -> void:
	refresh_tree(root)
	UI.refresh_fonts(root)

func _apply_locale(code: String, save: bool) -> void:
	locale = code
	TranslationServer.set_locale(code)
	if save:
		var config := ConfigFile.new()
		config.load(SETTINGS_PATH)
		config.set_value("display", "locale", code)
		config.save(SETTINGS_PATH)
	locale_changed.emit(code)
