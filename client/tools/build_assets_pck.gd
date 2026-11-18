extends SceneTree

# Builds assets.pck for the Android APK workaround. Raw GLB/NSBMD/NSBTX/TTF
# sources stay out because the runtime uses their imported .scn/.ctex/.fontdata
# resources; raw PNGs stay in because actor frames fall back to Image.load_from_file.
const OUT_PATH := "res://game.pck"
const ASSET_SKIP := ["glb", "nsbmd", "nsbtx", "ttf"]
# Audio under assets/bw/audio is loaded at runtime with load_from_file and is
# marked with .gdignore so Godot never imports it; skip any stale imported
# copies from older runs so the pack does not carry the audio twice.
const IMPORTED_SKIP := ["md5", "tmp", "oggvorbisstr", "sample"]

func _init() -> void:
	var packer := PCKPacker.new()
	var err := packer.pck_start(OUT_PATH)
	if err != OK:
		push_error("pck_start failed: %s" % err)
		quit(1)
		return
	var count := _add_tree(packer, "res://assets", "assets", ASSET_SKIP)
	count += _add_tree(packer, "res://.godot/imported", ".godot/imported", IMPORTED_SKIP)
	err = packer.flush()
	print("Packed %d files into %s (flush=%s)" % [count, OUT_PATH, err])
	quit(0 if err == OK else 1)

func _add_tree(packer: PCKPacker, src_root: String, dst_root: String, skip_ext: Array) -> int:
	var count := 0
	var pending: Array[String] = [src_root]
	while not pending.is_empty():
		var dir_path: String = pending.pop_back()
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		for sub in dir.get_directories():
			pending.append(dir_path.path_join(sub))
		for file_name in dir.get_files():
			var ext := file_name.get_extension().to_lower()
			if ext in skip_ext:
				continue
			var source := dir_path.path_join(file_name)
			var rel := source.trim_prefix(src_root)
			if rel.begins_with("/"):
				rel = rel.substr(1)
			packer.add_file(dst_root.path_join(rel), source)
			count += 1
	return count
