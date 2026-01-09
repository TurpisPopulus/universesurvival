extends Node2D

@export var access_level: int = 5
@onready var admin_button: Button = get_node_or_null("Ui/AdminButton")
@onready var admin_menu: Control = get_node_or_null("Ui/AdminMenu")
@onready var admin_map_editor_button: Button = get_node_or_null("Ui/AdminMenu/AdminVBox/AdminMapEditorButton")
@onready var admin_back_button: Button = get_node_or_null("Ui/AdminMenu/AdminVBox/AdminBackButton")
@onready var map_editor_panel: Control = get_node_or_null("Ui/MapEditorPanel")
@onready var map_editor_save_button: Button = get_node_or_null("Ui/MapEditorPanel/MapEditorVBox/MapEditorActions/MapEditorSaveButton")
@onready var map_editor_back_button: Button = get_node_or_null("Ui/MapEditorPanel/MapEditorVBox/MapEditorActions/MapEditorBackButton")
@onready var tile_palette: Node = get_node_or_null("Ui/MapEditorPanel/MapEditorVBox/TilePalette")
@onready var world_map: Node = get_node_or_null("WorldMap")

func _ready() -> void:
	if admin_button != null:
		admin_button.visible = access_level == 1
		admin_button.pressed.connect(_on_admin_button_pressed)
	if admin_menu != null:
		admin_menu.visible = false
	if admin_map_editor_button != null:
		admin_map_editor_button.pressed.connect(_on_admin_map_editor_pressed)
	if admin_back_button != null:
		admin_back_button.pressed.connect(_on_admin_back_pressed)
	if map_editor_panel != null:
		map_editor_panel.visible = false
	if map_editor_save_button != null:
		map_editor_save_button.pressed.connect(_on_map_editor_save_pressed)
	if map_editor_back_button != null:
		map_editor_back_button.pressed.connect(_on_map_editor_back_pressed)
	if tile_palette != null and tile_palette.has_signal("tile_selected"):
		tile_palette.connect("tile_selected", Callable(self, "_on_tile_selected"))
	_on_tile_selected(0)

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
	if world_map != null and world_map.has_method("set_editor_mode"):
		world_map.set_editor_mode(true)

func _on_map_editor_back_pressed() -> void:
	if map_editor_panel != null:
		map_editor_panel.visible = false
	if admin_menu != null:
		admin_menu.visible = true
	if world_map != null and world_map.has_method("discard_map_changes"):
		world_map.discard_map_changes()
	if world_map != null and world_map.has_method("set_editor_mode"):
		world_map.set_editor_mode(false)

func _on_map_editor_save_pressed() -> void:
	if world_map != null and world_map.has_method("save_map_changes"):
		world_map.save_map_changes()

func _on_tile_selected(tile_id: int) -> void:
	if world_map != null and world_map.has_method("set_selected_tile"):
		world_map.set_selected_tile(tile_id)
