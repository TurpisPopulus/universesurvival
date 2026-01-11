extends TileMap

const NetworkCrypto = preload("res://NetworkCrypto.gd")
const TilesetManager = preload("res://TilesetManager.gd")

signal initial_load_progress(loaded: int, total: int)
signal initial_load_completed

const TILE_SIZE = 32
const CHUNK_SIZE_TILES = 100
const VIEW_DISTANCE_CHUNKS = 2
const CHUNK_POLL_SECONDS = 0.5

@export var player_path: NodePath = NodePath()
@export var map_origin_tile: Vector2i = Vector2i(128, 128)
const TILE_GRASS = Vector2i(0, 0)
const TILE_DIRT = Vector2i(1, 0)
const EDIT_PREFIX = "EDIT|"

@export var server_address: String = "127.0.0.1"
@export var server_port: int = 7777

var _player
var _loaded_chunks = {}
var _source_id = -1
var _last_player_chunk = Vector2i(2147483647, 2147483647)
var _udp = PacketPeerUDP.new()
var _edit_mode = false
var _selected_tile_id = 0
var _selected_tileset = "terrain"
var _pending_changes: Dictionary = {}
var _chunk_versions: Dictionary = {}
var _chunk_confirmed: Dictionary = {}
var _poll_accum := 0.0

var _tileset_manager: TilesetManager
var _tileset_sources: Dictionary = {}  # {tileset_name: {source_id: int, atlas: Dictionary}}
var _tile_atlas: Dictionary = {}
var _initial_required: Dictionary = {}
var _initial_total := 0
var _initial_loaded := false

func _ready() -> void:
	_tileset_manager = TilesetManager.new()
	add_child(_tileset_manager)

	_player = get_node_or_null(player_path)
	if _player == null:
		push_warning("WorldMap: player not found. Set player_path in the scene.")

	var err := _udp.connect_to_host(server_address, server_port)
	if err != OK:
		push_warning("WorldMap: UDP connect failed: %s:%s (err %s)" % [server_address, server_port, err])

	_loaded_chunks.clear()
	_chunk_versions.clear()
	_chunk_confirmed.clear()
	_setup_tileset()
	_request_visible_chunks(true)

func _process(_delta: float) -> void:
	_ensure_player()
	_refresh_player_chunk()
	_poll_accum += _delta
	if _poll_accum >= CHUNK_POLL_SECONDS:
		_poll_accum = 0.0
		_request_visible_chunks(false)
	_poll_chunk_responses()

func _unhandled_input(event: InputEvent) -> void:
	if not _edit_mode:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var world_pos = get_global_mouse_position()
		_place_tile_at(world_pos)
		get_viewport().set_input_as_handled()

func _setup_tileset() -> void:
	load_tileset("terrain")

func load_tileset(tileset_name: String) -> void:
	_selected_tileset = tileset_name

	# Если тайлсет уже загружен, просто переключаемся на него
	if _tileset_sources.has(tileset_name):
		var tileset_data = _tileset_sources[tileset_name]
		_source_id = tileset_data["source_id"]
		_tile_atlas = tileset_data["atlas"]
		print("WorldMap: switched to existing tileset '", tileset_name, "'")
		return

	# Загружаем новый тайлсет
	var tileset_path = _get_tileset_path(tileset_name)
	if tileset_path == "":
		push_warning("WorldMap: unknown tileset '%s'" % tileset_name)
		return

	var texture = load(tileset_path)
	if texture == null:
		push_warning("WorldMap: missing tileset texture %s" % tileset_path)
		return

	# Создаем TileSet если еще не создан
	if tile_set == null:
		tile_set = TileSet.new()
		tile_set.tile_size = Vector2i(TILE_SIZE, TILE_SIZE)

	# Создаем атлас для этого тайлсета
	var atlas = TileSetAtlasSource.new()
	atlas.texture = texture
	atlas.texture_region_size = Vector2i(TILE_SIZE, TILE_SIZE)

	var source_id = tile_set.add_source(atlas)
	var tile_atlas = {}

	var columns = max(1, int(texture.get_size().x / TILE_SIZE))
	var rows = max(1, int(texture.get_size().y / TILE_SIZE))

	for y in range(rows):
		for x in range(columns):
			var coords = Vector2i(x, y)
			atlas.create_tile(coords)
			var local_tile_id = y * columns + x
			tile_atlas[local_tile_id] = coords

	_tileset_sources[tileset_name] = {
		"source_id": source_id,
		"atlas": tile_atlas,
		"columns": columns,
		"rows": rows
	}

	# Обновляем текущий source_id и atlas для обратной совместимости
	_source_id = source_id
	_tile_atlas = tile_atlas

	print("WorldMap: loaded tileset '", tileset_name, "' with ", tile_atlas.size(), " tiles (", columns, "x", rows, ") as source ", source_id)
	queue_redraw()

func _get_tileset_path(tileset_name: String) -> String:
	var config_path = "res://data/tilesets.json"
	var file := FileAccess.open(config_path, FileAccess.READ)

	if file == null:
		return _get_default_tileset_path(tileset_name)

	var text = file.get_as_text()
	file.close()

	var parsed = JSON.parse_string(text)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		return _get_default_tileset_path(tileset_name)

	var tilesets = parsed.get("tilesets", [])
	if typeof(tilesets) != TYPE_ARRAY:
		return _get_default_tileset_path(tileset_name)

	for item in tilesets:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var name = str(item.get("name", "")).strip_edges()
		var path = str(item.get("path", "")).strip_edges()
		if name == tileset_name and path != "":
			return path

	return _get_default_tileset_path(tileset_name)

func _get_default_tileset_path(tileset_name: String) -> String:
	match tileset_name:
		"terrain":
			return "res://tiles/terrain.png"
		"ground":
			return "res://tiles/Ground.png"
		_:
			return "res://tiles/terrain.png"

func _refresh_player_chunk() -> void:
	if _player == null:
		return
	var player_chunk = _world_to_chunk(_player.global_position)
	if player_chunk == _last_player_chunk:
		return
	_last_player_chunk = player_chunk
	_request_visible_chunks(false)

func _request_visible_chunks(force: bool) -> void:
	if _player == null:
		return
	var player_chunk = _world_to_chunk(_player.global_position)
	var needed = {}

	for cy in range(player_chunk.y - VIEW_DISTANCE_CHUNKS, player_chunk.y + VIEW_DISTANCE_CHUNKS + 1):
		for cx in range(player_chunk.x - VIEW_DISTANCE_CHUNKS, player_chunk.x + VIEW_DISTANCE_CHUNKS + 1):
			var chunk = Vector2i(cx, cy)
			needed[chunk] = true
			_request_chunk(chunk, force)

	_track_initial_chunks(needed)
	var to_unload = []
	for chunk in _loaded_chunks.keys():
		if not needed.has(chunk):
			to_unload.append(chunk)
	for chunk in to_unload:
		_unload_chunk(chunk)

func _request_chunk(chunk: Vector2i, force: bool) -> void:
	if _source_id == -1:
		return
	if not force and _chunk_confirmed.get(chunk, false):
		return
	var last_version = int(_chunk_versions.get(chunk, -1))
	var payload = "CHUNK|%s|%s|%s" % [chunk.x, chunk.y, last_version]
	var packet: PackedByteArray = NetworkCrypto.encode_message(payload)
	if packet.size() == 0:
		push_warning("WorldMap: failed to encrypt chunk request")
		return
	var err = _udp.put_packet(packet)
	if err != OK:
		push_warning("WorldMap: failed to request chunk %s (err %s)" % [chunk, err])
		return

func _unload_chunk(chunk: Vector2i) -> void:
	var start = chunk * CHUNK_SIZE_TILES
	for y in range(CHUNK_SIZE_TILES):
		for x in range(CHUNK_SIZE_TILES):
			var tile_pos = Vector2i(start.x + x, start.y + y)
			erase_cell(0, tile_pos)
	_loaded_chunks.erase(chunk)
	_chunk_versions.erase(chunk)
	_chunk_confirmed.erase(chunk)

func _world_to_chunk(world: Vector2) -> Vector2i:
	var local_pos = to_local(world)
	var tile = local_to_map(local_pos)
	var server_tile = tile + map_origin_tile
	return Vector2i(floor(server_tile.x / CHUNK_SIZE_TILES), floor(server_tile.y / CHUNK_SIZE_TILES))

func _poll_chunk_responses() -> void:
	while _udp.get_available_packet_count() > 0:
		var data = _udp.get_packet()
		if _udp.get_packet_error() != OK:
			push_warning("WorldMap: UDP receive failed (err %s)" % _udp.get_packet_error())
			return
		var text: String = NetworkCrypto.decode_message(data)
		if text == "":
			push_warning("WorldMap: rejected insecure packet")
			continue
		var parsed = JSON.parse_string(text)
		if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
			continue
		var payload = parsed
		if not payload.has("x") or not payload.has("y") or not payload.has("size") or not payload.has("tiles"):
			continue
		var size = int(payload.get("size", CHUNK_SIZE_TILES))
		if size != CHUNK_SIZE_TILES:
			continue
		var chunk = Vector2i(int(payload["x"]), int(payload["y"]))
		var version = int(payload.get("version", 0))
		_apply_chunk(chunk, payload["tiles"])
		if _edit_mode and not _pending_changes.is_empty():
			_apply_pending_for_chunk(chunk)
		_loaded_chunks[chunk] = true
		_chunk_versions[chunk] = version
		_chunk_confirmed[chunk] = true
		_update_initial_progress()

func _apply_chunk(chunk: Vector2i, tiles: Variant) -> void:
	if typeof(tiles) != TYPE_ARRAY:
		return
	var tiles_array = tiles
	if tiles_array.size() < CHUNK_SIZE_TILES * CHUNK_SIZE_TILES:
		return
	var start = chunk * CHUNK_SIZE_TILES - map_origin_tile
	var index = 0
	for y in range(CHUNK_SIZE_TILES):
		for x in range(CHUNK_SIZE_TILES):
			var tile_pos = Vector2i(start.x + x, start.y + y)
			var global_tile_id = int(tiles_array[index])

			# Декодируем глобальный ID в (tileset, local_tile_id)
			var decoded = _tileset_manager.decode_global_tile_id(global_tile_id)
			var tileset_name = decoded["tileset"]
			var local_tile_id = decoded["tile_id"]

			# Загружаем тайлсет если ещё не загружен
			if tileset_name != "" and not _tileset_sources.has(tileset_name):
				load_tileset(tileset_name)

			_apply_tile_from_global(tile_pos, tileset_name, local_tile_id)
			index += 1

func set_editor_mode(enabled: bool) -> void:
	_edit_mode = enabled

func set_selected_tile(tile_id: int) -> void:
	if tile_id < 0:
		_selected_tile_id = tile_id
		print("WorldMap: selected tile for deletion")
		return

	# Сохраняем локальный ID и текущий тайлсет
	_selected_tile_id = tile_id

	# Проверяем, что тайл существует в текущем тайлсете
	if _tileset_sources.has(_selected_tileset):
		var tileset_data = _tileset_sources[_selected_tileset]
		if tileset_data["atlas"].has(tile_id):
			print("WorldMap: selected tile ID ", tile_id, " from tileset '", _selected_tileset, "'")
		else:
			print("WorldMap: WARNING - tile ID ", tile_id, " not found in tileset '", _selected_tileset, "'")

func save_map_changes() -> void:
	if _pending_changes.is_empty():
		return
	var changes: Array = []
	for pos in _pending_changes.keys():
		var server_pos = pos + map_origin_tile
		var local_tile_id = _pending_changes[pos]

		# Преобразуем локальный ID в глобальный ID (tileset + tile_id)
		var global_tile_id = local_tile_id
		if local_tile_id >= 0:
			global_tile_id = _tileset_manager.encode_global_tile_id(_selected_tileset, local_tile_id)

		changes.append({
			"x": server_pos.x,
			"y": server_pos.y,
			"tile": global_tile_id
		})
	var payload = {
		"changes": changes
	}
	var message = EDIT_PREFIX + JSON.stringify(payload)
	var packet: PackedByteArray = NetworkCrypto.encode_message(message)
	if packet.size() == 0:
		push_warning("WorldMap: failed to encrypt map update")
		return
	var err = _udp.put_packet(packet)
	if err != OK:
		push_warning("WorldMap: failed to send map update (err %s)" % err)
		return
	_request_chunks_for_changes(changes)
	_pending_changes.clear()

func discard_map_changes() -> void:
	_pending_changes.clear()
	_reload_visible_chunks_from_server()

func _place_tile_at(world_pos: Vector2) -> void:
	if _source_id == -1:
		print("WorldMap: _place_tile_at - no source_id")
		return
	var local_pos = to_local(world_pos)
	var cell = local_to_map(local_pos)
	print("WorldMap: placing tile ", _selected_tile_id, " at cell ", cell)
	_queue_tile_change(cell, _selected_tile_id)

func _queue_tile_change(tile_pos: Vector2i, tile_id: int) -> void:
	if _source_id == -1:
		return
	if tile_id < 0:
		_pending_changes[tile_pos] = tile_id
		erase_cell(0, tile_pos)
		print("WorldMap: queued tile deletion at ", tile_pos)
		return
	if not _tile_atlas.has(tile_id):
		print("WorldMap: ERROR - cannot place tile ", tile_id, " - not in atlas (atlas size: ", _tile_atlas.size(), ")")
		return
	_pending_changes[tile_pos] = tile_id
	_apply_tile_update(tile_pos, tile_id)
	print("WorldMap: queued tile ", tile_id, " at ", tile_pos)

func _ensure_player() -> void:
	if _player != null:
		return
	if player_path == NodePath():
		return
	_player = get_node_or_null(player_path)
	if _player != null:
		_request_visible_chunks(true)

func _apply_tile_update(tile_pos: Vector2i, tile_id: int) -> void:
	if _source_id == -1:
		return
	if tile_id < 0:
		erase_cell(0, tile_pos)
		return
	var atlas_coords = _tile_atlas.get(tile_id, TILE_GRASS)
	set_cell(0, tile_pos, _source_id, atlas_coords)

func _apply_tile_from_global(tile_pos: Vector2i, tileset_name: String, local_tile_id: int) -> void:
	if local_tile_id < 0:
		erase_cell(0, tile_pos)
		return

	if tileset_name == "":
		return

	if not _tileset_sources.has(tileset_name):
		print("WorldMap: WARNING - tileset '", tileset_name, "' not loaded, cannot apply tile")
		return

	var tileset_data = _tileset_sources[tileset_name]
	var source_id = tileset_data["source_id"]
	var atlas = tileset_data["atlas"]

	if atlas.has(local_tile_id):
		var atlas_coords = atlas[local_tile_id]
		set_cell(0, tile_pos, source_id, atlas_coords)
	else:
		print("WorldMap: WARNING - tile_id ", local_tile_id, " not found in tileset '", tileset_name, "'")

func _apply_pending_for_chunk(chunk: Vector2i) -> void:
	for pos in _pending_changes.keys():
		var server_pos = pos + map_origin_tile
		var cx = int(floor(server_pos.x / float(CHUNK_SIZE_TILES)))
		var cy = int(floor(server_pos.y / float(CHUNK_SIZE_TILES)))
		if cx == chunk.x and cy == chunk.y:
			var global_tile_id = int(_pending_changes[pos])
			var decoded = _tileset_manager.decode_global_tile_id(global_tile_id)
			var tileset_name = decoded["tileset"]
			var local_tile_id = decoded["tile_id"]

			if tileset_name != "" and not _tileset_sources.has(tileset_name):
				load_tileset(tileset_name)

			_apply_tile_from_global(pos, tileset_name, local_tile_id)

func _request_chunks_for_changes(changes: Array) -> void:
	var requested := {}
	for item in changes:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		if not item.has("x") or not item.has("y"):
			continue
		var server_x = int(item["x"])
		var server_y = int(item["y"])
		var chunk = Vector2i(floor(server_x / float(CHUNK_SIZE_TILES)), floor(server_y / float(CHUNK_SIZE_TILES)))
		if requested.has(chunk):
			continue
		requested[chunk] = true
		_chunk_confirmed[chunk] = false
		_request_chunk(chunk, true)

func _reload_visible_chunks_from_server() -> void:
	_loaded_chunks.clear()
	_chunk_versions.clear()
	_chunk_confirmed.clear()
	clear()
	_request_visible_chunks(true)

func _track_initial_chunks(needed: Dictionary) -> void:
	if _initial_loaded or _initial_total > 0:
		return
	_initial_required = needed.duplicate()
	_initial_total = _initial_required.size()
	_update_initial_progress()

func _update_initial_progress() -> void:
	if _initial_loaded or _initial_total <= 0:
		return
	var loaded := 0
	for chunk in _initial_required.keys():
		if _loaded_chunks.has(chunk):
			loaded += 1
	emit_signal("initial_load_progress", loaded, _initial_total)
	if loaded >= _initial_total:
		_initial_loaded = true
		emit_signal("initial_load_completed")
