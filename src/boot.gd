
static func _is_modloader_disabled() -> bool:
	var exe_dir := OS.get_executable_path().get_base_dir()
	return FileAccess.file_exists(exe_dir.path_join(DISABLED_FILE))

static func _static_force_vanilla_state(reason: String, log_lines: PackedStringArray) -> void:
	log_lines.append("[FileScope] RESET (" + reason + "): forcing vanilla state")
	_static_reset_override_cfg(log_lines)
	if FileAccess.file_exists(PASS_STATE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS_STATE_PATH))
		log_lines.append("[FileScope] RESET (" + reason + "): wiped pass state")
	if FileAccess.file_exists(PASS2_DIRTY_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS2_DIRTY_PATH))
		log_lines.append("[FileScope] RESET (" + reason + "): cleared pass2 dirty marker")
	_static_wipe_hook_cache()
	log_lines.append("[FileScope] RESET (" + reason + "): wiped hook pack")

static func _mount_previous_session() -> Dictionary:
	var mounted: Dictionary = {}
	var log_lines: PackedStringArray = []
	log_lines.append("[FileScope] _mount_previous_session() starting")

	if _is_modloader_disabled():
		_static_force_vanilla_state("modloader_disabled sentinel", log_lines)
		_write_filescope_log(log_lines)
		return mounted

	if FileAccess.file_exists(PASS2_DIRTY_PATH):
		_static_force_vanilla_state("pass 2 crashed mid-run", log_lines)
		_write_filescope_log(log_lines)
		return mounted


	var cfg := ConfigFile.new()
	if cfg.load(PASS_STATE_PATH) != OK:
		log_lines.append("[FileScope] No pass state file -- skipping")
		_write_filescope_log(log_lines)
		return mounted
	var saved_ver: String = cfg.get_value("state", "modloader_version", "")
	if saved_ver != MODLOADER_VERSION:
		log_lines.append("[FileScope] Version mismatch: saved=%s current=%s -- wiping" % [saved_ver, MODLOADER_VERSION])
		_static_wipe_hook_cache()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS_STATE_PATH))
		_static_reset_override_cfg(log_lines)
		_write_filescope_log(log_lines)
		return mounted
	var saved_exe_mtime: int = cfg.get_value("state", "exe_mtime", 0)
	if saved_exe_mtime != 0:
		var current_exe_mtime := FileAccess.get_modified_time(OS.get_executable_path())
		if current_exe_mtime != saved_exe_mtime:
			log_lines.append("[FileScope] Game exe mtime changed -- wiping hook cache")
			_static_wipe_hook_cache()
			DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS_STATE_PATH))
			_static_reset_override_cfg(log_lines)
			_write_filescope_log(log_lines)
			return mounted
	var paths: PackedStringArray = cfg.get_value("state", "archive_paths", PackedStringArray())
	if paths.is_empty():
		log_lines.append("[FileScope] Pass state has no archive paths -- skipping")
		_write_filescope_log(log_lines)
		return mounted

	log_lines.append("[FileScope] %d archive path(s) in pass state" % paths.size())

	var any_missing := false
	for path in paths:
		var abs_path := path if not path.begins_with("res://") and not path.begins_with("user://") \
				else ProjectSettings.globalize_path(path)
		if FileAccess.file_exists(abs_path):
			log_lines.append("[FileScope]   EXISTS: " + abs_path)
			continue
		log_lines.append("[FileScope]   MISSING: " + abs_path)
		any_missing = true

	if any_missing:
		log_lines.append("[FileScope] Archive(s) missing -- resetting to clean state")
		var exe_dir := OS.get_executable_path().get_base_dir()
		var cfg_path := exe_dir.path_join("override.cfg")
		var preserved := _read_preserved_cfg_sections(cfg_path)
		var f := FileAccess.open(cfg_path, FileAccess.WRITE)
		if f:
			f.store_string("[autoload]\nOrcKit=\"*" + MODLOADER_RES_PATH + "\"\n\n" + preserved)
			f.close()
		var state_path := ProjectSettings.globalize_path(PASS_STATE_PATH)
		if FileAccess.file_exists(state_path):
			DirAccess.remove_absolute(state_path)
		_write_filescope_log(log_lines)
		return mounted

	for path in paths:
		if ProjectSettings.load_resource_pack(path):
			var remaps := _static_resolve_remaps(path)
			log_lines.append("[FileScope]   MOUNTED: " + path
					+ (" (%d remaps)" % remaps if remaps > 0 else ""))
			mounted[path] = true
		elif path.get_extension().to_lower() == "vmz":
			var zip_path := _static_vmz_to_zip(path)
			if not zip_path.is_empty() and ProjectSettings.load_resource_pack(zip_path):
				var remaps := _static_resolve_remaps(zip_path)
				log_lines.append("[FileScope]   MOUNTED (vmz->zip): " + path
						+ (" (%d remaps)" % remaps if remaps > 0 else ""))
				mounted[path] = true
			else:
				log_lines.append("[FileScope]   MOUNT FAILED (vmz): " + path + " zip_path=" + zip_path)
		else:
			log_lines.append("[FileScope]   MOUNT FAILED: " + path)

	var hook_pack: String = cfg.get_value("state", "hook_pack_path", "") as String
	var wrapped_paths: PackedStringArray = cfg.get_value("state", "hook_pack_wrapped_paths", PackedStringArray())
	_static_cleanup_orphan_hook_packs(hook_pack, log_lines)
	if wrapped_paths.size() > 0:
		var pre_cached_count := 0
		var pre_cached_tokenized: PackedStringArray = []
		var pre_cached_source: PackedStringArray = []
		var pre_notloaded: PackedStringArray = []
		for path in wrapped_paths:
			if ResourceLoader.has_cached(path):
				pre_cached_count += 1
				var s := load(path) as GDScript
				if s != null and s.source_code.length() > 0:
					pre_cached_source.append(path.get_file())
				else:
					pre_cached_tokenized.append(path.get_file())
			else:
				pre_notloaded.append(path.get_file())
		log_lines.append("[FileScope] PRE-INIT cache: %d/%d wrapped scripts already cached at static init" \
				% [pre_cached_count, wrapped_paths.size()])
		if pre_cached_tokenized.size() > 0:
			log_lines.append("[FileScope]   tokenized (PCK-compiled already): " + ", ".join(pre_cached_tokenized))
		if pre_cached_source.size() > 0:
			log_lines.append("[FileScope]   source-loaded (our take_over_path from prev session): " + ", ".join(pre_cached_source))
		if pre_notloaded.size() > 0:
			log_lines.append("[FileScope]   NOT YET LOADED (preempt window open): " + ", ".join(pre_notloaded))
	if hook_pack != "":
		var hook_abs: String = hook_pack if not hook_pack.begins_with("user://") \
				else ProjectSettings.globalize_path(hook_pack)
		if FileAccess.file_exists(hook_abs):
			if ProjectSettings.load_resource_pack(hook_abs, true):
				log_lines.append("[FileScope] HOOK PACK mounted at static init: " + hook_pack)
				var hzr := ZIPReader.new()
				if hzr.open(hook_abs) == OK:
					var wrapped_set: Dictionary = {}
					for wp in wrapped_paths:
						wrapped_set[wp] = true
					var preloaded := 0
					var preload_failed := 0
					var skipped_lenient := 0
					for f: String in hzr.get_files():
						var rpath := "res://" + f
						if not _is_game_script_path(rpath):
							continue
						if not wrapped_set.has(rpath):
							skipped_lenient += 1
							continue
						var scr := ResourceLoader.load(rpath, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
						if scr == null or scr.source_code.is_empty():
							preload_failed += 1
							continue
						scr.take_over_path(rpath)
						preloaded += 1
					hzr.close()
					log_lines.append("[FileScope] HOOK PACK preempted %d wrapped script(s) at static init (%d failed, %d other vanilla left to lenient lazy-compile)" \
							% [preloaded, preload_failed, skipped_lenient])
			else:
				log_lines.append("[FileScope] HOOK PACK mount FAILED: " + hook_pack)
		else:
			log_lines.append("[FileScope] HOOK PACK path in pass_state but file missing: " + hook_abs)

	var test_pack_path := ProjectSettings.globalize_path("user://test_pack_precedence.zip")
	if FileAccess.file_exists(test_pack_path):
		if ProjectSettings.load_resource_pack(test_pack_path, true):
			log_lines.append("[FileScope] TEST: mounted test_pack_precedence.zip at static init")
		else:
			log_lines.append("[FileScope] TEST: FAILED to mount test_pack_precedence.zip")

	log_lines.append("[FileScope] Done -- %d archive(s) mounted" % mounted.size())
	_write_filescope_log(log_lines)
	return mounted

static func _static_reset_override_cfg(log_lines: PackedStringArray) -> void:
	var exe_dir := OS.get_executable_path().get_base_dir()
	var cfg_path := exe_dir.path_join("override.cfg")
	if not FileAccess.file_exists(cfg_path):
		return
	var preserved := _read_preserved_cfg_sections(cfg_path)
	var f := FileAccess.open(cfg_path, FileAccess.WRITE)
	if f == null:
		log_lines.append("[FileScope] WARNING: could not rewrite override.cfg (read-only?)")
		return
	f.store_string("[autoload]\nOrcKit=\"*" + MODLOADER_RES_PATH + "\"\n\n" + preserved)
	f.close()
	log_lines.append("[FileScope] override.cfg reset to clean [autoload] state")

static func _static_cleanup_orphan_hook_packs(keep_path: String, log_lines: PackedStringArray) -> void:
	var pack_dir := ProjectSettings.globalize_path(HOOK_PACK_DIR)
	if not DirAccess.dir_exists_absolute(pack_dir):
		return
	var keep_abs := ProjectSettings.globalize_path(keep_path) if keep_path != "" else ""
	var dir := DirAccess.open(pack_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var removed := 0
	while true:
		var fname := dir.get_next()
		if fname == "":
			break
		if not fname.begins_with(HOOK_PACK_PREFIX) or not fname.ends_with(".zip"):
			continue
		var full := pack_dir.path_join(fname)
		if keep_abs != "" and full == keep_abs:
			continue
		DirAccess.remove_absolute(full)
		removed += 1
	dir.list_dir_end()
	if removed > 0:
		log_lines.append("[FileScope] Cleaned %d orphan hook pack(s) from prior session(s)" % removed)

static func _static_wipe_hook_cache() -> void:
	var pack_dir := ProjectSettings.globalize_path(HOOK_PACK_DIR)
	if DirAccess.dir_exists_absolute(pack_dir):
		var pdir := DirAccess.open(pack_dir)
		if pdir != null:
			pdir.list_dir_begin()
			while true:
				var pname := pdir.get_next()
				if pname == "":
					break
				if pname.begins_with("Framework") and pname.ends_with(".gd"):
					DirAccess.remove_absolute(pack_dir.path_join(pname))
				elif pname.begins_with(HOOK_PACK_PREFIX) and pname.ends_with(".zip"):
					DirAccess.remove_absolute(pack_dir.path_join(pname))
			pdir.list_dir_end()
	var cache_dir := ProjectSettings.globalize_path(VANILLA_CACHE_DIR)
	if not DirAccess.dir_exists_absolute(cache_dir):
		return
	var dir := DirAccess.open(cache_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		var full := cache_dir.path_join(file_name)
		if dir.current_is_dir():
			var sub := DirAccess.open(full)
			if sub:
				sub.list_dir_begin()
				var sub_file := sub.get_next()
				while sub_file != "":
					DirAccess.remove_absolute(full.path_join(sub_file))
					sub_file = sub.get_next()
				sub.list_dir_end()
			DirAccess.remove_absolute(full)
		else:
			DirAccess.remove_absolute(full)
		file_name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(cache_dir)

func _build_autoload_sections() -> Dictionary:
	_clean_early_autoload_dir()
	var prepend: Array[Dictionary] = []
	var append: Array[Dictionary] = []
	for entry in _pending_autoloads:
		if entry.get("is_early", false):
			var path: String = entry["path"]
			var disk_path := _ensure_early_autoload_on_disk(path, entry.get("mod_name", ""))
			prepend.append({ "name": entry["name"], "path": disk_path })
		else:
			append.append({ "name": entry["name"], "path": entry["path"] })
	return { "prepend": prepend, "append": append }

const EARLY_AUTOLOAD_DIR := "user://modloader_early"

func _clean_early_autoload_dir() -> void:
	var dir_path := ProjectSettings.globalize_path(EARLY_AUTOLOAD_DIR)
	if not DirAccess.dir_exists_absolute(dir_path):
		return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry == "":
			break
		var full: String = dir_path.path_join(entry)
		if dir.current_is_dir():
			var sub := DirAccess.open(full)
			if sub:
				sub.list_dir_begin()
				var sub_file := sub.get_next()
				while sub_file != "":
					DirAccess.remove_absolute(full.path_join(sub_file))
					sub_file = sub.get_next()
				sub.list_dir_end()
			DirAccess.remove_absolute(full)
		else:
			DirAccess.remove_absolute(full)
	dir.list_dir_end()

func _ensure_early_autoload_on_disk(res_path: String, mod_name: String) -> String:
	var global := ProjectSettings.globalize_path(res_path)
	if FileAccess.file_exists(global):
		return res_path

	var script := load(res_path) as GDScript
	if script == null or not script.has_source_code():
		return res_path

	var rel := res_path.trim_prefix("res://")
	var disk_dir := ProjectSettings.globalize_path(EARLY_AUTOLOAD_DIR)
	var target := disk_dir.path_join(rel)
	DirAccess.make_dir_recursive_absolute(target.get_base_dir())
	var f := FileAccess.open(target, FileAccess.WRITE)
	if f == null:
		_log_critical("Cannot write early autoload to disk: " + target + " [" + mod_name + "]")
		return res_path
	f.store_string(script.source_code)
	f.close()

	var user_path := EARLY_AUTOLOAD_DIR.path_join(rel)
	_log_info("  Extracted early autoload to disk: " + user_path + " [" + mod_name + "]")
	return user_path

func _collect_enabled_archive_paths() -> PackedStringArray:
	var paths := PackedStringArray()
	var candidates: Array[Dictionary] = []
	for entry in _ui_mod_entries:
		if not entry["enabled"]:
			continue
		candidates.append(entry.duplicate())
	candidates.sort_custom(_compare_load_order)
	for c in candidates:
		if c["ext"] == "folder":
			var folder_name: String = c["full_path"].get_file()
			var tmp_zip := ProjectSettings.globalize_path(TMP_DIR).path_join(
					folder_name + "_dev.zip")
			if FileAccess.file_exists(tmp_zip):
				paths.append(tmp_zip)
			else:
				_log_warning("Folder mod '%s' has no cached zip -- skipping from pass state"
						% c["mod_name"])
			continue
		paths.append(c["full_path"])
	return paths

func _write_override_cfg(prepend_autoloads: Array[Dictionary]) -> Error:
	var exe_dir := OS.get_executable_path().get_base_dir()
	var path := exe_dir.path_join("override.cfg")
	var tmp := path + ".tmp"
	var preserved := _read_preserved_cfg_sections(path)
	var lines := PackedStringArray()
	lines.append("[autoload]")
	lines.append('OrcKit="*' + MODLOADER_RES_PATH + '"')
	for entry in prepend_autoloads:
		lines.append('%s="*%s"' % [entry["name"], entry["path"]])
	lines.append("")
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string("\n".join(lines) + "\n" + preserved)
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var dir := DirAccess.open(exe_dir)
	if dir == null:
		DirAccess.remove_absolute(tmp)
		return ERR_CANT_OPEN
	var err := dir.rename(tmp.get_file(), path.get_file())
	if err != OK:
		DirAccess.remove_absolute(tmp)
	return err

func _persist_hook_pack_state(pack_path: String, wrapped_paths: PackedStringArray = PackedStringArray()) -> void:
	var cfg := ConfigFile.new()
	cfg.load(PASS_STATE_PATH)
	cfg.set_value("state", "hook_pack_path", pack_path)
	cfg.set_value("state", "hook_pack_wrapped_paths", wrapped_paths)
	cfg.set_value("state", "hook_pack_exe_mtime", FileAccess.get_modified_time(OS.get_executable_path()))
	if cfg.get_value("state", "modloader_version", "") == "":
		cfg.set_value("state", "modloader_version", MODLOADER_VERSION)
	if cfg.save(PASS_STATE_PATH) == OK:
		_log_info("[OrcKitCodegen] Persisted hook pack path for next-session static-init mount: %s (%d wrapped path(s))" \
				% [pack_path.get_file(), wrapped_paths.size()])

func _write_pass_state(archive_paths: PackedStringArray, state_hash: String = "") -> Error:
	var cfg := ConfigFile.new()
	cfg.load(PASS_STATE_PATH)
	var count: int = cfg.get_value("state", "restart_count", 0)
	cfg.set_value("state", "restart_count", count + 1)
	cfg.set_value("state", "mods_hash", state_hash)
	cfg.set_value("state", "archive_paths", archive_paths)
	cfg.set_value("state", "modloader_version", MODLOADER_VERSION)
	cfg.set_value("state", "exe_mtime", FileAccess.get_modified_time(OS.get_executable_path()))
	cfg.set_value("state", "timestamp", Time.get_unix_time_from_system())
	var override_data: Array = []
	for entry in _pending_script_overrides:
		override_data.append(entry.duplicate())
	cfg.set_value("state", "script_overrides", override_data)
	var err := cfg.save(PASS_STATE_PATH)
	if err != OK:
		_log_critical("Failed to save pass state (error %d)" % err)
	return err

func _compute_state_hash(archive_paths: PackedStringArray, prepend_autoloads: Array[Dictionary]) -> String:
	if archive_paths.is_empty() and prepend_autoloads.is_empty():
		return ""
	var parts := PackedStringArray()
	var sorted_paths := Array(archive_paths)
	sorted_paths.sort()
	for p in sorted_paths:
		parts.append("a:%s@%d" % [p, FileAccess.get_modified_time(p)])
	for entry in prepend_autoloads:
		parts.append("p:%s=%s" % [entry["name"], entry["path"]])
	for entry in _ui_mod_entries:
		if entry["enabled"] and entry.get("cfg") != null:
			var ver: String = (entry["cfg"] as ConfigFile).get_value("mod", "version", "")
			if not ver.is_empty():
				parts.append("v:%s=%s" % [entry["mod_id"], ver])
	for entry in _pending_script_overrides:
		parts.append("so:%s=%s" % [entry["vanilla_path"], entry["mod_script_path"]])
	parts.append("ml:" + MODLOADER_VERSION)
	var self_mtime: int = FileAccess.get_modified_time(MODLOADER_RES_PATH)
	if self_mtime > 0:
		parts.append("ml_mtime:%d" % self_mtime)
	return "\n".join(parts).md5_text()

func _write_heartbeat() -> void:
	var f := FileAccess.open(HEARTBEAT_PATH, FileAccess.WRITE)
	if f:
		f.store_string("started:%d" % Time.get_unix_time_from_system())
		f.close()

func _delete_heartbeat() -> void:
	if FileAccess.file_exists(HEARTBEAT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(HEARTBEAT_PATH))

func _check_crash_recovery() -> void:
	if not FileAccess.file_exists(HEARTBEAT_PATH):
		return
	_log_warning("Heartbeat detected -- previous launch may have crashed")
	var cfg := ConfigFile.new()
	if cfg.load(PASS_STATE_PATH) == OK:
		var count: int = cfg.get_value("state", "restart_count", 0)
		if count >= MAX_RESTART_COUNT:
			_log_critical("Restart loop (%d crashes) -- resetting to clean state" % count)
			_restore_clean_override_cfg()
			DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS_STATE_PATH))
			_delete_heartbeat()
			return
	_delete_heartbeat()

func _check_safe_mode() -> void:
	var exe_dir := OS.get_executable_path().get_base_dir()
	var safe_path := exe_dir.path_join(SAFE_MODE_FILE)
	if not FileAccess.file_exists(safe_path):
		return
	_log_warning("Safe mode file detected -- resetting to clean state")
	_restore_clean_override_cfg()
	if FileAccess.file_exists(PASS_STATE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS_STATE_PATH))
	_delete_heartbeat()
	DirAccess.remove_absolute(safe_path)

func _clean_stale_cache() -> void:
	var cache_dir := ProjectSettings.globalize_path(TMP_DIR)
	if not DirAccess.dir_exists_absolute(cache_dir):
		return
	var dir := DirAccess.open(cache_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var fname := dir.get_next()
		if fname == "":
			break
		if fname.get_extension().to_lower() != "zip":
			continue
		var base := fname.get_basename()
		if base.ends_with("_dev"):
			var folder_name := base.substr(0, base.length() - 4)
			if DirAccess.dir_exists_absolute(_mods_dir.path_join(folder_name)):
				continue
		else:
			var vmz_name := base + ".vmz"
			if FileAccess.file_exists(_mods_dir.path_join(vmz_name)):
				continue
		DirAccess.remove_absolute(cache_dir.path_join(fname))
		_log_debug("Removed stale cache: " + fname)
	dir.list_dir_end()

func _restore_clean_override_cfg() -> void:
	var exe_dir := OS.get_executable_path().get_base_dir()
	var path := exe_dir.path_join("override.cfg")
	var preserved := _read_preserved_cfg_sections(path)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_log_critical("Cannot write override.cfg -- game dir may be read-only: " + exe_dir)
		return
	f.store_string("[autoload]\nOrcKit=\"*" + MODLOADER_RES_PATH + "\"\n\n" + preserved)
	f.close()

func _clear_restart_counter() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PASS_STATE_PATH) == OK:
		cfg.set_value("state", "restart_count", 0)
		cfg.save(PASS_STATE_PATH)