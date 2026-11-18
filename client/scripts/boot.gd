extends Node

const UI = preload("res://scripts/ui_theme.gd")

# The Android APK cannot hold more than 65535 ZIP entries, so assets live in
# game.pck. Mount it before loading Main.tscn: the main script preloads
# textures, and the theme font is loaded lazily after this point.
#
# On Android the pack sits inside the APK as a *deflated* ZIP entry. Random
# reads from a deflated entry are pathologically slow, so the first launch
# copies it to user storage and every later launch mounts that copy. The copy
# is chunked and reports progress to the Loading autoload, which is why the
# first launch shows the splash for a bit instead of a black screen.
const PACK_PATH := "res://game.pck"
const USER_PACK_PATH := "user://game.pck"
const PACK_TEMP_PATH := "user://game.pck.tmp"
const MAIN_SCENE := "res://scenes/Main.tscn"
const COPY_CHUNK := 1 << 20
const COPY_YIELD_EVERY := 4

func _ready() -> void:
	Loading.show_loading("BWMMO", "Preparing game data...")
	# Give the splash a couple of frames before the blocking work starts so
	# the player sees the animation immediately on a cold start.
	await get_tree().process_frame
	await get_tree().process_frame

	var has_pack: bool = await _mount_pack()
	Audio.reload_manifest()
	if has_pack:
		Loading.set_progress(0.58, "Loading fonts...")
	else:
		Loading.set_progress(0.58, "Starting without the asset pack...")
	await get_tree().process_frame

	var fallback := load("res://assets/fonts/NotoSansSC-Regular.ttf") as Font
	if fallback != null:
		ThemeDB.fallback_font = fallback
	UI.reset_font_cache()
	Loading.set_font(fallback)
	Loading.set_progress(0.68, "")
	Loading.set_status_key("Loading Unova...")
	await get_tree().process_frame

	get_tree().change_scene_to_file(MAIN_SCENE)

func _mount_pack() -> bool:
	var exists := FileAccess.file_exists(PACK_PATH)
	print("[boot] game.pck exists=", exists)
	if not exists:
		return false
	var pack_size := _file_size(PACK_PATH)
	print("[boot] game.pck size=", pack_size)

	if OS.has_feature("mobile") or _force_mobile_copy():
		var cached_size := _file_size(USER_PACK_PATH)
		if cached_size == pack_size:
			if ProjectSettings.load_resource_pack(USER_PACK_PATH, true):
				print("[boot] mounted cached user pack")
				return true
			print("[boot] cached user pack is unreadable; rebuilding it")
		elif cached_size > 0:
			# The APK's pack changed size (app update). Free the old cache
			# before writing the new one so peak storage stays reasonable.
			print("[boot] removing stale cached pack (%d bytes)" % cached_size)
			DirAccess.remove_absolute(ProjectSettings.globalize_path(USER_PACK_PATH))
		if pack_size > 0:
			var copied := await _copy_pack(pack_size)
			if copied and ProjectSettings.load_resource_pack(USER_PACK_PATH, true):
				print("[boot] mounted copied user pack")
				return true
		# Last resort: mount straight from the APK. Slow, but playable.
		return ProjectSettings.load_resource_pack(PACK_PATH, true)

	var mounted := ProjectSettings.load_resource_pack(PACK_PATH, true)
	print("[boot] direct mount=", mounted)
	return mounted

# Desktop-only shortcut for exercising the Android first-launch copy path
# without a phone: godot --headless ... -- --mobile-copy
func _force_mobile_copy() -> bool:
	return OS.get_cmdline_user_args().has("--mobile-copy")

# Copies res://game.pck to user:// in chunks, updating the splash every few
# chunks. The partial file is written to a .tmp name and only renamed once the
# size matches, so a killed first launch never leaves a corrupt cache behind.
func _copy_pack(pack_size: int) -> bool:
	print("[boot] copying game.pck to user storage (one time)")
	var source := FileAccess.open(PACK_PATH, FileAccess.READ)
	if source == null:
		push_error("Could not open %s: %s" % [PACK_PATH, FileAccess.get_open_error()])
		return false
	var target := FileAccess.open(PACK_TEMP_PATH, FileAccess.WRITE)
	if target == null:
		source.close()
		push_error("Could not write %s: %s" % [PACK_TEMP_PATH, FileAccess.get_open_error()])
		return false

	var copied := 0
	var chunk_index := 0
	Loading.set_progress(0.05, "Preparing assets (first launch)...")
	while copied < pack_size:
		var want := mini(COPY_CHUNK, pack_size - copied)
		var buffer := source.get_buffer(want)
		if buffer.is_empty():
			break
		target.store_buffer(buffer)
		copied += buffer.size()
		chunk_index += 1
		Loading.set_progress(
			0.05 + 0.48 * clampf(float(copied) / float(pack_size), 0.0, 1.0),
			"Preparing assets (first launch)... %d%%" % int(
				100.0 * float(copied) / float(pack_size)
			)
		)
		if chunk_index % COPY_YIELD_EVERY == 0:
			await get_tree().process_frame
	source.close()
	target.close()

	if _file_size(PACK_TEMP_PATH) != pack_size:
		push_error("Asset pack copy is incomplete (%d/%d bytes)" % [
			_file_size(PACK_TEMP_PATH), pack_size
		])
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PACK_TEMP_PATH))
		return false

	DirAccess.remove_absolute(ProjectSettings.globalize_path(USER_PACK_PATH))
	var error := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(PACK_TEMP_PATH),
		ProjectSettings.globalize_path(USER_PACK_PATH)
	)
	if error != OK:
		push_error("Could not move the asset pack into place: %s" % error)
		return false
	return true

func _file_size(path: String) -> int:
	if not FileAccess.file_exists(path):
		return 0
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var size := file.get_length()
	file.close()
	return size
