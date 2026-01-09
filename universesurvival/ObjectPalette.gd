extends TextureRect

signal object_selected(type_id: String, rotation: int)

@export var tile_size: int = 32
@export var types_path: String = "res://data/object_types.json"

var _columns: int = 1
var _rows: int = 1
var _selected_coords := Vector2i.ZERO
var _row_types: Array = []

func _ready() -> void:
	_load_types()
	if texture == null:
		texture = _load_texture("res://tiles/objects_palette.png")

	if texture != null:
		var tex_size = texture.get_size()
		custom_minimum_size = tex_size
		size = tex_size
		_columns = max(1, int(tex_size.x / tile_size))
		_rows = max(1, int(tex_size.y / tile_size))
		expand_mode = TextureRect.EXPAND_KEEP_SIZE
		stretch_mode = TextureRect.STRETCH_KEEP

	mouse_filter = Control.MOUSE_FILTER_STOP
	size_flags_horizontal = 0
	size_flags_vertical = 0
	queue_redraw()

func _load_texture(path: String) -> Texture2D:
	var res = load(path)
	if res is Texture2D:
		return res
	var image = Image.new()
	var err = image.load(path)
	if err != OK:
		return null
	return ImageTexture.create_from_image(image)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var local_pos = _to_texture_space(get_local_mouse_position())
		var coords = Vector2i(int(floor(local_pos.x / tile_size)), int(floor(local_pos.y / tile_size)))
		if coords.x < 0 or coords.y < 0 or coords.x >= _columns or coords.y >= _rows:
			return
		if coords.y >= _row_types.size():
			return
		_selected_coords = coords
		var type_id = _row_types[coords.y]
		if type_id == "":
			return
		var rotation = coords.x
		emit_signal("object_selected", type_id, rotation)
		queue_redraw()

func _draw() -> void:
	var pos = Vector2(_selected_coords.x * tile_size, _selected_coords.y * tile_size)
	var rect = Rect2(pos, Vector2(tile_size, tile_size))
	draw_rect(rect, Color(1, 1, 1, 0.25), true)
	draw_rect(rect, Color(1, 1, 1, 0.9), false, 2.0)

func _to_texture_space(local_pos: Vector2) -> Vector2:
	if texture == null:
		return local_pos
	var tex_size = texture.get_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return local_pos
	if size.x <= 0.0 or size.y <= 0.0:
		return local_pos
	var scale = Vector2(size.x / tex_size.x, size.y / tex_size.y)
	if scale.x != 0.0:
		local_pos.x /= scale.x
	if scale.y != 0.0:
		local_pos.y /= scale.y
	return local_pos

func _load_types() -> void:
	_row_types.clear()
	var file := FileAccess.open(types_path, FileAccess.READ)
	if file == null:
		_row_types = ["wall_wood", "wall_stone"]
		return
	var text = file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		_row_types = ["wall_wood", "wall_stone"]
		return
	var types = parsed.get("types", [])
	if typeof(types) != TYPE_ARRAY:
		_row_types = ["wall_wood", "wall_stone"]
		return
	var rows: Dictionary = {}
	for item in types:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var type_id = str(item.get("typeId", "")).strip_edges()
		var row = int(item.get("paletteRow", -1))
		if type_id == "" or row < 0:
			continue
		rows[row] = type_id
	var max_row = -1
	for row in rows.keys():
		max_row = max(max_row, int(row))
	if max_row < 0:
		_row_types = ["wall_wood", "wall_stone"]
		return
	_row_types.resize(max_row + 1)
	for row in rows.keys():
		_row_types[int(row)] = rows[row]
	for i in range(_row_types.size()):
		if _row_types[i] == null:
			_row_types[i] = ""
	if _row_types.is_empty():
		_row_types = ["wall_wood", "wall_stone"]
