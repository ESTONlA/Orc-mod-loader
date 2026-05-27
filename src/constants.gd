
const MODLOADER_VERSION := "1.1.0"

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
var _re_public_hook_call: RegEx

var _rtv_re_extends: RegEx
var _rtv_re_class_name: RegEx
var _rtv_re_func: RegEx
var _rtv_re_static_func: RegEx
var _rtv_re_var: RegEx

var _filescope_mounted: Dictionary = _mount_previous_session()
