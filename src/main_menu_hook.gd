
const _MENU_SCRIPT_PATH := "res://menu/menu.gd"
const _MENU_HOOK_NAME := "menu-_ready-post"
const _MODS_BUTTON_NAME := "OrcKitMods"

func _seed_core_hooks() -> void:
	pass

func _register_core_hooks() -> void:
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
