extends Control

signal resource_selected(type_id: String)

@export var types_path: String = "res://data/resource_types.json"
@export var cell_size: int = 64
@export var cell_padding: int = 8
@export var columns: int = 4

var _entries: Array = []
var _selected_index := -1

func _ready() -> void:
	_load_types()
	mouse_filter = Control.MOUSE_FILTER_STOP
	_update_layout()
	queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var local_pos = get_local_mouse_position()
		var index = _index_from_point(local_pos)
		if index < 0 or index >= _entries.size():
			return
		_selected_index = index
		var type_id = _entries[index]["type_id"]
		emit_signal("resource_selected", type_id)
		queue_redraw()

func _draw() -> void:
	if _entries.is_empty():
		return
	var cell = Vector2(cell_size, cell_size)
	for i in range(_entries.size()):
		var row = int(i / columns)
		var col = int(i % columns)
		var pos = Vector2(col * (cell_size + cell_padding), row * (cell_size + cell_padding))
		var rect = Rect2(pos, cell)
		draw_rect(rect, Color(0, 0, 0, 0.12), true)
		var tex: Texture2D = _entries[i]["texture"]
		if tex != null:
			var tex_size = tex.get_size()
			if tex_size.x > 0 and tex_size.y > 0:
				var scale = min(cell_size / tex_size.x, cell_size / tex_size.y)
				var draw_size = tex_size * scale
				var draw_pos = pos + (cell - draw_size) * 0.5
				draw_texture_rect(tex, Rect2(draw_pos, draw_size), false)
		if i == _selected_index:
			draw_rect(rect, Color(1, 1, 1, 0.9), false, 2.0)

func _index_from_point(local_pos: Vector2) -> int:
	if columns <= 0:
		return -1
	var stride = cell_size + cell_padding
	if stride <= 0:
		return -1
	var col = int(floor(local_pos.x / stride))
	var row = int(floor(local_pos.y / stride))
	if col < 0 or row < 0:
		return -1
	var cell_origin = Vector2(col * stride, row * stride)
	if local_pos.x > cell_origin.x + cell_size or local_pos.y > cell_origin.y + cell_size:
		return -1
	return row * columns + col

func _load_types() -> void:
	_entries.clear()
	var file := FileAccess.open(types_path, FileAccess.READ)
	if file == null:
		_apply_default_entries()
		return
	var text = file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		_apply_default_entries()
		return
	var types = parsed.get("types", [])
	if typeof(types) != TYPE_ARRAY:
		_apply_default_entries()
		return
	for item in types:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var type_id = str(item.get("typeId", "")).strip_edges()
		var texture_path = str(item.get("texture", "")).strip_edges()
		if type_id == "" or texture_path == "":
			continue
		var texture = _load_texture(texture_path)
		if texture == null:
			continue
		_entries.append({
			"type_id": type_id,
			"texture": texture
		})
	if _entries.is_empty():
		_apply_default_entries()

func _apply_default_entries() -> void:
	_entries.append({
		"type_id": "tree_oak",
		"texture": _load_texture("res://resources/tree_oak.png")
	})
	_entries.append({
		"type_id": "tree_pine",
		"texture": _load_texture("res://resources/tree_pine.png")
	})

func _load_texture(path: String) -> Texture2D:
	var res = load(path)
	if res is Texture2D:
		return res
	var image = Image.new()
	var err = image.load(path)
	if err != OK:
		return null
	return ImageTexture.create_from_image(image)

func _update_layout() -> void:
	if columns <= 0:
		columns = 1
	var rows = int(ceil(_entries.size() / float(columns)))
	var width = columns * cell_size + max(0, columns - 1) * cell_padding
	var height = rows * cell_size + max(0, rows - 1) * cell_padding
	custom_minimum_size = Vector2(width, height)
	size = custom_minimum_size
