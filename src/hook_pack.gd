
const REGISTRY_TARGETS: Array[String] = []

func _is_registry_target(filename: String) -> bool:
	return filename in REGISTRY_TARGETS

func _wrapped_paths_packed(paths: Array[String]) -> PackedStringArray:
	var out := PackedStringArray()
	for path in paths:
		out.append(path)
	return out

func _script_has_rewritten_methods(script: GDScript) -> bool:
	if script == null:
		return false
	for m in script.get_script_method_list():
		if str(m["name"]).begins_with("_rtv_vanilla_"):
			return true
	return false

func _strip_class_name_for_direct_compile(source: String) -> String:
	var out := PackedStringArray()
	for line in source.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.begins_with("class_name "):
			var extends_idx := trimmed.find(" extends ")
			if extends_idx >= 0:
				var indent_len := line.length() - line.strip_edges(true, false).length()
				out.append(line.substr(0, indent_len) + trimmed.substr(extends_idx + 1))
			continue
		out.append(line)
	return "\n".join(out)

func _compile_rewritten_source_for_path(path: String, source: String) -> GDScript:
	if source.is_empty():
		return null
	var direct_source := _strip_class_name_for_direct_compile(source)
	var fresh := GDScript.new()
	fresh.source_code = direct_source
	var err := fresh.reload()
	if err != OK:
		_log_critical("[OrcKitCodegen] activate %s: direct source compile failed (%s)" % [path, error_string(err)])
		return null
	if not _script_has_rewritten_methods(fresh):
		_log_critical("[OrcKitCodegen] activate %s: direct source compile lacks renames -- rewrite isn't compiling" % path)
		return null
	fresh.take_over_path(path)
	return fresh

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
		var pre_rename := _script_has_rewritten_methods(c)
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

		var already_live := _script_has_rewritten_methods(cached)
		if already_live:
			var fresh_source := FileAccess.get_file_as_string(vp)
			if not fresh_source.is_empty() and fresh_source != cached.source_code:
				_log_info("[OrcKitCodegen] activate %s: cached rewrite is stale (static-init had an older pack), compiling generated source directly" % vp)
				var fresh := _compile_rewritten_source_for_path(vp, fresh_source)
				if fresh == null:
					continue
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
		var has_rename := _script_has_rewritten_methods(cached)
		if not has_rename:
			_log_info("[OrcKitCodegen] activate %s: reload didn't apply (pre-compiled or live instances); compiling generated source directly" % vp)
			var fresh := _compile_rewritten_source_for_path(vp, our_source)
			if fresh == null:
				continue
			_log_info("[OrcKitCodegen] activate %s: direct compiled script took over game path" % vp)
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
