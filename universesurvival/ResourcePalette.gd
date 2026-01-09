extends TextureRect

signal resource_selected(type_id: String)

@export var tile_size: int = 32
@export var types_path: String = "res://data/resource_types.json"

var _columns: int = 1
var _rows: int = 1
var _selected_coords := Vector2i.ZERO
var _palette_map: Dictionary = {}

func _ready() -> void:
	_load_types()
	if texture == null:
		texture = _load_texture("res://tiles/resources_palette.png")

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
		if not _palette_map.has(coords):
			return
		_selected_coords = coords
		var type_id = _palette_map[coords]
		if type_id == "":
			return
		emit_signal("resource_selected", type_id)
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
	_palette_map.clear()
	var file := FileAccess.open(types_path, FileAccess.READ)
	if file == null:
		_palette_map[Vector2i(0, 0)] = "tree_oak"
		_palette_map[Vector2i(1, 0)] = "tree_pine"
		return
	var text = file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		_palette_map[Vector2i(0, 0)] = "tree_oak"
		_palette_map[Vector2i(1, 0)] = "tree_pine"
		return
	var types = parsed.get("types", [])
	if typeof(types) != TYPE_ARRAY:
		_palette_map[Vector2i(0, 0)] = "tree_oak"
		_palette_map[Vector2i(1, 0)] = "tree_pine"
		return
	for item in types:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var type_id = str(item.get("typeId", "")).strip_edges()
		var palette = item.get("palette")
		if type_id == "" or typeof(palette) != TYPE_ARRAY or palette.size() < 2:
			continue
		var px = int(palette[0])
		var py = int(palette[1])
		_palette_map[Vector2i(px, py)] = type_id
	if _palette_map.is_empty():
		_palette_map[Vector2i(0, 0)] = "tree_oak"
		_palette_map[Vector2i(1, 0)] = "tree_pine"
