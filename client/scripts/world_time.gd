class_name WorldTime
extends RefCounted

# Shared client-side world clock. The clock is accelerated 60x by default, so
# a full day takes 24 real minutes and the lighting can be seen changing in a
# normal play session. `--time=HH:MM`, `--time-scale=N`, `--real-time` and
# `--freeze-time` override it, which is also what the screenshot tests use.
#
# All visuals are derived from one keyframe table: sky gradient, ambient light,
# the sun/fill lights and the multiply tint that is applied to the 3D world.

const DEFAULT_SCALE := 60.0
const DAY_SECONDS := 86400.0

static var KEYFRAMES: Array = [
	{
		"h": 0.0,
		"sky_top": Color(0.120, 0.160, 0.280),
		"sky_horizon": Color(0.180, 0.240, 0.400),
		"ground_horizon": Color(0.100, 0.140, 0.220),
		"ground_bottom": Color(0.040, 0.060, 0.100),
		"tint": Color(0.42, 0.48, 0.76),
		"ambient": Color(0.34, 0.42, 0.70),
		"ambient_energy": 0.24,
		"sun": Color(0.62, 0.72, 1.0),
		"sun_energy": 0.07,
		"fill": Color(0.28, 0.38, 0.68),
		"fill_energy": 0.12,
		"pitch": -20.0,
		"yaw": 105.0
	},
	{
		"h": 4.5,
		"sky_top": Color(0.130, 0.170, 0.300),
		"sky_horizon": Color(0.200, 0.260, 0.420),
		"ground_horizon": Color(0.110, 0.150, 0.230),
		"ground_bottom": Color(0.045, 0.065, 0.110),
		"tint": Color(0.45, 0.50, 0.78),
		"ambient": Color(0.36, 0.44, 0.72),
		"ambient_energy": 0.26,
		"sun": Color(0.66, 0.74, 1.0),
		"sun_energy": 0.08,
		"fill": Color(0.30, 0.40, 0.70),
		"fill_energy": 0.12,
		"pitch": -14.0,
		"yaw": 95.0
	},
	{
		"h": 5.8,
		"sky_top": Color(0.240, 0.280, 0.500),
		"sky_horizon": Color(0.950, 0.620, 0.450),
		"ground_horizon": Color(0.550, 0.420, 0.400),
		"ground_bottom": Color(0.120, 0.140, 0.160),
		"tint": Color(0.86, 0.68, 0.64),
		"ambient": Color(0.66, 0.55, 0.60),
		"ambient_energy": 0.32,
		"sun": Color(1.0, 0.68, 0.45),
		"sun_energy": 0.35,
		"fill": Color(0.55, 0.55, 0.82),
		"fill_energy": 0.14,
		"pitch": -8.0,
		"yaw": 20.0
	},
	{
		"h": 7.5,
		"sky_top": Color(0.360, 0.580, 0.820),
		"sky_horizon": Color(0.880, 0.860, 0.720),
		"ground_horizon": Color(0.660, 0.740, 0.580),
		"ground_bottom": Color(0.180, 0.280, 0.180),
		"tint": Color(0.98, 0.95, 0.90),
		"ambient": Color(0.76, 0.80, 0.88),
		"ambient_energy": 0.38,
		"sun": Color(1.0, 0.95, 0.85),
		"sun_energy": 0.62,
		"fill": Color(0.74, 0.80, 0.92),
		"fill_energy": 0.16,
		"pitch": -44.0,
		"yaw": 55.0
	},
	{
		"h": 12.0,
		"sky_top": Color(0.360, 0.580, 0.820),
		"sky_horizon": Color(0.740, 0.840, 0.780),
		"ground_horizon": Color(0.620, 0.720, 0.580),
		"ground_bottom": Color(0.180, 0.280, 0.180),
		"tint": Color(1.0, 1.0, 1.0),
		"ambient": Color(0.74, 0.80, 0.92),
		"ambient_energy": 0.40,
		"sun": Color(1.0, 0.98, 0.92),
		"sun_energy": 0.70,
		"fill": Color(0.74, 0.80, 0.92),
		"fill_energy": 0.18,
		"pitch": -78.0,
		"yaw": 90.0
	},
	{
		"h": 16.5,
		"sky_top": Color(0.380, 0.560, 0.780),
		"sky_horizon": Color(0.860, 0.820, 0.640),
		"ground_horizon": Color(0.640, 0.700, 0.550),
		"ground_bottom": Color(0.180, 0.260, 0.170),
		"tint": Color(0.99, 0.93, 0.82),
		"ambient": Color(0.74, 0.76, 0.84),
		"ambient_energy": 0.38,
		"sun": Color(1.0, 0.90, 0.70),
		"sun_energy": 0.62,
		"fill": Color(0.72, 0.76, 0.90),
		"fill_energy": 0.16,
		"pitch": -34.0,
		"yaw": 160.0
	},
	{
		"h": 18.0,
		"sky_top": Color(0.300, 0.300, 0.560),
		"sky_horizon": Color(0.980, 0.550, 0.320),
		"ground_horizon": Color(0.450, 0.320, 0.320),
		"ground_bottom": Color(0.130, 0.130, 0.170),
		"tint": Color(0.95, 0.68, 0.55),
		"ambient": Color(0.62, 0.50, 0.55),
		"ambient_energy": 0.30,
		"sun": Color(1.0, 0.55, 0.30),
		"sun_energy": 0.28,
		"fill": Color(0.56, 0.48, 0.72),
		"fill_energy": 0.14,
		"pitch": -8.0,
		"yaw": 182.0
	},
	{
		"h": 19.5,
		"sky_top": Color(0.120, 0.160, 0.360),
		"sky_horizon": Color(0.450, 0.320, 0.480),
		"ground_horizon": Color(0.160, 0.170, 0.250),
		"ground_bottom": Color(0.040, 0.050, 0.100),
		"tint": Color(0.60, 0.56, 0.74),
		"ambient": Color(0.38, 0.42, 0.62),
		"ambient_energy": 0.26,
		"sun": Color(0.70, 0.62, 0.95),
		"sun_energy": 0.10,
		"fill": Color(0.34, 0.40, 0.66),
		"fill_energy": 0.12,
		"pitch": -12.0,
		"yaw": 192.0
	},
	{
		"h": 21.0,
		"sky_top": Color(0.120, 0.160, 0.280),
		"sky_horizon": Color(0.180, 0.240, 0.400),
		"ground_horizon": Color(0.100, 0.140, 0.220),
		"ground_bottom": Color(0.040, 0.060, 0.100),
		"tint": Color(0.42, 0.48, 0.76),
		"ambient": Color(0.34, 0.42, 0.70),
		"ambient_energy": 0.24,
		"sun": Color(0.62, 0.72, 1.0),
		"sun_energy": 0.07,
		"fill": Color(0.28, 0.38, 0.68),
		"fill_energy": 0.12,
		"pitch": -20.0,
		"yaw": 105.0
	},
	{
		"h": 24.0,
		"sky_top": Color(0.120, 0.160, 0.280),
		"sky_horizon": Color(0.180, 0.240, 0.400),
		"ground_horizon": Color(0.100, 0.140, 0.220),
		"ground_bottom": Color(0.040, 0.060, 0.100),
		"tint": Color(0.42, 0.48, 0.76),
		"ambient": Color(0.34, 0.42, 0.70),
		"ambient_energy": 0.24,
		"sun": Color(0.62, 0.72, 1.0),
		"sun_energy": 0.07,
		"fill": Color(0.28, 0.38, 0.68),
		"fill_energy": 0.12,
		"pitch": -20.0,
		"yaw": 105.0
	}
]

static var _configured := false
static var _start_hours := 12.0
static var _scale := DEFAULT_SCALE
static var _anchor_unix := 0.0

static func configure_from_args() -> void:
	if _configured:
		return
	_configured = true
	var now := Time.get_time_dict_from_system()
	_start_hours = float(now.get("hour", 0)) + float(now.get("minute", 0)) / 60.0
	var args := OS.get_cmdline_args()
	for argument in OS.get_cmdline_user_args():
		if not args.has(argument):
			args.append(argument)
	for argument in args:
		if argument.begins_with("--time="):
			var parsed := parse_clock(argument.substr(7))
			if parsed >= 0.0:
				_start_hours = parsed
		elif argument.begins_with("--time-scale="):
			var value := argument.substr(13).to_float()
			if value >= 0.0:
				_scale = value
		elif argument == "--real-time":
			_scale = 1.0
		elif argument == "--freeze-time" or argument == "--no-time":
			_scale = 0.0
	_anchor_unix = Time.get_unix_time_from_system()

static func set_clock(hours: float, scale: float = -1.0) -> void:
	_configured = true
	_start_hours = fposmod(hours, 24.0)
	if scale >= 0.0:
		_scale = scale
	_anchor_unix = Time.get_unix_time_from_system()

static func time_scale() -> float:
	if not _configured:
		configure_from_args()
	return _scale

static func now_hours() -> float:
	if not _configured:
		configure_from_args()
	if _scale <= 0.0:
		return _start_hours
	var elapsed := Time.get_unix_time_from_system() - _anchor_unix
	return fposmod(_start_hours + elapsed * _scale / 3600.0, 24.0)

static func parse_clock(value: String) -> float:
	var parts := value.split(":")
	if parts.size() < 2:
		return -1.0
	var hour := parts[0].to_int()
	var minute := parts[1].to_int()
	if hour < 0 or hour > 23 or minute < 0 or minute > 59:
		return -1.0
	return float(hour) + float(minute) / 60.0

static func clock_text(hours: float) -> String:
	var total_minutes := int(round(fposmod(hours, 24.0) * 60.0)) % (24 * 60)
	return "%02d:%02d" % [total_minutes / 60, total_minutes % 60]

static func phase(hours: float) -> String:
	var h := fposmod(hours, 24.0)
	if h >= 5.0 and h < 7.0:
		return "dawn"
	if h >= 7.0 and h < 17.0:
		return "day"
	if h >= 17.0 and h < 19.5:
		return "dusk"
	return "night"

static func phase_label(hours: float) -> String:
	match phase(hours):
		"dawn":
			return TranslationServer.translate("Dawn")
		"day":
			return TranslationServer.translate("Day")
		"dusk":
			return TranslationServer.translate("Dusk")
		_:
			return TranslationServer.translate("Night")

static func phase_color(hours: float) -> Color:
	match phase(hours):
		"dawn":
			return Color("ffb36b")
		"day":
			return Color("ffe08a")
		"dusk":
			return Color("ff9a7a")
		_:
			return Color("8fb7ff")

static func is_night(hours: float) -> bool:
	return phase(hours) == "night"

static func darkness(hours: float) -> float:
	var sun_energy := float(_at(hours)["sun_energy"])
	return clampf(1.0 - sun_energy / 0.65, 0.0, 1.0)

static func sky_colors(hours: float) -> Dictionary:
	return _at(hours)

static func world_tint(hours: float, indoor: bool = false) -> Color:
	var tint := _at(hours)["tint"] as Color
	if indoor:
		tint = tint.lerp(Color(1, 1, 1, 1), 0.55)
	tint.a = 1.0
	return tint

static func arena_tint(hours: float, indoor: bool = false) -> Color:
	var tint := world_tint(hours, indoor).lerp(Color(1, 1, 1, 1), 0.20)
	tint.a = 1.0
	return tint

static func sprite_tint(hours: float, indoor: bool = false) -> Color:
	var tint := world_tint(hours, indoor).lerp(Color(1, 1, 1, 1), 0.30)
	tint.a = 1.0
	return tint

static func _at(hours: float) -> Dictionary:
	var h := fposmod(hours, 24.0)
	for index in range(KEYFRAMES.size() - 1):
		var a: Dictionary = KEYFRAMES[index]
		var b: Dictionary = KEYFRAMES[index + 1]
		if h < float(a["h"]) or h > float(b["h"]):
			continue
		var span := maxf(0.0001, float(b["h"]) - float(a["h"]))
		var t := (h - float(a["h"])) / span
		t = t * t * (3.0 - 2.0 * t)
		return _mix(a, b, t)
	return KEYFRAMES[0].duplicate()

static func _mix(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var result := {}
	for key in a:
		if key == "h":
			continue
		var first: Variant = a[key]
		var second: Variant = b[key]
		if first is Color:
			result[key] = (first as Color).lerp(second as Color, t)
		elif first is float or first is int:
			result[key] = lerpf(float(first), float(second), t)
		else:
			result[key] = second
	return result
