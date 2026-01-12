extends Node

# Глобальный менеджер тайлсетов
# Управляет преобразованием между локальными и глобальными ID тайлов

const TILESET_ID_MULTIPLIER = 100000

var _tilesets: Dictionary = {}  # {tileset_name: tileset_index}
var _tileset_by_index: Dictionary = {}  # {tileset_index: tileset_name}
var _next_tileset_index: int = 0

func _ready() -> void:
	_load_tilesets_config()

func _load_tilesets_config() -> void:
	# Автоматически сканируем папку tiles/ для всех PNG файлов
	_tilesets.clear()
	_tileset_by_index.clear()
	_next_tileset_index = 0

	var dir := DirAccess.open("res://tiles/")
	if dir == null:
		print("TilesetManager: ERROR - Cannot open tiles/ directory")
		_setup_default_tilesets()
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()
	var tileset_names: Array = []

	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".png") and not file_name.ends_with(".import"):
			var tileset_name = file_name.trim_suffix(".png")
			tileset_names.append(tileset_name)
		file_name = dir.get_next()

	dir.list_dir_end()

	if tileset_names.is_empty():
		print("TilesetManager: WARNING - No PNG files found in tiles/")
		_setup_default_tilesets()
		return

	# Сортируем имена для стабильного порядка индексов
	tileset_names.sort()

	for name in tileset_names:
		register_tileset(name)

	print("TilesetManager: Loaded ", _tilesets.size(), " tilesets from tiles/ directory")

func _setup_default_tilesets() -> void:
	_tilesets.clear()
	_tileset_by_index.clear()
	_next_tileset_index = 0
	register_tileset("terrain")
	register_tileset("ground")

func register_tileset(tileset_name: String) -> int:
	if _tilesets.has(tileset_name):
		return _tilesets[tileset_name]

	var index = _next_tileset_index
	_tilesets[tileset_name] = index
	_tileset_by_index[index] = tileset_name
	_next_tileset_index += 1

	print("TilesetManager: registered tileset '", tileset_name, "' with index ", index)
	return index

func get_tileset_index(tileset_name: String) -> int:
	if _tilesets.has(tileset_name):
		return _tilesets[tileset_name]
	return -1

func get_tileset_name(tileset_index: int) -> String:
	if _tileset_by_index.has(tileset_index):
		return _tileset_by_index[tileset_index]
	return ""

# Преобразует (tileset_name, local_tile_id) в глобальный ID
func encode_global_tile_id(tileset_name: String, local_tile_id: int) -> int:
	var tileset_index = get_tileset_index(tileset_name)
	if tileset_index < 0:
		tileset_index = register_tileset(tileset_name)

	# Глобальный ID = tileset_index * 100000 + local_tile_id
	# Например: terrain(0):5 = 5, ground(1):52 = 100052
	return tileset_index * TILESET_ID_MULTIPLIER + local_tile_id

# Преобразует глобальный ID обратно в (tileset_name, local_tile_id)
func decode_global_tile_id(global_id: int) -> Dictionary:
	if global_id < 0:
		return {"tileset": "", "tile_id": global_id}

	var tileset_index = int(global_id / TILESET_ID_MULTIPLIER)
	var local_tile_id = global_id % TILESET_ID_MULTIPLIER
	var tileset_name = get_tileset_name(tileset_index)

	return {
		"tileset": tileset_name,
		"tile_id": local_tile_id
	}

# Для отладки
func get_all_tilesets() -> Array:
	var result = []
	for name in _tilesets.keys():
		result.append(name)
	return result
