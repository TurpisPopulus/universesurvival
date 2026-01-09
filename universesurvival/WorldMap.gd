extends TileMap

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
var _pending_changes: Dictionary = {}
var _chunk_versions: Dictionary = {}
var _poll_accum := 0.0

var _tile_atlas: Dictionary = {}

func _ready() -> void:
	_player = get_node_or_null(player_path)
	if _player == null:
		push_warning("WorldMap: player not found. Set player_path in the scene.")

	var err := _udp.connect_to_host(server_address, server_port)
	if err != OK:
		push_warning("WorldMap: UDP connect failed: %s:%s (err %s)" % [server_address, server_port, err])

	_loaded_chunks.clear()
	_chunk_versions.clear()
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
	var tileset = TileSet.new()
	tileset.tile_size = Vector2i(TILE_SIZE, TILE_SIZE)

	var texture = load("res://tiles/terrain.png")
	if texture == null:
		push_warning("WorldMap: missing tileset texture res://tiles/terrain.png")
		return

	var atlas = TileSetAtlasSource.new()
	atlas.texture = texture
	atlas.texture_region_size = Vector2i(TILE_SIZE, TILE_SIZE)

	_source_id = tileset.add_source(atlas)
	_tile_atlas.clear()
	var columns = max(1, int(texture.get_size().x / TILE_SIZE))
	var rows = max(1, int(texture.get_size().y / TILE_SIZE))
	for y in range(rows):
		for x in range(columns):
			var coords = Vector2i(x, y)
			atlas.create_tile(coords)
			var tile_id = y * columns + x
			_tile_atlas[tile_id] = coords

	tile_set = tileset

func _refresh_player_chunk() -> void:
	if _player == null:
		return
	var player_chunk = _world_to_chunk(_player.global_position)
	if player_chunk == _last_player_chunk:
		return
	_last_player_chunk = player_chunk
	_request_visible_chunks(true)

func _request_visible_chunks(force: bool) -> void:
	if _player == null:
		return
	var player_chunk = _world_to_chunk(_player.global_position)
	var needed = {}

	for cy in range(player_chunk.y - VIEW_DISTANCE_CHUNKS, player_chunk.y + VIEW_DISTANCE_CHUNKS + 1):
		for cx in range(player_chunk.x - VIEW_DISTANCE_CHUNKS, player_chunk.x + VIEW_DISTANCE_CHUNKS + 1):
			var chunk = Vector2i(cx, cy)
			needed[chunk] = true
			_request_chunk(chunk)

	var to_unload = []
	for chunk in _loaded_chunks.keys():
		if not needed.has(chunk):
			to_unload.append(chunk)
	for chunk in to_unload:
		_unload_chunk(chunk)

func _request_chunk(chunk: Vector2i) -> void:
	if _source_id == -1:
		return
	var last_version = int(_chunk_versions.get(chunk, -1))
	var payload = "CHUNK|%s|%s|%s" % [chunk.x, chunk.y, last_version]
	var err = _udp.put_packet(payload.to_utf8_buffer())
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
		var text = data.get_string_from_utf8()
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
			var tile_id = int(tiles_array[index])
			_apply_tile_update(tile_pos, tile_id)
			index += 1

func set_editor_mode(enabled: bool) -> void:
	_edit_mode = enabled

func set_selected_tile(tile_id: int) -> void:
	if _tile_atlas.has(tile_id):
		_selected_tile_id = tile_id

func save_map_changes() -> void:
	if _pending_changes.is_empty():
		return
	var changes: Array = []
	for pos in _pending_changes.keys():
		var server_pos = pos + map_origin_tile
		changes.append({
			"x": server_pos.x,
			"y": server_pos.y,
			"tile": _pending_changes[pos]
		})
	var payload = {
		"changes": changes
	}
	var message = EDIT_PREFIX + JSON.stringify(payload)
	var err = _udp.put_packet(message.to_utf8_buffer())
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
		return
	var local_pos = to_local(world_pos)
	var cell = local_to_map(local_pos)
	_queue_tile_change(cell, _selected_tile_id)

func _queue_tile_change(tile_pos: Vector2i, tile_id: int) -> void:
	if _source_id == -1:
		return
	if not _tile_atlas.has(tile_id):
		return
	_pending_changes[tile_pos] = tile_id
	_apply_tile_update(tile_pos, tile_id)

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
	var atlas_coords = _tile_atlas.get(tile_id, TILE_GRASS)
	set_cell(0, tile_pos, _source_id, atlas_coords)

func _apply_pending_for_chunk(chunk: Vector2i) -> void:
	for pos in _pending_changes.keys():
		var server_pos = pos + map_origin_tile
		var cx = int(floor(server_pos.x / float(CHUNK_SIZE_TILES)))
		var cy = int(floor(server_pos.y / float(CHUNK_SIZE_TILES)))
		if cx == chunk.x and cy == chunk.y:
			_apply_tile_update(pos, int(_pending_changes[pos]))

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
		_request_chunk(chunk)

func _reload_visible_chunks_from_server() -> void:
	_loaded_chunks.clear()
	_chunk_versions.clear()
	clear()
	_request_visible_chunks(true)
