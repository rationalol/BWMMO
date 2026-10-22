extends RefCounted

# Shared palette for the in-game HUD. The world is colorful pixel art, so the
# chrome stays a deep navy glass with a single mint accent.
const BG := Color(0.027, 0.059, 0.098, 1.0)
const PANEL := Color(0.047, 0.094, 0.153, 1.0)
const PANEL_LIGHT := Color(0.075, 0.137, 0.216, 1.0)
const INK := Color(0.031, 0.067, 0.110, 0.94)
const INK_SOFT := Color(0.035, 0.075, 0.122, 0.88)
const CARD := Color(0.047, 0.090, 0.145, 0.96)
const CARD_ALT := Color(0.063, 0.118, 0.184, 0.96)
const ACCENT := Color(0.388, 0.902, 0.643, 1.0)
const ACCENT_DIM := Color(0.184, 0.560, 0.400, 1.0)
const ACCENT_DARK := Color(0.109, 0.286, 0.208, 1.0)
const ACCENT_SOFT := Color(0.388, 0.902, 0.643, 0.14)
const TEXT := Color(0.914, 0.945, 0.980, 1.0)
const MUTED := Color(0.557, 0.643, 0.749, 1.0)
const FAINT := Color(0.557, 0.643, 0.749, 0.56)
const DANGER := Color(1.0, 0.420, 0.478, 1.0)
const GOLD := Color(0.961, 0.769, 0.318, 1.0)
const MALE := Color(0.388, 0.702, 1.0, 1.0)
const FEMALE := Color(1.0, 0.561, 0.745, 1.0)
const BORDER := Color(1.0, 1.0, 1.0, 0.08)
const BORDER_STRONG := Color(1.0, 1.0, 1.0, 0.14)
const HP_GREEN := Color(0.290, 0.871, 0.502, 1.0)
const HP_YELLOW := Color(0.980, 0.749, 0.141, 1.0)
const HP_RED := Color(0.969, 0.443, 0.443, 1.0)
const BW_FONT_PATH := "res://assets/bw/ui/bw_font.fnt"
const CJK_FONT_PATH := "res://assets/fonts/NotoSansSC-Regular.ttf"
const BW_FRAME_PATH := "res://assets/bw/ui/window_frame.png"
const BW_FRAME_OVERLAY_PATH := "res://assets/bw/ui/window_frame_overlay.png"

static var _bw_font: Font = null
static var _bw_checked := false
static var _bw_available := false
static var _cjk_font: Font = null
static var _cjk_checked := false
static var _cjk_available := false

static func has_bw_font() -> bool:
	if not _bw_checked:
		_bw_checked = true
		_bw_available = ResourceLoader.exists(BW_FONT_PATH)
	return _bw_available

static func has_cjk_font() -> bool:
	if not _cjk_checked:
		_cjk_checked = true
		_cjk_available = ResourceLoader.exists(CJK_FONT_PATH)
	return _cjk_available

static func cjk_locale() -> bool:
	var code := TranslationServer.get_locale()
	return code.begins_with("zh") or code.begins_with("ja") or code.begins_with("ko")

static func cjk_font() -> Font:
	if _cjk_font != null:
		return _cjk_font
	if has_cjk_font():
		_cjk_font = load(CJK_FONT_PATH) as Font
	if _cjk_font == null:
		_cjk_font = ThemeDB.fallback_font
	return _cjk_font

# All UI text goes through this helper. Latin locales keep the original BW
# bitmap face; CJK locales use Noto Sans SC, which also carries Latin glyphs.
static func bw_font() -> Font:
	if cjk_locale() and has_cjk_font():
		return cjk_font()
	if _bw_font != null:
		return _bw_font
	if has_bw_font():
		_bw_font = load(BW_FONT_PATH) as Font
	if _bw_font == null:
		_bw_font = ThemeDB.fallback_font
	return _bw_font

static func using_bitmap_font() -> bool:
	return not (cjk_locale() and has_cjk_font())

static func font_size(size: int) -> int:
	# The BW font is a bitmap font: its native 15 px size is the crisp one.
	# Tiny status/HP labels use the next readable step instead of scaling the
	# atlas to an arbitrary size. CJK glyphs need a little more room to stay
	# legible, so the requested size is kept with a small floor.
	if not using_bitmap_font():
		return maxi(11, size)
	if has_bw_font():
		return 15 if size >= 12 else 12
	return size

static func apply_font(control: Control, size: int) -> void:
	control.set_meta("ui_font_size", size)
	control.add_theme_font_override("font", bw_font())
	control.add_theme_font_size_override("font_size", font_size(size))

# Re-applies the active font after TranslationServer changes locale.
static func refresh_fonts(root: Node) -> void:
	if root is Control:
		var control := root as Control
		var size := int(control.get_meta("ui_font_size", -1))
		if size >= 0:
			control.add_theme_font_override("font", bw_font())
			control.add_theme_font_size_override("font_size", font_size(size))
			if bool(control.get_meta("ui_bold", false)):
				apply_bold(control as Label)
	for child in root.get_children():
		refresh_fonts(child)

static func add_bw_frame_overlay(panel: PanelContainer) -> void:
	if not ResourceLoader.exists(BW_FRAME_OVERLAY_PATH):
		return
	var texture := load(BW_FRAME_OVERLAY_PATH) as Texture2D
	if texture == null:
		return
	var overlay := NinePatchRect.new()
	overlay.name = "BWFrameOverlay"
	overlay.texture = texture
	overlay.patch_margin_left = 8
	overlay.patch_margin_top = 8
	overlay.patch_margin_right = 8
	overlay.patch_margin_bottom = 8
	overlay.axis_stretch_horizontal = NinePatchRect.AXIS_STRETCH_MODE_STRETCH
	overlay.axis_stretch_vertical = NinePatchRect.AXIS_STRETCH_MODE_STRETCH
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_child(overlay)

static func add_panel_content(
	panel: PanelContainer,
	margin_h: int = 10,
	margin_v: int = 8
) -> MarginContainer:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", margin_h)
	margin.add_theme_constant_override("margin_top", margin_v)
	margin.add_theme_constant_override("margin_right", margin_h)
	margin.add_theme_constant_override("margin_bottom", margin_v)
	margin.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.add_child(margin)
	return margin

static func bw_window_style(content_margin: int = 8) -> StyleBox:
	if ResourceLoader.exists(BW_FRAME_PATH):
		var texture := load(BW_FRAME_PATH) as Texture2D
		if texture != null:
			var style := StyleBoxTexture.new()
			style.texture = texture
			style.texture_margin_left = 8.0
			style.texture_margin_top = 8.0
			style.texture_margin_right = 8.0
			style.texture_margin_bottom = 8.0
			style.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
			style.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
			style.content_margin_left = content_margin
			style.content_margin_top = content_margin
			style.content_margin_right = content_margin
			style.content_margin_bottom = content_margin
			return style
	return glass_style(INK, 10, BORDER, 1, content_margin)

static func glass_style(
	bg_color: Color = INK,
	radius: int = 10,
	border_color: Color = BORDER,
	border_width: int = 1,
	margin: int = 10
) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg_color
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	style.border_width_left = border_width
	style.border_width_top = border_width
	style.border_width_right = border_width
	style.border_width_bottom = border_width
	style.border_color = border_color
	style.content_margin_left = margin
	style.content_margin_top = margin
	style.content_margin_right = margin
	style.content_margin_bottom = margin
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.34)
	style.shadow_size = 8
	style.shadow_offset = Vector2(0, 4)
	style.anti_aliasing = true
	return style

static func panel_style(
	bg_color: Color = PANEL,
	radius: int = 12,
	border_color: Color = BORDER
) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg_color
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = border_color
	style.content_margin_left = 16
	style.content_margin_top = 12
	style.content_margin_right = 16
	style.content_margin_bottom = 12
	style.anti_aliasing = true
	return style

static func button_style(bg_color: Color, radius: int = 8) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg_color
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	style.content_margin_left = 14
	style.content_margin_top = 9
	style.content_margin_right = 14
	style.content_margin_bottom = 9
	style.anti_aliasing = true
	return style

static func style_button(button: Button, primary: bool = false, small: bool = false) -> void:
	var base := ACCENT if primary else PANEL_LIGHT
	var hover := base.lightened(0.12)
	var pressed := base.darkened(0.12)
	var disabled := Color(base.r, base.g, base.b, 0.4)
	var font := Color(0.031, 0.067, 0.110, 1.0) if primary else TEXT
	button.add_theme_stylebox_override("normal", button_style(base))
	button.add_theme_stylebox_override("hover", button_style(hover))
	button.add_theme_stylebox_override("pressed", button_style(pressed))
	button.add_theme_stylebox_override("disabled", button_style(disabled))
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	button.add_theme_color_override("font_color", font)
	button.add_theme_color_override("font_hover_color", font)
	button.add_theme_color_override("font_pressed_color", font)
	button.add_theme_color_override("font_disabled_color", Color(font.r, font.g, font.b, 0.5))
	apply_font(button, 14 if small else 16)

static func style_ghost_button(button: Button) -> void:
	var normal := button_style(Color(1.0, 1.0, 1.0, 0.06))
	normal.border_width_left = 0
	normal.border_width_top = 0
	normal.border_width_right = 0
	normal.border_width_bottom = 0
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", button_style(Color(1.0, 1.0, 1.0, 0.12)))
	button.add_theme_stylebox_override("pressed", button_style(Color(1.0, 1.0, 1.0, 0.18)))
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	button.add_theme_color_override("font_color", TEXT)
	button.add_theme_color_override("font_hover_color", ACCENT)
	apply_font(button, 15)

static func style_line_edit(line: LineEdit, compact: bool = false) -> void:
	var vertical := 7 if compact else 12
	var normal := panel_style(Color(0.024, 0.055, 0.090, 0.96), 8)
	normal.content_margin_left = 10 if compact else 12
	normal.content_margin_right = 8 if compact else 10
	normal.content_margin_top = vertical
	normal.content_margin_bottom = vertical
	var focus := panel_style(Color(0.024, 0.055, 0.090, 0.96), 8, ACCENT_DIM)
	focus.content_margin_left = 10 if compact else 12
	focus.content_margin_right = 8 if compact else 10
	focus.content_margin_top = vertical
	focus.content_margin_bottom = vertical
	line.add_theme_stylebox_override("normal", normal)
	line.add_theme_stylebox_override("focus", focus)
	line.add_theme_stylebox_override("read_only", normal)
	line.add_theme_color_override("font_color", TEXT)
	line.add_theme_color_override("font_placeholder_color", Color(MUTED.r, MUTED.g, MUTED.b, 0.72))
	line.add_theme_color_override("caret_color", ACCENT)
	line.add_theme_color_override("selection_color", Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.28))
	apply_font(line, 11 if compact else 15)
	line.custom_minimum_size = Vector2(0, 30 if compact else 40)

static func style_label(label: Label, size: int = 15, color: Color = TEXT) -> void:
	label.add_theme_font_size_override("font_size", font_size(size))
	label.add_theme_color_override("font_color", color)

static func make_label(text: String, size: int = 15, color: Color = TEXT) -> Label:
	var label := Label.new()
	label.text = text
	style_label(label, size, color)
	apply_font(label, size)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label

static func apply_bold(label: Label, weight: float = 0.55) -> void:
	label.set_meta("ui_bold", true)
	# The bitmap face is already heavy; emboldening it would pin it to its
	# native 15 px size. The CJK face is a normal outline font, so a variation
	# keeps titles readable.
	if using_bitmap_font():
		return
	var variation := FontVariation.new()
	variation.base_font = bw_font()
	variation.variation_embolden = weight
	label.add_theme_font_override("font", variation)

static func make_bold_label(text: String, size: int = 15, color: Color = TEXT) -> Label:
	var label := make_label(text, size, color)
	apply_bold(label)
	return label

static func chip_style(color: Color, radius: int = 5) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	style.content_margin_left = 5
	style.content_margin_right = 5
	style.content_margin_top = 1
	style.content_margin_bottom = 1
	style.anti_aliasing = true
	return style

static func format_money(amount: int) -> String:
	var digits := str(absi(amount))
	var grouped := ""
	for index in range(digits.length()):
		if index > 0 and (digits.length() - index) % 3 == 0:
			grouped += ","
		grouped += digits[index]
	return "%s$%s" % ["-" if amount < 0 else "", grouped]

static func translate_or(prefix: String, id: String, fallback: String) -> String:
	var key := "%s.%s" % [prefix, id]
	var translated := TranslationServer.translate(key)
	return fallback if translated == key else translated

static func type_label(type_name: String) -> String:
	return translate_or("type", type_name, type_name)

static func status_label(code: String) -> String:
	return translate_or("status", code.to_upper(), code)

static func nature_label(nature: String) -> String:
	return translate_or("nature", nature, nature)

static func stat_label(stat: String) -> String:
	return translate_or("stat", stat, stat)

static func season_label(season: String) -> String:
	var fallback := season.capitalize()
	return translate_or("season", season.to_lower(), fallback)

static func type_color(type_name: String) -> Color:
	match type_name:
		"Normal":
			return Color(0.788, 0.761, 0.659)
		"Fighting":
			return Color(0.753, 0.267, 0.220)
		"Flying":
			return Color(0.663, 0.561, 0.953)
		"Poison":
			return Color(0.639, 0.388, 0.678)
		"Ground":
			return Color(0.878, 0.737, 0.408)
		"Rock":
			return Color(0.714, 0.631, 0.212)
		"Bug":
			return Color(0.612, 0.678, 0.220)
		"Ghost":
			return Color(0.486, 0.408, 0.686)
		"Steel":
			return Color(0.690, 0.690, 0.753)
		"Fire":
			return Color(0.933, 0.506, 0.188)
		"Water":
			return Color(0.388, 0.565, 0.941)
		"Grass":
			return Color(0.478, 0.780, 0.298)
		"Electric":
			return Color(0.965, 0.843, 0.263)
		"Psychic":
			return Color(0.933, 0.388, 0.588)
		"Ice":
			return Color(0.596, 0.839, 0.839)
		"Dragon":
			return Color(0.435, 0.361, 0.937)
		"Dark":
			return Color(0.439, 0.345, 0.282)
		_:
			return Color(0.788, 0.761, 0.659)

static func hp_color(ratio: float) -> Color:
	if ratio > 0.5:
		return HP_GREEN
	if ratio > 0.2:
		return HP_YELLOW
	return HP_RED
