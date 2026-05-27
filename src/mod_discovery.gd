
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
	_resolve_entry_dependencies(entries)
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
	var required_dependencies: Array[Dictionary] = []
	var optional_dependencies: Array[Dictionary] = []

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
		if cfg.has_section("dependencies"):
			required_dependencies = _parse_dependency_specs(cfg.get_value("dependencies", "required", ""))
			optional_dependencies = _parse_dependency_specs(cfg.get_value("dependencies", "optional", ""))
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
		"dependencies_required": required_dependencies,
		"dependencies_optional": optional_dependencies,
		"dependency_errors": [],
		"dependency_warnings": [],
		"dependency_blocked": false,
	}
	return entry

func _build_entry_warnings(entry: Dictionary) -> Array[String]:
	var warnings: Array[String] = []
	var ext: String = entry["ext"]
	if ext != "pck" and ext != "folder":
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
	for dep_warn: String in entry.get("dependency_warnings", []):
		warnings.append(dep_warn)
	for dep_err: String in entry.get("dependency_errors", []):
		warnings.append(dep_err)
	return warnings


func _parse_dependency_specs(value: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw_spec: String in _dependency_value_strings(value):
		var spec := raw_spec.strip_edges()
		if spec == "":
			continue
		var dep := _parse_dependency_spec(spec)
		if not String(dep.get("id", "")).is_empty():
			out.append(dep)
	return out

func _dependency_value_strings(value: Variant) -> Array[String]:
	var out: Array[String] = []
	if value is Array:
		for item in value:
			out.append_array(_dependency_value_strings(item))
	elif value is PackedStringArray:
		for item in value:
			out.append(str(item))
	else:
		var text := str(value).replace("\r", "\n")
		for chunk in text.split("\n", false):
			for part in chunk.split(",", false):
				var s := str(part).strip_edges()
				if s != "":
					out.append(s)
	return out

func _parse_dependency_spec(spec: String) -> Dictionary:
	for op in [">=", "<=", "==", ">", "<", "="]:
		var idx := spec.find(op)
		if idx > 0:
			return {
				"id": spec.substr(0, idx).strip_edges(),
				"op": "==" if op == "=" else op,
				"version": spec.substr(idx + op.length()).strip_edges(),
				"raw": spec,
			}
	return {"id": spec.strip_edges(), "op": "", "version": "", "raw": spec}

func _resolve_entry_dependencies(entries: Array[Dictionary]) -> void:
	var by_id: Dictionary = {}
	for entry: Dictionary in entries:
		by_id[str(entry.get("mod_id", "")).to_lower()] = entry
	for entry: Dictionary in entries:
		var errors: Array[String] = []
		var warnings: Array[String] = []
		for dep: Dictionary in entry.get("dependencies_required", []):
			var issue := _dependency_issue(dep, by_id)
			if issue != "":
				errors.append(issue)
		for dep: Dictionary in entry.get("dependencies_optional", []):
			if not by_id.has(str(dep.get("id", "")).to_lower()):
				warnings.append("Optional dependency not found: " + str(dep.get("raw", dep.get("id", ""))))
		entry["dependency_errors"] = errors
		entry["dependency_warnings"] = warnings
		entry["dependency_blocked"] = errors.size() > 0
		var combined: Array[String] = _build_entry_warnings(entry)
		entry["warnings"] = combined

func _dependency_issue(dep: Dictionary, by_id: Dictionary) -> String:
	var dep_id := str(dep.get("id", "")).to_lower()
	var raw := str(dep.get("raw", dep_id))
	if not by_id.has(dep_id):
		return "Missing required dependency: " + raw
	var op := str(dep.get("op", ""))
	var version := str(dep.get("version", ""))
	if op == "":
		return ""
	var entry: Dictionary = by_id[dep_id]
	var have := str(entry.get("version", ""))
	var cmp := compare_versions(have, version)
	var ok := false
	match op:
		">=":
			ok = cmp >= 0
		"<=":
			ok = cmp <= 0
		">":
			ok = cmp > 0
		"<":
			ok = cmp < 0
		"==":
			ok = cmp == 0
	if ok:
		return ""
	return "Required dependency version not met: %s (found %s)" % [raw, have if have != "" else "unversioned"]


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
