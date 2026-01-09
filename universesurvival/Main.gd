extends Node2D

@export var access_level: int = 5
@onready var admin_button: Button = get_node_or_null("Ui/AdminButton")
@onready var admin_menu: Control = get_node_or_null("Ui/AdminMenu")
@onready var admin_map_editor_button: Button = get_node_or_null("Ui/AdminMenu/AdminVBox/AdminMapEditorButton")
@onready var admin_object_editor_button: Button = get_node_or_null("Ui/AdminMenu/AdminVBox/AdminObjectEditorButton")
@onready var admin_back_button: Button = get_node_or_null("Ui/AdminMenu/AdminVBox/AdminBackButton")
@onready var map_editor_panel: Control = get_node_or_null("Ui/MapEditorPanel")
@onready var map_editor_save_button: Button = get_node_or_null("Ui/MapEditorPanel/MapEditorVBox/MapEditorActions/MapEditorSaveButton")
@onready var map_editor_delete_button: Button = get_node_or_null("Ui/MapEditorPanel/MapEditorVBox/MapEditorActions/MapEditorDeleteButton")
@onready var map_editor_back_button: Button = get_node_or_null("Ui/MapEditorPanel/MapEditorVBox/MapEditorActions/MapEditorBackButton")
@onready var tile_palette: Node = get_node_or_null("Ui/MapEditorPanel/MapEditorVBox/TilePalette")
@onready var object_editor_panel: Control = get_node_or_null("Ui/ObjectEditorPanel")
@onready var object_editor_save_button: Button = get_node_or_null("Ui/ObjectEditorPanel/ObjectEditorVBox/ObjectEditorActions/ObjectEditorSaveButton")
@onready var object_editor_delete_button: Button = get_node_or_null("Ui/ObjectEditorPanel/ObjectEditorVBox/ObjectEditorActions/ObjectEditorDeleteButton")
@onready var object_editor_back_button: Button = get_node_or_null("Ui/ObjectEditorPanel/ObjectEditorVBox/ObjectEditorActions/ObjectEditorBackButton")
@onready var object_palette: Node = get_node_or_null("Ui/ObjectEditorPanel/ObjectEditorVBox/ObjectPalette")
@onready var world_map: Node = get_node_or_null("WorldMap")
@onready var world_objects: Node = get_node_or_null("WorldObjects")
@onready var player: Node = get_node_or_null("Player")
@onready var loading_overlay: Control = get_node_or_null("Ui/LoadingOverlay")
@onready var loading_image: TextureRect = get_node_or_null("Ui/LoadingOverlay/LoadingImage")
@onready var loading_progress: ProgressBar = get_node_or_null("Ui/LoadingOverlay/LoadingProgress")

const MIN_LOADING_TIME_SEC := 1.2
const SERVER_CONFIRM_TIMEOUT_SEC := 5.0
var _loading_start_ms := 0
var _map_loaded := false
var _objects_loaded := false
var _map_loaded_count := 0
var _map_total_count := 0
var _objects_loaded_count := 0
var _objects_total_count := 0
var _loading_finish_requested := false
var _server_confirmed := false

func _ready() -> void:
	if admin_button != null:
		admin_button.visible = access_level == 1
		admin_button.pressed.connect(_on_admin_button_pressed)
	if admin_menu != null:
		admin_menu.visible = false
	if admin_map_editor_button != null:
		admin_map_editor_button.pressed.connect(_on_admin_map_editor_pressed)
	if admin_object_editor_button != null:
		admin_object_editor_button.pressed.connect(_on_admin_object_editor_pressed)
	if admin_back_button != null:
		admin_back_button.pressed.connect(_on_admin_back_pressed)
	if map_editor_panel != null:
		map_editor_panel.visible = false
	if object_editor_panel != null:
		object_editor_panel.visible = false
	if map_editor_save_button != null:
		map_editor_save_button.pressed.connect(_on_map_editor_save_pressed)
	if map_editor_delete_button != null:
		map_editor_delete_button.pressed.connect(_on_map_editor_delete_pressed)
	if map_editor_back_button != null:
		map_editor_back_button.pressed.connect(_on_map_editor_back_pressed)
	if tile_palette != null and tile_palette.has_signal("tile_selected"):
		tile_palette.connect("tile_selected", Callable(self, "_on_tile_selected"))
	if object_editor_save_button != null:
		object_editor_save_button.pressed.connect(_on_object_editor_save_pressed)
	if object_editor_delete_button != null:
		object_editor_delete_button.pressed.connect(_on_object_editor_delete_pressed)
	if object_editor_back_button != null:
		object_editor_back_button.pressed.connect(_on_object_editor_back_pressed)
	if object_palette != null and object_palette.has_signal("object_selected"):
		object_palette.connect("object_selected", Callable(self, "_on_object_selected"))
	_on_tile_selected(0)
	_on_object_selected("wall_wood", 0)
	_setup_loading_overlay()
	_bind_loading_signals()
	_set_loading_active(true)

func _on_admin_button_pressed() -> void:
	if admin_button != null:
		admin_button.visible = false
	if admin_menu != null:
		admin_menu.visible = true

func _on_admin_back_pressed() -> void:
	if admin_menu != null:
		admin_menu.visible = false
	if admin_button != null:
		admin_button.visible = access_level == 1

func _on_admin_map_editor_pressed() -> void:
	if admin_menu != null:
		admin_menu.visible = false
	if map_editor_panel != null:
		map_editor_panel.visible = true
	if object_editor_panel != null:
		object_editor_panel.visible = false
	if world_map != null and world_map.has_method("set_editor_mode"):
		world_map.set_editor_mode(true)
	if world_objects != null and world_objects.has_method("set_editor_mode"):
		world_objects.set_editor_mode(false)

func _on_admin_object_editor_pressed() -> void:
	if admin_menu != null:
		admin_menu.visible = false
	if object_editor_panel != null:
		object_editor_panel.visible = true
	if map_editor_panel != null:
		map_editor_panel.visible = false
	if world_map != null and world_map.has_method("set_editor_mode"):
		world_map.set_editor_mode(false)
	if world_objects != null and world_objects.has_method("set_editor_mode"):
		world_objects.set_editor_mode(true)

func _on_map_editor_back_pressed() -> void:
	if map_editor_panel != null:
		map_editor_panel.visible = false
	if admin_menu != null:
		admin_menu.visible = true
	if world_map != null and world_map.has_method("discard_map_changes"):
		world_map.discard_map_changes()
	if world_map != null and world_map.has_method("set_editor_mode"):
		world_map.set_editor_mode(false)
	if world_objects != null and world_objects.has_method("set_editor_mode"):
		world_objects.set_editor_mode(false)

func _on_map_editor_save_pressed() -> void:
	if world_map != null and world_map.has_method("save_map_changes"):
		world_map.save_map_changes()

func _on_tile_selected(tile_id: int) -> void:
	if world_map != null and world_map.has_method("set_selected_tile"):
		world_map.set_selected_tile(tile_id)

func _on_map_editor_delete_pressed() -> void:
	if world_map != null and world_map.has_method("set_selected_tile"):
		world_map.set_selected_tile(-1)

func _on_object_editor_back_pressed() -> void:
	if object_editor_panel != null:
		object_editor_panel.visible = false
	if admin_menu != null:
		admin_menu.visible = true
	if world_objects != null and world_objects.has_method("discard_object_changes"):
		world_objects.discard_object_changes()
	if world_objects != null and world_objects.has_method("set_editor_mode"):
		world_objects.set_editor_mode(false)

func _on_object_editor_save_pressed() -> void:
	if world_objects != null and world_objects.has_method("save_object_changes"):
		world_objects.save_object_changes()

func _on_object_editor_delete_pressed() -> void:
	if world_objects != null and world_objects.has_method("set_selected_object"):
		world_objects.set_selected_object("__remove__", 0)

func _on_object_selected(type_id: String, rotation: int) -> void:
	if world_objects != null and world_objects.has_method("set_selected_object"):
		world_objects.set_selected_object(type_id, rotation)

func _setup_loading_overlay() -> void:
	if loading_image != null:
		loading_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		loading_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	if loading_progress != null:
		loading_progress.min_value = 0.0
		loading_progress.max_value = 100.0
		loading_progress.value = 0.0

func _bind_loading_signals() -> void:
	_loading_start_ms = Time.get_ticks_msec()
	_server_confirmed = false
	if world_map != null:
		if world_map.has_signal("initial_load_progress"):
			world_map.connect("initial_load_progress", Callable(self, "_on_map_load_progress"))
		if world_map.has_signal("initial_load_completed"):
			world_map.connect("initial_load_completed", Callable(self, "_on_map_load_completed"))
	if world_objects != null:
		if world_objects.has_signal("initial_load_progress"):
			world_objects.connect("initial_load_progress", Callable(self, "_on_objects_load_progress"))
		if world_objects.has_signal("initial_load_completed"):
			world_objects.connect("initial_load_completed", Callable(self, "_on_objects_load_completed"))
	if player != null and player.has_signal("server_confirmed"):
		player.connect("server_confirmed", Callable(self, "_on_server_confirmed"))
	_update_loading_progress()

func _set_loading_active(active: bool) -> void:
	if loading_overlay != null:
		loading_overlay.visible = active
	if player != null and player.has_method("set_loading_blocked"):
		player.set_loading_blocked(active)

func _on_map_load_progress(loaded: int, total: int) -> void:
	_map_loaded_count = loaded
	_map_total_count = total
	_update_loading_progress()

func _on_objects_load_progress(loaded: int, total: int) -> void:
	_objects_loaded_count = loaded
	_objects_total_count = total
	_update_loading_progress()

func _on_map_load_completed() -> void:
	_map_loaded = true
	_map_loaded_count = _map_total_count
	_update_loading_progress()
	_try_finish_loading()

func _on_objects_load_completed() -> void:
	_objects_loaded = true
	_objects_loaded_count = _objects_total_count
	_update_loading_progress()
	_try_finish_loading()

func _update_loading_progress() -> void:
	if loading_progress == null:
		return
	var segments := 0
	var total_ratio := 0.0
	if _map_total_count > 0:
		total_ratio += float(_map_loaded_count) / float(_map_total_count)
		segments += 1
	if _objects_total_count > 0:
		total_ratio += float(_objects_loaded_count) / float(_objects_total_count)
		segments += 1
	if segments == 0:
		loading_progress.value = 0.0
		return
	total_ratio /= float(segments)
	loading_progress.value = clamp(total_ratio * 100.0, 0.0, 100.0)

func _try_finish_loading() -> void:
	if _loading_finish_requested:
		return
	if not _map_loaded or not _objects_loaded:
		return
	_loading_finish_requested = true
	var elapsed := (Time.get_ticks_msec() - _loading_start_ms) / 1000.0
	if elapsed < MIN_LOADING_TIME_SEC:
		await get_tree().create_timer(MIN_LOADING_TIME_SEC - elapsed).timeout
	if player != null and player.has_method("set_loading_blocked"):
		player.set_loading_blocked(false)
	await _wait_for_server_confirm()
	_set_loading_active(false)

func _on_server_confirmed() -> void:
	_server_confirmed = true

func _wait_for_server_confirm() -> void:
	if _server_confirmed:
		return
	if player == null or not player.has_signal("server_confirmed"):
		return
	var timeout := get_tree().create_timer(SERVER_CONFIRM_TIMEOUT_SEC)
	while not _server_confirmed and timeout.time_left > 0.0:
		await get_tree().process_frame
