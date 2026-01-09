extends Node2D

@export var access_level: int = 5
@onready var admin_button: Button = get_node_or_null("Ui/AdminButton")
@onready var admin_menu: Control = get_node_or_null("Ui/AdminMenu")
@onready var admin_map_editor_button: Button = get_node_or_null("Ui/AdminMenu/AdminVBox/AdminMapEditorButton")
@onready var admin_object_editor_button: Button = get_node_or_null("Ui/AdminMenu/AdminVBox/AdminObjectEditorButton")
@onready var admin_resource_editor_button: Button = get_node_or_null("Ui/AdminMenu/AdminVBox/AdminResourceEditorButton")
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
@onready var resource_editor_panel: Control = get_node_or_null("Ui/ResourceEditorPanel")
@onready var resource_editor_save_button: Button = get_node_or_null("Ui/ResourceEditorPanel/ResourceEditorVBox/ResourceEditorActions/ResourceEditorSaveButton")
@onready var resource_editor_delete_button: Button = get_node_or_null("Ui/ResourceEditorPanel/ResourceEditorVBox/ResourceEditorActions/ResourceEditorDeleteButton")
@onready var resource_editor_back_button: Button = get_node_or_null("Ui/ResourceEditorPanel/ResourceEditorVBox/ResourceEditorActions/ResourceEditorBackButton")
@onready var resource_palette: Node = get_node_or_null("Ui/ResourceEditorPanel/ResourceEditorVBox/ResourcePalette")
@onready var world_map: Node = get_node_or_null("WorldMap")
@onready var world_objects: Node = get_node_or_null("WorldObjects")
@onready var world_resources: Node = get_node_or_null("WorldResources")
@onready var player: Node = get_node_or_null("Player")
@onready var pause_overlay: Control = get_node_or_null("Ui/PauseOverlay")
@onready var pause_resume_button: Button = get_node_or_null("Ui/PauseOverlay/PauseCenter/PausePanel/PauseMargin/PauseVBox/ResumeButton")
@onready var pause_settings_button: Button = get_node_or_null("Ui/PauseOverlay/PauseCenter/PausePanel/PauseMargin/PauseVBox/SettingsButton")
@onready var pause_exit_button: Button = get_node_or_null("Ui/PauseOverlay/PauseCenter/PausePanel/PauseMargin/PauseVBox/ExitToMenuButton")
@onready var pause_settings_center: Control = get_node_or_null("Ui/PauseOverlay/SettingsCenter")
@onready var settings_video_button: Button = get_node_or_null("Ui/PauseOverlay/SettingsCenter/SettingsPanel/SettingsMargin/SettingsVBox/SettingsBody/SettingsMenu/VideoButton")
@onready var settings_sound_button: Button = get_node_or_null("Ui/PauseOverlay/SettingsCenter/SettingsPanel/SettingsMargin/SettingsVBox/SettingsBody/SettingsMenu/SoundButton")
@onready var settings_authors_button: Button = get_node_or_null("Ui/PauseOverlay/SettingsCenter/SettingsPanel/SettingsMargin/SettingsVBox/SettingsBody/SettingsMenu/AuthorsButton")
@onready var settings_back_button: Button = get_node_or_null("Ui/PauseOverlay/SettingsCenter/SettingsPanel/SettingsMargin/SettingsVBox/SettingsBody/SettingsMenu/SettingsBackButton")
@onready var settings_video_panel: VBoxContainer = get_node_or_null("Ui/PauseOverlay/SettingsCenter/SettingsPanel/SettingsMargin/SettingsVBox/SettingsBody/SettingsContent/ContentMargin/VideoPanel")
@onready var settings_sound_panel: VBoxContainer = get_node_or_null("Ui/PauseOverlay/SettingsCenter/SettingsPanel/SettingsMargin/SettingsVBox/SettingsBody/SettingsContent/ContentMargin/SoundPanel")
@onready var settings_authors_panel: VBoxContainer = get_node_or_null("Ui/PauseOverlay/SettingsCenter/SettingsPanel/SettingsMargin/SettingsVBox/SettingsBody/SettingsContent/ContentMargin/AuthorsPanel")
@onready var settings_resolution: OptionButton = get_node_or_null("Ui/PauseOverlay/SettingsCenter/SettingsPanel/SettingsMargin/SettingsVBox/SettingsBody/SettingsContent/ContentMargin/VideoPanel/ResolutionRow/ResolutionOption")
@onready var settings_mode: OptionButton = get_node_or_null("Ui/PauseOverlay/SettingsCenter/SettingsPanel/SettingsMargin/SettingsVBox/SettingsBody/SettingsContent/ContentMargin/VideoPanel/ModeRow/ModeOption")
@onready var loading_overlay: Control = get_node_or_null("Ui/LoadingOverlay")
@onready var loading_image: TextureRect = get_node_or_null("Ui/LoadingOverlay/LoadingImage")
@onready var loading_progress: ProgressBar = get_node_or_null("Ui/LoadingOverlay/LoadingProgress")

const MIN_LOADING_TIME_SEC := 1.2
const SERVER_CONFIRM_TIMEOUT_SEC := 5.0
var _loading_start_ms := 0
var _map_loaded := false
var _objects_loaded := false
var _resources_loaded := false
var _map_loaded_count := 0
var _map_total_count := 0
var _objects_loaded_count := 0
var _objects_total_count := 0
var _resources_loaded_count := 0
var _resources_total_count := 0
var _loading_finish_requested := false
var _server_confirmed := false
var _resolution_options: Array[Vector2i] = []
var _pending_windowed_size := Vector2i.ZERO
var _updating_video_ui := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if admin_button != null:
		admin_button.visible = access_level == 1
		admin_button.pressed.connect(_on_admin_button_pressed)
	if admin_menu != null:
		admin_menu.visible = false
	if admin_map_editor_button != null:
		admin_map_editor_button.pressed.connect(_on_admin_map_editor_pressed)
	if admin_object_editor_button != null:
		admin_object_editor_button.pressed.connect(_on_admin_object_editor_pressed)
	if admin_resource_editor_button != null:
		admin_resource_editor_button.pressed.connect(_on_admin_resource_editor_pressed)
	if admin_back_button != null:
		admin_back_button.pressed.connect(_on_admin_back_pressed)
	if map_editor_panel != null:
		map_editor_panel.visible = false
	if object_editor_panel != null:
		object_editor_panel.visible = false
	if resource_editor_panel != null:
		resource_editor_panel.visible = false
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
	if resource_editor_save_button != null:
		resource_editor_save_button.pressed.connect(_on_resource_editor_save_pressed)
	if resource_editor_delete_button != null:
		resource_editor_delete_button.pressed.connect(_on_resource_editor_delete_pressed)
	if resource_editor_back_button != null:
		resource_editor_back_button.pressed.connect(_on_resource_editor_back_pressed)
	if resource_palette != null and resource_palette.has_signal("resource_selected"):
		resource_palette.connect("resource_selected", Callable(self, "_on_resource_selected"))
	if pause_overlay != null:
		pause_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
		pause_overlay.visible = false
	if pause_settings_center != null:
		pause_settings_center.visible = false
	if pause_resume_button != null:
		pause_resume_button.pressed.connect(_on_pause_resume_pressed)
	if pause_settings_button != null:
		pause_settings_button.pressed.connect(_on_pause_settings_pressed)
	if pause_exit_button != null:
		pause_exit_button.pressed.connect(_on_pause_exit_pressed)
	if settings_video_button != null:
		settings_video_button.pressed.connect(_on_settings_video_pressed)
	if settings_sound_button != null:
		settings_sound_button.pressed.connect(_on_settings_sound_pressed)
	if settings_authors_button != null:
		settings_authors_button.pressed.connect(_on_settings_authors_pressed)
	if settings_back_button != null:
		settings_back_button.pressed.connect(_on_settings_back_pressed)
	if settings_resolution != null:
		settings_resolution.item_selected.connect(_on_resolution_selected)
	if settings_mode != null:
		settings_mode.item_selected.connect(_on_mode_selected)
	_setup_video_settings()
	_on_tile_selected(0)
	_on_object_selected("wall_wood", 0)
	_on_resource_selected("tree_oak")
	_setup_loading_overlay()
	_bind_loading_signals()
	_set_loading_active(true)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		if loading_overlay != null and loading_overlay.visible:
			return
		if pause_settings_center != null and pause_settings_center.visible:
			_show_pause_settings(false)
			get_viewport().set_input_as_handled()
			return
		_toggle_pause_menu()
		get_viewport().set_input_as_handled()

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
	if resource_editor_panel != null:
		resource_editor_panel.visible = false
	if world_map != null and world_map.has_method("set_editor_mode"):
		world_map.set_editor_mode(true)
	if world_objects != null and world_objects.has_method("set_editor_mode"):
		world_objects.set_editor_mode(false)
	if world_resources != null and world_resources.has_method("set_editor_mode"):
		world_resources.set_editor_mode(false)

func _on_admin_object_editor_pressed() -> void:
	if admin_menu != null:
		admin_menu.visible = false
	if object_editor_panel != null:
		object_editor_panel.visible = true
	if map_editor_panel != null:
		map_editor_panel.visible = false
	if resource_editor_panel != null:
		resource_editor_panel.visible = false
	if world_map != null and world_map.has_method("set_editor_mode"):
		world_map.set_editor_mode(false)
	if world_objects != null and world_objects.has_method("set_editor_mode"):
		world_objects.set_editor_mode(true)
	if world_resources != null and world_resources.has_method("set_editor_mode"):
		world_resources.set_editor_mode(false)

func _on_admin_resource_editor_pressed() -> void:
	if admin_menu != null:
		admin_menu.visible = false
	if resource_editor_panel != null:
		resource_editor_panel.visible = true
	if map_editor_panel != null:
		map_editor_panel.visible = false
	if object_editor_panel != null:
		object_editor_panel.visible = false
	if world_map != null and world_map.has_method("set_editor_mode"):
		world_map.set_editor_mode(false)
	if world_objects != null and world_objects.has_method("set_editor_mode"):
		world_objects.set_editor_mode(false)
	if world_resources != null and world_resources.has_method("set_editor_mode"):
		world_resources.set_editor_mode(true)

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
	if world_resources != null and world_resources.has_method("set_editor_mode"):
		world_resources.set_editor_mode(false)

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
	if world_resources != null and world_resources.has_method("set_editor_mode"):
		world_resources.set_editor_mode(false)

func _on_object_editor_save_pressed() -> void:
	if world_objects != null and world_objects.has_method("save_object_changes"):
		world_objects.save_object_changes()

func _on_object_editor_delete_pressed() -> void:
	if world_objects != null and world_objects.has_method("set_selected_object"):
		world_objects.set_selected_object("__remove__", 0)

func _on_object_selected(type_id: String, rotation: int) -> void:
	if world_objects != null and world_objects.has_method("set_selected_object"):
		world_objects.set_selected_object(type_id, rotation)

func _on_resource_editor_back_pressed() -> void:
	if resource_editor_panel != null:
		resource_editor_panel.visible = false
	if admin_menu != null:
		admin_menu.visible = true
	if world_resources != null and world_resources.has_method("discard_resource_changes"):
		world_resources.discard_resource_changes()
	if world_resources != null and world_resources.has_method("set_editor_mode"):
		world_resources.set_editor_mode(false)

func _on_resource_editor_save_pressed() -> void:
	if world_resources != null and world_resources.has_method("save_resource_changes"):
		world_resources.save_resource_changes()

func _on_resource_editor_delete_pressed() -> void:
	if world_resources != null and world_resources.has_method("set_selected_resource"):
		world_resources.set_selected_resource("__remove__")

func _on_resource_selected(type_id: String) -> void:
	if world_resources != null and world_resources.has_method("set_selected_resource"):
		world_resources.set_selected_resource(type_id)

func _on_pause_resume_pressed() -> void:
	_set_pause_menu_visible(false)

func _on_pause_settings_pressed() -> void:
	_show_pause_settings(true)

func _on_pause_exit_pressed() -> void:
	_set_pause_menu_visible(false)
	_return_to_main_menu()

func _on_settings_video_pressed() -> void:
	_show_settings_panel(settings_video_panel)

func _on_settings_sound_pressed() -> void:
	_show_settings_panel(settings_sound_panel)

func _on_settings_authors_pressed() -> void:
	_show_settings_panel(settings_authors_panel)

func _on_settings_back_pressed() -> void:
	_show_pause_settings(false)

func _toggle_pause_menu() -> void:
	if pause_overlay == null:
		return
	_set_pause_menu_visible(not pause_overlay.visible)

func _set_pause_menu_visible(visible: bool) -> void:
	if not visible:
		_show_pause_settings(false)
	if pause_overlay != null:
		pause_overlay.visible = visible
	get_tree().paused = visible

func _show_pause_settings(visible: bool) -> void:
	if pause_settings_center != null:
		pause_settings_center.visible = visible
	if pause_overlay != null:
		var pause_panel := pause_overlay.get_node_or_null("PauseCenter")
		if pause_panel != null:
			pause_panel.visible = not visible
	if visible:
		_sync_video_ui()
		_show_settings_panel(settings_video_panel)

func _return_to_main_menu() -> void:
	var packed := load("res://main_menu.tscn") as PackedScene
	if packed == null:
		return
	var scene := packed.instantiate()
	get_tree().root.add_child(scene)
	var previous := get_tree().current_scene
	get_tree().current_scene = scene
	if previous != null:
		previous.queue_free()

func _setup_video_settings() -> void:
	if settings_mode != null:
		settings_mode.clear()
		settings_mode.add_item("Окно", 0)
		settings_mode.add_item("Полный экран", 1)
	_refresh_resolution_list()
	_sync_video_ui()

func _refresh_resolution_list() -> void:
	_resolution_options.clear()
	if settings_resolution == null:
		return
	var screen_size := DisplayServer.screen_get_size()
	var common_resolutions := [
		Vector2i(800, 600),
		Vector2i(1024, 576),
		Vector2i(1280, 720),
		Vector2i(1366, 768),
		Vector2i(1600, 900),
		Vector2i(1920, 1080),
		Vector2i(2560, 1440),
		Vector2i(3840, 2160)
	]
	for res in common_resolutions:
		if res.x <= screen_size.x and res.y <= screen_size.y:
			_add_resolution_option(res)
	var current_size := DisplayServer.window_get_size()
	_add_resolution_option(current_size)
	_resolution_options.sort_custom(func(a, b): return a.x * a.y < b.x * b.y)
	settings_resolution.clear()
	for res in _resolution_options:
		settings_resolution.add_item("%dx%d" % [res.x, res.y])

func _add_resolution_option(resolution: Vector2i) -> void:
	for existing in _resolution_options:
		if existing == resolution:
			return
	_resolution_options.append(resolution)

func _find_resolution_index(resolution: Vector2i) -> int:
	for i in _resolution_options.size():
		if _resolution_options[i] == resolution:
			return i
	return -1

func _sync_video_ui() -> void:
	if settings_mode == null or settings_resolution == null:
		return
	_updating_video_ui = true
	_refresh_resolution_list()
	var mode := DisplayServer.window_get_mode()
	var is_fullscreen := mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	settings_mode.select(1 if is_fullscreen else 0)
	var current_size := DisplayServer.window_get_size()
	var index := _find_resolution_index(current_size)
	if index >= 0:
		settings_resolution.select(index)
	_pending_windowed_size = current_size
	_updating_video_ui = false

func _on_resolution_selected(index: int) -> void:
	if _updating_video_ui:
		return
	if index < 0 or index >= _resolution_options.size():
		return
	var selected := _resolution_options[index]
	_pending_windowed_size = selected
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED:
		DisplayServer.window_set_size(selected)

func _on_mode_selected(index: int) -> void:
	if _updating_video_ui:
		return
	if index == 1:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		if _pending_windowed_size != Vector2i.ZERO:
			DisplayServer.window_set_size(_pending_windowed_size)

func _show_settings_panel(panel: Control) -> void:
	if settings_video_panel != null:
		settings_video_panel.visible = panel == settings_video_panel
	if settings_sound_panel != null:
		settings_sound_panel.visible = panel == settings_sound_panel
	if settings_authors_panel != null:
		settings_authors_panel.visible = panel == settings_authors_panel

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
	if world_resources != null:
		if world_resources.has_signal("initial_load_progress"):
			world_resources.connect("initial_load_progress", Callable(self, "_on_resources_load_progress"))
		if world_resources.has_signal("initial_load_completed"):
			world_resources.connect("initial_load_completed", Callable(self, "_on_resources_load_completed"))
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

func _on_resources_load_progress(loaded: int, total: int) -> void:
	_resources_loaded_count = loaded
	_resources_total_count = total
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

func _on_resources_load_completed() -> void:
	_resources_loaded = true
	_resources_loaded_count = _resources_total_count
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
	if _resources_total_count > 0:
		total_ratio += float(_resources_loaded_count) / float(_resources_total_count)
		segments += 1
	if segments == 0:
		loading_progress.value = 0.0
		return
	total_ratio /= float(segments)
	loading_progress.value = clamp(total_ratio * 100.0, 0.0, 100.0)

func _try_finish_loading() -> void:
	if _loading_finish_requested:
		return
	if not _map_loaded or not _objects_loaded or not _resources_loaded:
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
