extends Control

enum EditorMode { TERRAIN, OBJECTS, RESOURCES, BLOCKING, SURFACE }

signal editor_closed
signal editor_saved

@export var world_map_path: NodePath = NodePath()
@export var world_objects_path: NodePath = NodePath()
@export var world_resources_path: NodePath = NodePath()
@export var world_blocking_path: NodePath = NodePath()
@export var world_surface_path: NodePath = NodePath()

var _current_mode: EditorMode = EditorMode.TERRAIN
var _world_map
var _world_objects
var _world_resources
var _world_blocking
var _world_surface

@onready var mode_buttons_container: HBoxContainer = $VBoxContainer/ModeButtons
@onready var palette_container: Control = $VBoxContainer/PaletteScroll/PaletteContainer
@onready var action_buttons: HBoxContainer = $VBoxContainer/ActionButtons
@onready var save_button: Button = $VBoxContainer/ActionButtons/SaveButton
@onready var delete_button: Button = $VBoxContainer/ActionButtons/DeleteButton
@onready var back_button: Button = $VBoxContainer/ActionButtons/BackButton

@onready var terrain_button: Button = $VBoxContainer/ModeButtons/TerrainButton
@onready var objects_button: Button = $VBoxContainer/ModeButtons/ObjectsButton
@onready var resources_button: Button = $VBoxContainer/ModeButtons/ResourcesButton
@onready var blocking_button: Button = $VBoxContainer/ModeButtons/BlockingButton
@onready var surface_button: Button = $VBoxContainer/ModeButtons/SurfaceButton

var _tile_palette
var _object_palette
var _resource_palette
var _blocking_palette
var _surface_palette

func _ready() -> void:
	_world_map = get_node_or_null(world_map_path)
	_world_objects = get_node_or_null(world_objects_path)
	_world_resources = get_node_or_null(world_resources_path)
	_world_blocking = get_node_or_null(world_blocking_path)
	_world_surface = get_node_or_null(world_surface_path)

	_setup_mode_buttons()
	_setup_action_buttons()
	_setup_palettes()
	_set_mode(EditorMode.TERRAIN)

func _setup_mode_buttons() -> void:
	if terrain_button != null:
		terrain_button.pressed.connect(_on_terrain_pressed)
	if objects_button != null:
		objects_button.pressed.connect(_on_objects_pressed)
	if resources_button != null:
		resources_button.pressed.connect(_on_resources_pressed)
	if blocking_button != null:
		blocking_button.pressed.connect(_on_blocking_pressed)
	if surface_button != null:
		surface_button.pressed.connect(_on_surface_pressed)

func _setup_action_buttons() -> void:
	if save_button != null:
		save_button.pressed.connect(_on_save_pressed)
	if delete_button != null:
		delete_button.pressed.connect(_on_delete_pressed)
	if back_button != null:
		back_button.pressed.connect(_on_back_pressed)

func _setup_palettes() -> void:
	for child in palette_container.get_children():
		child.queue_free()

	var TilePaletteScript = load("res://TilePalette.gd")
	if TilePaletteScript:
		_tile_palette = TilePaletteScript.new()
		_tile_palette.name = "TilePalette"
		palette_container.add_child(_tile_palette)
		if _tile_palette.has_signal("tile_selected"):
			_tile_palette.connect("tile_selected", Callable(self, "_on_tile_selected"))
		if _tile_palette.has_signal("tileset_changed"):
			_tile_palette.connect("tileset_changed", Callable(self, "_on_tileset_changed"))

	var ObjectPaletteScript = load("res://ObjectPalette.gd")
	if ObjectPaletteScript:
		_object_palette = ObjectPaletteScript.new()
		_object_palette.name = "ObjectPalette"
		palette_container.add_child(_object_palette)
		if _object_palette.has_signal("object_selected"):
			_object_palette.connect("object_selected", Callable(self, "_on_object_selected"))

	var ResourcePaletteScript = load("res://ResourcePalette.gd")
	if ResourcePaletteScript:
		_resource_palette = ResourcePaletteScript.new()
		_resource_palette.name = "ResourcePalette"
		palette_container.add_child(_resource_palette)
		if _resource_palette.has_signal("resource_selected"):
			_resource_palette.connect("resource_selected", Callable(self, "_on_resource_selected"))

	var BlockingPaletteScript = load("res://BlockingPalette.gd")
	if BlockingPaletteScript:
		_blocking_palette = BlockingPaletteScript.new()
		_blocking_palette.name = "BlockingPalette"
		palette_container.add_child(_blocking_palette)
		if _blocking_palette.has_signal("blocking_selected"):
			_blocking_palette.connect("blocking_selected", Callable(self, "_on_blocking_selected"))

	var SurfacePaletteScript = load("res://SurfacePalette.gd")
	if SurfacePaletteScript:
		_surface_palette = SurfacePaletteScript.new()
		_surface_palette.name = "SurfacePalette"
		palette_container.add_child(_surface_palette)
		if _surface_palette.has_signal("surface_selected"):
			_surface_palette.connect("surface_selected", Callable(self, "_on_surface_selected"))

func _set_mode(mode: EditorMode) -> void:
	_current_mode = mode
	_disable_all_editors()
	_hide_all_palettes()

	match mode:
		EditorMode.TERRAIN:
			if _world_map != null and _world_map.has_method("set_editor_mode"):
				_world_map.set_editor_mode(true)
			if _tile_palette != null:
				_tile_palette.visible = true
		EditorMode.OBJECTS:
			if _world_objects != null and _world_objects.has_method("set_editor_mode"):
				_world_objects.set_editor_mode(true)
			if _object_palette != null:
				_object_palette.visible = true
		EditorMode.RESOURCES:
			if _world_resources != null and _world_resources.has_method("set_editor_mode"):
				_world_resources.set_editor_mode(true)
			if _resource_palette != null:
				_resource_palette.visible = true
		EditorMode.BLOCKING:
			if _world_blocking != null and _world_blocking.has_method("set_editor_mode"):
				_world_blocking.set_editor_mode(true)
			if _blocking_palette != null:
				_blocking_palette.visible = true
		EditorMode.SURFACE:
			if _world_surface != null and _world_surface.has_method("set_editor_mode"):
				_world_surface.set_editor_mode(true)
			if _surface_palette != null:
				_surface_palette.visible = true

	_update_mode_buttons()

func _disable_all_editors() -> void:
	if _world_map != null and _world_map.has_method("set_editor_mode"):
		_world_map.set_editor_mode(false)
	if _world_objects != null and _world_objects.has_method("set_editor_mode"):
		_world_objects.set_editor_mode(false)
	if _world_resources != null and _world_resources.has_method("set_editor_mode"):
		_world_resources.set_editor_mode(false)
	if _world_blocking != null and _world_blocking.has_method("set_editor_mode"):
		_world_blocking.set_editor_mode(false)
	if _world_surface != null and _world_surface.has_method("set_editor_mode"):
		_world_surface.set_editor_mode(false)

func _hide_all_palettes() -> void:
	if _tile_palette != null:
		_tile_palette.visible = false
	if _object_palette != null:
		_object_palette.visible = false
	if _resource_palette != null:
		_resource_palette.visible = false
	if _blocking_palette != null:
		_blocking_palette.visible = false
	if _surface_palette != null:
		_surface_palette.visible = false

func _update_mode_buttons() -> void:
	if terrain_button != null:
		terrain_button.button_pressed = _current_mode == EditorMode.TERRAIN
	if objects_button != null:
		objects_button.button_pressed = _current_mode == EditorMode.OBJECTS
	if resources_button != null:
		resources_button.button_pressed = _current_mode == EditorMode.RESOURCES
	if blocking_button != null:
		blocking_button.button_pressed = _current_mode == EditorMode.BLOCKING
	if surface_button != null:
		surface_button.button_pressed = _current_mode == EditorMode.SURFACE

func _on_terrain_pressed() -> void:
	_set_mode(EditorMode.TERRAIN)

func _on_objects_pressed() -> void:
	_set_mode(EditorMode.OBJECTS)

func _on_resources_pressed() -> void:
	_set_mode(EditorMode.RESOURCES)

func _on_blocking_pressed() -> void:
	_set_mode(EditorMode.BLOCKING)

func _on_surface_pressed() -> void:
	_set_mode(EditorMode.SURFACE)

func _on_tile_selected(tile_id: int) -> void:
	print("UnifiedMapEditor: received tile_selected signal with tile_id ", tile_id)
	if _world_map != null and _world_map.has_method("set_selected_tile"):
		_world_map.set_selected_tile(tile_id)
	else:
		print("UnifiedMapEditor: WARNING - _world_map is null or doesn't have set_selected_tile method")

func _on_tileset_changed(tileset_name: String) -> void:
	print("UnifiedMapEditor: received tileset_changed signal with tileset_name '", tileset_name, "'")
	if _world_map != null and _world_map.has_method("load_tileset"):
		_world_map.load_tileset(tileset_name)
	else:
		print("UnifiedMapEditor: WARNING - _world_map is null or doesn't have load_tileset method")

func _on_object_selected(type_id: String, rotation: int) -> void:
	if _world_objects != null and _world_objects.has_method("set_selected_object"):
		_world_objects.set_selected_object(type_id, rotation)

func _on_resource_selected(type_id: String) -> void:
	if _world_resources != null and _world_resources.has_method("set_selected_resource"):
		_world_resources.set_selected_resource(type_id)

func _on_blocking_selected(type_id: String) -> void:
	if _world_blocking != null and _world_blocking.has_method("set_selected_block"):
		_world_blocking.set_selected_block(type_id)

func _on_surface_selected(surface_id: int) -> void:
	if _world_surface != null and _world_surface.has_method("set_selected_surface"):
		_world_surface.set_selected_surface(surface_id)

func _on_save_pressed() -> void:
	match _current_mode:
		EditorMode.TERRAIN:
			if _world_map != null and _world_map.has_method("save_map_changes"):
				_world_map.save_map_changes()
		EditorMode.OBJECTS:
			if _world_objects != null and _world_objects.has_method("save_object_changes"):
				_world_objects.save_object_changes()
		EditorMode.RESOURCES:
			if _world_resources != null and _world_resources.has_method("save_resource_changes"):
				_world_resources.save_resource_changes()
		EditorMode.BLOCKING:
			if _world_blocking != null and _world_blocking.has_method("save_blocking_changes"):
				_world_blocking.save_blocking_changes()
		EditorMode.SURFACE:
			if _world_surface != null and _world_surface.has_method("save_surface_changes"):
				_world_surface.save_surface_changes()
	emit_signal("editor_saved")

func _on_delete_pressed() -> void:
	match _current_mode:
		EditorMode.TERRAIN:
			if _world_map != null and _world_map.has_method("set_selected_tile"):
				_world_map.set_selected_tile(-1)
		EditorMode.OBJECTS:
			if _world_objects != null and _world_objects.has_method("set_selected_object"):
				_world_objects.set_selected_object("__remove__", 0)
		EditorMode.RESOURCES:
			if _world_resources != null and _world_resources.has_method("set_selected_resource"):
				_world_resources.set_selected_resource("__remove__")
		EditorMode.BLOCKING:
			if _world_blocking != null and _world_blocking.has_method("set_selected_block"):
				_world_blocking.set_selected_block("__remove__")
		EditorMode.SURFACE:
			if _world_surface != null and _world_surface.has_method("set_selected_surface"):
				_world_surface.set_selected_surface(0)

func _on_back_pressed() -> void:
	_discard_all_changes()
	_disable_all_editors()
	emit_signal("editor_closed")

func _discard_all_changes() -> void:
	if _world_map != null and _world_map.has_method("discard_map_changes"):
		_world_map.discard_map_changes()
	if _world_objects != null and _world_objects.has_method("discard_object_changes"):
		_world_objects.discard_object_changes()
	if _world_resources != null and _world_resources.has_method("discard_resource_changes"):
		_world_resources.discard_resource_changes()
	if _world_blocking != null and _world_blocking.has_method("discard_blocking_changes"):
		_world_blocking.discard_blocking_changes()
	if _world_surface != null and _world_surface.has_method("discard_surface_changes"):
		_world_surface.discard_surface_changes()

func open_editor() -> void:
	visible = true
	_set_mode(EditorMode.TERRAIN)

func close_editor() -> void:
	_discard_all_changes()
	_disable_all_editors()
	visible = false

func set_world_nodes(world_map, world_objects, world_resources, world_blocking, world_surface) -> void:
	_world_map = world_map
	_world_objects = world_objects
	_world_resources = world_resources
	_world_blocking = world_blocking
	_world_surface = world_surface
