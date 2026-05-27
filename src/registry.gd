
const Registry := {
	RESOURCES = "resources",
	SCENES = "scenes",
	SCRIPTS = "scripts",
	SCENE_NODES = "scene_nodes",
	TOWERS = "towers",
	UPGRADES = "upgrades",
	LEVELS = "levels",
	ABILITIES = "abilities",
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

func register_tower(id: String, data: Variant) -> bool: return register(Registry.TOWERS, id, data)
func override_tower(id: String, data: Variant) -> bool: return override(Registry.TOWERS, id, data)
func get_tower(id: String) -> Variant: return get_entry(Registry.TOWERS, id)
func list_towers() -> Dictionary: return list(Registry.TOWERS)

func register_upgrade(id: String, data: Variant) -> bool: return register(Registry.UPGRADES, id, data)
func override_upgrade(id: String, data: Variant) -> bool: return override(Registry.UPGRADES, id, data)
func get_upgrade(id: String) -> Variant: return get_entry(Registry.UPGRADES, id)
func list_upgrades() -> Dictionary: return list(Registry.UPGRADES)

func register_level(id: String, data: Variant) -> bool: return register(Registry.LEVELS, id, data)
func override_level(id: String, data: Variant) -> bool: return override(Registry.LEVELS, id, data)
func get_level(id: String) -> Variant: return get_entry(Registry.LEVELS, id)
func list_levels() -> Dictionary: return list(Registry.LEVELS)

func register_ability(id: String, data: Variant) -> bool: return register(Registry.ABILITIES, id, data)
func override_ability(id: String, data: Variant) -> bool: return override(Registry.ABILITIES, id, data)
func get_ability(id: String) -> Variant: return get_entry(Registry.ABILITIES, id)
func list_abilities() -> Dictionary: return list(Registry.ABILITIES)


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
