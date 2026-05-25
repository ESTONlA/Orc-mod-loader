
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