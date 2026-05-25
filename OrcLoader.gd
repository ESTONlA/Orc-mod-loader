extends Node


const MODLOADER_VERSION := "1.0.0"

const MODLOADER_RES_PATH := "res://OrcLoader.gd"
const MOD_DIR := "mods"
const TMP_DIR := "user://vmz_mount_cache"
const UI_CONFIG_PATH := "user://mod_config.cfg"
const VANILLA_PROFILE := "__vanilla__"
const CONFLICT_REPORT_PATH := "user://modloader_conflicts.txt"
const PASS_STATE_PATH := "user://mod_pass_state.cfg"
const HEARTBEAT_PATH := "user://modloader_heartbeat.txt"
const PASS2_DIRTY_PATH := "user://modloader_pass2_dirty"
const SAFE_MODE_FILE := "modloader_safe_mode"
const DISABLED_FILE := "modloader_disabled"
const MAX_RESTART_COUNT := 2

const HOOK_PACK_DIR := "user://modloader_hooks"
const HOOK_PACK_PREFIX := "framework_pack"
const HOOK_PACK_MOUNT_BASE := "res://modloader_hooks"
const VANILLA_CACHE_DIR := "user://modloader_hooks/vanilla"

const PRIORITY_MIN := -999
const PRIORITY_MAX := 999
const TRACKED_EXTENSIONS: Array[String] = ["gd", "tscn", "tres", "gdns", "gdnlib", "scn"]

const GAME_RUNTIME_SKIP_LIST: Array[String] = []

const GAME_RESOURCE_SERIALIZED_SKIP: Array[String] = []

const GAME_RESOURCE_DATA_SKIP: Array[String] = [
	"EnemySpawnWave.gd",
	"EnemySpawnerData.gd",
	"LevelData.gd",
	"UpgradeData.gd",
]

const GAME_ENGINE_VOID_METHODS: Array[String] = [
	"_ready", "_process", "_physics_process", "_input",
	"_unhandled_input", "_unhandled_key_input",
	"_enter_tree", "_exit_tree", "_notification",
]

var _mods_dir: String = ""
var _developer_mode := false
var _active_profile := "Default"
var _ui_window: Control = null
var _ui_hint_label: Label = null
var _ui_launch_btn: Button = null
var _has_loaded := false
var _last_mod_txt_status := "none"
var _last_mod_txt_error := ""
var _boot_complete: bool = false
var _dirty_since_boot: bool = false

var _mods_filter_text: String = ""
var _mods_hide_disabled: bool = false
var _mods_filter_focus_pending: bool = false

var _ui_mod_entries: Array[Dictionary] = []
var _hidden_folder_profile_keys: Dictionary = {}
var _hidden_folder_ids: Dictionary = {}
var _pending_autoloads: Array[Dictionary] = []
var _report_lines: Array[String] = []
var _loaded_mod_ids: Dictionary = {}
var _registered_autoload_names: Dictionary = {}
var _override_registry: Dictionary = {}
var _mod_script_analysis: Dictionary = {}
var _archive_file_sets: Dictionary = {}

signal frameworks_ready
var _hooks: Dictionary = {}
var _dispatch_counts: Dictionary = {}
var _any_mod_hooked: bool = false
var _hooked_bases: Dictionary = {}
var _next_id: int = 1
var _skip_super: bool = false
var _seq: int = 0
var _caller: Node = null
var _is_ready: bool = false
var _wrapper_active: Dictionary = {}
var _post_legacy_warned: Dictionary = {}

var _class_name_to_path: Dictionary = {}
var _all_game_script_paths: Array[String] = []
var _pck_zero_byte_paths: Dictionary = {}
var _scripts_with_scene_preloads: Dictionary = {}

var _pending_script_overrides: Array[Dictionary] = []
var _applied_script_overrides: Dictionary = {}

var _hooked_methods: Dictionary = {}
var _any_mod_declared_registry: bool = false

var _re_take_over: RegEx
var _re_extends: RegEx
var _re_extends_classname: RegEx
var _re_class_name: RegEx
var _re_func: RegEx
var _re_preload: RegEx
var _re_filename_priority: RegEx
var _re_hook_call: RegEx

var _rtv_re_extends: RegEx
var _rtv_re_class_name: RegEx
var _rtv_re_func: RegEx
var _rtv_re_static_func: RegEx
var _rtv_re_var: RegEx

var _filescope_mounted: Dictionary = _mount_previous_session()


func _log_info(msg: String) -> void:
	var line := "[OrcKit][Info] " + msg
	print(line)
	_report_lines.append(line)

func _log_warning(msg: String) -> void:
	var line := "[OrcKit][Warning] " + msg
	push_warning(line)
	_report_lines.append(line)

func _log_critical(msg: String) -> void:
	var line := "[OrcKit][Critical] " + msg
	push_error(line)
	_report_lines.append(line)

func _log_debug(msg: String) -> void:
	if not _developer_mode:
		return
	var line := "[OrcKit][Debug] " + msg
	print(line)
	_report_lines.append(line)


static func _static_vmz_to_zip(vmz_path: String) -> String:
	var cache_dir := ProjectSettings.globalize_path(TMP_DIR)
	if not DirAccess.dir_exists_absolute(cache_dir):
		DirAccess.make_dir_recursive_absolute(cache_dir)
	if not FileAccess.file_exists(vmz_path):
		return ""
	var zip_name := vmz_path.get_file().get_basename() + ".zip"
	var zip_path := cache_dir.path_join(zip_name)
	if FileAccess.file_exists(zip_path):
		var src_time := FileAccess.get_modified_time(vmz_path)
		var zip_time := FileAccess.get_modified_time(zip_path)
		if src_time <= zip_time:
			return zip_path
	var src := FileAccess.open(vmz_path, FileAccess.READ)
	if src == null:
		return ""
	var dst := FileAccess.open(zip_path, FileAccess.WRITE)
	if dst == null:
		src.close()
		return ""
	while src.get_position() < src.get_length():
		dst.store_buffer(src.get_buffer(65536))
	src.close()
	dst.close()
	return zip_path

static func _write_filescope_log(lines: PackedStringArray) -> void:
	for line in lines:
		print(line)
	var f := FileAccess.open("user://modloader_filescope.log", FileAccess.WRITE)
	if f:
		for line in lines:
			f.store_line(line)
		f.close()

static func _read_preserved_cfg_sections(cfg_path: String) -> String:
	if not FileAccess.file_exists(cfg_path):
		return ""
	var f := FileAccess.open(cfg_path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	var result := PackedStringArray()
	var in_autoload_section := false
	for line in text.split("\n"):
		var stripped := line.strip_edges()
		if stripped.begins_with("["):
			var section := stripped.to_lower()
			in_autoload_section = section == "[autoload]" or section == "[autoload_prepend]"
			if not in_autoload_section:
				result.append(line)
			continue
		if not in_autoload_section and stripped != "":
			result.append(line)
	var preserved := "\n".join(result).strip_edges()
	if preserved.is_empty():
		return ""
	return "\n" + preserved + "\n"

func _normalize_to_res_path(zip_path: String) -> String:
	var path := zip_path.replace("\\", "/")
	if path.begins_with("res://"):   return path
	if path.begins_with("/"):        return "res:/" + path
	if path.begins_with(".") or path == "mod.txt": return ""
	if path.get_extension().to_lower() in TRACKED_EXTENSIONS:
		return "res://" + path
	return ""

func _try_mount_pack(path: String) -> bool:
	if ProjectSettings.load_resource_pack(path):
		_resolve_remaps(path)
		return true
	if path.get_extension().to_lower() != "vmz":
		return false
	var zip_path := _static_vmz_to_zip(path)
	if not zip_path.is_empty() and ProjectSettings.load_resource_pack(zip_path):
		_resolve_remaps(zip_path)
		return true
	return false

func _resolve_remaps(archive_path: String) -> void:
	var remap_count := _static_resolve_remaps(archive_path)
	if remap_count > 0:
		_log_debug("  Resolved %d .remap file(s)" % remap_count)

static func _static_resolve_remaps(archive_path: String) -> int:
	var zr := ZIPReader.new()
	if zr.open(archive_path) != OK:
		return 0

	var count := 0
	for f: String in zr.get_files():
		if not f.ends_with(".remap"):
			continue
		var remap_bytes := zr.read_file(f)
		if remap_bytes.is_empty():
			continue
		var cfg := ConfigFile.new()
		if cfg.parse(remap_bytes.get_string_from_utf8()) != OK:
			continue
		var target: String = cfg.get_value("remap", "path", "")
		if target.is_empty():
			continue
		if target.begins_with("res://.godot/exported/"):
			continue
		var original_path := f.trim_suffix(".remap")
		if not original_path.begins_with("res://"):
			original_path = "res://" + original_path
		var res: Resource = load(target)
		if res != null:
			res.take_over_path(original_path)
			count += 1
	zr.close()
	return count


func read_mod_config(path: String) -> ConfigFile:
	_last_mod_txt_status = "none"
	_last_mod_txt_error = ""
	var zr := ZIPReader.new()
	if zr.open(path) != OK:
		return null
	if not zr.file_exists("mod.txt"):
		for f: String in zr.get_files():
			if f.get_file() == "mod.txt":
				_last_mod_txt_status = "nested:" + f
				zr.close()
				return null
		zr.close()
		return null
	var raw := zr.read_file("mod.txt")
	zr.close()
	if raw.size() == 0:
		_last_mod_txt_status = "parse_error"
		return null
	var text := raw.get_string_from_utf8()
	var cfg := _parse_mod_txt(text)
	if cfg == null:
		_last_mod_txt_status = "parse_error"
		return null
	_last_mod_txt_status = "ok"
	return cfg

func read_mod_config_folder(folder_path: String) -> ConfigFile:
	_last_mod_txt_status = "none"
	_last_mod_txt_error = ""
	var mod_txt_path := folder_path.path_join("mod.txt")
	if not FileAccess.file_exists(mod_txt_path):
		return null
	var f := FileAccess.open(mod_txt_path, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	var cfg := _parse_mod_txt(text)
	if cfg == null:
		_last_mod_txt_status = "parse_error"
		return null
	_last_mod_txt_status = "ok"
	return cfg

func _parse_mod_txt(text: String) -> ConfigFile:
	_last_mod_txt_error = ""
	if text.begins_with("\uFEFF"):
		text = text.substr(1)
	var preprocessed := _quote_unquoted_hooks_values(text)
	var cfg := ConfigFile.new()
	if cfg.parse(preprocessed) != OK:
		_last_mod_txt_error = _diagnose_parse_failure(preprocessed)
		return null
	for line in text.split("\n"):
		var stripped := line.strip_edges()
		if stripped == "[registry]" and not cfg.has_section("registry"):
			cfg.set_value("registry", "_modloader_header_present", true)
			break
	return cfg

func _quote_unquoted_hooks_values(text: String) -> String:
	var lines := text.split("\n")
	var out := PackedStringArray()
	var in_hooks := false
	for line in lines:
		var stripped := line.strip_edges()
		if stripped.begins_with("[") and stripped.ends_with("]"):
			in_hooks = stripped.to_lower() == "[hooks]"
			out.append(line)
			continue
		if not in_hooks:
			out.append(line)
			continue
		if stripped.is_empty() or stripped.begins_with("#") or stripped.begins_with(";"):
			out.append(line)
			continue
		var eq_pos := line.find("=")
		if eq_pos < 0:
			out.append(line)
			continue
		var key_part := line.substr(0, eq_pos)
		var val_part := line.substr(eq_pos + 1)
		if val_part.strip_edges(true, false).begins_with("\""):
			out.append(line)
			continue
		var comment := ""
		var comment_pos := -1
		for j in val_part.length():
			var ch := val_part[j]
			if ch == "#" or ch == ";":
				comment_pos = j
				break
		if comment_pos >= 0:
			comment = val_part.substr(comment_pos)
			val_part = val_part.substr(0, comment_pos)
		var val_trim := val_part.strip_edges()
		var escaped := val_trim.replace("\\", "\\\\").replace("\"", "\\\"")
		var rebuilt := "%s= \"%s\"" % [key_part, escaped]
		if not comment.is_empty():
			rebuilt += "  " + comment
		out.append(rebuilt)
	return "\n".join(out)

func _diagnose_parse_failure(text: String) -> String:
	var current_section := ""
	var line_num := 0
	for line in text.split("\n"):
		line_num += 1
		var stripped := line.strip_edges()
		if stripped.is_empty() or stripped.begins_with("#") or stripped.begins_with(";"):
			continue
		if stripped.begins_with("[") and stripped.ends_with("]"):
			current_section = stripped.substr(1, stripped.length() - 2)
			continue
		var probe := ConfigFile.new()
		var header := ""
		if current_section != "":
			header = "[%s]\n" % current_section
		if probe.parse(header + line + "\n") != OK:
			var section_label := ("[%s]" % current_section) if current_section != "" else "(no section)"
			return "line %d %s: %s" % [line_num, section_label, _truncate_for_log(stripped)]
	return "could not pin line (full parse failed but per-line probes passed)"

func _truncate_for_log(s: String) -> String:
	if s.length() <= 80:
		return s
	return s.substr(0, 77) + "..."


func zip_folder_to_temp(folder_path: String) -> String:
	var folder_name := folder_path.get_file()
	var tmp_zip_path := ProjectSettings.globalize_path(TMP_DIR).path_join(
			folder_name + "_dev.zip")
	var zp := ZIPPacker.new()
	if zp.open(tmp_zip_path) != OK:
		_log_critical("Failed to create temp zip: " + tmp_zip_path)
		return ""
	_zip_folder_recursive(zp, folder_path, folder_name)
	zp.close()
	return tmp_zip_path

func _zip_folder_recursive(zp: ZIPPacker, disk_path: String, archive_prefix: String) -> void:
	var dir := DirAccess.open(disk_path)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry == "":
			break
		if entry.begins_with("."):
			continue
		var full := disk_path.path_join(entry)
		var arc_path := entry if archive_prefix == "" else archive_prefix.path_join(entry)
		if dir.current_is_dir():
			_zip_folder_recursive(zp, full, arc_path)
		else:
			var data := FileAccess.get_file_as_bytes(full)
			zp.start_file(arc_path)
			zp.write_file(data)
			zp.close_file()
	dir.list_dir_end()


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


const _TEXT_SCAN_EXTS: Dictionary = {
	"gd": true, "tscn": true, "tres": true, "gdshader": true,
}

const _BINARY_SCAN_EXTS: Dictionary = {
	"scn": true, "res": true,
}

const _MAX_FINDINGS_PER_MOD: int = 50

const _MAX_TEXT_SCAN_BYTES: int = 8 * 1024 * 1024

const _SECURITY_RULES: Array = [
	{
		"id": "os_execute",
		"pattern": "\\bOS\\.execute\\s*\\(",
		"description": "Runs a system command via OS.execute.",
		"binary": true,
	},
	{
		"id": "os_create_process",
		"pattern": "\\bOS\\.create_process\\s*\\(",
		"description": "Spawns a process via OS.create_process.",
		"binary": true,
	},
	{
		"id": "os_create_instance",
		"pattern": "\\bOS\\.create_instance\\s*\\(",
		"description": "Spawns another copy of the game via OS.create_instance, with custom CLI args.",
		"binary": true,
	},
	{
		"id": "os_shell_open",
		"pattern": "\\bOS\\.shell_open\\s*\\((?!\\s*\"https?://)",
		"description": "Calls OS.shell_open on a path or URI (not an http(s) URL). The OS handler decides what to launch.",
		"binary": false,
	},
	{
		"id": "os_kill",
		"pattern": "\\bOS\\.kill\\s*\\(",
		"description": "Terminates a process by PID via OS.kill.",
		"binary": true,
	},
	{
		"id": "os_crash",
		"pattern": "\\bOS\\.crash\\s*\\(",
		"description": "Forces an engine crash via OS.crash. Used by malware as anti-debug or to defeat scanners.",
		"binary": true,
	},
	{
		"id": "disable_save_safety",
		"pattern": "\\bOS\\.set_use_file_access_save_and_swap\\s*\\(\\s*false\\b",
		"description": "Disables Godot's atomic-write save protection. No legitimate use in a mod.",
		"binary": true,
	},
	{
		"id": "expression_eval",
		"pattern": "\\bExpression\\.new\\s*\\(",
		"description": "Parses and runs GDScript-flavored code from a string at runtime via Expression.new().",
		"binary": true,
	},
	{
		"id": "script_from_string",
		"pattern": "\\.set_source_code\\s*\\(",
		"description": "Builds a GDScript from a runtime string via .set_source_code(). The source isn't part of the shipped files.",
		"binary": true,
	},
	{
		"id": "deserialize_objects",
		"pattern": "\\b(?:bytes_to_var_with_objects|var_to_bytes_with_objects|str_to_var)\\s*\\(",
		"description": "Uses bytes_to_var_with_objects / str_to_var. These rebuild Object instances from bytes (including any attached scripts).",
		"binary": true,
	},
	{
		"id": "marshalls_objects_decode",
		"pattern": "\\bMarshalls\\.base64_to_variant\\s*\\([^)]*\\btrue\\b",
		"description": "Uses Marshalls.base64_to_variant with allow_objects=true. Reconstructs Object instances from a base64 string.",
		"binary": true,
	},
	{
		"id": "byte_decode_loop",
		"pattern": "for\\s+\\w+\\s+in[^:]{1,200}:[\\s\\S]{0,200}?\\+=\\s*(?:char|String\\.chr)\\s*\\(",
		"description": "Contains a byte-array decode loop (`for c in bytes: acc += char(c)`). This pattern is often used to obfuscate string literals.",
		"binary": false,
	},
	{
		"id": "large_int_array",
		"pattern": "\\[\\s*\\d+(?:\\s*,\\s*\\d+){15,}",
		"description": "Contains a large integer literal (16+ entries). Often appears alongside obfuscated string-decoding loops.",
		"binary": false,
	},
]

const RISK_CLEAN := 0
const RISK_RED := 2

const _RED_SOLO_RULES: Dictionary = {
	"os_crash": true,
	"disable_save_safety": true,
}

const _PROCESS_SPAWN_RULES: Array = [
	"os_execute", "os_create_process", "os_create_instance",
	"os_shell_open", "os_kill",
]
const _OBFUSCATION_RULES: Array = [
	"byte_decode_loop", "large_int_array",
]
const _RUNTIME_CODE_RULES: Array = [
	"script_from_string", "marshalls_objects_decode",
	"deserialize_objects", "expression_eval",
]

func compute_risk_level(findings: Array) -> int:
	if findings.is_empty():
		return RISK_CLEAN
	var present: Dictionary = {}
	for f: Dictionary in findings:
		present[str(f.get("rule", ""))] = true
	for solo in _RED_SOLO_RULES:
		if present.has(solo):
			return RISK_RED
	if present.has("byte_decode_loop") and present.has("large_int_array"):
		return RISK_RED
	var has_obf := _any_present(present, _OBFUSCATION_RULES)
	var has_spawn := _any_present(present, _PROCESS_SPAWN_RULES)
	var has_runtime := _any_present(present, _RUNTIME_CODE_RULES)
	if has_obf and has_spawn:
		return RISK_RED
	if has_runtime and has_spawn:
		return RISK_RED
	return RISK_CLEAN

func _any_present(present: Dictionary, rules: Array) -> bool:
	for r in rules:
		if present.has(r):
			return true
	return false

var _security_compiled: Dictionary = {}

func _security_compile_rules() -> void:
	if not _security_compiled.is_empty():
		return
	for rule: Dictionary in _SECURITY_RULES:
		var re := RegEx.new()
		if re.compile(str(rule["pattern"])) == OK:
			_security_compiled[rule["id"]] = re
		else:
			_log_warning("[SecurityScan] Failed to compile rule pattern: " + str(rule["id"]))

func scan_mod(full_path: String, ext: String) -> Array:
	_security_compile_rules()
	var findings: Array = []
	match ext:
		"vmz", "zip":
			_security_scan_zip(full_path, findings)
		"pck":
			_security_scan_pck(full_path, findings)
		"folder":
			_security_scan_folder(full_path, "", findings)
	findings.sort_custom(_security_sort_findings)
	return findings

func _security_sort_findings(a: Dictionary, b: Dictionary) -> bool:
	var fa: String = a.get("file", "")
	var fb: String = b.get("file", "")
	if fa != fb:
		return fa < fb
	return int(a.get("line", 0)) < int(b.get("line", 0))

func _security_scan_zip(zip_path: String, findings: Array) -> void:
	var zr := ZIPReader.new()
	if zr.open(zip_path) != OK:
		return
	for f: String in zr.get_files():
		if findings.size() >= _MAX_FINDINGS_PER_MOD:
			break
		if f == "mod.txt" or f.ends_with("/mod.txt"):
			continue
		var ext := f.get_extension().to_lower()
		if _TEXT_SCAN_EXTS.has(ext):
			var bytes := zr.read_file(f)
			if bytes.size() > _MAX_TEXT_SCAN_BYTES:
				continue
			_security_scan_text(f, bytes.get_string_from_utf8(), findings)
			continue
		if _BINARY_SCAN_EXTS.has(ext) or ext == "gdc":
			_security_scan_binary(f, zr.read_file(f), findings)
	zr.close()

func _security_scan_folder(root: String, rel: String, findings: Array) -> void:
	var dir := DirAccess.open(root.path_join(rel))
	if dir == null:
		return
	dir.list_dir_begin()
	while findings.size() < _MAX_FINDINGS_PER_MOD:
		var entry := dir.get_next()
		if entry == "":
			break
		if entry.begins_with("."):
			continue
		var rel_path := entry if rel == "" else rel.path_join(entry)
		if dir.current_is_dir():
			_security_scan_folder(root, rel_path, findings)
			continue
		if entry == "mod.txt":
			continue
		var ext := entry.get_extension().to_lower()
		var disk_path := root.path_join(rel_path)
		if _TEXT_SCAN_EXTS.has(ext):
			var bytes := FileAccess.get_file_as_bytes(disk_path)
			if bytes.size() > _MAX_TEXT_SCAN_BYTES:
				continue
			_security_scan_text(rel_path, bytes.get_string_from_utf8(), findings)
			continue
		if _BINARY_SCAN_EXTS.has(ext) or ext == "gdc":
			_security_scan_binary(rel_path,
					FileAccess.get_file_as_bytes(disk_path), findings)
	dir.list_dir_end()

func _security_scan_pck(pck_path: String, findings: Array) -> void:
	var entries := _security_pck_list_with_offsets(pck_path)
	if entries.is_empty():
		return
	var f := FileAccess.open(pck_path, FileAccess.READ)
	if f == null:
		return
	for entry: Dictionary in entries:
		if findings.size() >= _MAX_FINDINGS_PER_MOD:
			break
		var path: String = entry["path"]
		var ext := path.get_extension().to_lower()
		if not (_TEXT_SCAN_EXTS.has(ext) or _BINARY_SCAN_EXTS.has(ext) or ext == "gdc"):
			continue
		f.seek(int(entry["offset"]))
		var bytes := f.get_buffer(int(entry["size"]))
		if _TEXT_SCAN_EXTS.has(ext):
			if bytes.size() > _MAX_TEXT_SCAN_BYTES:
				continue
			_security_scan_text(path, bytes.get_string_from_utf8(), findings)
		else:
			_security_scan_binary(path, bytes, findings)
	f.close()

func _security_scan_text(file: String, text: String, findings: Array) -> void:
	if text.is_empty():
		return
	var stripped := _strip_gdscript_comments(text)
	var orig_lines := text.split("\n")
	for rule: Dictionary in _SECURITY_RULES:
		if findings.size() >= _MAX_FINDINGS_PER_MOD:
			return
		var re: RegEx = _security_compiled.get(rule["id"], null)
		if re == null:
			continue
		var m := re.search(stripped)
		if m == null:
			continue
		var pre := stripped.substr(0, m.get_start())
		var line := pre.count("\n") + 1
		var preview := ""
		if line - 1 < orig_lines.size():
			preview = (orig_lines[line - 1] as String).strip_edges()
			if preview.length() > 120:
				preview = preview.substr(0, 117) + "..."
		findings.append({
			"rule": rule["id"],
			"file": file,
			"line": line,
			"preview": preview,
			"description": rule["description"],
		})

func _strip_gdscript_comments(text: String) -> String:
	if text.is_empty():
		return text
	var out := PackedStringArray()
	for line in text.split("\n"):
		out.append(_strip_line_comment(line))
	return "\n".join(out)

func _strip_line_comment(line: String) -> String:
	var in_str := ""
	var prev := ""
	for i in line.length():
		var c := line[i]
		if in_str != "":
			if c == in_str and prev != "\\":
				in_str = ""
		elif c == "\"" or c == "'":
			in_str = c
		elif c == "#":
			return line.substr(0, i)
		prev = c
	return line

func _security_scan_binary(file: String, bytes: PackedByteArray, findings: Array) -> void:
	if bytes.is_empty():
		return
	var as_text := bytes.get_string_from_utf8()
	if as_text.is_empty():
		var out := PackedByteArray()
		for b in bytes:
			if b >= 32 and b < 127:
				out.append(b)
			else:
				out.append(0x20)
		as_text = out.get_string_from_ascii()
	for rule: Dictionary in _SECURITY_RULES:
		if not bool(rule.get("binary", false)):
			continue
		if findings.size() >= _MAX_FINDINGS_PER_MOD:
			return
		var re: RegEx = _security_compiled.get(rule["id"], null)
		if re == null:
			continue
		if re.search(as_text) == null:
			continue
		findings.append({
			"rule": rule["id"],
			"file": file,
			"line": 0,
			"preview": "(matched in binary file)",
			"description": rule["description"],
		})

func _security_pck_list_with_offsets(pck_path: String) -> Array:
	const MAGIC_GDPC: int = 0x43504447
	const PACK_DIR_ENCRYPTED := 1
	const PACK_FORMAT_V2 := 2
	const PACK_FORMAT_V3 := 3
	var result: Array = []
	var f := FileAccess.open(pck_path, FileAccess.READ)
	if f == null:
		return result
	var magic: int = f.get_32()
	if magic != MAGIC_GDPC:
		f.close()
		return result
	var version: int = f.get_32()
	if version < PACK_FORMAT_V2 or version > PACK_FORMAT_V3:
		f.close()
		return result
	f.get_32(); f.get_32(); f.get_32()
	var pack_flags: int = f.get_32()
	f.get_64()
	if version == PACK_FORMAT_V3:
		f.seek(f.get_64())
	else:
		for i in 16:
			f.get_32()
	if pack_flags & PACK_DIR_ENCRYPTED:
		f.close()
		return result
	var file_count: int = f.get_32()
	for i in file_count:
		var path_len: int = f.get_32()
		if path_len == 0 or path_len > 4096:
			break
		var path := f.get_buffer(path_len).get_string_from_utf8()
		var offset: int = f.get_64()
		var size: int = f.get_64()
		f.get_buffer(16)
		f.get_32()
		if not path.is_empty():
			result.append({"path": path, "offset": offset, "size": size})
	f.close()
	return result


func collect_mod_metadata() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	_mods_dir = OS.get_executable_path().get_base_dir().path_join(MOD_DIR)
	_log_info("Scanning mods dir: " + _mods_dir)
	DirAccess.make_dir_recursive_absolute(_mods_dir)
	var dir := DirAccess.open(_mods_dir)
	if dir == null:
		_log_critical("Failed to open mods dir: " + _mods_dir
				+ " (error " + str(DirAccess.get_open_error()) + ")")
		return entries
	var seen: Dictionary = {}
	var skipped_files: Array[String] = []
	_hidden_folder_profile_keys.clear()
	_hidden_folder_ids.clear()
	dir.list_dir_begin()
	while true:
		var entry_name := dir.get_next()
		if entry_name == "":
			break
		if dir.current_is_dir():
			if entry_name.begins_with("."):
				continue
			if _developer_mode:
				if not seen.has(entry_name):
					seen[entry_name] = true
					entries.append(_build_folder_entry(_mods_dir, entry_name))
			else:
				_record_hidden_folder(_mods_dir, entry_name)
			continue
		var ext := entry_name.get_extension().to_lower()
		if ext not in ["vmz", "zip", "pck"]:
			skipped_files.append(entry_name)
			continue
		if seen.has(entry_name):
			continue
		seen[entry_name] = true
		entries.append(_build_archive_entry(_mods_dir, entry_name, ext))
	dir.list_dir_end()
	if skipped_files.size() > 0:
		_log_debug("Skipped " + str(skipped_files.size()) + " non-mod file(s) in mods dir:")
		for sf in skipped_files:
			_log_debug("  " + sf + "  (not .vmz/.pck)")
	entries = _dedupe_by_mod_id(entries)
	if entries.size() == 0:
		_log_warning("No mods found in: " + _mods_dir)
	else:
		_log_info("Found " + str(entries.size()) + " mod(s):")
		for e in entries:
			var tag := " [folder]" if e["ext"] == "folder" else ""
			_log_info("  " + e["file_name"] + " (" + e["mod_name"] + ")" + tag)
	return entries

func _build_archive_entry(mods_dir: String, file_name: String, ext: String) -> Dictionary:
	_log_info("[ModScan] inspecting " + file_name)
	var full_path := mods_dir.path_join(file_name)
	if ext == "pck":
		_last_mod_txt_status = "pck"
	var cfg: ConfigFile = read_mod_config(full_path) if ext != "pck" else null
	var entry := _entry_from_config(cfg, file_name, full_path, ext)
	entry["warnings"] = _build_entry_warnings(entry)
	entry["security_findings"] = scan_mod(full_path, ext)
	entry["risk_level"] = compute_risk_level(entry["security_findings"])
	_log_security_findings(entry)
	return entry

func _build_folder_entry(mods_dir: String, dir_name: String) -> Dictionary:
	_log_info("[ModScan] inspecting " + dir_name + " [folder]")
	var folder_path := mods_dir.path_join(dir_name)
	var cfg: ConfigFile = read_mod_config_folder(folder_path)
	var entry := _entry_from_config(cfg, dir_name, folder_path, "folder")
	entry["warnings"] = _build_entry_warnings(entry)
	entry["security_findings"] = scan_mod(folder_path, "folder")
	entry["risk_level"] = compute_risk_level(entry["security_findings"])
	_log_security_findings(entry)
	return entry

func _record_hidden_folder(mods_dir: String, dir_name: String) -> void:
	var folder_path := mods_dir.path_join(dir_name)
	var cfg: ConfigFile = read_mod_config_folder(folder_path)
	var entry := _entry_from_config(cfg, dir_name, folder_path, "folder")
	_hidden_folder_profile_keys[entry["profile_key"]] = true
	if not entry["profile_key"].begins_with("zip:"):
		_hidden_folder_ids[entry["mod_id"]] = true

func _log_security_findings(entry: Dictionary) -> void:
	var findings: Array = entry.get("security_findings", [])
	if findings.is_empty():
		return
	_log_debug("[ModScan] %s uses %d notable API(s)" \
			% [entry["file_name"], findings.size()])
	for f: Dictionary in findings:
		var loc: String = f["file"]
		if int(f.get("line", 0)) > 0:
			loc += ":" + str(f["line"])
		_log_debug("  %s @ %s -- %s" \
				% [f["rule"], loc, f.get("preview", "")])

func _entry_from_config(cfg: ConfigFile, file_name: String, full_path: String, ext: String) -> Dictionary:
	var mod_name := file_name
	var mod_id   := file_name
	var version  := ""
	var author   := ""
	var priority := 0
	var has_mod_id := false

	var base_name := file_name.get_basename()
	var filename_priority := 0
	var has_filename_priority := false
	if _re_filename_priority:
		var m := _re_filename_priority.search(base_name)
		if m:
			filename_priority = int(m.get_string(1))
			base_name = m.get_string(2)
			has_filename_priority = true
			mod_name = base_name
			mod_id   = base_name

	if cfg:
		mod_name = str(cfg.get_value("mod", "name", mod_name))
		if cfg.has_section_key("mod", "id"):
			mod_id = str(cfg.get_value("mod", "id"))
			has_mod_id = true
		version = str(cfg.get_value("mod", "version", ""))
		author = str(cfg.get_value("mod", "author", ""))
		if cfg.has_section_key("mod", "priority"):
			priority = int(str(cfg.get_value("mod", "priority")))
		elif has_filename_priority:
			priority = filename_priority
	elif has_filename_priority:
		priority = filename_priority
	priority = clampi(priority, PRIORITY_MIN, PRIORITY_MAX)

	var profile_key := ("zip:" + file_name) if not has_mod_id else (mod_id + "@" + version)

	var entry := {
		"file_name": file_name, "full_path": full_path, "ext": ext,
		"mod_name": mod_name, "mod_id": mod_id, "version": version,
		"author": author,
		"profile_key": profile_key,
		"priority": priority, "enabled": true,
		"cfg": cfg, "mod_txt_status": _last_mod_txt_status,
		"mod_txt_error": _last_mod_txt_error,
	}
	return entry

func _build_entry_warnings(entry: Dictionary) -> Array[String]:
	var warnings: Array[String] = []
	var ext: String = entry["ext"]
	if ext == "pck" or ext == "folder":
		return warnings
	var status: String = entry.get("mod_txt_status", "none")
	if status == "none":
		warnings.append("Invalid mod -- may not work correctly. Reinstall the mod.")
	elif status == "parse_error":
		var detail: String = entry.get("mod_txt_error", "")
		if detail.is_empty():
			warnings.append("Invalid mod -- mod.txt failed to parse. Reinstall the mod.")
		else:
			warnings.append("mod.txt parse error at " + detail)
	elif status.begins_with("nested:"):
		warnings.append("Invalid mod -- packaged incorrectly. Reinstall the mod.")
	return warnings



func _compare_load_order(a: Dictionary, b: Dictionary) -> bool:
	if a["priority"] != b["priority"]:
		return a["priority"] < b["priority"]
	var a_name := (a["mod_name"] as String).to_lower()
	var b_name := (b["mod_name"] as String).to_lower()
	if a_name != b_name:
		return a_name < b_name
	return (a["file_name"] as String).to_lower() < (b["file_name"] as String).to_lower()

func compare_versions(a: String, b: String) -> int:
	if a.is_empty() or b.is_empty():
		return 0 if a == b else (-1 if a.is_empty() else 1)
	var pa := a.lstrip("vV").split(".")
	var pb := b.lstrip("vV").split(".")
	var n: int = max(pa.size(), pb.size())
	for i in n:
		var sa := pa[i] if i < pa.size() else "0"
		var sb := pb[i] if i < pb.size() else "0"
		var va := int(sa) if sa.is_valid_int() else 0
		var vb := int(sb) if sb.is_valid_int() else 0
		if va < vb: return -1
		if va > vb: return 1
	return 0

func _dedupe_by_mod_id(entries: Array[Dictionary]) -> Array[Dictionary]:
	var groups: Dictionary = {}
	for e in entries:
		var pk: String = str(e.get("profile_key", ""))
		if e["ext"] == "pck" or pk.begins_with("zip:"):
			continue
		var mid: String = str(e["mod_id"])
		if not groups.has(mid):
			groups[mid] = []
		(groups[mid] as Array).append(e)

	var winners_by_id: Dictionary = {}
	for mid in groups.keys():
		var members: Array = groups[mid]
		if members.size() == 1:
			winners_by_id[mid] = members[0]
			continue
		members.sort_custom(_compare_dedup_priority)
		var winner: Dictionary = members[0]
		var hidden: Array[Dictionary] = []
		var w_v: String = ("v" + str(winner["version"])) if str(winner["version"]) != "" else "(unversioned)"
		for j in range(1, members.size()):
			var loser: Dictionary = members[j]
			hidden.append({"file_name": loser["file_name"], "version": loser["version"]})
			var l_v: String = ("v" + str(loser["version"])) if str(loser["version"]) != "" else "(unversioned)"
			_log_warning("Duplicate mod_id '" + mid + "' detected: keeping "
					+ str(winner["file_name"]) + " (" + w_v + "), hiding "
					+ str(loser["file_name"]) + " (" + l_v + ")")
		winner["duplicates_hidden"] = hidden
		winners_by_id[mid] = winner

	var seen_ids: Dictionary = {}
	var out: Array[Dictionary] = []
	for e in entries:
		var pk: String = str(e.get("profile_key", ""))
		if e["ext"] == "pck" or pk.begins_with("zip:"):
			out.append(e)
			continue
		var mid: String = str(e["mod_id"])
		if seen_ids.has(mid):
			continue
		seen_ids[mid] = true
		out.append(winners_by_id[mid])
	return out

func _compare_dedup_priority(a: Dictionary, b: Dictionary) -> bool:
	var vc := compare_versions(str(a.get("version", "")), str(b.get("version", "")))
	if vc != 0:
		return vc > 0
	var am: int = FileAccess.get_modified_time(str(a["full_path"]))
	var bm: int = FileAccess.get_modified_time(str(b["full_path"]))
	if am != bm:
		return am > bm
	return (a["file_name"] as String).to_lower() < (b["file_name"] as String).to_lower()


func load_all_mods(pass_label: String = "") -> void:
	_pending_autoloads.clear()
	_loaded_mod_ids.clear()
	_registered_autoload_names.clear()
	_override_registry.clear()
	_report_lines.clear()
	_mod_script_analysis.clear()
	_archive_file_sets.clear()
	_hooks.clear()
	_pending_script_overrides.clear()
	_applied_script_overrides.clear()
	_hooked_methods.clear()
	_any_mod_declared_registry = false

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP_DIR))

	var candidates: Array[Dictionary] = []
	for entry in _ui_mod_entries:
		if not entry["enabled"]:
			continue
		candidates.append(entry.duplicate())
	candidates.sort_custom(_compare_load_order)

	if candidates.is_empty():
		_log_info("No mods enabled.")
		return

	for i in range(1, candidates.size()):
		if (candidates[i]["mod_name"] as String).to_lower() \
				== (candidates[i - 1]["mod_name"] as String).to_lower():
			_log_warning("Duplicate mod name '" + candidates[i]["mod_name"]
					+ "' -- archives '" + candidates[i - 1]["file_name"]
					+ "' and '" + candidates[i]["file_name"]
					+ "'. Load order tie broken by archive filename.")

	var header := "=== Load Order" + (" (" + pass_label + ")" if pass_label != "" else "") + " ==="
	_log_info(header)
	for i in candidates.size():
		var c: Dictionary = candidates[i]
		_log_info("  [" + str(i + 1) + "] " + c["mod_name"] + " | " + c["file_name"]
				+ " [priority=" + str(c["priority"]) + "]")
	_log_info("=" .repeat(header.length()))

	for load_index in candidates.size():
		_process_mod_candidate(candidates[load_index], load_index)

	_merge_hook_calls_into_wrap_mask()

func _merge_hook_calls_into_wrap_mask() -> void:
	if _mod_script_analysis.is_empty():
		return
	var prefix_to_path: Dictionary = {}
	for cn: String in _class_name_to_path:
		var p: String = _class_name_to_path[cn]
		prefix_to_path[p.get_file().get_basename().to_lower()] = p
	for sp: String in _all_game_script_paths:
		var key := sp.get_file().get_basename().to_lower()
		if not prefix_to_path.has(key):
			prefix_to_path[key] = sp
	for mod_name: String in _mod_script_analysis:
		var analysis: Dictionary = _mod_script_analysis[mod_name]
		for entry: Dictionary in (analysis.get("hook_calls", []) as Array):
			var prefix: String = entry["prefix"]
			var method: String = entry["method"]
			if not prefix_to_path.has(prefix):
				_log_warning("[Hooks] %s calls .hook(\"%s-%s-...\") but no vanilla script matches prefix '%s' -- check spelling, or declare the path in [hooks] in mod.txt" \
						% [mod_name, prefix, method, prefix])
				continue
			var path: String = prefix_to_path[prefix]
			if not _hooked_methods.has(path):
				_hooked_methods[path] = {}
			(_hooked_methods[path] as Dictionary)[method.to_lower()] = true

func _process_mod_candidate(c: Dictionary, load_index: int) -> void:
	var file_name: String = c["file_name"]
	var full_path: String = c["full_path"]
	var ext:       String = c["ext"]
	var mod_name:  String = c["mod_name"]
	var mod_id:    String = c["mod_id"]
	var cfg               = c["cfg"]

	_log_info("--- [" + str(load_index + 1) + "] " + mod_name + " (" + file_name + ")")

	if ext != "pck" and _loaded_mod_ids.has(mod_id):
		_log_warning("Duplicate mod id '" + mod_id + "' -- skipped: " + file_name)
		return

	var mount_path := full_path
	if ext == "folder":
		mount_path = zip_folder_to_temp(full_path)
		if mount_path == "":
			_log_critical("Failed to zip folder: " + file_name)
			return

	if _filescope_mounted.has(full_path):
		_log_debug("  File-scope mount active -- skipping re-mount")
		_log_debug("  Mount path: " + mount_path)
	elif not _try_mount_pack(mount_path):
		_log_critical("Failed to mount: " + file_name + " (path: " + mount_path + ")")
		return
	else:
		_log_debug("  Mounted OK")
		_log_debug("  Mount path: " + mount_path)

	if ext != "pck":
		var scan_path := mount_path if ext == "folder" else full_path
		scan_and_register_archive_claims(scan_path, mod_name, file_name, load_index)

	if ext == "pck" or cfg == null:
		if cfg == null and ext != "pck":
			var status: String = c.get("mod_txt_status", "none")
			if status.begins_with("nested:"):
				_log_warning("  Invalid mod -- packaged incorrectly (nested mod.txt at " + status.substr(7) + ")")
			elif status == "parse_error":
				var detail: String = c.get("mod_txt_error", "")
				if detail.is_empty():
					_log_warning("  Invalid mod -- mod.txt failed to parse")
				else:
					_log_warning("  Invalid mod -- mod.txt parse error at " + detail)
			else:
				_log_warning("  No mod.txt -- autoloads skipped")
		return

	_loaded_mod_ids[mod_id] = {
		"mod_id":    mod_id,
		"mod_name":  mod_name,
		"version":   String(c.get("version", "")),
		"file_name": file_name,
		"priority":  int(c.get("priority", 0)),
	}

	if cfg != null and cfg.has_section("hooks"):
		for key in cfg.get_section_keys("hooks"):
			var script_path := _canonical_hook_script_path(str(key).strip_edges())
			var methods_str := str(cfg.get_value("hooks", key, "")).strip_edges()
			if script_path.is_empty():
				continue
			if not _hooked_methods.has(script_path):
				_hooked_methods[script_path] = {}
			var specific_methods: Array[String] = []
			var has_wildcard := methods_str == ""
			for raw_method in methods_str.split(","):
				var method_name: String = raw_method.strip_edges()
				if method_name == "":
					continue
				if method_name == "*":
					has_wildcard = true
					continue
				specific_methods.append(method_name)
			if has_wildcard:
				if not specific_methods.is_empty():
					_log_warning("  [hooks] %s mixes '*' with specific methods (%s); '*' wins, all methods wrapped [%s]" \
							% [script_path, ", ".join(specific_methods), mod_name])
				else:
					_log_info("  Hooks declared: %s :: * (all methods) [%s]" % [script_path, mod_name])
				continue
			for method_name in specific_methods:
				(_hooked_methods[script_path] as Dictionary)[method_name.to_lower()] = true
				_log_info("  Hook declared: %s :: %s [%s]" % [script_path, method_name, mod_name])

	if cfg != null and cfg.has_section("registry"):
		_any_mod_declared_registry = true
		_log_info("  Registry section declared [%s] -- generic registry facade active" % mod_name)

	var _extend_sections: Array[String] = ["script_extend", "script_overrides"]
	if cfg != null:
		for section in _extend_sections:
			if not cfg.has_section(section):
				continue
			for key in cfg.get_section_keys(section):
				var vanilla_path := str(key).strip_edges()
				var mod_script_path := str(cfg.get_value(section, key)).strip_edges()
				if vanilla_path.is_empty() or mod_script_path.is_empty():
					_log_warning("  Empty [%s] entry -- skipped" % section)
					continue
				_pending_script_overrides.append({
					"vanilla_path": vanilla_path,
					"mod_script_path": mod_script_path,
					"mod_name": mod_name,
					"priority": c.get("priority", 0),
				})
				_log_info("  [%s] %s -> %s" % [section, vanilla_path, mod_script_path])

	if cfg == null or not cfg.has_section("autoload"):
		return

	var keys: PackedStringArray = cfg.get_section_keys("autoload")
	for key in keys:
		var autoload_name := str(key)
		var raw_path := str(cfg.get_value("autoload", key)).lstrip("*").strip_edges()
		var is_early := raw_path.begins_with("!")
		if is_early:
			raw_path = raw_path.lstrip("!")
		var res_path := raw_path

		if res_path == "":
			_log_warning("  Empty autoload path for '" + autoload_name + "' -- skipped")
			continue

		if _registered_autoload_names.has(autoload_name):
			_log_warning("Duplicate autoload name '" + autoload_name + "' -- skipped")
			continue
		_registered_autoload_names[autoload_name] = true

		if _archive_file_sets.has(file_name) and not _archive_file_sets[file_name].has(res_path):
			_log_critical("  Autoload path not found in archive: " + res_path)
			_log_critical("    Declared in mod.txt but missing from: " + file_name)
			var similar: Array[String] = []
			var target_file := res_path.get_file().to_lower()
			for p: String in _archive_file_sets[file_name]:
				if p.get_file().to_lower() == target_file:
					similar.append(p)
			if similar.size() > 0:
				_log_critical("    Similar paths in archive: " + ", ".join(similar))
			continue

		_pending_autoloads.append({
			"mod_name": mod_name, "name": autoload_name, "path": res_path,
			"is_early": is_early,
		})
		var early_tag := " [EARLY]" if is_early else ""
		_log_debug("  Autoload queued: " + autoload_name + " -> " + res_path + early_tag)
		_register_claim(res_path, mod_name, file_name, load_index)



func _register_claim(res_path: String, mod_name: String, archive: String,
		load_index: int) -> void:
	if not _override_registry.has(res_path):
		_override_registry[res_path] = []
	for existing in _override_registry[res_path]:
		if existing["mod_name"] == mod_name and existing["archive"] == archive:
			return
	_override_registry[res_path].append({
		"mod_name": mod_name, "archive": archive, "load_index": load_index,
	})


func _apply_script_overrides() -> void:
	if _pending_script_overrides.is_empty():
		return
	_pending_script_overrides.sort_custom(func(a, b): return a["priority"] < b["priority"])
	var applied := 0
	for entry in _pending_script_overrides:
		var vanilla_path: String = entry["vanilla_path"]
		var mod_path: String = entry["mod_script_path"]
		var mod_name: String = entry["mod_name"]

		var src_script := load(mod_path) as GDScript
		if src_script == null:
			_log_critical("[Overrides] Failed to load: %s [%s]" % [mod_path, mod_name])
			continue
		var source := src_script.source_code
		if source.is_empty():
			_log_critical("[Overrides] Empty source: %s [%s]" % [mod_path, mod_name])
			continue

		var normalized: String = source.replace("\r\n", "\n").replace("\r", "\n")
		var af := _rtv_autofix_legacy_syntax(normalized)
		var fixed_src: String = af["source"]
		var af_total: int = int(af["bodyless"]) + int(af["tool"]) + int(af["onready"]) \
				+ int(af["export"]) + int(af.get("base", 0))
		if af_total > 0:
			_log_info("[Overrides] Autofix %s: %d bodyless, %d tool, %d onready, %d export, %d base() -> super" \
					% [mod_path, af["bodyless"], af["tool"], af["onready"], af["export"], af.get("base", 0)])

		var new_script := GDScript.new()
		new_script.source_code = fixed_src
		var err := new_script.reload()
		if err != OK:
			_log_critical("[Overrides] Compile failed for %s (error %d) [%s]" % [mod_path, err, mod_name])
			continue
		new_script.take_over_path(vanilla_path)
		_applied_script_overrides[vanilla_path] = true
		applied += 1
		_log_info("[Overrides] Applied: %s -> %s [%s]" % [vanilla_path, mod_path, mod_name])
	if applied > 0:
		_log_info("[Overrides] Applied %d script override(s)" % applied)

func scan_and_register_archive_claims(archive_path: String, mod_name: String,
		archive_file: String, load_index: int) -> void:
	var zr := ZIPReader.new()
	if zr.open(archive_path) != OK:
		_log_warning("  Could not scan archive: " + archive_file)
		return

	var files := zr.get_files()

	var backslash_count := 0
	var example_bad := ""
	for f: String in files:
		if "\\" in f:
			backslash_count += 1
			if example_bad == "":
				example_bad = f
	if backslash_count > 0:
		_log_critical("  BAD ZIP: " + str(backslash_count) + " entries use Windows backslash paths.")
		_log_critical("    Re-pack with 7-Zip. Example bad entry: '" + example_bad + "'")

	var tracked_count := 0
	var path_set: Dictionary = {}
	var gd_analysis: Dictionary = {
		"take_over_literal_paths": [],
		"extends_paths":           [],
		"uses_dynamic_override":   false,
		"lifecycle_no_super":      [],
		"calls_update_tooltip":    false,
		"class_names":             [],
		"extends_class_names":     [],
		"override_methods":        {},
		"preload_paths":           [],
		"calls_base":              false,
		"total_gd_files":          0,
		"hook_calls":              [],
	}

	for f in files:
		if f.get_extension().to_lower() == "gd":
			gd_analysis["total_gd_files"] = gd_analysis["total_gd_files"] + 1
			var gd_bytes := zr.read_file(f)
			if gd_bytes.size() > 0:
				var gd_text := gd_bytes.get_string_from_utf8()
				_scan_gd_source(gd_text, gd_analysis)
				if _class_name_to_path.size() > 0:
					_check_class_name_safety(gd_text, f, mod_name)

		var res_path := _normalize_to_res_path(f)
		if res_path == "" and f.ends_with(".remap"):
			res_path = _normalize_to_res_path(f.trim_suffix(".remap"))
		if res_path == "":
			continue

		path_set[res_path] = true
		tracked_count += 1
		_register_claim(res_path, mod_name, archive_file, load_index)

	zr.close()
	_mod_script_analysis[mod_name] = gd_analysis
	_archive_file_sets[archive_file] = path_set

	_log_debug("  " + str(tracked_count) + " resource path(s)")

	if gd_analysis["total_gd_files"] > 0:
		var override_count: int = (gd_analysis["take_over_literal_paths"] as Array).size() \
				+ (gd_analysis["extends_paths"] as Array).size()
		var dynamic_tag := " [uses overrideScript()]" if gd_analysis["uses_dynamic_override"] else ""
		_log_debug("  " + str(gd_analysis["total_gd_files"]) + " .gd file(s), "
				+ str(override_count) + " override target(s)" + dynamic_tag)


func _scan_gd_source(text: String, analysis: Dictionary) -> void:
	for m in _re_take_over.search_all(text):
		var path := m.get_string(1)
		if path not in (analysis["take_over_literal_paths"] as Array):
			(analysis["take_over_literal_paths"] as Array).append(path)

	var m_ext := _re_extends.search(text)
	if m_ext:
		var path := m_ext.get_string(1)
		if path not in (analysis["extends_paths"] as Array):
			(analysis["extends_paths"] as Array).append(path)

	var m_ext_cn := _re_extends_classname.search(text)
	if m_ext_cn:
		var cn := m_ext_cn.get_string(1)
		if cn not in (analysis["extends_class_names"] as Array):
			(analysis["extends_class_names"] as Array).append(cn)

	for m_cn in _re_class_name.search_all(text):
		var cn := m_cn.get_string(1)
		if cn not in (analysis["class_names"] as Array):
			(analysis["class_names"] as Array).append(cn)

	if not analysis["uses_dynamic_override"]:
		analysis["uses_dynamic_override"] = "take_over_path(" in text

	if not analysis["calls_update_tooltip"]:
		analysis["calls_update_tooltip"] = "UpdateTooltip" in text

	if not analysis["calls_base"]:
		analysis["calls_base"] = "base(" in text

	for m_pl in _re_preload.search_all(text):
		var pl_path := m_pl.get_string(1)
		if pl_path not in (analysis["preload_paths"] as Array):
			(analysis["preload_paths"] as Array).append(pl_path)

	for m_hk in _re_hook_call.search_all(text):
		var prefix := m_hk.get_string(1).to_lower()
		var method := m_hk.get_string(2)
		var already: bool = false
		for existing: Dictionary in (analysis["hook_calls"] as Array):
			if existing["prefix"] == prefix and existing["method"] == method:
				already = true
				break
		if not already:
			(analysis["hook_calls"] as Array).append({"prefix": prefix, "method": method})

	var func_matches := _re_func.search_all(text)

	var ext_target := ""
	if m_ext:
		ext_target = m_ext.get_string(1)

	for i in func_matches.size():
		var func_name := func_matches[i].get_string(1)

		if ext_target != "":
			if not (analysis["override_methods"] as Dictionary).has(ext_target):
				(analysis["override_methods"] as Dictionary)[ext_target] = []
			var method_list: Array = (analysis["override_methods"] as Dictionary)[ext_target]
			if func_name not in method_list:
				method_list.append(func_name)

		if ext_target == "":
			continue
		const _LIFECYCLE := ["_ready", "_process", "_physics_process",
				"_input", "_unhandled_input", "_unhandled_key_input"]
		if func_name not in _LIFECYCLE:
			continue
		var body_start := func_matches[i].get_end()
		var body_end := text.length() if i + 1 >= func_matches.size() \
				else func_matches[i + 1].get_start()
		var body := text.substr(body_start, body_end - body_start)
		if "super(" not in body and "super." not in body:
			if func_name not in (analysis["lifecycle_no_super"] as Array):
				(analysis["lifecycle_no_super"] as Array).append(func_name)

func _check_class_name_safety(text: String, file_path: String, mod_name: String) -> void:
	for m_cn in _re_class_name.search_all(text):
		var cn := m_cn.get_string(1)
		if _class_name_to_path.has(cn):
			var res_path := _normalize_to_res_path(file_path)
			var game_path: String = _class_name_to_path[cn]
			if res_path != game_path:
				_log_critical("  CONFLICT: %s re-declares class_name %s (game has it at %s)" % [file_path, cn, game_path])
	for m_to in _re_take_over.search_all(text):
		var to_path := m_to.get_string(1)
		for cn: String in _class_name_to_path:
			if _class_name_to_path[cn] == to_path:
				_log_critical("  DANGER: %s calls take_over_path on class_name script %s (%s) -- this will crash" % [file_path, to_path, cn])
				break



func _instantiate_autoload(mod_name: String, autoload_name: String, res_path: String) -> void:
	var resource: Resource = load(res_path)
	if resource == null:
		_log_critical("Autoload failed: %s -> %s [%s]" % [autoload_name, res_path, mod_name])
		if _developer_mode:
			_log_debug("  FileAccess=%s  ResourceLoader=%s"
					% [str(FileAccess.file_exists(res_path)), str(ResourceLoader.exists(res_path))])
		return

	if get_tree().root.has_node(autoload_name):
		_log_warning("Autoload name '" + autoload_name + "' conflicts with existing node at /root/"
				+ autoload_name + " -- Godot will rename it. [" + mod_name + "]")

	if resource is PackedScene:
		var instance: Node = (resource as PackedScene).instantiate()
		if instance == null:
			_log_critical("PackedScene.instantiate() returned null: " + autoload_name
					+ " -> " + res_path + " [" + mod_name + "]")
			return
		instance.name = autoload_name
		get_tree().root.add_child(instance)
		_log_debug("Autoload instantiated (scene): " + autoload_name + " [" + mod_name + "]")
		return

	if resource is GDScript:
		var gdscript := resource as GDScript
		if not gdscript.can_instantiate():
			_log_critical("Autoload script failed to compile: " + autoload_name
					+ " -> " + res_path + " [" + mod_name + "]")
			_log_critical("  can_instantiate() returned false. Check the Godot log above for parse errors.")
			return
		var inst: Variant = gdscript.new()
		if inst == null:
			_log_warning("Autoload script returned null: " + autoload_name)
			return
		if inst is Node:
			(inst as Node).name = autoload_name
			get_tree().root.add_child(inst as Node)
			_log_debug("Autoload instantiated (script): " + autoload_name + " [" + mod_name + "]")
			return
		_log_warning("Autoload is not a Node -- not added to tree: " + autoload_name
				+ " [" + mod_name + "]")
		return

	_log_warning("Autoload is not a PackedScene or GDScript: " + autoload_name
			+ " -> " + res_path + " [" + mod_name + "]")


func _log_override_timing_warnings() -> void:
	for mod_name: String in _mod_script_analysis:
		var analysis: Dictionary = _mod_script_analysis[mod_name]
		if not analysis["uses_dynamic_override"]:
			continue
		var targets: Array = analysis["extends_paths"]
		if targets.is_empty():
			continue
		var target_list := ", ".join(targets.map(func(p): return (p as String).get_file()))
		_log_debug(mod_name + " uses overrideScript() on: " + target_list
				+ " -- applies after scene reload")


func _verify_script_overrides() -> void:
	var printed_header: bool = false
	for mod_name: String in _mod_script_analysis:
		var analysis: Dictionary = _mod_script_analysis[mod_name]
		if not analysis.get("uses_dynamic_override", false):
			continue
		var targets: Array = analysis.get("extends_paths", [])
		if targets.is_empty():
			continue
		if not printed_header:
			_log_info("[OverrideVerify] === Post-autoload cache check ===")
			printed_header = true
		for vanilla_path in targets:
			var vp: String = String(vanilla_path)
			var scr := load(vp) as Script
			if scr == null:
				_log_warning("[OverrideVerify] %s | %s | FAIL: load() returned null" % [mod_name, vp])
				continue
			var src: String = scr.source_code
			var src_head: String = src.substr(0, 60).replace("\n", " | ").replace("\t", " ")
			_log_info("[OverrideVerify] %s | %s | resource_path=%s src_head=[%s]" \
					% [mod_name, vp, scr.resource_path, src_head])


func _print_conflict_summary() -> void:
	_log_info("")
	_log_info("============================================")
	_log_info("=== OrcKit Compatibility Summary         ===")
	_log_info("============================================")
	_log_info("Mods loaded:  " + str(_loaded_mod_ids.size()))

	var conflicted_paths: Array[String] = []
	for res_path: String in _override_registry:
		var claims: Array = _override_registry[res_path]
		if claims.size() > 1:
			conflicted_paths.append(res_path)

	_log_info("Conflicting resource paths: " + str(conflicted_paths.size()))

	if conflicted_paths.is_empty():
		_log_info("No resource path conflicts -- all mods appear compatible.")
	else:
		_log_info("")
		_log_info("--- Conflicted Paths (last loader wins) ---")
		for res_path in conflicted_paths:
			var claims: Array = _override_registry[res_path]
			var winner: Dictionary = claims[claims.size() - 1]
			_log_warning("CONFLICT: " + res_path)
			for claim in claims:
				var marker := " <-- wins" if claim == winner else ""
				_log_info("    [" + str(claim["load_index"] + 1) + "] "
						+ claim["mod_name"] + " via " + claim["archive"] + marker)

	if not _hooks.is_empty():
		_log_info("")
		_log_info("--- Hook Registrations ---")
		for hook_name: String in _hooks:
			var arr: Array = _hooks[hook_name]
			if arr.size() > 0:
				_log_info("  %s (%d callback(s))" % [hook_name, arr.size()])

	_log_info("============================================")
	_log_info("")

func _write_conflict_report() -> void:
	var f := FileAccess.open(CONFLICT_REPORT_PATH, FileAccess.WRITE)
	if f == null:
		_log_warning("Could not write report to: " + CONFLICT_REPORT_PATH)
		return
	for line in _report_lines:
		f.store_line(line)
	f.close()
	_log_info("Conflict report written to: " + CONFLICT_REPORT_PATH)


func _load_developer_mode_setting() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return
	_developer_mode = bool(cfg.get_value("settings", "developer_mode", false))
	if _developer_mode:
		_log_info("Developer mode: ON")

func _load_ui_config() -> void:
	_active_profile = "Default"
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		_save_ui_config()
		return

	var has_any_profile := false
	for sec: String in cfg.get_sections():
		if sec.begins_with("profile."):
			has_any_profile = true
			break
	if not has_any_profile:
		if cfg.has_section("enabled"):
			for key: String in cfg.get_section_keys("enabled"):
				cfg.set_value("profile.Default.enabled", key, cfg.get_value("enabled", key))
		if cfg.has_section("priority"):
			for key: String in cfg.get_section_keys("priority"):
				cfg.set_value("profile.Default.priority", key, cfg.get_value("priority", key))

	_active_profile = "Default"

	_apply_profile_to_entries(cfg, _active_profile)

	if _active_profile == "Default" and not has_any_profile:
		_save_ui_config()

func _apply_profile_to_entries(cfg: ConfigFile, profile: String) -> void:
	var is_vanilla := profile == VANILLA_PROFILE
	_load_per_profile_settings(cfg, profile)
	var en_sec := "profile." + profile + ".enabled"
	var pr_sec := "profile." + profile + ".priority"
	for entry in _ui_mod_entries:
		var pk: String = entry["profile_key"]
		entry.erase("profile_version_mismatch")
		var resolved_key := ""
		if cfg.has_section_key(en_sec, pk) or cfg.has_section_key(pr_sec, pk):
			resolved_key = pk
		elif not pk.begins_with("zip:"):
			resolved_key = _find_stored_key_for_mod_id(cfg, profile, entry["mod_id"])
			if resolved_key != "" and resolved_key != pk:
				entry["profile_version_mismatch"] = {
					"stored":  _version_from_profile_key(resolved_key),
					"current": entry["version"],
				}
		if is_vanilla:
			entry["enabled"] = false
		elif resolved_key != "" and cfg.has_section_key(en_sec, resolved_key):
			entry["enabled"] = bool(cfg.get_value(en_sec, resolved_key))
		else:
			entry["enabled"] = profile == "Default"
		if resolved_key != "" and cfg.has_section_key(pr_sec, resolved_key):
			entry["priority"] = int(str(cfg.get_value(pr_sec, resolved_key)))

func _load_per_profile_settings(cfg: ConfigFile, profile: String) -> void:
	if profile == VANILLA_PROFILE:
		_mods_hide_disabled = false
		return
	var sec := "profile." + profile + ".settings"
	_mods_hide_disabled = bool(cfg.get_value(sec, "hide_disabled", false))

func _save_per_profile_setting(key: String, value: Variant) -> void:
	if _active_profile == VANILLA_PROFILE:
		return
	var cfg := ConfigFile.new()
	cfg.load(UI_CONFIG_PATH)
	var sec := "profile." + _active_profile + ".settings"
	cfg.set_value(sec, key, value)
	cfg.save(UI_CONFIG_PATH)
	if _boot_complete:
		_dirty_since_boot = true

func _mods_entry_visible(entry: Dictionary) -> bool:
	if _mods_hide_disabled and not bool(entry.get("enabled", false)):
		return false
	if _mods_filter_text != "":
		var needle := _mods_filter_text.to_lower()
		var hay := str(entry.get("mod_name", "")).to_lower()
		if not hay.contains(needle):
			return false
	return true

func _find_stored_key_for_mod_id(cfg: ConfigFile, profile: String, mod_id: String) -> String:
	var prefix := mod_id + "@"
	for suffix: String in [".enabled", ".priority"]:
		var sec := "profile." + profile + suffix
		if cfg.has_section(sec):
			for key: String in cfg.get_section_keys(sec):
				if key.begins_with(prefix):
					return key
	return ""

func _version_from_profile_key(key: String) -> String:
	var at := key.find("@")
	if at < 0:
		return ""
	return key.substr(at + 1)

func _list_profiles_in_cfg(cfg: ConfigFile) -> Array[String]:
	var names: Array[String] = []
	var prefix := "profile."
	var suffix := ".enabled"
	for sec: String in cfg.get_sections():
		if sec.begins_with(prefix) and sec.ends_with(suffix):
			var name: String = sec.substr(prefix.length(), sec.length() - prefix.length() - suffix.length())
			if name != "" and name != VANILLA_PROFILE and not (name in names):
				names.append(name)
	var pr_suffix := ".priority"
	for sec: String in cfg.get_sections():
		if sec.begins_with(prefix) and sec.ends_with(pr_suffix):
			var name: String = sec.substr(prefix.length(), sec.length() - prefix.length() - pr_suffix.length())
			if name != "" and name != VANILLA_PROFILE and not (name in names):
				names.append(name)
	names.sort()
	return names

func _list_profiles() -> Array[String]:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return []
	return _list_profiles_in_cfg(cfg)

func _save_ui_config() -> void:
	var cfg := ConfigFile.new()
	cfg.load(UI_CONFIG_PATH)

	if cfg.has_section("enabled"):
		cfg.erase_section("enabled")
	if cfg.has_section("priority"):
		cfg.erase_section("priority")

	if _active_profile != VANILLA_PROFILE:
		var en_sec := "profile." + _active_profile + ".enabled"
		var pr_sec := "profile." + _active_profile + ".priority"
		var preserved_enabled: Dictionary = {}
		var preserved_priority: Dictionary = {}
		if not _hidden_folder_profile_keys.is_empty() and cfg.has_section(en_sec):
			for key: String in cfg.get_section_keys(en_sec):
				if _hidden_folder_profile_keys.has(key):
					preserved_enabled[key] = cfg.get_value(en_sec, key)
		if not _hidden_folder_profile_keys.is_empty() and cfg.has_section(pr_sec):
			for key: String in cfg.get_section_keys(pr_sec):
				if _hidden_folder_profile_keys.has(key):
					preserved_priority[key] = cfg.get_value(pr_sec, key)
		if cfg.has_section(en_sec):
			cfg.erase_section(en_sec)
		if cfg.has_section(pr_sec):
			cfg.erase_section(pr_sec)
		for entry in _ui_mod_entries:
			var pk: String = entry["profile_key"]
			cfg.set_value(en_sec, pk, entry["enabled"])
			cfg.set_value(pr_sec, pk, entry["priority"])
		for k in preserved_enabled.keys():
			cfg.set_value(en_sec, k, preserved_enabled[k])
		for k in preserved_priority.keys():
			cfg.set_value(pr_sec, k, preserved_priority[k])

	cfg.set_value("settings", "developer_mode", _developer_mode)
	cfg.set_value("settings", "active_profile", _active_profile)
	cfg.save(UI_CONFIG_PATH)
	if _boot_complete:
		_dirty_since_boot = true

func _missing_mods_in_active_profile() -> Array[String]:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return []
	var en_sec := "profile." + _active_profile + ".enabled"
	if not cfg.has_section(en_sec):
		return []
	var present: Dictionary = {}
	var ids_installed: Dictionary = {}
	for entry in _ui_mod_entries:
		present[entry["profile_key"]] = true
		if not entry["profile_key"].begins_with("zip:"):
			ids_installed[entry["mod_id"]] = true
	for key in _hidden_folder_profile_keys.keys():
		present[key] = true
	for mid in _hidden_folder_ids.keys():
		ids_installed[mid] = true
	var missing: Array[String] = []
	for key: String in cfg.get_section_keys(en_sec):
		if present.has(key):
			continue
		var at := key.find("@")
		if at > 0 and ids_installed.has(key.substr(0, at)):
			continue
		missing.append(key)
	missing.sort()
	return missing

func _remove_missing_entry_from_profile(stored_key: String) -> void:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return
	for suffix: String in [".enabled", ".priority"]:
		var sec := "profile." + _active_profile + suffix
		if cfg.has_section(sec) and cfg.has_section_key(sec, stored_key):
			cfg.erase_section_key(sec, stored_key)
	cfg.save(UI_CONFIG_PATH)

func _remove_all_missing_entries_from_profile() -> void:
	var missing := _missing_mods_in_active_profile()
	if missing.is_empty():
		return
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return
	for suffix: String in [".enabled", ".priority"]:
		var sec := "profile." + _active_profile + suffix
		if not cfg.has_section(sec):
			continue
		for key: String in missing:
			if cfg.has_section_key(sec, key):
				cfg.erase_section_key(sec, key)
	cfg.save(UI_CONFIG_PATH)

func _rebuild_mods_tab(tabs: TabContainer) -> void:
	var old := tabs.get_node_or_null("Mods")
	if old == null:
		return
	var idx := old.get_index()
	tabs.remove_child(old)
	old.queue_free()
	var new_tab := build_mods_tab(tabs)
	new_tab.name = "Mods"
	tabs.add_child(new_tab)
	tabs.move_child(new_tab, idx)
	tabs.current_tab = idx
	refresh_launch_button_label()

func _attach_ui_dialog(d: Window) -> void:
	var parent: Node = _ui_window if _ui_window != null else get_tree().root
	parent.add_child(d)
	if _ui_window != null and _ui_window.theme != null:
		d.theme = _ui_window.theme

func _connect_dialog_exits(d: ConfirmationDialog, on_confirm: Callable, on_dismiss: Callable) -> void:
	d.confirmed.connect(on_confirm)
	d.canceled.connect(on_dismiss)
	d.close_requested.connect(on_dismiss)

func _wire_hint(c: Control, text: String) -> void:
	if _ui_hint_label == null:
		return
	var default_text := _ui_hint_label.text
	c.mouse_entered.connect(func():
		if is_instance_valid(_ui_hint_label):
			_ui_hint_label.text = text
	)
	c.mouse_exited.connect(func():
		if is_instance_valid(_ui_hint_label):
			_ui_hint_label.text = default_text
	)

func _show_security_findings_dialog(entry: Dictionary) -> void:
	var findings: Array = entry.get("security_findings", [])
	if findings.is_empty():
		return
	var d := AcceptDialog.new()
	var mod_name := str(entry.get("mod_name", "?"))
	d.title = "Suspicious code in " + mod_name
	d.ok_button_text = "Close"
	d.min_size = Vector2(580, 420)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(560, 380)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	d.add_child(scroll)

	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)
	scroll.add_child(body)

	var intro := Label.new()
	intro.text = "The scanner found patterns in this mod's code that are commonly used by malware " \
			+ "(obfuscated string decoding combined with process spawning, anti-debug calls, etc.). " \
			+ "If you don't trust this mod, do not enable it."
	intro.modulate = Color(0.95, 0.6, 0.6)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.add_theme_font_size_override("font_size", 11)
	body.add_child(intro)

	body.add_child(HSeparator.new())

	var rule_color := Color(0.95, 0.4, 0.4)
	for f: Dictionary in findings:
		var card := VBoxContainer.new()
		card.add_theme_constant_override("separation", 4)
		body.add_child(card)

		var rule_lbl := Label.new()
		rule_lbl.text = str(f.get("rule", "?"))
		rule_lbl.modulate = rule_color
		rule_lbl.add_theme_font_size_override("font_size", 13)
		card.add_child(rule_lbl)

		var desc_lbl := Label.new()
		desc_lbl.text = str(f.get("description", ""))
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_lbl.add_theme_font_size_override("font_size", 11)
		card.add_child(desc_lbl)

		var loc := str(f.get("file", "?"))
		if int(f.get("line", 0)) > 0:
			loc += ":" + str(f.get("line"))
		var loc_lbl := Label.new()
		loc_lbl.text = loc
		loc_lbl.modulate = Color(0.55, 0.55, 0.55)
		loc_lbl.add_theme_font_size_override("font_size", 10)
		card.add_child(loc_lbl)

		var preview := str(f.get("preview", ""))
		if not preview.is_empty():
			var pre_lbl := Label.new()
			pre_lbl.text = "  " + preview
			pre_lbl.modulate = Color(0.78, 0.85, 0.6)
			pre_lbl.add_theme_font_size_override("font_size", 11)
			pre_lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
			pre_lbl.clip_text = true
			card.add_child(pre_lbl)

		body.add_child(HSeparator.new())

	_attach_ui_dialog(d)
	d.confirmed.connect(d.queue_free)
	d.close_requested.connect(d.queue_free)
	d.popup_centered()

func _enabled_red_mods() -> Array:
	var out: Array = []
	for entry in _ui_mod_entries:
		if entry.get("enabled", false) and int(entry.get("risk_level", 0)) == 2:
			out.append(entry)
	return out

func _confirm_red_launch(red_mods: Array) -> bool:
	var d := ConfirmationDialog.new()
	d.title = "Suspicious mods enabled"
	d.ok_button_text = "Launch anyway"
	d.cancel_button_text = "Go back"
	d.dialog_autowrap = true
	d.min_size = Vector2(560, 120)

	var lines := PackedStringArray()
	lines.append("The scanner found patterns in the following mod(s) that are commonly used by malware. If you don't trust them, go back and disable them before launching.")
	lines.append("")
	for entry: Dictionary in red_mods:
		lines.append("    " + str(entry.get("mod_name", "?")))
	d.dialog_text = "\n".join(lines)

	_attach_ui_dialog(d)
	d.exclusive = true
	d.always_on_top = true
	d.get_ok_button().modulate = Color(1.0, 0.55, 0.55)

	var state := [false, false]
	d.confirmed.connect(func():
		state[0] = true
		state[1] = true)
	d.canceled.connect(func(): state[0] = true)
	d.close_requested.connect(func(): state[0] = true)
	d.popup_centered()
	d.grab_focus()
	while not state[0]:
		await get_tree().process_frame
	d.queue_free()
	return state[1]


func _ui_box(bg: Color, border: Color, margin: int = 0, radius: int = 4) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.corner_radius_top_left = radius
	sb.corner_radius_top_right = radius
	sb.corner_radius_bottom_left = radius
	sb.corner_radius_bottom_right = radius
	if margin > 0:
		sb.content_margin_left = margin
		sb.content_margin_right = margin
		sb.content_margin_top = margin
		sb.content_margin_bottom = margin
	return sb

func _ui_button_style(btn: Button, bg: Color, border: Color, hover: Color, pressed: Color) -> void:
	var normal := _ui_box(bg, border, 8, 5)
	var hover_box := normal.duplicate()
	hover_box.bg_color = hover
	hover_box.border_color = Color(0.58, 0.76, 0.44)
	var pressed_box := normal.duplicate()
	pressed_box.bg_color = pressed
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover_box)
	btn.add_theme_stylebox_override("pressed", pressed_box)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	btn.add_theme_color_override("font_color", Color(0.89, 0.93, 0.82))
	btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))

func show_mod_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "OrcKitUILayer"
	layer.layer = 8192
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().root.add_child(layer)

	var overlay := Control.new()
	overlay.name = "OrcKitOverlay"
	overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(overlay)

	var shade := ColorRect.new()
	shade.name = "Backdrop"
	shade.color = Color(0.0, 0.0, 0.0, 0.42)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(shade)

	var win := Panel.new()
	win.name = "OrcKitPanel"
	win.custom_minimum_size = Vector2(1040, 660)
	win.set_anchors_preset(Control.PRESET_CENTER)
	win.offset_left = -520
	win.offset_top = -330
	win.offset_right = 520
	win.offset_bottom = 330
	overlay.add_child(win)

	_ui_window = overlay

	var dark_theme := make_dark_theme()
	overlay.theme = dark_theme
	win.theme = dark_theme
	var win_style := _ui_box(Color(0.025, 0.032, 0.026, 0.97), Color(0.38, 0.48, 0.31), 0, 8)
	win_style.shadow_color = Color(0.0, 0.0, 0.0, 0.45)
	win_style.shadow_size = 18
	win_style.shadow_offset = Vector2(0, 6)
	win.add_theme_stylebox_override("panel", win_style)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.theme = dark_theme
	win.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 14)
	root.add_child(header)

	var title_stack := VBoxContainer.new()
	title_stack.add_theme_constant_override("separation", 1)
	title_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title_stack)

	var title := Label.new()
	title.text = "ORCKIT"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(0.88, 0.96, 0.70))
	title_stack.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Sir, We Have an Orc Problem Playtest mod deployment"
	subtitle.add_theme_font_size_override("font_size", 12)
	subtitle.modulate = Color(0.62, 0.68, 0.55)
	title_stack.add_child(subtitle)

	var status_box := PanelContainer.new()
	status_box.add_theme_stylebox_override("panel", _ui_box(Color(0.04, 0.055, 0.04), Color(0.22, 0.30, 0.20), 8, 6))
	header.add_child(status_box)
	var status_lbl := Label.new()
	status_lbl.text = str(_ui_mod_entries.size()) + " mods scanned"
	status_lbl.add_theme_font_size_override("font_size", 11)
	status_lbl.add_theme_color_override("font_color", Color(0.74, 0.86, 0.60))
	status_box.add_child(status_lbl)

	var version_box := PanelContainer.new()
	version_box.add_theme_stylebox_override("panel", _ui_box(Color(0.035, 0.04, 0.036), Color(0.18, 0.23, 0.17), 8, 6))
	header.add_child(version_box)
	var version_lbl := Label.new()
	version_lbl.text = "v" + MODLOADER_VERSION
	version_lbl.add_theme_font_size_override("font_size", 11)
	version_lbl.modulate = Color(0.58, 0.64, 0.52)
	version_box.add_child(version_lbl)

	root.add_child(HSeparator.new())

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(tabs)

	root.add_child(HSeparator.new())

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	root.add_child(bottom)

	var hint := Label.new()
	hint.text = "Ready. Higher load order wins when mods touch the same file."
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	hint.modulate = Color(0.56, 0.62, 0.50)
	bottom.add_child(hint)
	_ui_hint_label = hint

	var launch_btn := Button.new()
	launch_btn.text = "  Launch Game  "
	launch_btn.custom_minimum_size = Vector2(180, 40)
	_ui_button_style(launch_btn, Color(0.18, 0.28, 0.13), Color(0.52, 0.68, 0.34), Color(0.25, 0.38, 0.18), Color(0.12, 0.19, 0.09))

	bottom.add_child(launch_btn)
	_ui_launch_btn = launch_btn

	var mods_tab := build_mods_tab(tabs)
	mods_tab.name = "Mods"
	tabs.add_child(mods_tab)

	refresh_launch_button_label()

	while true:
		await launch_btn.pressed
		var red_mods := _enabled_red_mods()
		if red_mods.is_empty():
			break
		var proceed: bool = await _confirm_red_launch(red_mods)
		if proceed:
			break
	_ui_window = null
	_ui_hint_label = null
	_ui_launch_btn = null
	layer.queue_free()

func refresh_launch_button_label() -> void:
	if not is_instance_valid(_ui_launch_btn):
		return
	var any_enabled := false
	for entry in _ui_mod_entries:
		if entry.get("enabled", false):
			any_enabled = true
			break
	if any_enabled:
		_ui_launch_btn.text = "  Launch with Mods (Restart)  "
	else:
		_ui_launch_btn.text = "  Launch Unmodded  "

func _make_pencil_icon() -> ImageTexture:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var line := Color(0.84, 0.84, 0.84)
	for x in range(1, 13):
		img.set_pixel(x, 5, line)
		img.set_pixel(x, 9, line)
	for y in range(5, 10):
		img.set_pixel(1, y, line)
		img.set_pixel(12, y, line)
	for y in range(5, 10):
		img.set_pixel(4, y, line)
	img.set_pixel(13, 6, line)
	img.set_pixel(13, 7, line)
	img.set_pixel(13, 8, line)
	img.set_pixel(14, 7, line)
	return ImageTexture.create_from_image(img)

func _make_trashcan_icon() -> ImageTexture:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var line := Color(0.84, 0.84, 0.84)
	for x in range(6, 10):
		img.set_pixel(x, 2, line)
	for x in range(3, 13):
		img.set_pixel(x, 4, line)
	for y in range(5, 14):
		img.set_pixel(4, y, line)
		img.set_pixel(11, y, line)
	for x in range(5, 11):
		img.set_pixel(x, 13, line)
	for y in range(6, 12):
		img.set_pixel(6, y, line)
		img.set_pixel(8, y, line)
		img.set_pixel(10, y, line)
	return ImageTexture.create_from_image(img)

func make_dark_theme() -> Theme:
	var t := Theme.new()

	const C_PANEL := Color(0.035, 0.044, 0.037)
	const C_FIELD := Color(0.025, 0.030, 0.026)
	const C_BTN   := Color(0.070, 0.085, 0.070)
	const C_BORD  := Color(0.190, 0.250, 0.170)
	const C_HI    := Color(0.86, 0.96, 0.70)
	const C_TEXT  := Color(0.84, 0.88, 0.78)
	const C_DIM   := Color(0.47, 0.52, 0.43)

	var bn := StyleBoxFlat.new()
	bn.bg_color = C_BTN
	bn.border_color = C_BORD
	bn.border_width_top = 1; bn.border_width_bottom = 1
	bn.border_width_left = 1; bn.border_width_right = 1
	bn.corner_radius_top_left = 5; bn.corner_radius_top_right = 5
	bn.corner_radius_bottom_left = 5; bn.corner_radius_bottom_right = 5
	bn.content_margin_left = 8; bn.content_margin_right = 8
	bn.content_margin_top = 4; bn.content_margin_bottom = 4
	var bh := bn.duplicate()
	bh.bg_color = Color(0.105, 0.135, 0.095); bh.border_color = Color(0.48, 0.64, 0.34)
	var bp := bn.duplicate(); bp.bg_color = Color(0.045, 0.058, 0.043)
	var bd := bn.duplicate()
	bd.bg_color = Color(0.035, 0.040, 0.035); bd.border_color = Color(0.11, 0.13, 0.10)
	t.set_stylebox("normal",   "Button", bn)
	t.set_stylebox("hover",    "Button", bh)
	t.set_stylebox("pressed",  "Button", bp)
	t.set_stylebox("disabled", "Button", bd)
	t.set_stylebox("focus",    "Button", StyleBoxEmpty.new())
	t.set_color("font_color",          "Button", C_TEXT)
	t.set_color("font_hover_color",    "Button", Color(1.0, 1.0, 1.0))
	t.set_color("font_pressed_color",  "Button", C_TEXT)
	t.set_color("font_disabled_color", "Button", C_DIM)

	t.set_color("font_color",       "CheckBox", C_TEXT)
	t.set_color("font_hover_color", "CheckBox", Color(1.0, 1.0, 1.0))

	t.set_color("font_color", "Label", C_TEXT)

	var ps := _ui_box(C_PANEL, Color(0.12, 0.16, 0.11), 0, 6)
	t.set_stylebox("panel", "Panel",          ps)
	t.set_stylebox("panel", "PanelContainer", ps.duplicate())

	var ts := StyleBoxFlat.new()
	ts.bg_color = Color(0.055, 0.072, 0.050)
	ts.border_color = Color(0.34, 0.46, 0.25)
	ts.border_width_top = 1; ts.border_width_left = 1; ts.border_width_right = 1
	ts.border_width_bottom = 0
	ts.corner_radius_top_left = 5; ts.corner_radius_top_right = 5
	ts.content_margin_left = 12; ts.content_margin_right = 12
	ts.content_margin_top = 5;   ts.content_margin_bottom = 5
	var tu := ts.duplicate()
	tu.bg_color = Color(0.026, 0.032, 0.027)
	tu.border_color = Color(0.12, 0.15, 0.11)
	tu.border_width_bottom = 1
	var tc_panel := _ui_box(Color(0.032, 0.041, 0.034), Color(0.16, 0.21, 0.14), 0, 6)
	tc_panel.content_margin_left   = 10
	tc_panel.content_margin_right  = 10
	tc_panel.content_margin_top    = 8
	tc_panel.content_margin_bottom = 8
	t.set_stylebox("tab_selected",   "TabContainer", ts)
	t.set_stylebox("tab_unselected", "TabContainer", tu)
	t.set_stylebox("tab_hovered",    "TabContainer", tu.duplicate())
	t.set_stylebox("panel",          "TabContainer", tc_panel)
	t.set_color("font_selected_color",   "TabContainer", C_HI)
	t.set_color("font_unselected_color", "TabContainer", C_DIM)
	t.set_color("font_hovered_color",    "TabContainer", C_TEXT)

	var sep := StyleBoxFlat.new(); sep.bg_color = Color(0.16, 0.22, 0.13)
	t.set_stylebox("separator", "HSeparator", sep)
	t.set_constant("separation", "HSeparator", 1)

	var le := StyleBoxFlat.new()
	le.bg_color = C_FIELD
	le.border_color = C_BORD
	le.border_width_top = 1; le.border_width_bottom = 1
	le.border_width_left = 1; le.border_width_right = 1
	le.corner_radius_top_left = 5; le.corner_radius_top_right = 5
	le.corner_radius_bottom_left = 5; le.corner_radius_bottom_right = 5
	le.content_margin_left = 6; le.content_margin_right = 6
	le.content_margin_top = 3; le.content_margin_bottom = 3
	t.set_stylebox("normal", "LineEdit", le)
	t.set_stylebox("focus",  "LineEdit", le.duplicate())
	t.set_color("font_color", "LineEdit", C_TEXT)

	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())

	var pm_panel := StyleBoxFlat.new()
	pm_panel.bg_color = Color(0.040, 0.050, 0.042)
	pm_panel.border_color = C_BORD
	pm_panel.border_width_top = 1; pm_panel.border_width_bottom = 1
	pm_panel.border_width_left = 1; pm_panel.border_width_right = 1
	pm_panel.corner_radius_top_left = 5; pm_panel.corner_radius_top_right = 5
	pm_panel.corner_radius_bottom_left = 5; pm_panel.corner_radius_bottom_right = 5
	pm_panel.content_margin_left = 4; pm_panel.content_margin_right = 4
	pm_panel.content_margin_top = 4;  pm_panel.content_margin_bottom = 4
	t.set_stylebox("panel", "PopupMenu", pm_panel)
	var pm_hover := StyleBoxFlat.new()
	pm_hover.bg_color = Color(0.11, 0.15, 0.09)
	t.set_stylebox("hover", "PopupMenu", pm_hover)
	var pm_sep := StyleBoxFlat.new()
	pm_sep.bg_color = C_BORD
	pm_sep.content_margin_top = 1; pm_sep.content_margin_bottom = 1
	t.set_stylebox("separator", "PopupMenu", pm_sep)
	t.set_color("font_color",           "PopupMenu", C_TEXT)
	t.set_color("font_hover_color",     "PopupMenu", Color(1.0, 1.0, 1.0))
	t.set_color("font_disabled_color",  "PopupMenu", C_DIM)
	t.set_color("font_separator_color", "PopupMenu", C_DIM)

	t.set_stylebox("normal",   "OptionButton", bn.duplicate())
	t.set_stylebox("hover",    "OptionButton", bh.duplicate())
	t.set_stylebox("pressed",  "OptionButton", bp.duplicate())
	t.set_stylebox("disabled", "OptionButton", bd.duplicate())
	t.set_stylebox("focus",    "OptionButton", StyleBoxEmpty.new())
	t.set_color("font_color",         "OptionButton", C_TEXT)
	t.set_color("font_hover_color",   "OptionButton", Color(1.0, 1.0, 1.0))
	t.set_color("font_pressed_color", "OptionButton", C_TEXT)

	var tt_panel := StyleBoxFlat.new()
	tt_panel.bg_color = Color(0.060, 0.075, 0.055)
	tt_panel.border_color = C_BORD
	tt_panel.border_width_top = 1; tt_panel.border_width_bottom = 1
	tt_panel.border_width_left = 1; tt_panel.border_width_right = 1
	tt_panel.content_margin_left = 8; tt_panel.content_margin_right = 8
	tt_panel.content_margin_top = 4;  tt_panel.content_margin_bottom = 4
	t.set_stylebox("panel", "TooltipPanel", tt_panel)
	t.set_color("font_color", "TooltipLabel", C_TEXT)

	var dlg_panel := StyleBoxFlat.new()
	dlg_panel.bg_color = Color(0.045, 0.055, 0.046)
	dlg_panel.border_color = C_BORD
	dlg_panel.border_width_top = 1; dlg_panel.border_width_bottom = 1
	dlg_panel.border_width_left = 1; dlg_panel.border_width_right = 1
	dlg_panel.corner_radius_top_left = 6; dlg_panel.corner_radius_top_right = 6
	dlg_panel.corner_radius_bottom_left = 6; dlg_panel.corner_radius_bottom_right = 6
	dlg_panel.content_margin_left = 10; dlg_panel.content_margin_right = 10
	dlg_panel.content_margin_top = 8;   dlg_panel.content_margin_bottom = 8
	t.set_stylebox("panel", "AcceptDialog", dlg_panel)
	t.set_stylebox("panel", "ConfirmationDialog", dlg_panel.duplicate())
	t.set_stylebox("embedded_border",           "Window", dlg_panel.duplicate())
	t.set_stylebox("embedded_unfocused_border", "Window", dlg_panel.duplicate())
	t.set_color("title_color", "Window", C_HI)

	return t

func build_mods_tab(tabs: TabContainer) -> Control:
	var outer := VBoxContainer.new()
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_theme_constant_override("separation", 10)


	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 8)
	outer.add_child(toolbar)

	var open_btn := Button.new()
	open_btn.text = "Mods Folder"
	toolbar.add_child(open_btn)
	open_btn.pressed.connect(func():
		OS.shell_open(ProjectSettings.globalize_path(_mods_dir))
	)
	_wire_hint(open_btn, "Open the game's mods folder in your file manager.")

	var on_vanilla := false

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	var dev_check := CheckBox.new()
	dev_check.text = "Developer Mode"
	dev_check.tooltip_text = "Enables verbose logging, conflict report, and loose folder loading"
	dev_check.button_pressed = _developer_mode
	dev_check.add_theme_font_size_override("font_size", 11)
	dev_check.modulate = Color(0.58, 0.64, 0.52)
	toolbar.add_child(dev_check)
	_wire_hint(dev_check, "Developer Mode: verbose logging, conflict report, and loose folder loading.")

	dev_check.toggled.connect(func(on: bool):
		_developer_mode = on
		_ui_mod_entries = collect_mod_metadata()
		_load_ui_config()
		_rebuild_mods_tab(tabs)
	)

	outer.add_child(HSeparator.new())

	var split := HSplitContainer.new()
	split.split_offset = 610
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(split)


	var left_col := VBoxContainer.new()
	left_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(left_col)

	var filter_bar := HBoxContainer.new()
	filter_bar.add_theme_constant_override("separation", 6)
	left_col.add_child(filter_bar)

	var filter_edit := LineEdit.new()
	filter_edit.placeholder_text = "Filter mods..."
	filter_edit.text = _mods_filter_text
	filter_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	filter_bar.add_child(filter_edit)

	var all_btn := Button.new()
	all_btn.text = "All"
	all_btn.tooltip_text = "Enable every visible mod"
	all_btn.disabled = on_vanilla
	filter_bar.add_child(all_btn)
	_wire_hint(all_btn, "Enable every visible mod (respects the search filter).")

	var none_btn := Button.new()
	none_btn.text = "None"
	none_btn.tooltip_text = "Disable every visible mod"
	none_btn.disabled = on_vanilla
	filter_bar.add_child(none_btn)
	_wire_hint(none_btn, "Disable every visible mod (respects the search filter).")

	var hide_check := CheckBox.new()
	hide_check.text = "Hide disabled"
	hide_check.tooltip_text = "Hide rows for disabled mods"
	hide_check.button_pressed = _mods_hide_disabled
	hide_check.add_theme_font_size_override("font_size", 11)
	hide_check.disabled = on_vanilla
	filter_bar.add_child(hide_check)
	_wire_hint(hide_check, "Hide rows for disabled mods.")

	filter_edit.text_changed.connect(func(t: String):
		_mods_filter_text = t
		_mods_filter_focus_pending = true
		_rebuild_mods_tab(tabs)
	)
	all_btn.pressed.connect(func():
		for entry in _ui_mod_entries:
			if _mods_entry_visible(entry):
				entry["enabled"] = true
		_save_ui_config()
		_rebuild_mods_tab(tabs)
	)
	none_btn.pressed.connect(func():
		for entry in _ui_mod_entries:
			if _mods_entry_visible(entry):
				entry["enabled"] = false
		_save_ui_config()
		_rebuild_mods_tab(tabs)
	)
	hide_check.toggled.connect(func(on: bool):
		_mods_hide_disabled = on
		_save_per_profile_setting("hide_disabled", on)
		_rebuild_mods_tab(tabs)
	)

	var left_scroll := ScrollContainer.new()
	left_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_col.add_child(left_scroll)

	var list_pad := MarginContainer.new()
	list_pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_pad.add_theme_constant_override("margin_right", 16)
	left_scroll.add_child(list_pad)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 6)
	list_pad.add_child(list)


	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 250
	right.add_theme_constant_override("separation", 6)
	split.add_child(right)

	var order_header := Label.new()
	order_header.text = "DEPLOYMENT ORDER"
	order_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	order_header.add_theme_font_size_override("font_size", 11)
	order_header.add_theme_color_override("font_color", Color(0.74, 0.86, 0.60))
	right.add_child(order_header)
	right.add_child(HSeparator.new())

	var order_panel := PanelContainer.new()
	order_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.028, 0.036, 0.030)
	panel_style.border_color = Color(0.13, 0.18, 0.11)
	panel_style.border_width_top = 1
	panel_style.border_width_bottom = 1
	panel_style.border_width_left = 1
	panel_style.border_width_right = 1
	panel_style.corner_radius_top_left = 6
	panel_style.corner_radius_top_right = 6
	panel_style.corner_radius_bottom_left = 6
	panel_style.corner_radius_bottom_right = 6
	panel_style.content_margin_left = 8
	panel_style.content_margin_right = 8
	panel_style.content_margin_top = 6
	panel_style.content_margin_bottom = 6
	order_panel.add_theme_stylebox_override("panel", panel_style)
	right.add_child(order_panel)

	var order_scroll := ScrollContainer.new()
	order_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	order_panel.add_child(order_scroll)

	var order_list := VBoxContainer.new()
	order_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	order_scroll.add_child(order_list)

	var refresh_order := func():
		for child in order_list.get_children():
			child.queue_free()
		var sorted := _ui_mod_entries.filter(func(e): return e["enabled"])
		sorted.sort_custom(_compare_load_order)
		if sorted.is_empty():
			var lbl := Label.new()
			lbl.text = "No mods armed."
			lbl.modulate = Color(0.50, 0.56, 0.46)
			order_list.add_child(lbl)
			return
		for i in sorted.size():
			var e: Dictionary = sorted[i]
			var lbl := Label.new()
			lbl.text = str(i + 1).pad_zeros(2) + "  " + e["mod_name"]
			lbl.add_theme_font_size_override("font_size", 12)
			lbl.modulate = Color(0.82, 0.88, 0.74)
			lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			order_list.add_child(lbl)

	var missing_files := _missing_mods_in_active_profile()
	if not missing_files.is_empty():
		var missing_hdr_row := HBoxContainer.new()
		list.add_child(missing_hdr_row)
		var missing_hdr := Label.new()
		missing_hdr.text = "Missing mods"
		missing_hdr.modulate = Color(1.0, 0.55, 0.55)
		missing_hdr.add_theme_font_size_override("font_size", 11)
		missing_hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		missing_hdr_row.add_child(missing_hdr)
		var remove_all_btn := Button.new()
		remove_all_btn.text = "Remove all"
		remove_all_btn.tooltip_text = "Strip every missing-mod entry from config"
		missing_hdr_row.add_child(remove_all_btn)
		_wire_hint(remove_all_btn, "Strip every missing-mod entry from config.")
		remove_all_btn.pressed.connect(func():
			_remove_all_missing_entries_from_profile()
			_rebuild_mods_tab(tabs)
		)
		list.add_child(HSeparator.new())
		for fn: String in missing_files:
			var miss_row := HBoxContainer.new()
			list.add_child(miss_row)
			var miss_lbl := Label.new()
			var display := fn.trim_prefix("zip:")
			miss_lbl.text = display + "  --  not installed"
			miss_lbl.modulate = Color(1.0, 0.45, 0.45)
			miss_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			miss_row.add_child(miss_lbl)
			var remove_btn := Button.new()
			remove_btn.text = "Remove"
			remove_btn.tooltip_text = "Strip this entry from config"
			miss_row.add_child(remove_btn)
			var captured := fn
			remove_btn.pressed.connect(func():
				_remove_missing_entry_from_profile(captured)
				_rebuild_mods_tab(tabs)
			)
			list.add_child(HSeparator.new())


	var header_row := HBoxContainer.new()
	list.add_child(header_row)

	var h_on := Label.new()
	h_on.text = "ARM"
	h_on.custom_minimum_size.x = 30
	h_on.add_theme_font_size_override("font_size", 10)
	h_on.modulate = Color(0.58, 0.64, 0.52)
	header_row.add_child(h_on)

	var h_name := Label.new()
	h_name.text = "MOD PACKAGE"
	h_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h_name.add_theme_font_size_override("font_size", 10)
	h_name.modulate = Color(0.58, 0.64, 0.52)
	header_row.add_child(h_name)

	var h_prio := Label.new()
	h_prio.text = "ORDER"
	h_prio.custom_minimum_size.x = 100
	h_prio.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h_prio.add_theme_font_size_override("font_size", 10)
	h_prio.modulate = Color(0.58, 0.64, 0.52)
	header_row.add_child(h_prio)

	list.add_child(HSeparator.new())


	if _ui_mod_entries.is_empty():
		var empty := Label.new()
		empty.text = "No mods found.\n\nPlace .vmz or .pck files in:\n" \
				+ ProjectSettings.globalize_path(_mods_dir)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.modulate = Color(0.5, 0.5, 0.5)
		empty.add_theme_font_size_override("font_size", 12)
		list.add_child(empty)

	var rendered_any := false
	for entry in _ui_mod_entries:
		if not _mods_entry_visible(entry):
			continue
		rendered_any = true
		var row_panel := PanelContainer.new()
		row_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var row_bg := Color(0.045, 0.060, 0.043) if entry["enabled"] else Color(0.028, 0.034, 0.030)
		var row_border := Color(0.24, 0.34, 0.16) if entry["enabled"] else Color(0.10, 0.13, 0.10)
		row_panel.add_theme_stylebox_override("panel", _ui_box(row_bg, row_border, 0, 6))
		list.add_child(row_panel)

		var row_pad := MarginContainer.new()
		row_pad.add_theme_constant_override("margin_left", 8)
		row_pad.add_theme_constant_override("margin_right", 8)
		row_pad.add_theme_constant_override("margin_top", 7)
		row_pad.add_theme_constant_override("margin_bottom", 7)
		row_panel.add_child(row_pad)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row_pad.add_child(row)

		var check := CheckBox.new()
		check.button_pressed = entry["enabled"]
		check.custom_minimum_size.x = 34
		row.add_child(check)

		var name_col := VBoxContainer.new()
		name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_col.add_theme_constant_override("separation", 2)
		row.add_child(name_col)

		var name_lbl := Label.new()
		name_lbl.text = entry["mod_name"]
		name_lbl.clip_text = true
		name_lbl.add_theme_font_size_override("font_size", 13)
		name_lbl.modulate = Color(0.82, 0.94, 0.62) if entry["enabled"] else Color(0.55, 0.60, 0.50)
		name_col.add_child(name_lbl)

		var meta_parts := PackedStringArray()
		var version := str(entry.get("version", ""))
		var author := str(entry.get("author", ""))
		if version != "":
			meta_parts.append("v" + version)
		if author != "":
			meta_parts.append(author)
		meta_parts.append(str(entry.get("file_name", "")))
		var meta_lbl := Label.new()
		meta_lbl.text = "  |  ".join(meta_parts)
		meta_lbl.clip_text = true
		meta_lbl.add_theme_font_size_override("font_size", 10)
		meta_lbl.modulate = Color(0.48, 0.54, 0.44)
		name_col.add_child(meta_lbl)

		if entry["ext"] == "folder":
			var dev_lbl := Label.new()
			dev_lbl.text = "dev folder"
			dev_lbl.modulate = Color(0.90, 0.55, 0.35)
			dev_lbl.add_theme_font_size_override("font_size", 11)
			name_col.add_child(dev_lbl)
		for warn_text: String in entry.get("warnings", []):
			var warn := Label.new()
			warn.text = warn_text
			warn.modulate = Color(0.95, 0.70, 0.28)
			warn.add_theme_font_size_override("font_size", 11)
			name_col.add_child(warn)

		for dup: Dictionary in entry.get("duplicates_hidden", []):
			var dup_v_raw: String = str(dup.get("version", ""))
			var dup_v: String = ("v" + dup_v_raw) if dup_v_raw != "" else "(unversioned)"
			var hide_lbl := Label.new()
			hide_lbl.text = "older version hidden: " + str(dup["file_name"]) + " (" + dup_v + ")"
			hide_lbl.modulate = Color(0.95, 0.70, 0.28)
			hide_lbl.add_theme_font_size_override("font_size", 11)
			name_col.add_child(hide_lbl)

		var vm: Dictionary = entry.get("profile_version_mismatch", {})
		if not vm.is_empty():
			var stored_v: String = str(vm.get("stored", ""))
			var current_v: String = str(vm.get("current", ""))
			var stored_disp := stored_v if stored_v != "" else "(unset)"
			var current_disp := current_v if current_v != "" else "(unset)"
			var vm_lbl := Label.new()
			vm_lbl.text = "saved version: " + stored_disp + " -> " + current_disp
			vm_lbl.modulate = Color(0.95, 0.70, 0.28)
			vm_lbl.add_theme_font_size_override("font_size", 11)
			name_col.add_child(vm_lbl)

		var risk: int = int(entry.get("risk_level", 0))
		if risk == 2:
			var sec_btn := Button.new()
			sec_btn.text = "suspicious code"
			sec_btn.flat = true
			sec_btn.modulate = Color(0.95, 0.4, 0.4)
			sec_btn.add_theme_font_size_override("font_size", 11)
			sec_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
			sec_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			name_col.add_child(sec_btn)
			var captured_entry := entry
			sec_btn.pressed.connect(func(): _show_security_findings_dialog(captured_entry))

		if on_vanilla:
			check.disabled = true

		var spin := SpinBox.new()
		spin.min_value = PRIORITY_MIN
		spin.max_value = PRIORITY_MAX
		spin.value = entry["priority"]
		spin.custom_minimum_size.x = 108
		if on_vanilla:
			spin.editable = false
		row.add_child(spin)

		var e := entry
		var nlbl := name_lbl
		var rpanel := row_panel
		check.toggled.connect(func(on: bool):
			e["enabled"] = on
			nlbl.modulate = Color(0.82, 0.94, 0.62) if on else Color(0.55, 0.60, 0.50)
			var toggled_bg := Color(0.045, 0.060, 0.043) if on else Color(0.028, 0.034, 0.030)
			var toggled_border := Color(0.24, 0.34, 0.16) if on else Color(0.10, 0.13, 0.10)
			rpanel.add_theme_stylebox_override("panel", _ui_box(toggled_bg, toggled_border, 0, 6))
			refresh_order.call()
			refresh_launch_button_label()
			_save_ui_config()
		)
		spin.value_changed.connect(func(val: float):
			e["priority"] = int(val)
			refresh_order.call()
			_save_ui_config()
		)

	if not _ui_mod_entries.is_empty() and not rendered_any:
		var no_match := Label.new()
		no_match.text = "No mods match the current filter."
		no_match.modulate = Color(0.5, 0.5, 0.5)
		no_match.add_theme_font_size_override("font_size", 12)
		list.add_child(no_match)

	if _mods_filter_focus_pending:
		_mods_filter_focus_pending = false
		filter_edit.call_deferred("grab_focus")

	refresh_order.call()
	return outer


static func version() -> String:
	return MODLOADER_VERSION

static func major_version() -> int:
	return int(MODLOADER_VERSION.split(".")[0])

static func minor_version() -> int:
	return int(MODLOADER_VERSION.split(".")[1])

static func patch_version() -> int:
	return int(MODLOADER_VERSION.split(".")[2])

func _register_rtv_modlib_meta() -> void:
	if Engine.has_meta("RTVModLib"):
		_log_warning("[RTVModLib] Engine.meta 'RTVModLib' already set -- not overwriting")
		return
	Engine.set_meta("RTVModLib", self)
	_log_info("[RTVModLib] modloader registered as Engine.meta('RTVModLib')")

func _emit_frameworks_ready() -> void:
	_is_ready = true
	_register_core_hooks()
	_scene_nodes_connect_listener()
	frameworks_ready.emit()
	_log_info("[RTVModLib] frameworks_ready emitted")
	_verify_script_overrides()

static func _hook_base_of(hook_name: String) -> String:
	if hook_name.ends_with("-pre"):
		return hook_name.substr(0, hook_name.length() - 4)
	if hook_name.ends_with("-post"):
		return hook_name.substr(0, hook_name.length() - 5)
	if hook_name.ends_with("-callback"):
		return hook_name.substr(0, hook_name.length() - 9)
	return hook_name


func hook(hook_name: String, callback: Callable, priority: int = 100) -> int:
	var is_replace := not (hook_name.ends_with("-pre") \
			or hook_name.ends_with("-post") \
			or hook_name.ends_with("-callback"))
	if is_replace and _hooks.has(hook_name) and (_hooks[hook_name] as Array).size() > 0:
		var owner_id: int = (_hooks[hook_name] as Array)[0]["id"]
		_log_debug("[RTVModLib] replace hook '%s' already owned (id=%d), registration rejected" \
				% [hook_name, owner_id])
		return -1
	if not _hooks.has(hook_name):
		_hooks[hook_name] = []
	var entry := { "callback": callback, "priority": priority, "id": _next_id }
	(_hooks[hook_name] as Array).append(entry)
	(_hooks[hook_name] as Array).sort_custom(func(a, b): return a["priority"] < b["priority"])
	_any_mod_hooked = true
	var base := _hook_base_of(hook_name)
	_hooked_bases[base] = int(_hooked_bases.get(base, 0)) + 1
	var id := _next_id
	_next_id += 1
	return id

func add_hook(script_path: String, method_name: String, callback: Callable, is_before: bool = true) -> int:
	var stem := script_path.get_file().get_basename().to_lower()
	var suffix := "pre" if is_before else "post"
	var hook_name := "%s-%s-%s" % [stem, method_name.to_lower(), suffix]
	var res_path := _canonical_hook_script_path(script_path)
	if not _hooked_methods.has(res_path):
		_hooked_methods[res_path] = {}
	(_hooked_methods[res_path] as Dictionary)[method_name.to_lower()] = true
	return hook(hook_name, callback, 100)

func hook_many(entries: Dictionary, priority: int = 100) -> Dictionary:
	var results: Dictionary = {}
	var all_ok := true
	for hook_name in entries.keys():
		var id: int = hook(String(hook_name), entries[hook_name], priority)
		results[hook_name] = id
		if id == -1:
			all_ok = false
	return {"ok": all_ok, "results": results}


func unhook(hook_id: int) -> void:
	for hook_name in _hooks:
		var arr: Array = _hooks[hook_name]
		for i in range(arr.size() - 1, -1, -1):
			if arr[i]["id"] == hook_id:
				arr.remove_at(i)
				var base := _hook_base_of(hook_name)
				var c: int = int(_hooked_bases.get(base, 0)) - 1
				if c <= 0:
					_hooked_bases.erase(base)
				else:
					_hooked_bases[base] = c
				return

func has_hooks(hook_name: String) -> bool:
	return _hooks.has(hook_name) and (_hooks[hook_name] as Array).size() > 0

func has_replace(hook_name: String) -> bool:
	return _hooks.has(hook_name) and (_hooks[hook_name] as Array).size() > 0

func get_replace_owner(hook_name: String) -> int:
	if not _hooks.has(hook_name) or (_hooks[hook_name] as Array).size() == 0:
		return -1
	return (_hooks[hook_name] as Array)[0]["id"]

func skip_super() -> void:
	_skip_super = true

func seq() -> int:
	return _seq



func has_mod(mod_id: String, min_version: String = "") -> bool:
	if not _loaded_mod_ids.has(mod_id):
		return false
	if min_version == "":
		return true
	var info = _loaded_mod_ids[mod_id]
	var have: String = ""
	if info is Dictionary:
		have = String(info.get("version", ""))
	return _compare_versions(have, min_version) >= 0


func mod_info(mod_id: String) -> Dictionary:
	var info = _loaded_mod_ids.get(mod_id, null)
	if info is Dictionary:
		return (info as Dictionary).duplicate()
	return {}


func loaded_mods() -> Array[String]:
	var out: Array[String] = []
	for k in _loaded_mod_ids.keys():
		out.append(String(k))
	return out


func _compare_versions(a: String, b: String) -> int:
	var pa: PackedStringArray = a.split(".")
	var pb: PackedStringArray = b.split(".")
	var n: int = max(pa.size(), pb.size())
	for i in n:
		var ai: int = 0 if i >= pa.size() else _to_version_int(pa[i])
		var bi: int = 0 if i >= pb.size() else _to_version_int(pb[i])
		if ai < bi:
			return -1
		if ai > bi:
			return 1
	return 0

func _to_version_int(s: String) -> int:
	if s.is_valid_int():
		return int(s)
	return 0



func _dispatch(hook_name: String, args: Array) -> void:
	if not _hooks.has(hook_name):
		return
	var entries: Array = (_hooks[hook_name] as Array).duplicate()
	for entry in entries:
		_seq += 1
		var cb: Callable = entry["callback"]
		cb.callv(args)

func _dispatch_post(hook_name: String, args: Array, current_result: Variant) -> Variant:
	if not _hooks.has(hook_name):
		return current_result
	var entries: Array = (_hooks[hook_name] as Array).duplicate()
	var expected_with_result: int = args.size() + 1
	for entry in entries:
		_seq += 1
		var cb: Callable = entry["callback"]
		var argc: int = cb.get_argument_count()
		var ret: Variant = null
		if argc == expected_with_result:
			ret = cb.callv(args + [current_result])
		else:
			var warn_key: String = "%s::%d" % [hook_name, cb.get_object_id()]
			if not _post_legacy_warned.has(warn_key):
				_post_legacy_warned[warn_key] = true
				_log_warning("[RTVModLib] post hook '%s' callback uses legacy %d-arg signature (expected %d for non-void wrapper). Add a trailing _result param to your callback to receive + optionally mutate the return value; the legacy form will be removed in a future major version." \
						% [hook_name, argc, expected_with_result])
			cb.callv(args)
		if ret != null:
			current_result = ret
	return current_result

func _dispatch_deferred(hook_name: String, args: Array) -> void:
	if not _hooks.has(hook_name):
		return
	var entries: Array = (_hooks[hook_name] as Array).duplicate()
	for entry in entries:
		_seq += 1
		var cb: Callable = entry["callback"]
		cb.bindv(args).call_deferred()

func _get_hooks(hook_name: String) -> Array:
	if not _hooks.has(hook_name):
		return []
	var callbacks := []
	for entry in _hooks[hook_name]:
		callbacks.append(entry["callback"])
	return callbacks


const Registry := {
	RESOURCES = "resources",
	SCENES = "scenes",
	SCRIPTS = "scripts",
	SCENE_NODES = "scene_nodes",
}

var _registry_registered: Dictionary = {}
var _registry_overridden: Dictionary = {}
var _registry_patched: Dictionary = {}


func _registry_warn_unsupported(verb: String, registry: String) -> void:
	push_warning("[Registry] %s('%s', ...): OrcKit has no game-specific registry handler for this project. Use hooks or resource/script overrides instead." % [verb, registry])


func register(registry: String, id: String, data: Variant) -> bool:
	if id == "":
		push_warning("[Registry] register('%s', ...): empty id" % registry)
		return false
	if not _registry_registered.has(registry):
		_registry_registered[registry] = {}
	if (_registry_registered[registry] as Dictionary).has(id):
		push_warning("[Registry] register('%s', '%s'): id already registered" % [registry, id])
		return false
	(_registry_registered[registry] as Dictionary)[id] = data
	return true


func override(registry: String, id: String, data: Variant) -> bool:
	if id == "":
		push_warning("[Registry] override('%s', ...): empty id" % registry)
		return false
	if not _registry_overridden.has(registry):
		_registry_overridden[registry] = {}
	(_registry_overridden[registry] as Dictionary)[id] = get_entry(registry, id)
	if not _registry_registered.has(registry):
		_registry_registered[registry] = {}
	(_registry_registered[registry] as Dictionary)[id] = data
	return true


func patch(registry: String, id: Variant, fields: Dictionary) -> bool:
	if not (id is String) or String(id) == "":
		push_warning("[Registry] patch('%s', ...): id must be a non-empty String" % registry)
		return false
	var current := get_entry(registry, id)
	if current == null:
		_registry_warn_unsupported("patch", registry)
		return false
	if not (current is Object):
		push_warning("[Registry] patch('%s', '%s'): entry is not an Object/Resource" % [registry, id])
		return false
	if not _registry_patched.has(registry):
		_registry_patched[registry] = {}
	var reg_patch: Dictionary = _registry_patched[registry]
	if not reg_patch.has(id):
		reg_patch[id] = {}
	var stash: Dictionary = reg_patch[id]
	for field in fields.keys():
		var name := String(field)
		if not stash.has(name):
			stash[name] = current.get(name)
		current.set(name, fields[field])
	return true


func append(registry: String, id: Variant, field: String, values: Variant, allow_duplicates: bool = false) -> bool:
	return _array_op(registry, id, field, values, "append", allow_duplicates)


func prepend(registry: String, id: Variant, field: String, values: Variant, allow_duplicates: bool = false) -> bool:
	return _array_op(registry, id, field, values, "prepend", allow_duplicates)


func remove_from(registry: String, id: Variant, field: String, values: Variant) -> bool:
	return _array_op(registry, id, field, values, "remove_from", false)


func _array_op(registry: String, id: Variant, field: String, values: Variant, op: String, allow_duplicates: bool) -> bool:
	if not (id is String):
		push_warning("[Registry] %s('%s', ...): id must be a String" % [op, registry])
		return false
	var current := get_entry(registry, String(id))
	if current == null or not (current is Object):
		_registry_warn_unsupported(op, registry)
		return false
	var existing = current.get(field)
	if not (existing is Array):
		push_warning("[Registry] %s('%s', '%s'): field is not an Array" % [op, registry, field])
		return false
	if not _registry_patched.has(registry):
		_registry_patched[registry] = {}
	var reg_patch: Dictionary = _registry_patched[registry]
	if not reg_patch.has(id):
		reg_patch[id] = {}
	var stash: Dictionary = reg_patch[id]
	if not stash.has(field):
		stash[field] = (existing as Array).duplicate()
	var incoming := values if values is Array else [values]
	match op:
		"append":
			for value in incoming:
				if allow_duplicates or not (existing as Array).has(value):
					(existing as Array).append(value)
		"prepend":
			for i in range(incoming.size() - 1, -1, -1):
				var value = incoming[i]
				if allow_duplicates or not (existing as Array).has(value):
					(existing as Array).push_front(value)
		"remove_from":
			for value in incoming:
				while (existing as Array).has(value):
					(existing as Array).erase(value)
		_:
			return false
	return true


func remove(registry: String, id: String) -> bool:
	if _registry_registered.has(registry) and (_registry_registered[registry] as Dictionary).has(id):
		(_registry_registered[registry] as Dictionary).erase(id)
		return true
	return false


func revert(registry: String, id: Variant, fields: Array = []) -> bool:
	if not (id is String):
		push_warning("[Registry] revert('%s', ...): id must be a String" % registry)
		return false
	var sid := String(id)
	var changed := false
	if _registry_overridden.has(registry) and (_registry_overridden[registry] as Dictionary).has(sid):
		if not _registry_registered.has(registry):
			_registry_registered[registry] = {}
		(_registry_registered[registry] as Dictionary)[sid] = (_registry_overridden[registry] as Dictionary)[sid]
		(_registry_overridden[registry] as Dictionary).erase(sid)
		changed = true
	if _registry_patched.has(registry) and (_registry_patched[registry] as Dictionary).has(sid):
		var current := get_entry(registry, sid)
		if current is Object:
			var stash: Dictionary = (_registry_patched[registry] as Dictionary)[sid]
			var names := fields if not fields.is_empty() else stash.keys()
			for field in names:
				var name := String(field)
				if stash.has(name):
					current.set(name, stash[name])
					stash.erase(name)
					changed = true
			if stash.is_empty():
				(_registry_patched[registry] as Dictionary).erase(sid)
	return changed


func register_many(registry: String, entries: Dictionary) -> Dictionary:
	return _registry_many("register", registry, entries)


func override_many(registry: String, entries: Dictionary) -> Dictionary:
	return _registry_many("override", registry, entries)


func patch_many(registry: String, entries: Dictionary) -> Dictionary:
	return _registry_many("patch", registry, entries)


func append_many(registry: String, field: String, entries: Dictionary, allow_duplicates: bool = false) -> Dictionary:
	return _registry_array_many("append", registry, field, entries, allow_duplicates)


func prepend_many(registry: String, field: String, entries: Dictionary, allow_duplicates: bool = false) -> Dictionary:
	return _registry_array_many("prepend", registry, field, entries, allow_duplicates)


func remove_from_many(registry: String, field: String, entries: Dictionary) -> Dictionary:
	return _registry_array_many("remove_from", registry, field, entries, false)


func revert_many(registry: String, entries: Dictionary) -> Dictionary:
	var results: Dictionary = {}
	var ok := true
	for id in entries.keys():
		var fields: Array = []
		if entries[id] is Array:
			fields = entries[id]
		var result := revert(registry, String(id), fields)
		results[id] = result
		ok = ok and result
	return {"ok": ok, "results": results}


func remove_many(registry: String, ids: Array) -> Dictionary:
	var results: Dictionary = {}
	var ok := true
	for id in ids:
		var sid := String(id)
		var result := remove(registry, sid)
		results[sid] = result
		ok = ok and result
	return {"ok": ok, "results": results}


func _registry_many(verb: String, registry: String, entries: Dictionary) -> Dictionary:
	var results: Dictionary = {}
	var ok := true
	for id in entries.keys():
		var sid := String(id)
		var result := false
		match verb:
			"register": result = register(registry, sid, entries[id])
			"override": result = override(registry, sid, entries[id])
			"patch": result = patch(registry, sid, entries[id] if entries[id] is Dictionary else {})
		results[sid] = result
		ok = ok and result
	return {"ok": ok, "results": results}


func _registry_array_many(verb: String, registry: String, field: String, entries: Dictionary, allow_duplicates: bool) -> Dictionary:
	var results: Dictionary = {}
	var ok := true
	for id in entries.keys():
		var sid := String(id)
		var result := false
		match verb:
			"append": result = append(registry, sid, field, entries[id], allow_duplicates)
			"prepend": result = prepend(registry, sid, field, entries[id], allow_duplicates)
			"remove_from": result = remove_from(registry, sid, field, entries[id])
		results[sid] = result
		ok = ok and result
	return {"ok": ok, "results": results}


func get_entry(registry: String, id: String) -> Variant:
	if _registry_registered.has(registry):
		return (_registry_registered[registry] as Dictionary).get(id)
	return null


func has(registry: String, id: String, include_vanilla: bool = true) -> bool:
	return _registry_registered.has(registry) and (_registry_registered[registry] as Dictionary).has(id)


func keys(registry: String, include_vanilla: bool = true) -> Array[String]:
	var out: Array[String] = []
	if _registry_registered.has(registry):
		for id in (_registry_registered[registry] as Dictionary).keys():
			out.append(String(id))
	return out


func list(registry: String, include_vanilla: bool = true) -> Dictionary:
	return (_registry_registered.get(registry, {}) as Dictionary).duplicate()


func find(registry: String, predicate: Callable, include_vanilla: bool = true) -> Array:
	var out: Array = []
	for id in list(registry, include_vanilla).keys():
		var entry = get_entry(registry, String(id))
		if entry != null and bool(predicate.call(entry)):
			out.append({"id": String(id), "entry": entry})
	return out


func _generic_bundle_result(entries: Dictionary, label: String) -> Dictionary:
	push_warning("[Registry] %s is not implemented for this game. Use hooks or explicit resource overrides." % label)
	var results: Dictionary = {}
	for id in entries.keys():
		results[String(id)] = {"ok": false}
	return {"ok": entries.is_empty(), "results": results}


func register_item(entries: Dictionary) -> Dictionary: return _generic_bundle_result(entries, "register_item")
func register_furniture(entries: Dictionary) -> Dictionary: return _generic_bundle_result(entries, "register_furniture")
func register_weapon(entries: Dictionary) -> Dictionary: return _generic_bundle_result(entries, "register_weapon")
func register_magazine(entries: Dictionary) -> Dictionary: return _generic_bundle_result(entries, "register_magazine")
func register_attachment(entries: Dictionary) -> Dictionary: return _generic_bundle_result(entries, "register_attachment")
func register_ai_loadout(entries: Dictionary) -> Dictionary: return _generic_bundle_result(entries, "register_ai_loadout")


func _scene_nodes_connect_listener() -> void:
	pass


func setup(plan: Array) -> Dictionary:
	var results: Array = []
	var all_ok := true
	for entry in plan:
		var r: Dictionary = _setup_run_entry(entry)
		results.append(r)
		if not bool(r.get("ok", false)):
			all_ok = false
	return {"ok": all_ok, "results": results}


func _setup_run_entry(entry: Variant) -> Dictionary:
	if not (entry is Array):
		return {"verb": "<malformed>", "ok": false, "error": "entry is not an Array"}
	var arr: Array = entry
	if arr.is_empty():
		return {"verb": "<empty>", "ok": false, "error": "entry is empty"}
	var verb: String = String(arr[0])
	match verb:
		"register":
			return _setup_dispatch_many("register", arr, _bind_register_many())
		"override":
			return _setup_dispatch_many("override", arr, _bind_override_many())
		"patch":
			return _setup_dispatch_many("patch", arr, _bind_patch_many())
		"append":
			return _setup_dispatch_array_op("append", arr)
		"prepend":
			return _setup_dispatch_array_op("prepend", arr)
		"remove_from":
			return _setup_dispatch_array_op("remove_from", arr)
		"revert":
			return _setup_dispatch_many("revert", arr, _bind_revert_many())
		"remove":
			if arr.size() != 3:
				return {"verb": verb, "ok": false, "error": "expected [\"remove\", reg, [ids]]"}
			if not (arr[2] is Array):
				return {"verb": verb, "ok": false, "error": "expected ids Array as 3rd arg"}
			var rm: Dictionary = remove_many(String(arr[1]), arr[2])
			return {"verb": verb, "ok": rm.ok, "results": rm.results}
		"hooks":
			if arr.size() != 2:
				return {"verb": verb, "ok": false, "error": "expected [\"hooks\", {name: cb, ...}]"}
			if not (arr[1] is Dictionary):
				return {"verb": verb, "ok": false, "error": "expected hooks dict as 2nd arg"}
			var hr: Dictionary = hook_many(arr[1])
			return {"verb": verb, "ok": hr.ok, "results": hr.results}
		"register_item":
			return _setup_dispatch_aggregator(verb, arr, _bind_register_item())
		"register_weapon":
			return _setup_dispatch_aggregator(verb, arr, _bind_register_weapon())
		"register_magazine":
			return _setup_dispatch_aggregator(verb, arr, _bind_register_magazine())
		"register_attachment":
			return _setup_dispatch_aggregator(verb, arr, _bind_register_attachment())
		"register_furniture":
			return _setup_dispatch_aggregator(verb, arr, _bind_register_furniture())
		"register_ai_loadout":
			return _setup_dispatch_aggregator(verb, arr, _bind_register_ai_loadout())
		"when":
			return _setup_dispatch_when(arr)
		_:
			return {"verb": verb, "ok": false, "error": "unknown verb"}


func _setup_dispatch_many(verb: String, arr: Array, many_fn: Callable) -> Dictionary:
	if arr.size() != 3:
		return {"verb": verb, "ok": false, "error": "expected [\"%s\", reg, {id: payload}]" % verb}
	if not (arr[2] is Dictionary):
		return {"verb": verb, "ok": false, "error": "expected payload dict as 3rd arg"}
	var res: Dictionary = many_fn.call(String(arr[1]), arr[2])
	return {"verb": verb, "ok": res.ok, "results": res.results}


func _setup_dispatch_array_op(verb: String, arr: Array) -> Dictionary:
	if arr.size() < 4 or arr.size() > 5:
		return {"verb": verb, "ok": false, "error": "expected [\"%s\", reg, field, {id: values}, allow_duplicates?]" % verb}
	if not (arr[3] is Dictionary):
		return {"verb": verb, "ok": false, "error": "expected payload dict as 4th arg"}
	var reg: String = String(arr[1])
	var field: String = String(arr[2])
	var entries: Dictionary = arr[3]
	var allow_dups: bool = arr.size() == 5 and bool(arr[4])
	var res: Dictionary
	match verb:
		"append":      res = append_many(reg, field, entries, allow_dups)
		"prepend":     res = prepend_many(reg, field, entries, allow_dups)
		"remove_from": res = remove_from_many(reg, field, entries)
		_:
			return {"verb": verb, "ok": false, "error": "internal: bad array-op verb"}
	return {"verb": verb, "ok": res.ok, "results": res.results}


func _setup_dispatch_when(arr: Array) -> Dictionary:
	if arr.size() != 3:
		return {"verb": "when", "ok": false, "error": "expected [\"when\", predicate, sub_plan]"}
	if not (arr[2] is Array):
		return {"verb": "when", "ok": false, "error": "sub_plan must be an Array"}
	var truthy: bool = _setup_evaluate_predicate(arr[1])
	if not truthy:
		return {"verb": "when", "evaluated": false, "ok": true}
	var inner: Dictionary = setup(arr[2])
	return {"verb": "when", "evaluated": true, "ok": inner.ok, "results": inner.results}


func _setup_evaluate_predicate(p: Variant) -> bool:
	if p is Callable:
		return bool((p as Callable).call())
	if p is bool or p is int or p is float:
		return bool(p)
	if p == null:
		return false
	push_warning("[Registry] setup: when-predicate has unexpected type %s; treating as false" % typeof(p))
	return false


func _bind_register_many() -> Callable: return Callable(self, "register_many")
func _bind_override_many() -> Callable: return Callable(self, "override_many")
func _bind_patch_many() -> Callable:    return Callable(self, "patch_many")
func _bind_revert_many() -> Callable:   return Callable(self, "revert_many")


func _setup_dispatch_aggregator(verb: String, arr: Array, agg_fn: Callable) -> Dictionary:
	if arr.size() != 2:
		return {"verb": verb, "ok": false, "error": "expected [\"%s\", {id: data, ...}]" % verb}
	if not (arr[1] is Dictionary):
		return {"verb": verb, "ok": false, "error": "expected payload dict as 2nd arg"}
	var res: Dictionary = agg_fn.call(arr[1])
	return {"verb": verb, "ok": res.get("ok", false), "results": res.get("results", {})}


func _bind_register_item() -> Callable:       return Callable(self, "register_item")
func _bind_register_weapon() -> Callable:     return Callable(self, "register_weapon")
func _bind_register_magazine() -> Callable:   return Callable(self, "register_magazine")
func _bind_register_attachment() -> Callable: return Callable(self, "register_attachment")
func _bind_register_furniture() -> Callable:  return Callable(self, "register_furniture")
func _bind_register_ai_loadout() -> Callable: return Callable(self, "register_ai_loadout")


func _rtv_collect_nodes_by_class(node: Node, cls_name: String, out: Array) -> void:
	var scr := node.get_script() as GDScript
	if scr != null:
		var matched := false
		var s: GDScript = scr
		var depth := 0
		while s != null and depth < 8:
			if str(s.get_global_name()) == cls_name:
				matched = true
				break
			s = s.get_base_script() as GDScript
			depth += 1
		if matched:
			out.append(node)
	for child in node.get_children():
		_rtv_collect_nodes_by_class(child, cls_name, out)



const _GDSC_MAGIC := "GDSC"
const _GDSC_TOKEN_BITS := 8
const _GDSC_TOKEN_MASK := (1 << (_GDSC_TOKEN_BITS - 1)) - 1
const _GDSC_TOKEN_BYTE_MASK := 0x80

const _TOKEN_TEXT := {
	4: "<", 5: "<=", 6: ">", 7: ">=", 8: "==", 9: "!=",
	10: "and", 11: "or", 12: "not", 13: "&&", 14: "||", 15: "!",
	16: "&", 17: "|", 18: "~", 19: "^", 20: "<<", 21: ">>",
	22: "+", 23: "-", 24: "*", 25: "**", 26: "/", 27: "%",
	28: "=", 29: "+=", 30: "-=", 31: "*=", 32: "**=", 33: "/=",
	34: "%=", 35: "<<=", 36: ">>=", 37: "&=", 38: "|=", 39: "^=",
	40: "if", 41: "elif", 42: "else", 43: "for", 44: "while",
	45: "break", 46: "continue", 47: "pass", 48: "return", 49: "match", 50: "when",
	51: "as", 52: "assert", 53: "await", 54: "breakpoint", 55: "class",
	56: "class_name", 57: "const", 58: "enum", 59: "extends", 60: "func",
	61: "in", 62: "is", 63: "namespace", 64: "preload", 65: "self",
	66: "signal", 67: "static", 68: "super", 69: "trait", 70: "var",
	71: "void", 72: "yield",
	73: "[", 74: "]", 75: "{", 76: "}", 77: "(", 78: ")",
	79: ",", 80: ";", 81: ".", 82: "..", 83: "...",
	84: ":", 85: "$", 86: "->", 87: "_",
	91: "PI", 92: "TAU", 93: "INF", 94: "NAN",
	96: "`", 97: "?",
}

const _SPACE_BEFORE := {
	4: 1, 5: 1, 6: 1, 7: 1, 8: 1, 9: 1,
	10: 1, 11: 1, 12: 1, 13: 1, 14: 1,
	16: 1, 17: 1, 19: 1, 20: 1, 21: 1,
	22: 1, 23: 1, 24: 1, 25: 1, 26: 1, 27: 1,
	28: 1, 29: 1, 30: 1, 31: 1, 32: 1, 33: 1,
	34: 1, 35: 1, 36: 1, 37: 1, 38: 1, 39: 1,
	40: 1, 42: 1, 51: 1, 61: 1, 62: 1,
	86: 1,
}

const _SPACE_AFTER := {
	79: 1, 80: 1, 86: 1,
	4: 1, 5: 1, 6: 1, 7: 1, 8: 1, 9: 1,
	10: 1, 11: 1, 12: 1, 13: 1, 14: 1, 15: 1,
	16: 1, 17: 1, 19: 1, 20: 1, 21: 1,
	22: 1, 23: 1, 24: 1, 25: 1, 26: 1, 27: 1,
	28: 1, 29: 1, 30: 1, 31: 1, 32: 1, 33: 1,
	34: 1, 35: 1, 36: 1, 37: 1, 38: 1, 39: 1,
	84: 1,
	1: 1,
	40: 1, 41: 1, 42: 1, 43: 1, 44: 1,
	45: 1, 46: 1, 47: 1, 48: 1, 49: 1, 50: 1,
	51: 1, 52: 1, 53: 1, 54: 1, 55: 1,
	56: 1, 57: 1, 58: 1, 59: 1, 60: 1,
	61: 1, 62: 1, 63: 1, 64: 1, 65: 1,
	66: 1, 67: 1, 68: 1, 69: 1, 70: 1,
	71: 1, 72: 1,
}

func _detokenize_script(script_path: String) -> String:
	if _pck_zero_byte_paths.has(script_path):
		return ""
	var raw := PackedByteArray()

	var f := FileAccess.open(script_path, FileAccess.READ)
	if f:
		raw = f.get_buffer(f.get_length())
		f.close()

	if raw.is_empty():
		var glob_path := ProjectSettings.globalize_path(script_path)
		f = FileAccess.open(glob_path, FileAccess.READ)
		if f:
			raw = f.get_buffer(f.get_length())
			f.close()

	if raw.is_empty():
		var gdc_path := script_path.replace(".gd", ".gdc")
		raw = FileAccess.get_file_as_bytes(gdc_path)

	if raw.is_empty():
		_log_warning("[Detokenize] Cannot read bytes from: %s (tried res://, globalized, .gdc)" % script_path)
		return ""

	if raw.size() < 12:
		return ""
	var magic := raw.slice(0, 4).get_string_from_ascii()
	if magic != _GDSC_MAGIC:
		var text := raw.get_string_from_utf8()
		if not text.is_empty() and (text.begins_with("extends") or text.begins_with("class_name") or text.begins_with("@")):
			return text
		_log_warning("[Detokenize] Not a GDSC file: " + script_path)
		return ""

	var version := raw.decode_u32(4)
	if version != 100 and version != 101:
		_log_critical("[Detokenize] Unsupported GDSC version %d in %s (expected 100 or 101)" % [version, script_path])
		return ""

	var decompressed_size := raw.decode_u32(8)
	var buf: PackedByteArray
	if decompressed_size == 0:
		buf = raw.slice(12)
	else:
		var compressed := raw.slice(12)
		buf = compressed.decompress(decompressed_size, FileAccess.COMPRESSION_ZSTD)
		if buf.is_empty():
			_log_critical("[Detokenize] ZSTD decompression failed for: " + script_path)
			return ""

	var meta_size := 20 if version == 100 else 16
	if buf.size() < meta_size:
		return ""
	var ident_count: int = buf.decode_u32(0)
	var const_count: int = buf.decode_u32(4)
	var line_count: int  = buf.decode_u32(8)
	var token_count: int
	if version == 100:
		token_count = buf.decode_u32(16)
	else:
		token_count = buf.decode_u32(12)

	var offset := meta_size

	var identifiers: Array[String] = []
	for _i in ident_count:
		if offset + 4 > buf.size():
			break
		var str_len: int = buf.decode_u32(offset)
		offset += 4
		var s := ""
		for _j in str_len:
			if offset + 4 > buf.size():
				break
			var b0: int = buf[offset] ^ 0xb6
			var b1: int = buf[offset + 1] ^ 0xb6
			var b2: int = buf[offset + 2] ^ 0xb6
			var b3: int = buf[offset + 3] ^ 0xb6
			var code_point: int = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
			if code_point > 0:
				s += String.chr(code_point)
			offset += 4
		identifiers.append(s)

	var constants: Array = []
	for _i in const_count:
		if offset + 4 > buf.size():
			break
		var remaining := buf.slice(offset)
		var val = bytes_to_var(remaining)
		constants.append(val)
		var encoded := var_to_bytes(val)
		offset += encoded.size()

	var line_map := {}
	var col_map := {}
	for _i in line_count:
		if offset + 8 > buf.size():
			break
		var tok_idx: int = buf.decode_u32(offset)
		var line_val: int = buf.decode_u32(offset + 4)
		line_map[tok_idx] = line_val
		offset += 8
	for _i in line_count:
		if offset + 8 > buf.size():
			break
		var tok_idx: int = buf.decode_u32(offset)
		var col_val: int = buf.decode_u32(offset + 4)
		col_map[tok_idx] = col_val
		offset += 8

	var tokens: Array = []
	for _i in token_count:
		if offset >= buf.size():
			break
		var token_len := 8 if (buf[offset] & _GDSC_TOKEN_BYTE_MASK) else 5
		if offset + token_len > buf.size():
			break
		var raw_type: int = buf.decode_u32(offset)
		var tk_type: int = raw_type & _GDSC_TOKEN_MASK
		var data_idx: int = raw_type >> _GDSC_TOKEN_BITS
		tokens.append([tk_type, data_idx])
		offset += token_len

	var result := _gdsc_reconstruct(tokens, identifiers, constants, line_map, col_map)
	if result.is_empty():
		return ""
	_log_info("[Detokenize] Reconstructed: %s (%d tokens, %d lines) -- parse OK" \
			% [script_path, tokens.size(), result.count("\n") + 1])
	return result

func _gdsc_reconstruct(tokens: Array, identifiers: Array[String], constants: Array,
		line_map: Dictionary, col_map: Dictionary) -> String:
	var lines := PackedStringArray()
	var current_line := ""
	var current_line_num := 1
	var need_space := false
	var prev_tk := -1
	var line_started := false

	for i in tokens.size():
		var tk: int = tokens[i][0]
		var idx: int = tokens[i][1]

		if line_map.has(i):
			var new_line: int = line_map[i]
			while current_line_num < new_line:
				lines.append(current_line)
				current_line = ""
				current_line_num += 1
				need_space = false
				line_started = false

		if tk == 99:
			break

		if tk == 88:
			lines.append(current_line)
			current_line = ""
			current_line_num += 1
			need_space = false
			line_started = false
			prev_tk = tk
			continue

		if tk == 89 or tk == 90:
			prev_tk = tk
			continue

		var text := ""
		if tk == 2:
			text = identifiers[idx] if idx < identifiers.size() else "<ident?>"
		elif tk == 1:
			var aname: String = identifiers[idx] if idx < identifiers.size() else "?"
			text = aname if aname.begins_with("@") else ("@" + aname)
		elif tk == 3:
			text = _gdsc_variant_to_source(constants[idx] if idx < constants.size() else null)
		elif _TOKEN_TEXT.has(tk):
			text = _TOKEN_TEXT[tk]
		else:
			text = "<tk%d>" % tk

		if not line_started:
			line_started = true
			if col_map.has(i):
				var col: int = col_map[i]
				var tabs: int = col / 4
				for _t in tabs:
					current_line += "\t"

		var add_space_before := false
		if need_space and not current_line.is_empty() and not current_line.ends_with("\t"):
			if _SPACE_BEFORE.has(tk):
				add_space_before = true
			elif tk == 2 or tk == 3 or tk == 1 or (tk >= 40 and tk <= 72):
				var skip_anno := (prev_tk == 1 and (tk == 2 or tk == 1))
				if not skip_anno \
						and prev_tk != 77 and prev_tk != 73 \
						and prev_tk != 81 and prev_tk != 85 \
						and prev_tk != 18 \
						and prev_tk != 15 and prev_tk != 89 \
						and prev_tk != 88 and prev_tk != -1:
					add_space_before = true
			elif tk == 77:
				if prev_tk >= 40 and prev_tk <= 50:
					add_space_before = true
			elif tk == 12 or tk == 15:
				add_space_before = true

		if add_space_before and not current_line.ends_with(" ") and not current_line.ends_with("\t"):
			current_line += " "

		current_line += text

		need_space = _SPACE_AFTER.has(tk) or tk == 2 or tk == 3 \
				or tk == 78 or tk == 74 or tk == 76 \
				or tk == 91 or tk == 92 or tk == 93 \
				or tk == 94 or tk == 87

		prev_tk = tk

	if not current_line.is_empty():
		lines.append(current_line)

	var result := "\n".join(lines)
	if not result.ends_with("\n"):
		result += "\n"
	return result

func _gdsc_variant_to_source(value: Variant) -> String:
	if value == null:
		return "null"
	match typeof(value):
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_INT:
			return str(value)
		TYPE_FLOAT:
			var s := str(value)
			if "." not in s and "e" not in s and "inf" not in s.to_lower() and "nan" not in s.to_lower():
				s += ".0"
			return s
		TYPE_STRING:
			return '"%s"' % str(value).c_escape()
		TYPE_STRING_NAME:
			return '&"%s"' % str(value).c_escape()
		TYPE_NODE_PATH:
			return '^"%s"' % str(value).c_escape()
		TYPE_VECTOR2:
			return "Vector2(%s, %s)" % [_gdsc_variant_to_source(value.x), _gdsc_variant_to_source(value.y)]
		TYPE_VECTOR2I:
			return "Vector2i(%s, %s)" % [value.x, value.y]
		TYPE_VECTOR3:
			return "Vector3(%s, %s, %s)" % [_gdsc_variant_to_source(value.x), _gdsc_variant_to_source(value.y), _gdsc_variant_to_source(value.z)]
		TYPE_VECTOR3I:
			return "Vector3i(%s, %s, %s)" % [value.x, value.y, value.z]
		TYPE_COLOR:
			return "Color(%s, %s, %s, %s)" % [_gdsc_variant_to_source(value.r), _gdsc_variant_to_source(value.g), _gdsc_variant_to_source(value.b), _gdsc_variant_to_source(value.a)]
		TYPE_ARRAY:
			var parts := PackedStringArray()
			for item in value:
				parts.append(_gdsc_variant_to_source(item))
			return "[%s]" % ", ".join(parts)
		TYPE_DICTIONARY:
			var parts := PackedStringArray()
			for k in value:
				parts.append("%s: %s" % [_gdsc_variant_to_source(k), _gdsc_variant_to_source(value[k])])
			return "{%s}" % ", ".join(parts)
		_:
			return str(value)

func _read_vanilla_source(script_path: String) -> String:
	var cache_file := VANILLA_CACHE_DIR.path_join(script_path.trim_prefix("res://"))
	if FileAccess.file_exists(cache_file):
		var cached := FileAccess.get_file_as_string(cache_file)
		if not cached.is_empty():
			return cached

	var source := _detokenize_script(script_path)
	if source.is_empty():
		return ""

	if "_rtv_ready_done" in source or 'Engine.get_meta("RTVModLib"' in source:
		_log_critical("[Hooks] Detokenized source for %s already contains rewrite markers -- possible stale overlay. Delete %s and restart." \
				% [script_path, ProjectSettings.globalize_path(HOOK_PACK_DIR)])
		return ""
	_save_vanilla_source(script_path, source)
	return source

func _save_vanilla_source(script_path: String, source: String) -> void:
	if source.is_empty():
		return
	var cache_file := VANILLA_CACHE_DIR.path_join(script_path.trim_prefix("res://"))
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(cache_file.get_base_dir()))
	var f := FileAccess.open(cache_file, FileAccess.WRITE)
	if f:
		f.store_string(source)
		f.close()

func _probe_gdsc_version() -> int:
	var probe_paths := ["res://menu/menu.gd", "res://battle/battle.gd",
			"res://globals/game_manager.gd", "res://towers/base_tower.gd"]
	for p in probe_paths:
		var raw := FileAccess.get_file_as_bytes(p)
		if raw.size() < 12:
			raw = FileAccess.get_file_as_bytes(p.replace(".gd", ".gdc"))
			if raw.size() < 12:
				continue
		if raw.slice(0, 4).get_string_from_ascii() != _GDSC_MAGIC:
			continue
		return int(raw.decode_u32(4))
	return -1



const GAME_SCRIPT_PATHS: Array[String] = [
	"res://abilities/missile/missile.gd",
	"res://abilities/strafing_run/strafing_run.gd",
	"res://audio/audio_manager.gd",
	"res://audio/tower_audio_player.gd",
	"res://battle/ability_button.gd",
	"res://battle/active_abilities_spawner.gd",
	"res://battle/battle.gd",
	"res://battle/battle_camera.gd",
	"res://battle/battle_sounds.gd",
	"res://battle/enemies_alive_label.gd",
	"res://battle/enemies_killed_label.gd",
	"res://battle/enemy_spawner.gd",
	"res://battle/explosion_sprite.gd",
	"res://battle/health_progress_bar.gd",
	"res://battle/hud/enemies_to_spawn_label.gd",
	"res://battle/rigidbodies_debug_texture_rect.gd",
	"res://battle/shadow_texture_rect.gd",
	"res://battle/sim_running_button.gd",
	"res://battle/spawner_indicator_sprite.gd",
	"res://battle/time_container.gd",
	"res://battle/tower_button.gd",
	"res://battle/tower_placement.gd",
	"res://battle/ui.gd",
	"res://globals/constants.gd",
	"res://globals/dev_menu.gd",
	"res://globals/dev_options.gd",
	"res://globals/game_manager.gd",
	"res://globals/gpu_sim.gd",
	"res://globals/number_formatter.gd",
	"res://globals/save_system.gd",
	"res://globals/scene_transition/scene_transition.gd",
	"res://globals/steamy.gd",
	"res://globals/tooltip_manager/tooltip_manager.gd",
	"res://globals/tooltip_manager/tooltip_panel.gd",
	"res://globals/tutorial_manager.gd",
	"res://gpu_sim/gpu.gd",
	"res://gpu_sim/rigidbody.gd",
	"res://levels/enemy_spawn_wave.gd",
	"res://levels/enemy_spawner_data.gd",
	"res://levels/enemy_spawner_editor.gd",
	"res://levels/level_data.gd",
	"res://levels/level_editor.gd",
	"res://levels/world/world_gen.gd",
	"res://menu/background_blur.gd",
	"res://menu/menu.gd",
	"res://menu/new_game_dialog.gd",
	"res://menu/quit_popup.gd",
	"res://options/options.gd",
	"res://options/options_menu.gd",
	"res://startup_scene/startup.gd",
	"res://tech_tree/crt_effect.gd",
	"res://tech_tree/currency.gd",
	"res://tech_tree/hud/tech_tree_hud.gd",
	"res://tech_tree/hud/tower_stats/tower_stats.gd",
	"res://tech_tree/hud/tower_stats/tower_stats_label.gd",
	"res://tech_tree/hud/tower_stats_button.gd",
	"res://tech_tree/level_container.gd",
	"res://tech_tree/level_panel.gd",
	"res://tech_tree/level_selection.gd",
	"res://tech_tree/nodes/tech_tree_node.gd",
	"res://tech_tree/nodes_editor.gd",
	"res://tech_tree/tech_tree.gd",
	"res://tech_tree/tooltips/upgrade_tooltip.gd",
	"res://tech_tree/upgrades/upgrade.gd",
	"res://tech_tree/upgrades/upgrade_data.gd",
	"res://towers/base_tower.gd",
	"res://towers/cannon/cannon.gd",
	"res://towers/flamethrower/flamethrower.gd",
	"res://towers/gunner/gunner.gd",
	"res://towers/minigun_robot/minigun_robot.gd",
	"res://towers/mortar/mortar.gd",
	"res://towers/mortar/mortar_shell.gd",
	"res://tutorial/battle_tutorial.gd",
]

static func _is_game_script_path(path: String) -> bool:
	return path.begins_with("res://") \
			and path.ends_with(".gd") \
			and not path.begins_with("res://addons/") \
			and path != MODLOADER_RES_PATH

func _script_zip_entry(res_path: String) -> String:
	return res_path.trim_prefix("res://")

func _script_remap_entry(res_path: String) -> String:
	return _script_zip_entry(res_path) + ".remap"

func _script_gdc_entry(res_path: String) -> String:
	return _script_zip_entry(res_path).trim_suffix(".gd") + ".gdc"

func _find_game_script_by_filename(file_name: String) -> String:
	var wanted := file_name.to_lower()
	for path: String in _enumerate_game_scripts():
		if path.get_file().to_lower() == wanted:
			return path
	return ""

func _canonical_hook_script_path(script_path: String) -> String:
	if script_path.begins_with("res://"):
		return script_path
	var by_file := _find_game_script_by_filename(script_path.get_file())
	if by_file != "":
		return by_file
	return "res://" + script_path.trim_prefix("/")

func _build_class_name_lookup() -> void:
	_class_name_to_path.clear()
	var cache := ConfigFile.new()
	var load_err := cache.load("res://.godot/global_script_class_cache.cfg")
	if load_err == OK:
		var class_list: Array = cache.get_value("", "list", [])
		var skipped := 0
		for entry in class_list:
			var cn: String = str(entry.get("class", ""))
			var path: String = str(entry.get("path", ""))
			if cn != "" and path != "":
				_class_name_to_path[cn] = path
			else:
				skipped += 1
		if _class_name_to_path.size() < 10:
			_log_warning("Class cache has only %d entries (raw=%d) -- mod shadowing detected, using hardcoded fallback" \
					% [_class_name_to_path.size(), class_list.size()])
			_class_name_to_path = _get_hardcoded_class_map()
		else:
			_log_info("Loaded %d class_name mappings from game cache" % _class_name_to_path.size())
	else:
		_log_warning("Could not load global_script_class_cache.cfg -- using hardcoded fallback")
		_class_name_to_path = _get_hardcoded_class_map()

func _get_hardcoded_class_map() -> Dictionary:
	return {
		"BackgroundBlur": "res://menu/background_blur.gd",
		"BaseTower": "res://towers/base_tower.gd",
		"Battle": "res://battle/battle.gd",
		"BattleCamera": "res://battle/battle_camera.gd",
		"BattleSounds": "res://battle/battle_sounds.gd",
		"Cannon": "res://towers/cannon/cannon.gd",
		"Constants": "res://globals/constants.gd",
		"Currency": "res://tech_tree/currency.gd",
		"EnemySpawnWave": "res://levels/enemy_spawn_wave.gd",
		"EnemySpawner": "res://battle/enemy_spawner.gd",
		"EnemySpawnerData": "res://levels/enemy_spawner_data.gd",
		"EnemySpawnerEditor": "res://levels/enemy_spawner_editor.gd",
		"ExplosionSprite": "res://battle/explosion_sprite.gd",
		"Flamethrower": "res://towers/flamethrower/flamethrower.gd",
		"GPU": "res://gpu_sim/gpu.gd",
		"Gunner": "res://towers/gunner/gunner.gd",
		"LevelData": "res://levels/level_data.gd",
		"LevelEditor": "res://levels/level_editor.gd",
		"LevelPanel": "res://tech_tree/level_panel.gd",
		"Menu": "res://menu/menu.gd",
		"MinigunRobot": "res://towers/minigun_robot/minigun_robot.gd",
		"Missile": "res://abilities/missile/missile.gd",
		"Mortar": "res://towers/mortar/mortar.gd",
		"MortarShell": "res://towers/mortar/mortar_shell.gd",
		"Rigidbody": "res://gpu_sim/rigidbody.gd",
		"StrafingRun": "res://abilities/strafing_run/strafing_run.gd",
		"TechTreeHud": "res://tech_tree/hud/tech_tree_hud.gd",
		"TechTreeNode": "res://tech_tree/nodes/tech_tree_node.gd",
		"TooltipPanel": "res://globals/tooltip_manager/tooltip_panel.gd",
		"TowerAudioPlayer": "res://audio/tower_audio_player.gd",
		"TowerButton": "res://battle/tower_button.gd",
		"TowerPlacement": "res://battle/tower_placement.gd",
		"TowerStatsLabel": "res://tech_tree/hud/tower_stats/tower_stats_label.gd",
		"Upgrade": "res://tech_tree/upgrades/upgrade.gd",
		"UpgradeData": "res://tech_tree/upgrades/upgrade_data.gd",
		"UpgradeTooltip": "res://tech_tree/tooltips/upgrade_tooltip.gd",
		"WorldGen": "res://levels/world/world_gen.gd",
	}

func _enumerate_game_scripts() -> Array[String]:
	if not _all_game_script_paths.is_empty():
		return _all_game_script_paths
	var exe_dir := OS.get_executable_path().get_base_dir()
	var candidates := [OS.get_executable_path().get_file().get_basename() + ".pck"]
	for cand in candidates:
		var pck_path := exe_dir.path_join(cand)
		if not FileAccess.file_exists(pck_path):
			continue
		var paths := _parse_pck_file_list(pck_path)
		if paths.is_empty():
			continue
		var scripts: Array[String] = []
		for p in paths:
			var normalized := p
			if not normalized.begins_with("res://"):
				normalized = "res://" + normalized.trim_prefix("/")
			var canonical := normalized
			if canonical.ends_with(".gd.remap"):
				canonical = canonical.substr(0, canonical.length() - 6)
			elif canonical.ends_with(".remap"):
				canonical = canonical.substr(0, canonical.length() - 6)
			if canonical.ends_with(".gdc"):
				canonical = canonical.substr(0, canonical.length() - 4) + ".gd"
			if not _is_game_script_path(canonical):
				continue
			if canonical.ends_with(".gd") and canonical not in scripts:
				scripts.append(canonical)
		_log_info("[OrcKitCodegen] parsed %s -- %d total file(s), %d game script(s)" \
				% [cand, paths.size(), scripts.size()])
		_all_game_script_paths = scripts
		return scripts
	_all_game_script_paths = GAME_SCRIPT_PATHS.duplicate()
	_log_info("[OrcKitCodegen] using embedded playtest script manifest (%d game script paths)" \
			% _all_game_script_paths.size())
	return _all_game_script_paths

func _collect_module_scope_scene_preloads(source: String) -> PackedStringArray:
	var scenes := PackedStringArray()
	var re := RegEx.new()
	re.compile("preload\\(\"(res://[^\"]+\\.(?:tscn|scn))\"\\)")
	for line in source.split("\n"):
		if line.is_empty():
			continue
		var first := line[0]
		if first == "\t" or first == " ":
			continue
		var trimmed := line.strip_edges(true, false)
		if trimmed.is_empty() or trimmed.begins_with("#"):
			continue
		if "preload(" not in line:
			continue
		for m in re.search_all(line):
			var scene_path := m.get_string(1)
			if scene_path not in scenes:
				scenes.append(scene_path)
	return scenes

func _parse_pck_file_list(pck_path: String) -> PackedStringArray:
	const MAGIC_GDPC: int = 0x43504447
	const PACK_DIR_ENCRYPTED := 1
	const PACK_FORMAT_V2 := 2
	const PACK_FORMAT_V3 := 3
	var result := PackedStringArray()
	var f := FileAccess.open(pck_path, FileAccess.READ)
	if f == null:
		_log_warning("[PCK] cannot open: %s" % pck_path)
		return result

	var magic: int = f.get_32()
	if magic != MAGIC_GDPC:
		_log_warning("[PCK] %s: not a standalone PCK (magic=0x%x)" % [pck_path, magic])
		f.close()
		return result

	var pack_format_version: int = f.get_32()
	if pack_format_version < PACK_FORMAT_V2 or pack_format_version > PACK_FORMAT_V3:
		_log_warning("[PCK] %s: unsupported format version %d" % [pck_path, pack_format_version])
		f.close()
		return result

	f.get_32()
	f.get_32()
	f.get_32()
	var pack_flags: int = f.get_32()
	f.get_64()

	if pack_format_version == PACK_FORMAT_V3:
		f.seek(f.get_64())
	else:
		for i in 16:
			f.get_32()

	if pack_flags & PACK_DIR_ENCRYPTED:
		_log_warning("[PCK] %s: directory encrypted -- can't enumerate" % pck_path)
		f.close()
		return result

	var file_count: int = f.get_32()
	for i in file_count:
		var path_len: int = f.get_32()
		if path_len == 0 or path_len > 4096:
			_log_warning("[PCK] %s: suspicious path_len=%d at entry %d -- abort" \
					% [pck_path, path_len, i])
			break
		var path := f.get_buffer(path_len).get_string_from_utf8()
		f.get_64()
		var size: int = f.get_64()
		f.get_buffer(16)
		f.get_32()
		if not path.is_empty():
			result.append(path)
			if size == 0 and path.ends_with(".gd"):
				var res_path := path if path.begins_with("res://") else "res://" + path.trim_prefix("/")
				_pck_zero_byte_paths[res_path] = true

	f.close()
	return result


func _compile_regex() -> void:
	_re_take_over = RegEx.new()
	_re_take_over.compile('take_over_path\\s*\\(\\s*"(res://[^"]+)"')
	_re_extends = RegEx.new()
	_re_extends.compile('(?m)^extends\\s+"(res://[^"]+)"')
	_re_extends_classname = RegEx.new()
	_re_extends_classname.compile('(?m)^extends\\s+([A-Z]\\w+)\\s*$')
	_re_class_name = RegEx.new()
	_re_class_name.compile('(?m)^class_name\\s+(\\w+)')
	_re_func = RegEx.new()
	_re_func.compile('(?m)^(?:static\\s+)?func\\s+(\\w+)\\s*\\(')
	_re_preload = RegEx.new()
	_re_preload.compile('preload\\s*\\(\\s*"(res://[^"]+)"\\s*\\)')
	_re_filename_priority = RegEx.new()
	_re_filename_priority.compile('^(-?\\d+)-(.*)')
	_re_hook_call = RegEx.new()
	_re_hook_call.compile('\\.hook\\s*\\(\\s*"([A-Za-z_][\\w]*)-([A-Za-z_][\\w]*?)(?:-(?:pre|post|callback))?"')



func _rtv_compile_codegen_regex() -> void:
	if _rtv_re_extends != null:
		return
	_rtv_re_extends = RegEx.new()
	_rtv_re_extends.compile('^extends\\s+"?([\\w/.:"]+)"?')
	_rtv_re_class_name = RegEx.new()
	_rtv_re_class_name.compile('^class_name\\s+(\\w+)')
	_rtv_re_func = RegEx.new()
	_rtv_re_func.compile('^func\\s+(\\w+)\\s*\\(([^)]*)\\)(\\s*->\\s*([\\w\\[\\]]+))?\\s*:')
	_rtv_re_static_func = RegEx.new()
	_rtv_re_static_func.compile('^static\\s+func\\s+(\\w+)\\s*\\(([^)]*)\\)(\\s*->\\s*([\\w\\[\\]]+))?\\s*:')
	_rtv_re_var = RegEx.new()
	_rtv_re_var.compile('^(?:@export\\s+)?var\\s+(\\w+)')

func _rtv_extract_param_names(params: String) -> Array:
	var names: Array = []
	if params.strip_edges().is_empty():
		return names
	for p in params.split(","):
		var trimmed := (p as String).strip_edges()
		var without_type := trimmed.split(":")[0]
		var without_default := (without_type as String).split("=")[0]
		var name := (without_default as String).strip_edges()
		if not name.is_empty():
			names.append(name)
	return names

func _rtv_script_hook_prefix(filename: String) -> String:
	var stem := filename
	if stem.ends_with(".gd"):
		stem = stem.substr(0, stem.length() - 3)
	return stem.to_lower()


func _rtv_parse_script(filename: String, source: String) -> Dictionary:
	_rtv_compile_codegen_regex()
	var script := {
		"filename": filename,
		"path": filename,
		"extends": "",
		"class_name": null,
		"functions": [],
		"var_names": [],
	}
	var lines: PackedStringArray = source.split("\n")
	var func_starts: Array = []

	for line_num in lines.size():
		var line: String = lines[line_num]
		var trimmed := line.strip_edges()

		var m_ext := _rtv_re_extends.search(trimmed)
		if m_ext != null:
			script["extends"] = m_ext.get_string(1)

		var m_cn := _rtv_re_class_name.search(trimmed)
		if m_cn != null:
			script["class_name"] = m_cn.get_string(1)

		if not line.begins_with("\t") and not line.begins_with(" "):
			var m_var := _rtv_re_var.search(trimmed)
			if m_var != null:
				(script["var_names"] as Array).append(m_var.get_string(1))

		var m_sfunc := _rtv_re_static_func.search(trimmed)
		if m_sfunc != null:
			var ret_group = m_sfunc.get_string(4) if m_sfunc.get_start(4) != -1 else null
			func_starts.append([
				line_num, m_sfunc.get_string(1), m_sfunc.get_string(2),
				_rtv_extract_param_names(m_sfunc.get_string(2)), true,
				ret_group,
			])
			continue

		var m_func := _rtv_re_func.search(trimmed)
		if m_func != null:
			var ret_group2 = m_func.get_string(4) if m_func.get_start(4) != -1 else null
			func_starts.append([
				line_num, m_func.get_string(1), m_func.get_string(2),
				_rtv_extract_param_names(m_func.get_string(2)), false,
				ret_group2,
			])

	for idx in func_starts.size():
		var fs: Array = func_starts[idx]
		var line_num: int = fs[0]
		var name: String = fs[1]
		var params: String = fs[2]
		var param_names: Array = fs[3]
		var is_static: bool = fs[4]
		var return_type = fs[5]

		var body_start := line_num + 1
		var body_end := lines.size()
		if idx + 1 < func_starts.size():
			body_end = func_starts[idx + 1][0]

		var is_coroutine := false
		var has_return_value := false
		for i in range(body_start, body_end):
			if i >= lines.size():
				break
			var body_line := lines[i].strip_edges()
			if "await " in body_line:
				is_coroutine = true
			if body_line.begins_with("return ") and body_line.length() > 7:
				has_return_value = true

		if return_type != null and return_type != "void":
			has_return_value = true
		if return_type != null and return_type == "void":
			has_return_value = false

		(script["functions"] as Array).append({
			"name": name,
			"params": params,
			"param_names": param_names,
			"line_number": line_num + 1,
			"is_static": is_static,
			"return_type": return_type,
			"is_coroutine": is_coroutine,
			"has_return_value": has_return_value,
		})

	return script


func _rtv_rewrite_vanilla_source(source: String, parsed: Dictionary, method_mask: Dictionary = {}) -> String:
	var apply_mask: bool = not method_mask.is_empty()
	var hookable: Array = []
	for fe in parsed["functions"]:
		if fe["is_static"]:
			continue
		if apply_mask and not method_mask.has(fe["name"].to_lower()):
			continue
		hookable.append(fe)
	if hookable.is_empty():
		return source

	var hookable_names: Dictionary = {}
	for fe in hookable:
		hookable_names[fe["name"]] = true

	var src: String = source.replace("\r\n", "\n").replace("\r", "\n")

	var autofix := _rtv_autofix_legacy_syntax(src)
	src = autofix["source"]
	var af_total: int = int(autofix["bodyless"]) + int(autofix["tool"]) \
			+ int(autofix["onready"]) + int(autofix["export"]) + int(autofix.get("base", 0))
	if af_total > 0:
		_log_info("[Autofix] %s: %d bodyless, %d @tool, %d @onready, %d @export, %d base()->super -- legacy syntax normalized" \
				% [parsed.get("filename", "?"), autofix["bodyless"], autofix["tool"], autofix["onready"], autofix["export"], autofix.get("base", 0)])


	var lines: PackedStringArray = src.split("\n")
	var current_hooked_method: String = ""
	for i in lines.size():
		var line: String = lines[i]
		if not line.is_empty() and line[0] != "\t" and line[0] != " ":
			current_hooked_method = ""
			if line.begins_with("func "):
				var open_paren := line.find("(")
				if open_paren >= 0:
					var name_end := open_paren
					while name_end > 5 and line[name_end - 1] == " ":
						name_end -= 1
					var method_name := line.substr(5, name_end - 5)
					if hookable_names.has(method_name):
						lines[i] = "func _rtv_vanilla_" + method_name + line.substr(name_end)
						current_hooked_method = method_name
			continue
		if current_hooked_method.is_empty():
			continue
		if not ("super" in line):
			continue
		lines[i] = _rewrite_bare_super(line, current_hooked_method)

	lines = _rtv_apply_prelude_injections(parsed.get("filename", ""), lines, "_rtv_vanilla_")

	var indent := _detect_indent_style(src)
	var prefix := _rtv_script_hook_prefix(parsed["filename"])
	var appended := "\n\n"
	for fe in hookable:
		appended += _rtv_dispatch_inline_src(fe, prefix, indent) + "\n"

	appended += _rtv_registry_injection(parsed["filename"], indent)

	return "\n".join(lines) + appended

func _rtv_registry_injection(filename: String, indent: String) -> String:
	return ""


func _rtv_apply_prelude_injections(filename: String, lines: PackedStringArray, rename_prefix: String) -> PackedStringArray:
	return lines
func _rewrite_bare_super(line: String, method_name: String) -> String:
	var scan_end := line.length()
	var comment_idx := line.find("#")
	if comment_idx >= 0:
		scan_end = comment_idx
	var out := line
	var cursor := 0
	while cursor < scan_end:
		var idx := out.find("super", cursor)
		if idx < 0 or idx >= scan_end:
			break
		if idx > 0:
			var prev := out[idx - 1]
			if prev == "." or prev == "_" or prev.to_upper() != prev.to_lower() \
					or (prev >= "0" and prev <= "9"):
				cursor = idx + 5
				continue
		var after := idx + 5
		while after < out.length() and out[after] == " ":
			after += 1
		if after >= out.length() or out[after] != "(":
			cursor = idx + 5
			continue
		var before := out.substr(0, idx)
		var rest := out.substr(after)
		out = before + "super." + method_name + rest
		var delta := 1 + method_name.length()
		cursor = idx + 5 + delta + 1
		scan_end += delta
	return out

func _detect_indent_style(source: String) -> String:
	for line: String in source.split("\n"):
		if line.is_empty():
			continue
		var ch: String = line[0]
		if ch != "\t" and ch != " ":
			continue
		var stripped := line.strip_edges()
		if stripped.is_empty() or stripped.begins_with("#"):
			continue
		if ch == "\t":
			return "\t"
		var n := 0
		while n < line.length() and line[n] == " ":
			n += 1
		if n > 0:
			return " ".repeat(n)
	return "\t"

func _rtv_leading_indent(line: String) -> String:
	var n := 0
	while n < line.length() and (line[n] == "\t" or line[n] == " "):
		n += 1
	return line.substr(0, n)

func _rtv_is_block_header(trimmed: String) -> bool:
	if not trimmed.ends_with(":"):
		return false
	if trimmed == "else:":
		return true
	for kw in ["if ", "elif ", "for ", "while ", "match ", "func ", "class "]:
		if trimmed.begins_with(kw):
			return true
	if trimmed.begins_with("static func "):
		return true
	return false

func _rtv_autofix_legacy_syntax(source: String) -> Dictionary:
	var lines: PackedStringArray = source.split("\n")
	var out: PackedStringArray = PackedStringArray()
	var indent_unit := _detect_indent_style(source)
	var fix_bodyless := 0
	var fix_tool := 0
	var fix_onready := 0
	var fix_export := 0
	var fix_base := 0

	var current_method: String = ""
	var method_line_indent: String = ""

	for i in lines.size():
		var line: String = lines[i]

		var lead := _rtv_leading_indent(line)
		if lead.is_empty() and not line.strip_edges().is_empty():
			var stripped_top := line.strip_edges()
			if stripped_top.begins_with("func "):
				var open_paren := stripped_top.find("(")
				if open_paren > 5:
					current_method = stripped_top.substr(5, open_paren - 5).strip_edges()
					method_line_indent = ""
			elif stripped_top.begins_with("static func ") or stripped_top.begins_with("@"):
				current_method = ""
			else:
				current_method = ""

		if not current_method.is_empty() and line.find("base(") >= 0:
			var rewritten := _rtv_rewrite_bare_base(line, current_method)
			if rewritten != line:
				line = rewritten
				fix_base += 1

		lead = _rtv_leading_indent(line)
		var body_text := line.substr(lead.length())
		if i == 0 and body_text.strip_edges() == "tool":
			line = lead + "@tool"
			fix_tool += 1
		elif body_text.begins_with("onready var "):
			line = lead + "@onready var " + body_text.substr(12)
			fix_onready += 1
		elif body_text.begins_with("export var "):
			line = lead + "@export var " + body_text.substr(11)
			fix_export += 1

		out.append(line)

		var trimmed := line.strip_edges()
		if not _rtv_is_block_header(trimmed):
			continue
		var header_indent := _rtv_leading_indent(line)
		var j := i + 1
		var has_body := false
		while j < lines.size():
			var next_line: String = lines[j]
			var next_trimmed := next_line.strip_edges()
			if next_trimmed.is_empty():
				j += 1
				continue
			if next_trimmed.begins_with("#"):
				j += 1
				continue
			var next_indent := _rtv_leading_indent(next_line)
			if next_indent.length() > header_indent.length() \
					and next_indent.begins_with(header_indent):
				has_body = true
			break
		if not has_body:
			out.append(header_indent + indent_unit + "pass")
			fix_bodyless += 1

	return {
		"source": "\n".join(out),
		"bodyless": fix_bodyless,
		"tool": fix_tool,
		"onready": fix_onready,
		"export": fix_export,
		"base": fix_base,
	}

func _rtv_rewrite_bare_base(line: String, method_name: String) -> String:
	var comment_start := line.find("#")
	var head: String = line if comment_start < 0 else line.substr(0, comment_start)
	var tail: String = "" if comment_start < 0 else line.substr(comment_start)
	var i := 0
	var rewritten := ""
	while i < head.length():
		if i + 4 <= head.length() and head.substr(i, 4) == "base":
			var prev_ok := true
			if i > 0:
				var pc := head[i - 1]
				if pc >= "a" and pc <= "z":
					prev_ok = false
				elif pc >= "A" and pc <= "Z":
					prev_ok = false
				elif pc >= "0" and pc <= "9":
					prev_ok = false
				elif pc == "_" or pc == ".":
					prev_ok = false
			var j := i + 4
			while j < head.length() and (head[j] == " " or head[j] == "\t"):
				j += 1
			if prev_ok and j < head.length() and head[j] == "(":
				var close_idx := _rtv_find_matching_paren(head, j)
				if close_idx == j + 1 and close_idx > 0:
					var k := close_idx + 1
					if k < head.length() and head[k] == ".":
						var name_start := k + 1
						var name_end := name_start
						while name_end < head.length() \
								and _rtv_is_ident_char(head[name_end]):
							name_end += 1
						if name_end > name_start \
								and name_end < head.length() \
								and head[name_end] == "(":
							var chained_name: String = head.substr(name_start, name_end - name_start)
							rewritten += "super." + chained_name
							i = name_end
							continue
				rewritten += "super." + method_name
				i += 4
				continue
		rewritten += head[i]
		i += 1
	return rewritten + tail

func _rtv_find_matching_paren(s: String, open_idx: int) -> int:
	if open_idx >= s.length() or s[open_idx] != "(":
		return -1
	var depth := 0
	var in_dq := false
	var in_sq := false
	var i := open_idx
	while i < s.length():
		var c := s[i]
		if in_dq:
			if c == "\\" and i + 1 < s.length():
				i += 2
				continue
			if c == "\"":
				in_dq = false
		elif in_sq:
			if c == "\\" and i + 1 < s.length():
				i += 2
				continue
			if c == "'":
				in_sq = false
		else:
			if c == "\"":
				in_dq = true
			elif c == "'":
				in_sq = true
			elif c == "(":
				depth += 1
			elif c == ")":
				depth -= 1
				if depth == 0:
					return i
		i += 1
	return -1

func _rtv_is_ident_char(c: String) -> bool:
	if c == "_":
		return true
	if c >= "a" and c <= "z":
		return true
	if c >= "A" and c <= "Z":
		return true
	if c >= "0" and c <= "9":
		return true
	return false

func _rtv_strip_helper_reload(source: String) -> Dictionary:
	var lines: PackedStringArray = source.split("\n")
	var out: PackedStringArray = PackedStringArray()
	var stripped: int = 0
	var i: int = 0
	while i < lines.size():
		var line: String = lines[i]
		if not line.begins_with("func "):
			out.append(line)
			i += 1
			continue
		var start: int = i
		var end: int = i + 1
		while end < lines.size():
			var bl: String = lines[end]
			if bl.length() > 0 and not (bl[0] == "\t" or bl[0] == " "):
				break
			end += 1
		var has_tov: bool = false
		for k in range(start, end):
			if ".take_over_path(" in lines[k]:
				has_tov = true
				break
		if has_tov:
			for k in range(start, end):
				var bl: String = lines[k]
				var trimmed: String = bl.strip_edges()
				if trimmed.ends_with(".reload()") and not trimmed.begins_with("#"):
					var before_paren: int = trimmed.find(".reload()")
					var ident_part: String = trimmed.substr(0, before_paren)
					var is_bare_call: bool = true
					for c in ident_part:
						if not (c == "_" or c == "." or (c >= "a" and c <= "z") \
								or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9")):
							is_bare_call = false
							break
					if is_bare_call:
						var indent_len: int = 0
						while indent_len < bl.length() and (bl[indent_len] == "\t" or bl[indent_len] == " "):
							indent_len += 1
						var indent: String = bl.substr(0, indent_len)
						stripped += 1
						continue
				out.append(bl)
		else:
			for k in range(start, end):
				out.append(lines[k])
		i = end
	return {"source": "\n".join(out), "stripped": stripped}


func _rtv_dispatch_inline_src(fe: Dictionary, prefix: String, indent: String = "\t") -> String:
	var method_name: String = fe["name"]
	var params: String = fe["params"]
	var param_names_str: String = ", ".join(fe["param_names"])
	var hook_base: String = "%s-%s" % [prefix, method_name.to_lower()]
	var vanilla_call: String = "_rtv_vanilla_%s(%s)" % [method_name, param_names_str]
	var args_array: String = "[]" if param_names_str.is_empty() else "[%s]" % param_names_str
	var is_coro: bool = bool(fe["is_coroutine"])
	var is_engine_void: bool = method_name in GAME_ENGINE_VOID_METHODS
	var is_void: bool = is_engine_void or not bool(fe["has_return_value"])
	var aw: String = "await " if is_coro else ""

	var return_annot: String = ""
	var rt = fe.get("return_type")
	if rt != null and not (rt as String).is_empty():
		return_annot = " -> " + (rt as String)
	var sig: String = "func %s()%s:" % [method_name, return_annot] if params.is_empty() \
			else "func %s(%s)%s:" % [method_name, params, return_annot]

	var I1: String = indent
	var I2: String = indent + indent
	var I3: String = indent + indent + indent

	var out := ""
	if not is_void:
		out += "%s\n" % sig
		out += "%sif not Engine.has_meta(\"RTVModLib\"):\n" % I1
		out += "%sreturn %s%s\n" % [I2, aw, vanilla_call]
		out += "%svar _lib = Engine.get_meta(\"RTVModLib\")\n" % I1
		out += "%sif not _lib._any_mod_hooked:\n" % I1
		out += "%sreturn %s%s\n" % [I2, aw, vanilla_call]
		out += "%sif not _lib._hooked_bases.has(\"%s\"):\n" % [I1, hook_base]
		out += "%sreturn %s%s\n" % [I2, aw, vanilla_call]
		out += "%sif _lib._developer_mode:\n" % I1
		out += "%s_lib._dispatch_counts[\"%s\"] = int(_lib._dispatch_counts.get(\"%s\", 0)) + 1\n" % [I2, hook_base, hook_base]
		out += "%sif _lib._wrapper_active.has(\"%s\"):\n" % [I1, hook_base]
		out += "%sreturn %s%s\n" % [I2, aw, vanilla_call]
		out += "%s_lib._wrapper_active[\"%s\"] = true\n" % [I1, hook_base]
		out += "%svar _rtv_prev_caller = _lib._caller\n" % I1
		out += "%s_lib._caller = self\n" % I1
		out += "%s_lib._dispatch(\"%s-pre\", %s)\n" % [I1, hook_base, args_array]
		out += "%svar _result\n" % I1
		out += "%svar _repl = _lib._get_hooks(\"%s\")\n" % [I1, hook_base]
		out += "%sif _repl.size() > 0:\n" % I1
		out += "%svar _prev_skip = _lib._skip_super\n" % I2
		out += "%s_lib._skip_super = false\n" % I2
		out += "%svar _replret = _repl[0].callv(%s)\n" % [I2, args_array]
		out += "%svar _did_skip = _lib._skip_super\n" % I2
		out += "%s_lib._skip_super = _prev_skip\n" % I2
		out += "%sif _did_skip:\n" % I2
		out += "%s_result = _replret\n" % I3
		out += "%selse:\n" % I2
		out += "%s_result = %s%s\n" % [I3, aw, vanilla_call]
		out += "%selse:\n" % I1
		out += "%s_result = %s%s\n" % [I2, aw, vanilla_call]
		out += "%s_lib._caller = self\n" % I1
		out += "%s_result = _lib._dispatch_post(\"%s-post\", %s, _result)\n" % [I1, hook_base, args_array]
		out += "%s_lib._dispatch_deferred(\"%s-callback\", %s)\n" % [I1, hook_base, args_array]
		out += "%s_lib._wrapper_active.erase(\"%s\")\n" % [I1, hook_base]
		out += "%s_lib._caller = _rtv_prev_caller\n" % I1
		out += "%sreturn _result\n" % I1
	else:
		out += "%s\n" % sig
		out += "%sif not Engine.has_meta(\"RTVModLib\"):\n" % I1
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%sreturn\n" % I2
		out += "%svar _lib = Engine.get_meta(\"RTVModLib\")\n" % I1
		out += "%sif not _lib._any_mod_hooked:\n" % I1
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%sreturn\n" % I2
		out += "%sif not _lib._hooked_bases.has(\"%s\"):\n" % [I1, hook_base]
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%sreturn\n" % I2
		out += "%sif _lib._developer_mode:\n" % I1
		out += "%s_lib._dispatch_counts[\"%s\"] = int(_lib._dispatch_counts.get(\"%s\", 0)) + 1\n" % [I2, hook_base, hook_base]
		out += "%sif _lib._wrapper_active.has(\"%s\"):\n" % [I1, hook_base]
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%sreturn\n" % I2
		out += "%s_lib._wrapper_active[\"%s\"] = true\n" % [I1, hook_base]
		out += "%svar _rtv_prev_caller = _lib._caller\n" % I1
		out += "%s_lib._caller = self\n" % I1
		out += "%s_lib._dispatch(\"%s-pre\", %s)\n" % [I1, hook_base, args_array]
		out += "%svar _repl = _lib._get_hooks(\"%s\")\n" % [I1, hook_base]
		out += "%sif _repl.size() > 0:\n" % I1
		out += "%svar _prev_skip = _lib._skip_super\n" % I2
		out += "%s_lib._skip_super = false\n" % I2
		out += "%s_repl[0].callv(%s)\n" % [I2, args_array]
		out += "%svar _did_skip = _lib._skip_super\n" % I2
		out += "%s_lib._skip_super = _prev_skip\n" % I2
		out += "%sif !_did_skip:\n" % I2
		out += "%s%s%s\n" % [I3, aw, vanilla_call]
		out += "%selse:\n" % I1
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%s_lib._caller = self\n" % I1
		out += "%s_lib._dispatch(\"%s-post\", %s)\n" % [I1, hook_base, args_array]
		out += "%s_lib._dispatch_deferred(\"%s-callback\", %s)\n" % [I1, hook_base, args_array]
		out += "%s_lib._wrapper_active.erase(\"%s\")\n" % [I1, hook_base]
		out += "%s_lib._caller = _rtv_prev_caller\n" % I1
	return out



const REGISTRY_TARGETS: Array[String] = []

func _is_registry_target(filename: String) -> bool:
	return filename in REGISTRY_TARGETS

func _wrapped_paths_packed(paths: Array[String]) -> PackedStringArray:
	var out := PackedStringArray()
	for path in paths:
		out.append(path)
	return out

func _generate_hook_pack(defer_activation: bool = false) -> String:
	var hook_dir := ProjectSettings.globalize_path(HOOK_PACK_DIR)
	DirAccess.make_dir_recursive_absolute(hook_dir)
	var pack_zip_rel := HOOK_PACK_DIR.path_join("%s_%d.zip" % [HOOK_PACK_PREFIX, Time.get_ticks_msec()])
	var dir := DirAccess.open(hook_dir)
	if dir != null:
		dir.list_dir_begin()
		while true:
			var fname := dir.get_next()
			if fname == "":
				break
			if fname.begins_with("Framework") and fname.ends_with(".gd"):
				DirAccess.remove_absolute(hook_dir.path_join(fname))
		dir.list_dir_end()

	var tok_version := _probe_gdsc_version()
	if tok_version != -1 and tok_version != 100 and tok_version != 101:
		_log_critical("[STABILITY] Unsupported GDSC tokenizer v%d on Godot %s. OrcKit supports v100 (Godot 4.0-4.4) and v101 (Godot 4.5-4.6). Hook pack generation disabled -- script hooks will not fire. See README for supported Godot versions." \
				% [tok_version, Engine.get_version_info().get("string", "unknown")])
		return ""
	if tok_version != -1:
		_log_info("[STABILITY] Detokenizer compatible: GDSC v%d on Godot %s" \
				% [tok_version, Engine.get_version_info().get("string", "unknown")])

	var user_wrap_empty: bool = _hooked_methods.is_empty() and not _any_mod_declared_registry

	_seed_core_hooks()

	if user_wrap_empty:
		_log_info("[OrcKitCodegen] No user opt-in declarations ([hooks] / .hook() / [registry]) -- user mods' game targets run unmodified. Pack contains core hooks only.")

	var script_paths: Array[String] = _enumerate_game_scripts()
	if script_paths.is_empty():
		_log_warning("[OrcKitCodegen] script enumeration failed -- falling back to class_name list (%d)" % _class_name_to_path.size())
		for path: String in _class_name_to_path.values():
			script_paths.append(path)
	var vanilla_path_set: Dictionary = {}
	for sp: String in script_paths:
		vanilla_path_set[sp] = true
	var needed_paths: Dictionary = {}
	var hook_mask: Dictionary = {}
	for declared_path: String in _hooked_methods:
		var path := _canonical_hook_script_path(declared_path)
		if not _is_game_script_path(path):
			_log_warning("[OrcKitCodegen] [hooks] declared for non-game script path '%s' -- entry ignored" % path)
			continue
		if not vanilla_path_set.has(path):
			_log_warning("[OrcKitCodegen] [hooks] declared path '%s' doesn't match any known game script -- check for typos or stale paths; entry will no-op" % path)
		needed_paths[path] = true
		hook_mask[path] = (_hooked_methods[declared_path] as Dictionary).duplicate()
	if _any_mod_declared_registry:
		for rt_filename in REGISTRY_TARGETS:
			var rt_path := _find_game_script_by_filename(rt_filename)
			if rt_path == "":
				continue
			needed_paths[rt_path] = true
			hook_mask.erase(rt_path)
	_log_info("[OrcKitCodegen] Wrap surface: %d game script(s) declared (%d via [hooks]/.hook(), %d via [registry])" % [
		needed_paths.size(),
		_hooked_methods.size(),
		REGISTRY_TARGETS.size() if _any_mod_declared_registry else 0,
	])
	_log_info("[OrcKitCodegen] Skip lists: %d runtime-sensitive, %d data, %d serialized (total %d skipped from rewrite)" % [
		GAME_RUNTIME_SKIP_LIST.size(),
		GAME_RESOURCE_DATA_SKIP.size(),
		GAME_RESOURCE_SERIALIZED_SKIP.size(),
		GAME_RUNTIME_SKIP_LIST.size() + GAME_RESOURCE_DATA_SKIP.size() + GAME_RESOURCE_SERIALIZED_SKIP.size(),
	])

	var sibling_fixes: Dictionary = {}
	for archive_file: String in _archive_file_sets:
		var paths_set: Dictionary = _archive_file_sets[archive_file]
		var zr: ZIPReader = null
		var zip_path := archive_file
		var ext := archive_file.get_extension().to_lower()
		if ext == "vmz":
			var cache_dir := ProjectSettings.globalize_path(TMP_DIR)
			zip_path = cache_dir.path_join(archive_file.get_file().get_basename() + ".zip")
		elif ext == "folder":
			var folder_zip := ProjectSettings.globalize_path(TMP_DIR).path_join(archive_file.get_file() + "_dev.zip")
			zip_path = folder_zip
		if FileAccess.file_exists(zip_path):
			zr = ZIPReader.new()
			if zr.open(zip_path) != OK:
				zr = null
		for p: String in paths_set:
			if not p.ends_with(".gd"):
				continue
			if _is_game_script_path(p):
				continue
			if zr == null:
				if not ResourceLoader.exists(p):
					continue
				var raw_vfs := FileAccess.get_file_as_string(p)
				if raw_vfs.is_empty():
					continue
				var norm_vfs := raw_vfs.replace("\r\n", "\n").replace("\r", "\n")
				var af_vfs := _rtv_autofix_legacy_syntax(norm_vfs)
				var fixed_vfs: String = af_vfs["source"]
				var rl_vfs := _rtv_strip_helper_reload(fixed_vfs)
				fixed_vfs = rl_vfs["source"]
				sibling_fixes[p] = {
					"fixed_src": fixed_vfs,
					"af": af_vfs,
					"reload_stripped": int(rl_vfs["stripped"]),
					"changed": fixed_vfs != norm_vfs,
				}
				continue
			var entry := p.trim_prefix("res://")
			if not (entry in zr.get_files()):
				continue
			var bytes := zr.read_file(entry)
			if bytes.is_empty():
				continue
			var raw := bytes.get_string_from_utf8()
			if raw.is_empty():
				continue
			var norm := raw.replace("\r\n", "\n").replace("\r", "\n")
			var af := _rtv_autofix_legacy_syntax(norm)
			var fixed_src: String = af["source"]
			var rl := _rtv_strip_helper_reload(fixed_src)
			fixed_src = rl["source"]
			sibling_fixes[p] = {
				"fixed_src": fixed_src,
				"af": af,
				"reload_stripped": int(rl["stripped"]),
				"changed": fixed_src != norm,
			}
		if zr != null:
			zr.close()

	var zip_abs := ProjectSettings.globalize_path(pack_zip_rel)
	var zp := ZIPPacker.new()
	if zp.open(zip_abs) != OK:
		_log_critical("[OrcKitCodegen] Failed to create framework pack zip at %s" % zip_abs)
		return ""

	var script_count := 0
	var hook_count := 0
	var packed_paths: Array[String] = []
	var _step_b_allowlist: Array[String] = []
	var zero_byte_skipped: int = 0
	var surface_skipped: int = 0
	for script_path: String in script_paths:
		var filename := script_path.get_file()

		if filename in GAME_RUNTIME_SKIP_LIST:
			_log_debug("[OrcKitCodegen] Skipped %s (runtime-sensitive)" % filename)
			continue
		if filename in GAME_RESOURCE_SERIALIZED_SKIP or filename in GAME_RESOURCE_DATA_SKIP:
			continue
		if _pck_zero_byte_paths.has(script_path):
			zero_byte_skipped += 1
			continue
		if not _step_b_allowlist.is_empty() and filename not in _step_b_allowlist:
			continue
		if not needed_paths.has(script_path):
			surface_skipped += 1
			_log_debug("[OrcKitCodegen] Surface-skip %s (no mod extends/hooks/overrides)" % filename)
			continue

		if _override_registry.has(script_path) or _applied_script_overrides.has(script_path):
			var sources: PackedStringArray = []
			if _override_registry.has(script_path):
				for claim in _override_registry[script_path]:
					sources.append(claim["mod_name"])
			for entry in _pending_script_overrides:
				if entry["vanilla_path"] == script_path:
					sources.append(entry["mod_name"] + " [script_overrides]")
			if sources.size() > 0:
				_log_warning("[OrcKitCodegen] %s is rewritten and also overridden by %s -- override displaces the rewrite, hooks won't fire for that path" \
						% [script_path, ", ".join(sources)])

		var source := _read_vanilla_source(script_path)
		if source.is_empty():
			_log_warning("[OrcKitCodegen] Empty detokenized source for %s -- skipped" % script_path)
			continue

		var parsed := _rtv_parse_script(filename, source)
		var path_mask: Dictionary = hook_mask.get(script_path, {}) as Dictionary
		var apply_mask: bool = not path_mask.is_empty()
		var hookable_count := 0
		for fe in parsed["functions"]:
			if fe["is_static"]:
				continue
			if apply_mask and not path_mask.has(fe["name"].to_lower()):
				continue
			hookable_count += 1
		if hookable_count == 0:
			if apply_mask:
				_log_warning("[OrcKitCodegen] %s: declared [hooks] methods %s not found in game script -- skipping" \
						% [filename, str(path_mask.keys())])
			continue

		var scene_preloads := _collect_module_scope_scene_preloads(source)
		if scene_preloads.size() > 0 and not _is_registry_target(filename):
			_scripts_with_scene_preloads[script_path] = scene_preloads

		var rewritten := _rtv_rewrite_vanilla_source(source, parsed, path_mask)
		var gd_entry := _script_zip_entry(script_path)
		if zp.start_file(gd_entry) != OK:
			_log_warning("[OrcKitCodegen] Failed to start zip entry %s" % gd_entry)
			continue
		zp.write_file(rewritten.to_utf8_buffer())
		zp.close_file()
		var remap_entry := _script_remap_entry(script_path)
		if zp.start_file(remap_entry) != OK:
			_log_warning("[OrcKitCodegen] Failed to start zip entry %s" % remap_entry)
			continue
		var remap_body := "[remap]\npath=\"%s\"\n" % script_path
		zp.write_file(remap_body.to_utf8_buffer())
		zp.close_file()
		var gdc_entry := _script_gdc_entry(script_path)
		if zp.start_file(gdc_entry) != OK:
			_log_warning("[OrcKitCodegen] Failed to start zip entry %s" % gdc_entry)
			continue
		zp.write_file(PackedByteArray())
		zp.close_file()

		script_count += 1
		hook_count += hookable_count * 4
		packed_paths.append(script_path)
		_log_debug("[OrcKitCodegen] Rewrote %s (%d hooks)" % [script_path, hookable_count * 4])

	var sibling_fixed := 0
	var sibling_carried := 0
	var sibling_total_bodyless := 0
	var sibling_total_reload_stripped := 0
	for p: String in sibling_fixes:
		var fix: Dictionary = sibling_fixes[p]
		var fixed_src: String = fix["fixed_src"]
		var af: Dictionary = fix["af"]
		var reload_stripped: int = int(fix["reload_stripped"])
		var changed: bool = bool(fix["changed"])
		var zip_rel: String = p.trim_prefix("res://")
		if zp.start_file(zip_rel) != OK:
			_log_warning("[Autofix] Failed to pack sibling zip entry %s" % zip_rel)
			continue
		zp.write_file(fixed_src.to_utf8_buffer())
		zp.close_file()
		if changed:
			sibling_fixed += 1
			sibling_total_bodyless += int(af["bodyless"])
			sibling_total_reload_stripped += reload_stripped
			if reload_stripped > 0:
				_log_info("[Autofix] Stripped %d redundant .reload() call(s) from %s -- prevents Cannot-reload-while-instances-exist spam" % [reload_stripped, p])
			_log_info("[Autofix] Patched sibling %s: bodyless=%d tool=%d onready=%d export=%d" \
					% [p, af["bodyless"], af["tool"], af["onready"], af["export"]])
		else:
			sibling_carried += 1
	if sibling_fixed > 0:
		_log_info("[Autofix] %d mod sibling script(s) repaired (%d bodyless blocks, %d reload() stripped) -- packed into hook pack overlay" \
				% [sibling_fixed, sibling_total_bodyless, sibling_total_reload_stripped])
	if sibling_carried > 0:
		_log_debug("[Autofix] Carried %d unchanged mod sibling script(s) forward into new hook pack -- preserves VFS coverage across regen" \
				% sibling_carried)

	var canary_content := "MODLOADER-VFS-CANARY-" + MODLOADER_VERSION
	if zp.start_file("__modloader_canary__.txt") == OK:
		zp.write_file(canary_content.to_utf8_buffer())
		zp.close_file()

	zp.close()

	if zero_byte_skipped > 0:
		_log_info("[OrcKitCodegen] Skipped %d zero-byte PCK entry(ies) (base game ships empty .gd files -- not hookable, not a modloader failure): %s" \
				% [zero_byte_skipped, ", ".join(_pck_zero_byte_paths.keys())])
	if surface_skipped > 0:
		_log_info("[OrcKitCodegen] Surface-skipped %d game script(s) with no mod interaction -- they run native (no dispatch overhead)" \
				% surface_skipped)
	if script_count > 0:
		if defer_activation:
			_log_info("[OrcKitCodegen] Generated %d rewritten game script(s), %d hook points -- activation deferred to Pass 2 fresh engine" \
					% [script_count, hook_count])
			_persist_hook_pack_state(pack_zip_rel, _wrapped_paths_packed(packed_paths))
		elif ProjectSettings.load_resource_pack(pack_zip_rel, true):
			var canary_got := FileAccess.get_file_as_string("res://__modloader_canary__.txt")
			if canary_got.begins_with("MODLOADER-VFS-CANARY-"):
				_log_info("[STABILITY] VFS canary OK: hook pack mount precedence verified (%s)" % canary_got.strip_edges())
			else:
				_log_critical("[STABILITY] VFS canary FAILED (got '%s', expected MODLOADER-VFS-CANARY-*) -- hook pack mounted but files aren't served. Rewrites will not take effect this session." % canary_got.substr(0, 40))
			_log_info("[OrcKitCodegen] Generated %d rewritten game script(s), %d hook points -- pack mounted at res:// (%s)" \
					% [script_count, hook_count, pack_zip_rel.get_file()])
			_activate_rewritten_scripts(packed_paths, pack_zip_rel)
		else:
			_log_critical("[OrcKitCodegen] Failed to mount hook pack at %s -- rewrites won't load" % zip_abs)
	else:
		_log_info("[OrcKitCodegen] No scripts rewritten -- no pack mounted")
	return pack_zip_rel


func _activate_rewritten_scripts(script_paths: Array[String], pack_path: String) -> void:
	var deferred: PackedStringArray = []
	for path: String in script_paths:
		if _scripts_with_scene_preloads.has(path):
			deferred.append(path)
	if deferred.size() > 0:
		_log_info("[OrcKitCodegen] DEFER %d script(s) with module-scope scene preload -- will lazy-compile via VFS after mod overrides: %s" \
				% [deferred.size(), ", ".join(Array(deferred))])

	var pre_a := 0
	var pre_b := 0
	var pre_c := 0
	var pre_d := 0
	var pre_b_names: PackedStringArray = []
	var pre_c_names: PackedStringArray = []
	for vp: String in script_paths:
		if _scripts_with_scene_preloads.has(vp):
			continue
		var c := load(vp) as GDScript
		if c == null:
			pre_d += 1
			continue
		var pre_rename := false
		for m in c.get_script_method_list():
			if str(m["name"]).begins_with("_rtv_vanilla_"):
				pre_rename = true
				break
		var srclen: int = c.source_code.length()
		if pre_rename:
			pre_a += 1
		elif srclen > 0:
			pre_b += 1
			pre_b_names.append(vp)
		else:
			pre_c += 1
			pre_c_names.append(vp)
	_log_info("[OrcKitCodegen] PRE-ACTIVATE summary: inline-live=%d, pinned-with-source=%d, pinned-tokenized=%d, other=%d / total=%d" \
			% [pre_a, pre_b, pre_c, pre_d, script_paths.size()])
	if pre_b > 0:
		_log_info("[OrcKitCodegen]   pinned-with-source (GDScriptCache has our text but compiled methods are vanilla): %s" \
				% ", ".join(Array(pre_b_names).slice(0, 25)))
	if pre_c > 0:
		_log_info("[OrcKitCodegen]   pinned-tokenized (PCK .gdc, our static-init preload missed): %s" \
				% ", ".join(Array(pre_c_names).slice(0, 25)))

	var activated := 0
	var preactivated := 0
	for vp: String in script_paths:
		if _scripts_with_scene_preloads.has(vp):
			continue
		var cached := load(vp) as GDScript
		if cached == null:
			_log_warning("[OrcKitCodegen] activate %s: load returned null -- skip" % vp)
			continue

		var already_live := false
		for m in cached.get_script_method_list():
			if str(m["name"]).begins_with("_rtv_vanilla_"):
				already_live = true
				break
		if already_live:
			var fresh_source := FileAccess.get_file_as_string(vp)
			if not fresh_source.is_empty() and fresh_source != cached.source_code:
				_log_info("[OrcKitCodegen] activate %s: cached rewrite is stale (static-init had an older pack), forcing fresh+take_over_path" % vp)
				var fresh := ResourceLoader.load(vp, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
				if fresh == null:
					_log_critical("[OrcKitCodegen] activate %s: fresh load returned null -- skip" % vp)
					continue
				fresh.take_over_path(vp)
				activated += 1
				continue
			preactivated += 1
			activated += 1
			continue

		var our_source := FileAccess.get_file_as_string(vp)
		if our_source.is_empty():
			_log_warning("[OrcKitCodegen] activate %s: FileAccess returned empty -- skip" % vp)
			continue
		cached.source_code = our_source
		var err := cached.reload()
		if err != OK:
			_log_warning("[OrcKitCodegen] activate %s: reload failed (%s)" % [vp, error_string(err)])
		var has_rename := false
		for m in cached.get_script_method_list():
			if str(m["name"]).begins_with("_rtv_vanilla_"):
				has_rename = true
				break
		if not has_rename:
			_log_info("[OrcKitCodegen] activate %s: reload didn't apply (pre-compiled); falling back to fresh+take_over_path" % vp)
			var fresh := ResourceLoader.load(vp, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
			if fresh == null:
				_log_critical("[OrcKitCodegen] activate %s: fresh load returned null -- skip" % vp)
				continue
			var fresh_has_rename := false
			for m in fresh.get_script_method_list():
				if str(m["name"]).begins_with("_rtv_vanilla_"):
					fresh_has_rename = true
					break
			if not fresh_has_rename:
				_log_critical("[OrcKitCodegen] activate %s: fresh load also lacks renames -- rewrite isn't compiling" % vp)
				continue
			fresh.take_over_path(vp)
			_log_info("[OrcKitCodegen] activate %s: fresh script took over game path" % vp)
		activated += 1
	var eager_total := script_paths.size() - _scripts_with_scene_preloads.size()
	_log_info("[OrcKitCodegen] Activated %d/%d rewritten script(s) (%d already live from static-init preload; %d deferred to lazy-compile)" \
			% [activated, eager_total, preactivated, _scripts_with_scene_preloads.size()])

	_persist_hook_pack_state(pack_path, _wrapped_paths_packed(script_paths))

	if not _developer_mode:
		return
	var probe_counts := {
		"loader_pp": 0, "simulation_proc": 0, "profiler_proc": 0,
		"menu_ready": 0, "settings_load": 0,
		"controller_pp": 0, "character_pp": 0, "camera_pp": 0,
	}
	Engine.set_meta("_rtv_probe_counts", probe_counts)
	Engine.set_meta("_rtv_probe_first_args", {})
	var _bump := func(key: String, arg):
		var pc: Dictionary = Engine.get_meta("_rtv_probe_counts", {})
		pc[key] = int(pc.get(key, 0)) + 1
		Engine.set_meta("_rtv_probe_counts", pc)
		var fa: Dictionary = Engine.get_meta("_rtv_probe_first_args", {})
		if not fa.has(key):
			fa[key] = str(arg)
			Engine.set_meta("_rtv_probe_first_args", fa)
	hook("loader-_physics_process-pre", func(d): _bump.call("loader_pp", d), 100)
	hook("simulation-_process-pre", func(d): _bump.call("simulation_proc", d), 100)
	hook("profiler-_process-pre", func(d): _bump.call("profiler_proc", d), 100)
	hook("menu-_ready-pre", func(): _bump.call("menu_ready", "(no args)"), 100)
	hook("settings-loadpreferences-pre", func(): _bump.call("settings_load", "(no args)"), 100)
	hook("controller-_physics_process-pre", func(d): _bump.call("controller_pp", d), 100)
	hook("character-_physics_process-pre", func(d): _bump.call("character_pp", d), 100)
	hook("camera-_physics_process-pre", func(d): _bump.call("camera_pp", d), 100)

	var compile_proof_ok := 0
	var compile_proof_fail: PackedStringArray = []
	for vp: String in script_paths:
		if _scripts_with_scene_preloads.has(vp):
			continue
		var s := load(vp) as GDScript
		if s == null:
			compile_proof_fail.append(vp)
			continue
		var methods := s.get_script_method_list()
		var has_vanilla_rename := false
		var sample_rename := ""
		for m in methods:
			var n: String = str(m["name"])
			if n.begins_with("_rtv_vanilla_"):
				has_vanilla_rename = true
				if sample_rename == "":
					sample_rename = n
				if sample_rename != "" and has_vanilla_rename:
					break
		if _developer_mode:
			_log_info("[OrcKitCodegen] COMPILE-PROOF %s: %d methods compiled, _rtv_vanilla_* present=%s (e.g. %s)" \
					% [vp, methods.size(), has_vanilla_rename, sample_rename])
		if has_vanilla_rename:
			compile_proof_ok += 1
		else:
			compile_proof_fail.append(vp)

	var critical_set: Dictionary = {
		"res://menu/menu.gd": true,
		"res://battle/battle.gd": true,
		"res://globals/game_manager.gd": true,
	}
	var critical_failures: PackedStringArray = []
	for f in compile_proof_fail:
		if critical_set.has(f):
			critical_failures.append(f)
	var attempted := script_paths.size() - _scripts_with_scene_preloads.size()
	if compile_proof_ok == 0 and attempted > 0:
		_log_critical("[STABILITY] ALL %d rewrites failed to take effect -- VFS mount, hook pack, or cache eviction is broken. Mods will NOT work this session. Click 'Reset to Vanilla' in the UI or create modloader_disabled in the game folder." % attempted)
	elif critical_failures.size() > 0:
		_log_critical("[STABILITY] Hook rewrites missing on critical scripts: %s. Hooks on these scripts will NOT fire this session (likely cache-pinning fallback failure)." % ", ".join(critical_failures))
	else:
		var deferred_tag := ""
		if _scripts_with_scene_preloads.size() > 0:
			deferred_tag = ", %d deferred to lazy-compile" % _scripts_with_scene_preloads.size()
		_log_info("[STABILITY] COMPILE-PROOF summary: %d/%d rewrites active%s%s" \
				% [compile_proof_ok, attempted,
					(" (%d pinned-fallback)" % compile_proof_fail.size()) if compile_proof_fail.size() > 0 else "",
					deferred_tag])

	if _developer_mode:
		var autoload_names: Array[String] = ["SaveSystem", "GameManager", "TechTree",
				"GPUSim", "TooltipManager", "SceneTransition", "NumberFormatter",
				"AudioManager", "Steamy", "Options", "DevOptions", "TutorialManager",
				"Menu"]
		var root := get_tree().root
		for aname: String in autoload_names:
			var node: Node = root.get_node_or_null(aname)
			if node == null:
				_log_info("[OrcKitCodegen] AUTOLOAD-CHECK %s: node NOT in tree" % aname)
				continue
			var scr := node.get_script() as GDScript
			if scr == null:
				_log_info("[OrcKitCodegen] AUTOLOAD-CHECK %s: no script attached" % aname)
				continue
			var has_rename := false
			for m in scr.get_script_method_list():
				if str(m["name"]).begins_with("_rtv_vanilla_"):
					has_rename = true
					break
			var instance_methods_has_rename := false
			for m in node.get_method_list():
				if str(m["name"]).begins_with("_rtv_vanilla_"):
					instance_methods_has_rename = true
					break
			_log_info("[OrcKitCodegen] AUTOLOAD-CHECK %s: script=%s script_has_rename=%s instance_has_rename=%s" \
					% [aname, scr.resource_path, has_rename, instance_methods_has_rename])

	_dispatch_counts.clear()
	get_tree().create_timer(30.0).timeout.connect(func():
		var pc: Dictionary = Engine.get_meta("_rtv_probe_counts", {})
		var fa: Dictionary = Engine.get_meta("_rtv_probe_first_args", {})
		if _developer_mode and _dispatch_counts.size() > 0:
			var pairs: Array = []
			for k: String in _dispatch_counts:
				pairs.append([k, int(_dispatch_counts[k])])
			pairs.sort_custom(func(a, b): return a[1] > b[1])
			_log_info("[OrcKitCodegen] DISPATCH-COUNT top %d / %d tracked methods (dev mode, 30s window):" \
					% [min(20, pairs.size()), pairs.size()])
			for i in range(min(20, pairs.size())):
				_log_info("[OrcKitCodegen]   %-48s %d" % [pairs[i][0], pairs[i][1]])
			var lifecycle_runaway: Array = []
			for p in pairs:
				var name: String = p[0]
				if (name.ends_with("-_ready") or name.ends_with("-_enter_tree") \
						or name.ends_with("-_init")) and int(p[1]) > 10:
					lifecycle_runaway.append("%s=%d" % [name, p[1]])
			if lifecycle_runaway.size() > 0:
				_log_critical("[OrcKitCodegen] LIFECYCLE-RUNAWAY: %s -- these should fire once per node; elevated counts usually mean a mod is explicitly calling them from a loop or frequent callback, which cascades into connect-already-connected error spam" \
						% ", ".join(lifecycle_runaway))
		var total := 0
		for k: String in ["loader_pp", "simulation_proc", "profiler_proc",
				"menu_ready", "settings_load",
				"controller_pp", "character_pp", "camera_pp"]:
			var v := int(pc.get(k, 0))
			total += v
			_log_info("[OrcKitCodegen] HOOK-API %s: count=%d first_arg=%s" \
					% [k, v, fa.get(k, "n/a")])
		if total > 0:
			_log_info("[OrcKitCodegen] HOOK-API-LIVE: %d callback fires total across probes -- full chain verified" % total)
		else:
			_log_critical("[OrcKitCodegen] HOOK-API-DEAD: 0 callback fires -- dispatch runs but _hooks lookup/callback is broken")
		var check_classes: Array[String] = ["Controller", "Camera", "WeaponRig"]
		for cls_name: String in check_classes:
			var found: Array = []
			_rtv_collect_nodes_by_class(get_tree().root, cls_name, found)
			if found.is_empty():
				_log_info("[IXP-VERIFY] No %s node in tree yet" % cls_name)
				continue
			var node: Node = found[0]
			var scr := node.get_script() as GDScript
			if scr == null:
				_log_info("[IXP-VERIFY] %s: no script attached" % cls_name)
				continue
			var src: String = scr.source_code
			var has_ixp := "ImmersiveXP" in src or "IXP " in src or "overrideScript" in src
			var has_rewrite := "_rtv_vanilla_" in src
			_log_info("[IXP-VERIFY] %s instance script: path=%s src_len=%d ixp_content=%s rewrite_content=%s" \
					% [cls_name, scr.resource_path, src.length(), has_ixp, has_rewrite])
			var base := scr.get_base_script() as GDScript
			var depth := 1
			while base != null and depth < 6:
				var b_src: String = base.source_code
				var b_has_ixp := "ImmersiveXP" in b_src or "IXP " in b_src
				var b_has_rewrite := "_rtv_vanilla_" in b_src
				_log_info("[IXP-VERIFY]   base[%d]: path=%s src_len=%d ixp=%s rewrite=%s" \
						% [depth, base.resource_path, b_src.length(), b_has_ixp, b_has_rewrite])
				base = base.get_base_script() as GDScript
				depth += 1
	)


func _ready() -> void:
	if _has_loaded:
		return
	_has_loaded = true
	if _is_modloader_disabled():
		print("[OrcKit] disabled via sentinel file -- sitting idle")
		return
	await get_tree().process_frame
	_compile_regex()
	var is_pass_2 := "--modloader-restart" in OS.get_cmdline_user_args()
	if is_pass_2:
		await _run_pass_2()
	else:
		await _run_pass_1()

func _modloader_restart(clean_pass1: bool) -> void:
	var args: Array = []
	if clean_pass1:
		for a in OS.get_cmdline_args():
			if a != "--modloader-restart":
				args.append(a)
	else:
		args = Array(OS.get_cmdline_args())
	_preserve_engine_driver_args(args)
	if not clean_pass1:
		args.append_array(["--", "--modloader-restart"])
	OS.set_restart_on_exit(true, args)
	get_tree().quit()

func _preserve_engine_driver_args(args: Array) -> void:
	if not args.has("--rendering-driver"):
		var driver := RenderingServer.get_current_rendering_driver_name()
		if not driver.is_empty():
			args.append("--rendering-driver")
			args.append(driver)
	if not args.has("--rendering-method"):
		var method := RenderingServer.get_current_rendering_method()
		if not method.is_empty():
			args.append("--rendering-method")
			args.append(method)

func reopen_mod_ui() -> void:
	if _ui_window != null:
		return
	_dirty_since_boot = false
	await show_mod_ui()
	if _dirty_since_boot:
		_log_info("[OrcKit] Post-boot mod changes detected -- restarting")
		_modloader_restart(true)

func _run_pass_1() -> void:
	_log_info("OrcKit v" + MODLOADER_VERSION)
	_check_crash_recovery()
	_check_safe_mode()
	_compile_regex()
	_build_class_name_lookup()
	_enumerate_game_scripts()
	_load_developer_mode_setting()
	_ui_mod_entries = collect_mod_metadata()
	_clean_stale_cache()
	_load_ui_config()
	await show_mod_ui()
	_save_ui_config()

	load_all_mods()
	_apply_script_overrides()

	var sections := _build_autoload_sections()
	var archive_paths := _collect_enabled_archive_paths()

	var new_hash := _compute_state_hash(archive_paths, sections.prepend)
	var old_hash := ""
	var state_cfg := ConfigFile.new()
	if state_cfg.load(PASS_STATE_PATH) == OK:
		old_hash = state_cfg.get_value("state", "mods_hash", "")

	if new_hash == old_hash and not new_hash.is_empty():
		_log_info("Mod state unchanged -- skipping restart")
		await _finish_with_existing_mounts()
		return


	if archive_paths.size() > 0:
		_log_info("Preparing two-pass restart -- %d archive(s)" % archive_paths.size())
		if sections.prepend.size() > 0:
			_log_info("  %d early autoload(s) written after OrcKit in [autoload]" % sections.prepend.size())
		_register_rtv_modlib_meta()
		_generate_hook_pack(true)
		_write_heartbeat()
		var err := _write_override_cfg(sections.prepend)
		if err != OK:
			_log_critical("Failed to write override.cfg (error %d) -- single-pass fallback" % err)
			await _finish_single_pass()
			return
		if _write_pass_state(archive_paths, new_hash) != OK:
			await _finish_single_pass()
			return
		_modloader_restart(false)
		return

	if FileAccess.file_exists(PASS_STATE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS_STATE_PATH))
		_restore_clean_override_cfg()
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(HOOK_PACK_DIR)):
		_static_wipe_hook_cache()
		_log_info("[Hooks] Cleaned up unused hook artifacts")
	await _finish_single_pass()

func _finish_with_existing_mounts() -> void:
	_boot_complete = true
	_register_rtv_modlib_meta()
	_generate_hook_pack()
	for entry in _pending_autoloads:
		if get_tree().root.has_node(entry["name"]):
			_log_info("  Autoload '%s' already in tree -- skipped" % entry["name"])
			continue
		_instantiate_autoload(entry["mod_name"], entry["name"], entry["path"])
	if _developer_mode:
		_log_override_timing_warnings()
		_print_conflict_summary()
		_write_conflict_report()
	_emit_frameworks_ready()
	_delete_heartbeat()
	if not _filescope_mounted.is_empty() or not _archive_file_sets.is_empty() or _pending_autoloads.size() > 0:
		var err := get_tree().reload_current_scene()
		if err != OK:
			_log_critical("reload_current_scene() failed with error " + str(err))
			return

func _finish_single_pass() -> void:
	_boot_complete = true
	_register_rtv_modlib_meta()
	_generate_hook_pack()
	for entry in _pending_autoloads:
		_instantiate_autoload(entry["mod_name"], entry["name"], entry["path"])
	if _developer_mode:
		_log_override_timing_warnings()
		_print_conflict_summary()
		_write_conflict_report()
	_emit_frameworks_ready()
	_delete_heartbeat()
	if not _archive_file_sets.is_empty() or _pending_autoloads.size() > 0:
		var err := get_tree().reload_current_scene()
		if err != OK:
			_log_critical("reload_current_scene() failed with error " + str(err))
			return



func _run_pass_2() -> void:
	_boot_complete = true
	_log_info("Pass 2 -- %d archive(s) mounted at file-scope" % _filescope_mounted.size())
	var _dirty_f := FileAccess.open(PASS2_DIRTY_PATH, FileAccess.WRITE)
	if _dirty_f:
		_dirty_f.store_string(str(Time.get_unix_time_from_system()))
		_dirty_f.close()
	var _pass_cfg := ConfigFile.new()
	if _pass_cfg.load(PASS_STATE_PATH) == OK:
		var saved_overrides: Array = _pass_cfg.get_value("state", "script_overrides", [])
		for entry in saved_overrides:
			if entry is Dictionary and entry.has("vanilla_path") and entry.has("mod_script_path"):
				_pending_script_overrides.append(entry)
			else:
				_log_warning("[Overrides] Malformed entry in pass state -- skipped")
	_apply_script_overrides()
	_clear_restart_counter()
	_compile_regex()
	_build_class_name_lookup()
	_enumerate_game_scripts()
	_load_developer_mode_setting()
	_ui_mod_entries = collect_mod_metadata()
	_load_ui_config()

	load_all_mods("Pass 2")
	_register_rtv_modlib_meta()
	_generate_hook_pack()
	for entry in _pending_autoloads:
		if get_tree().root.has_node(entry["name"]):
			_log_info("  Autoload '%s' already in tree -- skipped" % entry["name"])
			continue
		_instantiate_autoload(entry["mod_name"], entry["name"], entry["path"])

	if _developer_mode:
		_log_override_timing_warnings()
		_print_conflict_summary()
		_write_conflict_report()
	_emit_frameworks_ready()
	_delete_heartbeat()
	if FileAccess.file_exists(PASS2_DIRTY_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS2_DIRTY_PATH))
	if not _filescope_mounted.is_empty() or not _archive_file_sets.is_empty() or _pending_autoloads.size() > 0:
		var err := get_tree().reload_current_scene()
		if err != OK:
			_log_critical("reload_current_scene() failed with error " + str(err))
			return


const _MENU_SCRIPT_PATH := "res://menu/menu.gd"
const _MENU_HOOK_NAME := "menu-_ready-post"
const _MODS_BUTTON_NAME := "OrcKitMods"

func _seed_core_hooks() -> void:
	if not _hooked_methods.has(_MENU_SCRIPT_PATH):
		_hooked_methods[_MENU_SCRIPT_PATH] = {}
	(_hooked_methods[_MENU_SCRIPT_PATH] as Dictionary)["_ready"] = true

func _register_core_hooks() -> void:
	hook(_MENU_HOOK_NAME, _on_menu_ready, 100)
	var tree := get_tree()
	if tree == null:
		return
	var cb := Callable(self, "_on_node_added_for_mods_button")
	if not tree.node_added.is_connected(cb):
		tree.node_added.connect(cb)
	if tree.root != null:
		_scan_existing_nodes_for_mods_button(tree.root)

func _on_menu_ready() -> void:
	var menu_root := _caller
	_try_inject_mods_button(menu_root)

func _on_node_added_for_mods_button(node: Node) -> void:
	_try_inject_mods_button(node)

func _scan_existing_nodes_for_mods_button(node: Node) -> void:
	_try_inject_mods_button(node)
	for child in node.get_children():
		_scan_existing_nodes_for_mods_button(child)

func _try_inject_mods_button(menu_root: Node) -> void:
	if menu_root == null or menu_root.get_script() == null:
		return
	if menu_root.get_script().resource_path != _MENU_SCRIPT_PATH:
		return
	_inject_mods_button(menu_root)

func _inject_mods_button(menu_root: Node) -> void:
	var buttons := menu_root.get_node_or_null("Buttons/VBoxContainer")
	if buttons == null:
		_log_warning("[OrcKit] Main menu has no Buttons/VBoxContainer container; skipping Mods button injection")
		return
	if buttons.get_node_or_null(_MODS_BUTTON_NAME) != null:
		return
	var btn := Button.new()
	btn.name = _MODS_BUTTON_NAME
	btn.text = "Mods"
	btn.theme_type_variation = &"MainMenuButton"
	btn.flat = true
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var quit_btn := buttons.get_node_or_null("Quit")
	buttons.add_child(btn)
	if quit_btn != null:
		buttons.move_child(btn, quit_btn.get_index())
	btn.pressed.connect(_on_mods_button_pressed)
	_log_info("[OrcKit] Injected Mods button into main menu")

func _on_mods_button_pressed() -> void:
	reopen_mod_ui()

