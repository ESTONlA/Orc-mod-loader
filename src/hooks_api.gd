
static func version() -> String:
	return MODLOADER_VERSION

static func major_version() -> int:
	return int(MODLOADER_VERSION.split(".")[0])

static func minor_version() -> int:
	return int(MODLOADER_VERSION.split(".")[1])

static func patch_version() -> int:
	return int(MODLOADER_VERSION.split(".")[2])

func _register_orcmodlib_meta() -> void:
	if Engine.has_meta("OrcmodLib"):
		_log_warning("[OrcmodLib] Engine.meta 'OrcmodLib' already set -- not overwriting")
		return
	Engine.set_meta("OrcmodLib", self)
	_log_info("[OrcmodLib] modloader registered as Engine.meta('OrcmodLib')")

func _emit_frameworks_ready() -> void:
	_is_ready = true
	_register_core_hooks()
	_scene_nodes_connect_listener()
	frameworks_ready.emit()
	_log_info("[OrcmodLib] frameworks_ready emitted")
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
		_log_debug("[OrcmodLib] replace hook '%s' already owned (id=%d), registration rejected" \
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

func get_loaded_mods() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for k in _loaded_mod_ids.keys():
		var info = _loaded_mod_ids[k]
		if info is Dictionary:
			out.append((info as Dictionary).duplicate())
	return out

func get_resource_owner(res_path: String) -> Dictionary:
	var normalized := _normalize_resource_query_path(res_path)
	if not _override_registry.has(normalized):
		return {}
	var claims: Array = _override_registry[normalized]
	if claims.is_empty():
		return {}
	return (claims[claims.size() - 1] as Dictionary).duplicate()

func on_battle_start(callback: Callable, priority: int = 100) -> int:
	var cb := func():
		_call_public_callback(callback, [_caller])
	return _register_game_event("res://battle/battle.gd", "_ready", "post", cb, priority)

func on_battle_end(callback: Callable, priority: int = 100) -> int:
	var cb := func():
		var battle = _caller
		_call_public_callback(callback, [
			battle.get("health") if battle != null else null,
			battle.get("total_enemies_spawned") if battle != null else null,
			battle.get("total_enemies_killed") if battle != null else null,
			battle,
		])
	return _register_game_event("res://battle/battle.gd", "_end_battle", "post", cb, priority)

func on_enemy_spawned(callback: Callable, priority: int = 100) -> int:
	var cb := func(count: int):
		_call_public_callback(callback, [count, _caller])
	return _register_game_event("res://battle/battle.gd", "_on_enemies_spawned", "post", cb, priority)

func on_enemy_killed(callback: Callable, priority: int = 100) -> int:
	var cb := func(count: int, data: PackedByteArray):
		_call_public_callback(callback, [count, data, _caller])
	return _register_game_event("res://battle/battle.gd", "_on_enemies_killed", "post", cb, priority)

func on_tower_placed(callback: Callable, priority: int = 100) -> int:
	var cb := func(tower):
		_call_public_callback(callback, [tower, _caller])
	return _register_game_event("res://battle/battle.gd", "add_tower", "post", cb, priority)

func on_tower_removed(callback: Callable, priority: int = 100) -> int:
	var cb := func(tower):
		_call_public_callback(callback, [tower, _caller])
	return _register_game_event("res://battle/battle.gd", "remove_tower", "post", cb, priority)

func on_level_loaded(callback: Callable, priority: int = 100) -> int:
	var cb := func():
		_call_public_callback(callback, [_current_selected_level(), _caller])
	return _register_game_event("res://battle/battle.gd", "_ready", "post", cb, priority)

func on_tech_tree_opened(callback: Callable, priority: int = 100) -> int:
	var cb := func():
		_call_public_callback(callback, [_caller])
	return _register_game_event("res://menu/menu.gd", "_on_tech_tree_pressed", "post", cb, priority)

func on_upgrade_purchased(callback: Callable, priority: int = 100) -> int:
	var cb := func():
		var upgrade = _caller
		_call_public_callback(callback, [
			upgrade,
			upgrade.get("level") if upgrade != null else null,
		])
	return _register_game_event("res://tech_tree/upgrades/upgrade.gd", "buy", "post", cb, priority)

func _register_game_event(script_path: String, method_name: String, phase: String,
		callback: Callable, priority: int) -> int:
	var res_path := _canonical_hook_script_path(script_path)
	if not _hooked_methods.has(res_path):
		_hooked_methods[res_path] = {}
	(_hooked_methods[res_path] as Dictionary)[method_name.to_lower()] = true
	var stem := res_path.get_file().get_basename().to_lower()
	return hook("%s-%s-%s" % [stem, method_name.to_lower(), phase], callback, priority)

func _call_public_callback(callback: Callable, args: Array) -> Variant:
	if not callback.is_valid():
		return null
	var argc := callback.get_argument_count()
	if argc < 0 or argc >= args.size():
		return callback.callv(args)
	return callback.callv(args.slice(0, argc))

func _current_selected_level() -> Variant:
	var gm := get_node_or_null("/root/GameManager")
	if gm == null:
		return null
	return gm.get("selected_level")

func _normalize_resource_query_path(res_path: String) -> String:
	var p := res_path.replace("\\", "/")
	if p.begins_with("res://"):
		return p
	if p.begins_with("/"):
		return "res:/" + p
	return "res://" + p


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
				_log_warning("[OrcmodLib] post hook '%s' callback uses legacy %d-arg signature (expected %d for non-void wrapper). Add a trailing _result param to your callback to receive + optionally mutate the return value; the legacy form will be removed in a future major version." \
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
