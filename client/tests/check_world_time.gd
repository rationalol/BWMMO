extends SceneTree

const WorldTimeScript = preload("res://scripts/world_time.gd")

func _luminance(color: Color) -> float:
	return color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722

func _init() -> void:
	var failures := 0
	WorldTimeScript.set_clock(12.0, 0.0)
	if WorldTimeScript.clock_text(12.0) != "12:00":
		push_error("12:00 formatting is %s" % WorldTimeScript.clock_text(12.0))
		failures += 1
	if WorldTimeScript.clock_text(18.5) != "18:30":
		push_error("18:30 formatting is %s" % WorldTimeScript.clock_text(18.5))
		failures += 1
	if WorldTimeScript.phase(6.0) != "dawn":
		push_error("06:00 should be dawn")
		failures += 1
	if WorldTimeScript.phase(12.0) != "day":
		push_error("12:00 should be day")
		failures += 1
	if WorldTimeScript.phase(18.5) != "dusk":
		push_error("18:30 should be dusk")
		failures += 1
	if WorldTimeScript.phase(23.0) != "night":
		push_error("23:00 should be night")
		failures += 1
	if not is_equal_approx(WorldTimeScript.now_hours(), 12.0):
		push_error("frozen clock did not stay at 12:00")
		failures += 1

	var day_tint := WorldTimeScript.world_tint(12.0, false)
	var night_tint := WorldTimeScript.world_tint(23.0, false)
	var indoor_night := WorldTimeScript.world_tint(23.0, true)
	if _luminance(night_tint) >= _luminance(day_tint):
		push_error("night tint is not darker than day tint")
		failures += 1
	if _luminance(indoor_night) <= _luminance(night_tint):
		push_error("indoor tint should stay brighter at night")
		failures += 1
	if WorldTimeScript.arena_tint(23.0, false).is_equal_approx(Color(1, 1, 1, 1)):
		push_error("night battle arena tint is white")
		failures += 1
	if _luminance(WorldTimeScript.sprite_tint(23.0, false)) <= _luminance(night_tint):
		push_error("battle sprites should stay brighter than the battlefield")
		failures += 1

	var day_sky := WorldTimeScript.sky_colors(12.0)
	var night_sky := WorldTimeScript.sky_colors(23.0)
	for key in ["sky_top", "sky_horizon", "ground_horizon", "ground_bottom", "ambient", "sun", "fill"]:
		if not day_sky.has(key) or not night_sky.has(key):
			push_error("sky palette is missing %s" % key)
			failures += 1
	if day_sky.has("sky_top") and night_sky.has("sky_top"):
		if _luminance(night_sky["sky_top"]) >= _luminance(day_sky["sky_top"]):
			push_error("night sky top is not darker than day sky top")
			failures += 1
	if WorldTimeScript.darkness(12.0) > 0.05:
		push_error("noon should not be dark")
		failures += 1
	if WorldTimeScript.darkness(23.0) < 0.5:
		push_error("night should be dark")
		failures += 1

	print("[world-time] %s" % ("FAILED" if failures > 0 else "PASSED"))
	quit(1 if failures > 0 else 0)
