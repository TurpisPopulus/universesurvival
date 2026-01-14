extends VBoxContainer

signal tile_selected(tile_id: int)
signal tileset_changed(tileset_name: String)

@export var tile_size: int = 32
@export var config_path: String = "res://data/tilesets.json"

var _columns: int = 1
var _rows: int = 1
var _selected_coords := Vector2i.ZERO
var _current_tileset: String = "terrain"
var _tilesets: Dictionary = {}
var _tileset_selector: OptionButton
var _texture_rect: TextureRect

func _ready() -> void:
	_load_tilesets_config()
	_create_tileset_selector()
	_create_texture_rect()

	if _texture_rect.texture == null:
		load_tileset(_current_tileset)

func _load_tilesets_config() -> void:
	# Автоматически сканируем папку tiles/ для всех PNG файлов
	_tilesets.clear()
	var dir := DirAccess.open("res://tiles/")

	if dir == null:
		print("TilePalette: ERROR - Cannot open tiles/ directory")
		_setup_default_tilesets()
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()

	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".png") and not file_name.ends_with(".import"):
			# Создаем имя тайлсета из имени файла (без расширения)
			var tileset_name = file_name.trim_suffix(".png")
			var tileset_path = "res://tiles/" + file_name
			_tilesets[tileset_name] = tileset_path
			print("TilePalette: Found tileset '", tileset_name, "' at '", tileset_path, "'")
		file_name = dir.get_next()

	dir.list_dir_end()

	if _tilesets.is_empty():
		print("TilePalette: WARNING - No PNG files found in tiles/")
		_setup_default_tilesets()
	else:
		print("TilePalette: Loaded ", _tilesets.size(), " tilesets from tiles/ directory")

func _setup_default_tilesets() -> void:
	_tilesets = {
		"terrain": "res://tiles/terrain.png",
		"ground": "res://tiles/Ground.png"
	}

func _create_tileset_selector() -> void:
	_tileset_selector = OptionButton.new()
	_tileset_selector.name = "TilesetSelector"

	var index = 0
	for tileset_name in _tilesets.keys():
		_tileset_selector.add_item(tileset_name, index)
		if tileset_name == _current_tileset:
			_tileset_selector.select(index)
		index += 1

	_tileset_selector.item_selected.connect(_on_tileset_selected)
	add_child(_tileset_selector)

func _create_texture_rect() -> void:
	_texture_rect = TextureRect.new()
	_texture_rect.name = "TilesetTexture"
	_texture_rect.mouse_filter = Control.MOUSE_FILTER_STOP
	_texture_rect.expand_mode = TextureRect.EXPAND_KEEP_SIZE
	_texture_rect.stretch_mode = TextureRect.STRETCH_KEEP
	_texture_rect.size_flags_horizontal = 0
	_texture_rect.size_flags_vertical = 0
	_texture_rect.gui_input.connect(_on_texture_gui_input)
	_texture_rect.draw.connect(_on_texture_draw)
	add_child(_texture_rect)

func _on_tileset_selected(index: int) -> void:
	var tileset_name = _tileset_selector.get_item_text(index)
	print("TilePalette: tileset selector changed to index ", index, " = '", tileset_name, "'")

	# Предупреждение: переключение тайлсета меняет визуализацию существующих тайлов
	if _current_tileset != tileset_name:
		print("TilePalette: WARNING - Switching tileset will change how existing tiles are displayed!")

	load_tileset(tileset_name)
	print("TilePalette: emitting tileset_changed signal with '", tileset_name, "'")
	emit_signal("tileset_changed", tileset_name)

func load_tileset(tileset_name: String) -> void:
	if not _tilesets.has(tileset_name):
		print("TilePalette: ERROR - tileset '", tileset_name, "' not found in _tilesets")
		return

	_current_tileset = tileset_name
	var path = _tilesets[tileset_name]
	print("TilePalette: loading tileset '", tileset_name, "' from path '", path, "'")
	_texture_rect.texture = load(path)

	if _texture_rect.texture != null:
		_update_texture_properties()
		_selected_coords = Vector2i.ZERO
		print("TilePalette: loaded tileset with grid ", _columns, "x", _rows, " = ", _columns * _rows, " tiles")
		_texture_rect.queue_redraw()
	else:
		print("TilePalette: ERROR - failed to load texture from '", path, "'")

func _update_texture_properties() -> void:
	var tex_size = _texture_rect.texture.get_size()
	_texture_rect.custom_minimum_size = tex_size
	_texture_rect.size = tex_size
	_columns = max(1, int(tex_size.x / tile_size))
	_rows = max(1, int(tex_size.y / tile_size))

func get_current_tileset() -> String:
	return _current_tileset

func clear_selection() -> void:
	_selected_coords = Vector2i(-1, -1)
	if _texture_rect != null:
		_texture_rect.queue_redraw()

func _on_texture_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var local_pos = _to_texture_space(_texture_rect.get_local_mouse_position())
		var coords = Vector2i(int(floor(local_pos.x / tile_size)), int(floor(local_pos.y / tile_size)))
		if coords.x < 0 or coords.y < 0 or coords.x >= _columns or coords.y >= _rows:
			return
		_selected_coords = coords
		var tile_id = coords.y * _columns + coords.x
		print("TilePalette: selected tile at coords ", coords, " = tile_id ", tile_id, " (grid: ", _columns, "x", _rows, ")")
		emit_signal("tile_selected", tile_id)
		_texture_rect.queue_redraw()

func _on_texture_draw() -> void:
	# Не рисуем выделение, если координаты отрицательные (сброшены)
	if _selected_coords.x < 0 or _selected_coords.y < 0:
		return
	var pos = Vector2(_selected_coords.x * tile_size, _selected_coords.y * tile_size)
	var rect = Rect2(pos, Vector2(tile_size, tile_size))
	_texture_rect.draw_rect(rect, Color(1, 1, 1, 0.25), true)
	_texture_rect.draw_rect(rect, Color(1, 1, 1, 0.9), false, 2.0)

func _to_texture_space(local_pos: Vector2) -> Vector2:
	if _texture_rect.texture == null:
		return local_pos
	var tex_size = _texture_rect.texture.get_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return local_pos
	if _texture_rect.size.x <= 0.0 or _texture_rect.size.y <= 0.0:
		return local_pos
	var scale = Vector2(_texture_rect.size.x / tex_size.x, _texture_rect.size.y / tex_size.y)
	if scale.x != 0.0:
		local_pos.x /= scale.x
	if scale.y != 0.0:
		local_pos.y /= scale.y
	return local_pos
