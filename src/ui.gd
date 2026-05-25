
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