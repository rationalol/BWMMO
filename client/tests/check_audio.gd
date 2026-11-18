extends Node

# Headless audio check: manifest shape, map -> BGM resolution, loop metadata
# and stream loading. Run with:
#   .tools/Godot_v4.4.1-stable_win64_console.exe --headless --path client \
#     res://tests/AudioTest.tscn

var failures := 0

func _ready() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		print("[audio-test] FAIL: %s" % message)
	else:
		print("[audio-test] ok: %s" % message)

func _run() -> void:
	await get_tree().process_frame
	Audio.reload_manifest()
	if not Audio.has_audio():
		print("[audio-test] SKIP: client/assets/bw/audio/manifest.json missing")
		get_tree().quit(0)
		return

	var manifest: Dictionary = Audio.manifest
	var bgm: Dictionary = manifest.get("bgm", {})
	var sfx: Dictionary = manifest.get("sfx", {})
	_check(bgm.size() >= 20, "manifest has BGM entries (%d)" % bgm.size())
	_check(sfx.size() >= 15, "manifest has SFX entries (%d)" % sfx.size())

	var grid: Dictionary = manifest.get("locationGrid", {})
	_check(not grid.is_empty(), "location grid present")
	_check(Audio.bgm_key_at_cell(784, 752) == "seq_bgm_t_01",
		"Nuvema Town cell resolves to the town theme")
	_check(Audio.bgm_key_at_cell(784, 688) == "seq_bgm_r_a",
		"Route 1 cell resolves to the route theme")
	_check(Audio.bgm_key_for_map("unova_in_1", "", "") == "seq_bgm_pokecen",
		"indoor map 1 resolves to the Pokémon Center theme")
	_check(Audio.bgm_key_for_map("unova_in_396", "", "") == "seq_bgm_labo",
		"Juniper's lab resolves to the lab theme")

	var battle: Dictionary = manifest.get("battle", {})
	for kind in ["wild", "trainer"]:
		_check(bgm.has(str(battle.get(kind, ""))), "battle %s theme exists" % kind)

	for key in bgm:
		var entry: Dictionary = bgm[key]
		var path := "res://assets/bw/audio/%s" % str(entry.get("file", ""))
		if not FileAccess.file_exists(path):
			_check(false, "BGM file exists: %s" % key)
			continue
		if bool(entry.get("loop", false)):
			_check(float(entry.get("loopOffset", 0.0)) >= 0.0,
				"loop offset present: %s" % key)
	for key in sfx:
		var path := "res://assets/bw/audio/%s" % str(sfx[key])
		if not FileAccess.file_exists(path):
			_check(false, "SFX file exists: %s" % key)

	# Load one looping track end to end: this covers the Ogg loader and the
	# loop properties the Audio manager applies at runtime.
	var first_key := "seq_bgm_t_01"
	if bgm.has(first_key):
		var entry: Dictionary = bgm[first_key]
		var path := "res://assets/bw/audio/%s" % str(entry.get("file", ""))
		var stream := AudioStreamOggVorbis.load_from_file(path)
		_check(stream != null, "town theme OGG loads")
		if stream != null:
			_check(stream.get_length() >= float(entry.get("loopOffset", 0.0)),
				"town theme is at least as long as its loop offset")
			_check(stream.get_length() >= 10.0, "town theme is not a stub")

	var sfx_stream := AudioStreamWAV.load_from_file("res://assets/bw/audio/sfx/select.wav")
	_check(sfx_stream != null, "select SFX WAV loads")

	print("[audio-test] %s" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
	get_tree().quit(1 if failures > 0 else 0)
