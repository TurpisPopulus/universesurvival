extends Control

signal surface_selected(surface_id: int)

const CELL_SIZE := 64
const COLUMNS := 3

var _types: Array = []
var _selected_index: int = 0

func _ready() -> void:
	_load_types()
	queue_redraw()

func _load_types() -> void:
	_types.clear()
	var file := FileAccess.open("res://data/surface_types.json", FileAccess.READ)
	if file == null:
		_apply_default_types()
		return
	var text := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		_apply_default_types()
		return
	var types_arr = parsed.get("types", [])
	if typeof(types_arr) != TYPE_ARRAY:
		_apply_default_types()
		return
	for item in types_arr:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var surface_id = int(item.get("surfaceId", 0))
		var name_str = str(item.get("name", "ground"))
		var display_name = str(item.get("displayName", name_str))
		var color_str = str(item.get("color", "#8B451380"))
		var color = Color.from_string(color_str, Color(0.55, 0.27, 0.07, 0.5))
		_types.append({
			"surfaceId": surface_id,
			"name": name_str,
			"displayName": display_name,
			"color": color
		})
	if _types.is_empty():
		_apply_default_types()
	_update_minimum_size()

func _apply_default_types() -> void:
	_types = [
		{"surfaceId": 0, "name": "ground", "displayName": "Ground", "color": Color(0.55, 0.27, 0.07, 0.5)},
		{"surfaceId": 1, "name": "water_shallow", "displayName": "Shallow", "color": Color(0.53, 0.81, 0.92, 0.5)},
		{"surfaceId": 2, "name": "water_deep", "displayName": "Deep", "color": Color(0, 0, 0.5, 0.75)}
	]
	_update_minimum_size()

func _update_minimum_size() -> void:
	var rows = int(ceil(float(_types.size()) / float(COLUMNS)))
	custom_minimum_size = Vector2(COLUMNS * CELL_SIZE, rows * CELL_SIZE)

func _draw() -> void:
	var font := ThemeDB.fallback_font
	var font_size := 12
	for i in range(_types.size()):
		var row := int(i / COLUMNS)
		var col := i % COLUMNS
		var rect := Rect2(col * CELL_SIZE, row * CELL_SIZE, CELL_SIZE, CELL_SIZE)
		var type_data = _types[i]
		var color: Color = type_data.get("color", Color(0.5, 0.5, 0.5, 0.5))
		draw_rect(rect.grow(-2), color)
		if i == _selected_index:
			draw_rect(rect.grow(-1), Color.WHITE, false, 2.0)
		var label = type_data.get("displayName", type_data["name"])
		var text_size = font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
		var text_pos = rect.position + (rect.size - text_size) / 2 + Vector2(0, text_size.y * 0.75)
		draw_string(font, text_pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var local_pos: Vector2 = event.position
		var col := int(local_pos.x / CELL_SIZE)
		var row := int(local_pos.y / CELL_SIZE)
		var index := row * COLUMNS + col
		if index >= 0 and index < _types.size():
			_selected_index = index
			queue_redraw()
			emit_signal("surface_selected", _types[index]["surfaceId"])
			accept_event()

func get_selected_surface_id() -> int:
	if _selected_index >= 0 and _selected_index < _types.size():
		return _types[_selected_index]["surfaceId"]
	return 0
