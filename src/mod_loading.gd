
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
		if bool(entry.get("dependency_blocked", false)):
			_log_warning("Skipping " + str(entry.get("mod_name", entry.get("file_name", "")))
					+ " -- required dependencies are missing or incompatible.")
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

func _static_public_hook_targets(helper_name: String) -> Array[Dictionary]:
	match helper_name:
		"on_battle_start":
			return [{"prefix": "battle", "method": "_ready"}]
		"on_battle_end":
			return [{"prefix": "battle", "method": "_end_battle"}]
		"on_enemy_spawned":
			return [{"prefix": "battle", "method": "_on_enemies_spawned"}]
		"on_enemy_killed":
			return [{"prefix": "battle", "method": "_on_enemies_killed"}]
		"on_tower_placed":
			return [{"prefix": "battle", "method": "add_tower"}]
		"on_tower_removed":
			return [{"prefix": "battle", "method": "remove_tower"}]
		"on_level_loaded":
			return [{"prefix": "battle", "method": "_ready"}]
		"on_tech_tree_opened":
			return [{"prefix": "menu", "method": "_on_tech_tree_pressed"}]
		"on_upgrade_purchased":
			return [{"prefix": "upgrade", "method": "buy"}]
	return []

func _record_static_hook_call(analysis: Dictionary, prefix: String, method: String) -> void:
	var normalized_prefix := prefix.to_lower()
	var normalized_method := method.to_lower()
	for existing: Dictionary in (analysis["hook_calls"] as Array):
		if existing["prefix"] == normalized_prefix and existing["method"] == normalized_method:
			return
	(analysis["hook_calls"] as Array).append({
		"prefix": normalized_prefix,
		"method": normalized_method,
	})

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
		_record_static_hook_call(analysis, prefix, method)

	for m_pub in _re_public_hook_call.search_all(text):
		var helper_name := m_pub.get_string(1)
		for target: Dictionary in _static_public_hook_targets(helper_name):
			_record_static_hook_call(analysis, target["prefix"], target["method"])

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
