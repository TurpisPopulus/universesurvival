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
