extends Control

# Original Black/White style battler plate: the name, gender and level float
# above a long ribbon-shaped HP bar. The player's plate also carries the HP
# numbers and the EXP bar. Geometry is drawn, not styled, so it keeps the
# sharp bevelled look of the ROM at any size.

const UI = preload("res://scripts/ui_theme.gd")
const FONT_2X_PATH := "res://assets/bw/ui/bw_font_2x.fnt"
const FONT_3X_PATH := "res://assets/bw/ui/bw_font_3x.fnt"

const OUTLINE := Color("0a0f0f")
const PLATE_LIGHT := Color("e9fbfd")
const PLATE_TOP := Color("f7ffff")
const PLATE_MID := Color("c4d2d4")
const BEVEL := Color("78898b")
const BAND := Color("22302f")
const HP_GREEN := Color("2edc64")
const HP_YELLOW := Color("f0cc3c")
const HP_RED := Color("f05c5c")
const HP_TEXT := Color("5ce834")
const HP_TEXT_OUTLINE := Color("123808")
const EXP_FILL := Color("23d9cb")
const EXP_TOP := Color("8bfff4")
const GOLD := Color("f0b43c")
const TEXT := Color("f7fcfb")
const MUTED := Color("b6c4c0")
const FEMALE := Color("ff7aa8")
const MALE := Color("5cc0ff")

var side := "enemy"
var _font_huge: Font = null
var _font_small: Font = null
var _font_name: Font = null
var _huge_size := 45
var _small_size := 30
var _name_size := 45
var _creature: Dictionary = {}
var _name := ""
var _level := 1
var _gender := ""
var _max_hp := 1
var _target_hp := 0
var _display_hp := -1.0
var _exp_ratio := 0.0
var _has_exp := false

func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	_load_fonts()
	set_process(false)

func _load_fonts() -> void:
	_font_huge = null
	_font_small = null
	_huge_size = 45
	_small_size = 30
	if ResourceLoader.exists(FONT_3X_PATH):
		_font_huge = load(FONT_3X_PATH) as Font
	if ResourceLoader.exists(FONT_2X_PATH):
		_font_small = load(FONT_2X_PATH) as Font
	if _font_huge == null:
		_font_huge = UI.bw_font()
		_huge_size = 15
	if _font_small == null:
		_font_small = UI.bw_font()
		_small_size = 15
	_refresh_name_font()

func _refresh_name_font() -> void:
	if UI.cjk_locale() and UI.has_cjk_font():
		_font_name = UI.cjk_font()
		_name_size = 30
	else:
		_font_name = _font_huge
		_name_size = _huge_size

func refresh_fonts() -> void:
	_load_fonts()
	queue_redraw()

func setup(p_side: String) -> void:
	side = p_side
	queue_redraw()

func reset() -> void:
	_display_hp = -1.0
	_creature = {}
	queue_redraw()

func set_creature(data: Dictionary) -> void:
	_creature = data
	_name = str(data.get("name", "?"))
	_level = int(data.get("level", 1))
	_gender = str(data.get("gender", "")).to_lower()
	_max_hp = maxi(1, int(data.get("maxHp", 1)))
	_target_hp = clampi(int(data.get("hp", 0)), 0, _max_hp)
	if _display_hp < 0.0:
		_display_hp = float(_target_hp)
	_has_exp = data.has("xp")
	if _has_exp:
		var xp := maxf(0.0, float(data.get("xp", 0)))
		var next_xp := maxf(1.0, float(data.get("xpToNext", 1)))
		_exp_ratio = clampf(xp / next_xp, 0.0, 1.0)
	set_process(_display_hp != float(_target_hp))
	queue_redraw()

func _process(delta: float) -> void:
	if _display_hp == float(_target_hp):
		set_process(false)
		return
	var rate := maxf(1.0, float(_max_hp) * 2.4)
	_display_hp = move_toward(_display_hp, float(_target_hp), rate * delta)
	queue_redraw()

func _draw() -> void:
	if _name == "":
		return
	_draw_name_and_level()
	_draw_hp_bar()
	if side == "player":
		_draw_hp_numbers()
		if _has_exp:
			_draw_exp_bar()

func _draw_name_and_level() -> void:
	var baseline := 39.0
	_draw_with(_font_name, _name_size, _name, Vector2(8.0, baseline), TEXT, OUTLINE, 4)

	var num_text := str(_level)
	var num_w := _text_width(num_text)
	var lv_text := "Lv."
	var lv_w := _text_width(lv_text)
	var right := size.x - 10.0
	_draw_huge(num_text, Vector2(right - num_w, baseline), TEXT)
	_draw_huge(lv_text, Vector2(right - num_w - lv_w, baseline), GOLD)

	var symbol := ""
	var symbol_color := MUTED
	if _gender == "female":
		symbol = "♀"
		symbol_color = FEMALE
	elif _gender == "male":
		symbol = "♂"
		symbol_color = MALE
	if symbol != "":
		var sym_w := _text_width(symbol)
		_draw_huge(
			symbol,
			Vector2(right - num_w - lv_w - sym_w - 20.0, baseline),
			symbol_color
		)

func _draw_hp_bar() -> void:
	var bw := size.x
	var by := 46.0
	var bh := 26.0
	var tip := 22.0
	var bottom := by + bh + 10.0
	var outer: PackedVector2Array
	var body: PackedVector2Array
	if side == "enemy":
		outer = PackedVector2Array([
			Vector2(24.0, by),
			Vector2(bw, by),
			Vector2(bw - tip, bottom),
			Vector2(24.0, bottom)
		])
		body = PackedVector2Array([
			Vector2(28.0, by + 4.0),
			Vector2(bw - 4.0, by + 4.0),
			Vector2(bw - tip - 4.0, bottom - 4.0),
			Vector2(28.0, bottom - 4.0)
		])
	else:
		outer = PackedVector2Array([
			Vector2(0.0, by),
			Vector2(bw - 24.0, by),
			Vector2(bw - 24.0, bottom),
			Vector2(tip, bottom)
		])
		body = PackedVector2Array([
			Vector2(4.0, by + 4.0),
			Vector2(bw - 28.0, by + 4.0),
			Vector2(bw - 28.0, bottom - 4.0),
			Vector2(tip + 4.0, bottom - 4.0)
		])

	_shifted_polygon(outer, Vector2(0.0, 10.0), Color(0.02, 0.05, 0.04, 0.42))
	draw_colored_polygon(outer, OUTLINE)
	draw_colored_polygon(body, PLATE_MID)

	var light := PackedVector2Array([
		body[0] + Vector2(2.0, 2.0),
		body[1] + Vector2(-2.0, 2.0),
		body[2] + Vector2(-2.0, -6.0),
		body[3] + Vector2(2.0, -6.0)
	])
	draw_colored_polygon(light, PLATE_LIGHT)
	var top_band := PackedVector2Array([
		light[0],
		light[1],
		light[1] + Vector2(0.0, 6.0),
		light[0] + Vector2(0.0, 6.0)
	])
	draw_colored_polygon(top_band, PLATE_TOP)
	var bevel := PackedVector2Array([
		light[3],
		light[2],
		light[2] + Vector2(0.0, 4.0),
		light[3] + Vector2(0.0, 4.0)
	])
	draw_colored_polygon(bevel, BEVEL)

	# HP label, sitting inside the left end of the ribbon.
	_draw_small("HP", Vector2(12.0, by + 24.0), HP_TEXT, HP_TEXT_OUTLINE, 3)

	var track_x0 := 66.0
	var track_x1 := bw - 34.0
	var track_y0 := by + 7.0
	var track_y1 := by + 22.0
	draw_rect(Rect2(track_x0 - 2.0, track_y0 - 2.0, track_x1 - track_x0 + 4.0, track_y1 - track_y0 + 4.0), OUTLINE)
	draw_rect(Rect2(track_x0, track_y0, track_x1 - track_x0, track_y1 - track_y0), PLATE_LIGHT)

	var ratio := clampf(_display_hp / float(_max_hp), 0.0, 1.0)
	var fill_w := (track_x1 - track_x0) * ratio
	if fill_w > 0.5:
		var color := _hp_color(ratio)
		draw_rect(Rect2(track_x0, track_y0, fill_w, track_y1 - track_y0), OUTLINE)
		var inner_y0 := track_y0 + 2.0
		var inner_y1 := track_y1 - 2.0
		var inner_w := maxf(1.0, fill_w - 4.0)
		draw_rect(Rect2(track_x0 + 2.0, inner_y0, inner_w, inner_y1 - inner_y0), color)
		draw_rect(Rect2(track_x0 + 2.0, inner_y0, inner_w, 3.0), color.lightened(0.35))
		draw_rect(Rect2(track_x0 + 2.0, inner_y1 - 3.0, inner_w, 3.0), color.darkened(0.30))
		draw_rect(Rect2(track_x0 + 2.0, inner_y0, 2.0, inner_y1 - inner_y0), color.darkened(0.42))

func _draw_hp_numbers() -> void:
	var y0 := 90.0
	var y1 := 122.0
	var band := PackedVector2Array([
		Vector2(38.0, y0),
		Vector2(size.x - 24.0, y0),
		Vector2(size.x - 24.0, y1),
		Vector2(22.0, y1)
	])
	draw_colored_polygon(band, OUTLINE)
	var inner := PackedVector2Array([
		Vector2(41.0, y0 + 3.0),
		Vector2(size.x - 27.0, y0 + 3.0),
		Vector2(size.x - 27.0, y1 - 3.0),
		Vector2(26.0, y1 - 3.0)
	])
	draw_colored_polygon(inner, BAND)
	var hp_text := "%d / %d" % [int(round(_display_hp)), _max_hp]
	var hp_w := _text_width(hp_text)
	_draw_huge(hp_text, Vector2(size.x - 42.0 - hp_w, y1 - 4.0), TEXT)

func _draw_exp_bar() -> void:
	var x0 := 54.0
	var x1 := size.x - 54.0
	var y0 := 128.0
	var y1 := 138.0
	draw_rect(Rect2(x0 - 2.0, y0 - 2.0, x1 - x0 + 4.0, y1 - y0 + 4.0), OUTLINE)
	draw_rect(Rect2(x0, y0, x1 - x0, y1 - y0), Color("e2eef0"))
	var fill_w := (x1 - x0) * _exp_ratio
	if fill_w > 0.0:
		draw_rect(Rect2(x0, y0, fill_w, y1 - y0), EXP_FILL)
		draw_rect(Rect2(x0, y0, fill_w, 3.0), EXP_TOP)

func _hp_color(ratio: float) -> Color:
	if ratio > 0.5:
		return HP_GREEN
	if ratio > 0.2:
		return HP_YELLOW
	return HP_RED

func _draw_huge(
	text: String,
	pos: Vector2,
	color: Color,
	outline_color: Color = OUTLINE,
	outline_size: int = 5
) -> void:
	_draw_with(_font_huge, _huge_size, text, pos, color, outline_color, outline_size)

func _draw_small(
	text: String,
	pos: Vector2,
	color: Color,
	outline_color: Color = OUTLINE,
	outline_size: int = 3
) -> void:
	_draw_with(_font_small, _small_size, text, pos, color, outline_color, outline_size)

func _draw_with(
	font: Font,
	font_size: int,
	text: String,
	pos: Vector2,
	color: Color,
	outline_color: Color,
	outline_size: int
) -> void:
	if font == null:
		return
	draw_string_outline(
		font,
		pos,
		text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1.0,
		font_size,
		outline_size,
		outline_color
	)
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, color)

func _text_width(text: String) -> float:
	if _font_huge == null:
		return 0.0
	return _font_huge.get_string_size(
		text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, _huge_size
	).x

func _shifted_polygon(points: PackedVector2Array, offset: Vector2, color: Color) -> void:
	var shifted := PackedVector2Array()
	for point in points:
		shifted.append(point + offset)
	draw_colored_polygon(shifted, color)
