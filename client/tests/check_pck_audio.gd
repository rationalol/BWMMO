extends Node

# Verifies the audio paths inside game.pck, which is how the Android build
# consumes them. Run with:
#   .tools/Godot_v4.4.1-stable_win64_console.exe --headless --path client \
#     res://tests/PckAudioTest.tscn

var failures := 0

func _ready() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		print("[pck-audio] FAIL: %s" % message)
	else:
		print("[pck-audio] ok: %s" % message)

func _run() -> void:
	await get_tree().process_frame
	if not FileAccess.file_exists("res://game.pck"):
		print("[pck-audio] SKIP: client/game.pck missing")
		get_tree().quit(0)
		return
	var mounted := ProjectSettings.load_resource_pack("res://game.pck", true)
	_check(mounted, "game.pck mounts")
	Audio.reload_manifest()
	_check(Audio.has_audio(), "audio manifest is readable from game.pck")
	if not Audio.has_audio():
		get_tree().quit(1)
		return
	var bgm: Dictionary = Audio.manifest.get("bgm", {})
	_check(bgm.size() >= 50, "pck manifest lists the full BGM set (%d)" % bgm.size())
	var stream := AudioStreamOggVorbis.load_from_file(
		"res://assets/bw/audio/bgm/seq_bgm_t_01.ogg"
	)
	_check(stream != null, "town theme loads from game.pck")
	if stream != null:
		_check(stream.get_length() > 30.0, "town theme has audio data")
	var sfx := AudioStreamWAV.load_from_file("res://assets/bw/audio/sfx/select.wav")
	_check(sfx != null, "select SFX loads from game.pck")
	print("[pck-audio] %s" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
	get_tree().quit(1 if failures > 0 else 0)
