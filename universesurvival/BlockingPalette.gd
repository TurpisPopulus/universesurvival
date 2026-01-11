extends Control

signal blocking_selected(type_id: String)

const CELL_SIZE := 64
const COLUMNS := 3

var _types: Array = []
var _selected_index: int = 0

func _ready() -> void:
	_load_types()
	queue_redraw()

func _load_types() -> void:
	_types.clear()
	var file := FileAccess.open("res://data/blocking_types.json", FileAccess.READ)
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
		var type_id = str(item.get("typeId", "")).strip_edges()
		var display_name = str(item.get("displayName", type_id))
		var size_arr = item.get("size", [1, 1])
		var size_x = 1
		var size_y = 1
		if typeof(size_arr) == TYPE_ARRAY and size_arr.size() >= 2:
			size_x = max(1, int(size_arr[0]))
			size_y = max(1, int(size_arr[1]))
		var color_str = str(item.get("color", "#FF000080"))
		var color = Color.from_string(color_str, Color(1, 0, 0, 0.5))
		if type_id != "":
			_types.append({
				"typeId": type_id,
				"displayName": display_name,
				"size": Vector2i(size_x, size_y),
				"color": color
			})
	if _types.is_empty():
		_apply_default_types()
	_update_minimum_size()

func _apply_default_types() -> void:
	_types = [
		{"typeId": "block_1x1", "displayName": "1x1", "size": Vector2i(1, 1), "color": Color(1, 0, 0, 0.5)},
		{"typeId": "block_2x2", "displayName": "2x2", "size": Vector2i(2, 2), "color": Color(1, 0, 0, 0.5)}
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
		var color: Color = type_data.get("color", Color(1, 0, 0, 0.5))
		draw_rect(rect.grow(-2), color)
		if i == _selected_index:
			draw_rect(rect.grow(-1), Color.WHITE, false, 2.0)
		var label = type_data.get("displayName", type_data["typeId"])
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
			emit_signal("blocking_selected", _types[index]["typeId"])
			accept_event()

func get_selected_type_id() -> String:
	if _selected_index >= 0 and _selected_index < _types.size():
		return _types[_selected_index]["typeId"]
	return "block_1x1"
