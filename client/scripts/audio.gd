extends Node

# BGM/SFX playback for the original Black/White audio rendered from the ROM.
# The manifest and streams live under res://assets/bw/audio and are loaded
# lazily: this autoload starts before Boot mounts game.pck, so nothing here may
# touch the asset tree in _ready().

const MANIFEST_PATH := "res://assets/bw/audio/manifest.json"
const SETTINGS_PATH := "user://settings.cfg"
const MUSIC_FADE := 0.55
const SILENT_DB := -60.0
const SFX_VOICES := 8

var manifest: Dictionary = {}
var music_volume_db := -7.0
var sfx_volume_db := -3.0

var _manifest_ready := false
var _music_a: AudioStreamPlayer
var _music_b: AudioStreamPlayer
var _active_music: AudioStreamPlayer
var _current_key := ""
var _current_loop := false
var _jingle_active := false
var _jingle_restore := ""
var _music_tween: Tween
var _bgm_cache: Dictionary = {}
var _sfx_cache: Dictionary = {}
var _sfx_players: Array[AudioStreamPlayer] = []
var _sfx_next := 0
var _missing_logged: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_volumes()
	_music_a = _make_music_player("MusicA")
	_music_b = _make_music_player("MusicB")
	_active_music = _music_a
	_music_a.finished.connect(_on_music_finished.bind(_music_a))
	_music_b.finished.connect(_on_music_finished.bind(_music_b))
	for index in range(SFX_VOICES):
		var player := AudioStreamPlayer.new()
		player.name = "Sfx%d" % index
		player.bus = "Master"
		player.volume_db = sfx_volume_db
		add_child(player)
		_sfx_players.append(player)


func reload_manifest() -> void:
	_manifest_ready = false
	manifest = {}
	_bgm_cache.clear()
	_sfx_cache.clear()
	_ensure_manifest()


func _ensure_manifest() -> void:
	if _manifest_ready:
		return
	_manifest_ready = true
	if not FileAccess.file_exists(MANIFEST_PATH):
		print("[audio] no BGM manifest; running silent")
		return
	var file := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if file == null:
		push_warning("Could not open %s" % MANIFEST_PATH)
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Dictionary:
		manifest = parsed
		var bgm_entries: Dictionary = manifest.get("bgm", {})
		var sfx_entries: Dictionary = manifest.get("sfx", {})
		print("[audio] %d BGM, %d SFX" % [bgm_entries.size(), sfx_entries.size()])
	else:
		push_warning("Invalid audio manifest")


func has_audio() -> bool:
	_ensure_manifest()
	return not manifest.is_empty()


# --- BGM -------------------------------------------------------------------

func play_bgm(key: String, fade: float = MUSIC_FADE) -> void:
	if key == "":
		return
	if key == _current_key and _active_music != null and _active_music.playing:
		return
	var stream := _load_bgm(key)
	if stream == null:
		return
	_ensure_manifest()
	_jingle_active = false
	_jingle_restore = ""
	_current_key = key
	_current_loop = false
	if stream is AudioStreamOggVorbis:
		_current_loop = (stream as AudioStreamOggVorbis).loop
	var outgoing := _active_music
	var incoming := _music_b if _active_music == _music_a else _music_a
	# A player may still be fading out from an interrupted crossfade; stop it
	# before reusing the slot so two tracks cannot overlap at a stale volume.
	incoming.stop()
	incoming.stream = stream
	incoming.volume_db = SILENT_DB
	incoming.play()
	_active_music = incoming
	if _music_tween != null and _music_tween.is_valid():
		_music_tween.kill()
	if fade <= 0.01:
		incoming.volume_db = music_volume_db
		outgoing.stop()
		return
	_music_tween = create_tween()
	_music_tween.set_parallel(true)
	_music_tween.tween_property(incoming, "volume_db", music_volume_db, fade)
	if outgoing != null and outgoing.playing:
		_music_tween.tween_property(outgoing, "volume_db", SILENT_DB, fade)
		_music_tween.chain().tween_callback(outgoing.stop)


func play_map_bgm(
	map_id: String,
	location_key: String,
	location_display: String = "",
	x: int = -1,
	y: int = -1
) -> void:
	var key := bgm_key_for_map(map_id, location_key, location_display, x, y)
	if key != "":
		play_bgm(key)


func bgm_key_for_map(
	map_id: String,
	location_key: String,
	location_display: String = "",
	x: int = -1,
	y: int = -1
) -> String:
	_ensure_manifest()
	if manifest.is_empty():
		return ""
	if map_id == "unova_full" and x >= 0 and y >= 0:
		var cell := bgm_key_at_cell(x, y)
		if cell != "":
			return cell
	var locations: Dictionary = manifest.get("locations", {})
	if location_key != "" and locations.has(location_key):
		return str(locations[location_key])
	if location_display != "" and locations.has(location_display):
		return str(locations[location_display])
	var indoor: Dictionary = manifest.get("indoorMaps", {})
	if indoor.has(map_id):
		return str(indoor[map_id])
	if map_id.begins_with("unova_in_"):
		return "seq_bgm_t_01"
	if location_key.begins_with("Route") or location_display.begins_with("Route"):
		return "seq_bgm_r_a"
	return "seq_bgm_t_01"


# The outdoor world is one big ROM matrix; each 32x32-tile cell stores the
# BGM key its zone uses. This avoids depending on translated place names.
func bgm_key_at_cell(x: int, y: int) -> String:
	var info: Dictionary = manifest.get("locationGrid", {})
	if info.is_empty():
		return ""
	var tile := int(info.get("tileSize", 32))
	if tile <= 0:
		return ""
	var grid: Array = info.get("grid", [])
	var cy := int(floor(float(y) / float(tile)))
	var cx := int(floor(float(x) / float(tile)))
	if cy < 0 or cy >= grid.size():
		return ""
	var row: Array = grid[cy]
	if cx < 0 or cx >= row.size():
		return ""
	return str(row[cx])


func battle_bgm(mode: String) -> void:
	_ensure_manifest()
	var battle: Dictionary = manifest.get("battle", {})
	var key := str(battle.get("wild" if mode == "wild" else "trainer", ""))
	if key != "":
		play_bgm(key)


func play_victory() -> void:
	_ensure_manifest()
	var key := str(manifest.get("victory", ""))
	if key == "":
		return
	play_jingle(key)
	# The fanfare ends in silence; the map theme returns when the result
	# screen closes, not underneath the jingle.
	_jingle_restore = ""


func play_title() -> void:
	_ensure_manifest()
	play_bgm(str(manifest.get("title", "")))


# Plays a non-looping music cue, then returns to the track that was playing.
func play_jingle(key: String) -> void:
	var stream := _load_bgm(key)
	if stream == null:
		return
	if stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = false
	var outgoing := _active_music
	var incoming := _music_b if _active_music == _music_a else _music_a
	# A player may still be fading out from an interrupted crossfade; stop it
	# before reusing the slot so two tracks cannot overlap at a stale volume.
	incoming.stop()
	incoming.stream = stream
	incoming.volume_db = SILENT_DB
	incoming.play()
	_active_music = incoming
	_current_key = key
	_current_loop = false
	_jingle_active = true
	if _music_tween != null and _music_tween.is_valid():
		_music_tween.kill()
	_music_tween = create_tween()
	_music_tween.set_parallel(true)
	_music_tween.tween_property(incoming, "volume_db", music_volume_db, 0.25)
	if outgoing != null and outgoing.playing:
		_music_tween.tween_property(outgoing, "volume_db", SILENT_DB, 0.25)
		_music_tween.chain().tween_callback(outgoing.stop)


func stop_bgm(fade: float = 0.6) -> void:
	if _active_music == null or not _active_music.playing:
		return
	_current_key = ""
	_jingle_active = false
	if _music_tween != null and _music_tween.is_valid():
		_music_tween.kill()
	_music_tween = create_tween()
	_music_tween.tween_property(_active_music, "volume_db", SILENT_DB, fade)
	_music_tween.tween_callback(_active_music.stop)


func _on_music_finished(player: AudioStreamPlayer) -> void:
	if player != _active_music:
		return
	if _jingle_active:
		_jingle_active = false
		var restore := _jingle_restore
		_jingle_restore = ""
		_current_key = ""
		if restore != "":
			play_bgm(restore)


func _make_music_player(name: String) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.name = name
	player.bus = "Master"
	player.volume_db = SILENT_DB
	add_child(player)
	return player


func _load_bgm(key: String) -> AudioStream:
	if key == "":
		return null
	if _bgm_cache.has(key):
		return _bgm_cache[key]
	_ensure_manifest()
	var entries: Dictionary = manifest.get("bgm", {})
	if not entries.has(key):
		_log_missing("bgm", key)
		return null
	var entry: Dictionary = entries[key]
	var path := "res://assets/bw/audio/%s" % str(entry.get("file", ""))
	var stream := _load_stream(path)
	if stream == null:
		return null
	if stream is AudioStreamOggVorbis:
		var ogg := stream as AudioStreamOggVorbis
		ogg.loop = bool(entry.get("loop", false))
		ogg.loop_offset = float(entry.get("loopOffset", 0.0))
	_bgm_cache[key] = stream
	return stream


# --- SFX -------------------------------------------------------------------

func play_sfx(key: String, volume_offset_db: float = 0.0) -> void:
	if key == "":
		return
	var stream := _load_sfx(key)
	if stream == null:
		return
	var player: AudioStreamPlayer = null
	for candidate in _sfx_players:
		if not candidate.playing:
			player = candidate
			break
	if player == null:
		player = _sfx_players[_sfx_next]
		_sfx_next = (_sfx_next + 1) % _sfx_players.size()
	player.stream = stream
	player.volume_db = sfx_volume_db + volume_offset_db
	player.play()


func _load_sfx(key: String) -> AudioStream:
	if _sfx_cache.has(key):
		return _sfx_cache[key]
	_ensure_manifest()
	var entries: Dictionary = manifest.get("sfx", {})
	if not entries.has(key):
		_log_missing("sfx", key)
		return null
	var path := "res://assets/bw/audio/%s" % str(entries[key])
	var stream := _load_stream(path)
	if stream != null:
		_sfx_cache[key] = stream
	return stream


func _load_stream(path: String) -> AudioStream:
	if not FileAccess.file_exists(path):
		_log_missing("file", path)
		return null
	if path.get_extension().to_lower() == "ogg":
		return AudioStreamOggVorbis.load_from_file(path)
	return AudioStreamWAV.load_from_file(path)


func _log_missing(kind: String, key: String) -> void:
	var tag := "%s:%s" % [kind, key]
	if _missing_logged.has(tag):
		return
	_missing_logged[tag] = true
	print("[audio] missing %s %s" % [kind, key])


# --- Volume ----------------------------------------------------------------

func set_music_volume_db(value: float) -> void:
	music_volume_db = clampf(value, -40.0, 0.0)
	if _active_music != null and _active_music.playing:
		_active_music.volume_db = music_volume_db
	_save_volumes()


func set_sfx_volume_db(value: float) -> void:
	sfx_volume_db = clampf(value, -40.0, 0.0)
	_save_volumes()


func _load_volumes() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return
	music_volume_db = float(config.get_value("audio", "music", music_volume_db))
	sfx_volume_db = float(config.get_value("audio", "sfx", sfx_volume_db))


func _save_volumes() -> void:
	var config := ConfigFile.new()
	config.load(SETTINGS_PATH)
	config.set_value("audio", "music", music_volume_db)
	config.set_value("audio", "sfx", sfx_volume_db)
	config.save(SETTINGS_PATH)
