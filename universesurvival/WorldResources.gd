extends TileMap

signal initial_load_progress(loaded: int, total: int)
signal initial_load_completed

const TILE_SIZE = 32
const CHUNK_SIZE_TILES = 100
const VIEW_DISTANCE_CHUNKS = 2
const CHUNK_POLL_SECONDS = 0.5
const RESOURCES_PREFIX = "RESOURCES"
const RESOURCE_EDIT_PREFIX = "RESOURCE_EDIT|"

@export var player_path: NodePath = NodePath()
@export var map_origin_tile: Vector2i = Vector2i(128, 128)
@export var server_address: String = "127.0.0.1"
@export var server_port: int = 7777
@export var types_path: String = "res://data/resource_types.json"

var _player
var _loaded_chunks = {}
var _chunk_versions: Dictionary = {}
var _chunk_positions: Dictionary = {}
var _udp = PacketPeerUDP.new()
var _edit_mode = false
var _selected_type_id = "tree_oak"
var _pending_changes: Dictionary = {}
var _poll_accum := 0.0
var _last_player_chunk = Vector2i(2147483647, 2147483647)
var _collision_nodes: Dictionary = {}

var _type_tiles: Dictionary = {}
var _tile_defs: Dictionary = {}
var _initial_required: Dictionary = {}
var _initial_total := 0
var _initial_loaded := false

func _ready() -> void:
	_player = get_node_or_null(player_path)
	if _player == null:
		push_warning("WorldResources: player not found. Set player_path in the scene.")
	set_process_unhandled_input(false)

	var err := _udp.connect_to_host(server_address, server_port)
	if err != OK:
		push_warning("WorldResources: UDP connect failed: %s:%s (err %s)" % [server_address, server_port, err])

	_loaded_chunks.clear()
	_chunk_versions.clear()
	_chunk_positions.clear()
	_load_types()
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
		_place_resource_at(world_pos)
		get_viewport().set_input_as_handled()

func _setup_tileset() -> void:
	var tileset = TileSet.new()
	tileset.tile_size = Vector2i(TILE_SIZE, TILE_SIZE)
	_tile_defs.clear()

	var sources: Dictionary = {}
	for type_id in _type_tiles.keys():
		var tiles: Array = _type_tiles[type_id]
		for tile in tiles:
			var texture_path = tile.get("texture", "")
			var atlas = tile.get("atlas", Vector2i.ZERO)
			if texture_path == "":
				continue
			var source_data = _ensure_source(tileset, sources, texture_path)
			if source_data == null:
				continue
			var source_id = int(source_data["source_id"])
			var atlas_source: TileSetAtlasSource = source_data["atlas"]
			atlas_source.create_tile(atlas)
			var key = _tile_key(type_id, int(tile.get("index", 0)))
			_tile_defs[key] = {
				"source_id": source_id,
				"coords": atlas,
				"offset": tile.get("offset", Vector2i.ZERO),
				"blocking": bool(tile.get("blocking", false))
			}

	tile_set = tileset

func _ensure_source(tileset: TileSet, sources: Dictionary, texture_path: String) -> Variant:
	if sources.has(texture_path):
		return sources[texture_path]
	var texture = _load_texture(texture_path)
	if texture == null:
		push_warning("WorldResources: missing texture %s" % texture_path)
		return null
	var atlas = TileSetAtlasSource.new()
	atlas.texture = texture
	atlas.texture_region_size = Vector2i(TILE_SIZE, TILE_SIZE)
	var source_id = tileset.add_source(atlas)
	var data = {"source_id": source_id, "atlas": atlas}
	sources[texture_path] = data
	return data

func _load_texture(path: String) -> Texture2D:
	var res = load(path)
	if res is Texture2D:
		return res
	var image = Image.new()
	var err = image.load(path)
	if err != OK:
		return null
	return ImageTexture.create_from_image(image)

func _load_types() -> void:
	_type_tiles.clear()
	var file := FileAccess.open(types_path, FileAccess.READ)
	if file == null:
		_apply_default_types()
		return
	var text = file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		_apply_default_types()
		return
	var types = parsed.get("types", [])
	if typeof(types) != TYPE_ARRAY:
		_apply_default_types()
		return
	for item in types:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var type_id = str(item.get("typeId", "")).strip_edges()
		var texture = str(item.get("texture", "")).strip_edges()
		var tiles = item.get("tiles", [])
		if type_id == "" or texture == "" or typeof(tiles) != TYPE_ARRAY:
			continue
		var entries: Array = []
		var index = 0
		for tile in tiles:
			if typeof(tile) != TYPE_DICTIONARY:
				continue
			var atlas = tile.get("atlas")
			var offset = tile.get("offset", [0, 0])
			if typeof(atlas) != TYPE_ARRAY or atlas.size() < 2:
				continue
			var ax = int(atlas[0])
			var ay = int(atlas[1])
			var ox = 0
			var oy = 0
			if typeof(offset) == TYPE_ARRAY and offset.size() >= 2:
				ox = int(offset[0])
				oy = int(offset[1])
			entries.append({
				"texture": texture,
				"atlas": Vector2i(ax, ay),
				"offset": Vector2i(ox, oy),
				"blocking": bool(tile.get("blocking", false)),
				"index": index
			})
			index += 1
		if entries.is_empty():
			continue
		_type_tiles[type_id] = entries
	if _type_tiles.is_empty():
		_apply_default_types()

func _apply_default_types() -> void:
	_type_tiles.clear()
	_type_tiles["tree_oak"] = [
		{"texture": "res://tiles/resources_trees.png", "atlas": Vector2i(0, 1), "offset": Vector2i(0, 0), "blocking": true, "index": 0},
		{"texture": "res://tiles/resources_trees.png", "atlas": Vector2i(0, 0), "offset": Vector2i(0, -1), "blocking": false, "index": 1}
	]
	_type_tiles["tree_pine"] = [
		{"texture": "res://tiles/resources_trees.png", "atlas": Vector2i(1, 1), "offset": Vector2i(0, 0), "blocking": true, "index": 0},
		{"texture": "res://tiles/resources_trees.png", "atlas": Vector2i(1, 0), "offset": Vector2i(0, -1), "blocking": false, "index": 1}
	]

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

	_track_initial_chunks(needed)
	var to_unload = []
	for chunk in _loaded_chunks.keys():
		if not needed.has(chunk):
			to_unload.append(chunk)
	for chunk in to_unload:
		_unload_chunk(chunk)

func _request_chunk(chunk: Vector2i) -> void:
	var last_version = int(_chunk_versions.get(chunk, -1))
	var payload = "%s|%s|%s|%s" % [RESOURCES_PREFIX, chunk.x, chunk.y, last_version]
	var err = _udp.put_packet(payload.to_utf8_buffer())
	if err != OK:
		push_warning("WorldResources: failed to request chunk %s (err %s)" % [chunk, err])
		return

func _unload_chunk(chunk: Vector2i) -> void:
	_clear_loaded_chunk(chunk)
	_loaded_chunks.erase(chunk)
	_chunk_versions.erase(chunk)

func _clear_loaded_chunk(chunk: Vector2i) -> void:
	if not _chunk_positions.has(chunk):
		return
	for pos in _chunk_positions[chunk]:
		erase_cell(0, pos)
		_remove_collision_at(pos)
	_chunk_positions.erase(chunk)

func _world_to_chunk(world: Vector2) -> Vector2i:
	var local_pos = to_local(world)
	var tile = local_to_map(local_pos)
	var server_tile = tile + map_origin_tile
	return Vector2i(floor(server_tile.x / CHUNK_SIZE_TILES), floor(server_tile.y / CHUNK_SIZE_TILES))

func _poll_chunk_responses() -> void:
	while _udp.get_available_packet_count() > 0:
		var data = _udp.get_packet()
		if _udp.get_packet_error() != OK:
			push_warning("WorldResources: UDP receive failed (err %s)" % _udp.get_packet_error())
			return
		var text = data.get_string_from_utf8()
		var parsed = JSON.parse_string(text)
		if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
			continue
		var payload = parsed
		if not payload.has("x") or not payload.has("y") or not payload.has("resources"):
			continue
		var chunk = Vector2i(int(payload["x"]), int(payload["y"]))
		var version = int(payload.get("version", 0))
		_apply_resource_chunk(chunk, payload.get("resources", []))
		if _edit_mode and not _pending_changes.is_empty():
			_apply_pending_for_chunk(chunk)
		_loaded_chunks[chunk] = true
		_chunk_versions[chunk] = version
		_update_initial_progress()

func _apply_resource_chunk(chunk: Vector2i, resources: Variant) -> void:
	if typeof(resources) != TYPE_ARRAY:
		return
	_clear_loaded_chunk(chunk)
	var positions: Array = []
	for item in resources:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		if not item.has("x") or not item.has("y") or not item.has("typeId"):
			continue
		var server_x = int(item["x"])
		var server_y = int(item["y"])
		var type_id = str(item["typeId"])
		var tile_pos = Vector2i(server_x, server_y) - map_origin_tile
		var placed = _apply_resource_update(tile_pos, type_id)
		for pos in placed:
			positions.append(pos)
	_chunk_positions[chunk] = positions

func set_editor_mode(enabled: bool) -> void:
	_edit_mode = enabled
	set_process_unhandled_input(enabled)
	if enabled and _tile_defs.is_empty():
		_load_types()
		_setup_tileset()

func set_selected_resource(type_id: String) -> void:
	_selected_type_id = type_id

func save_resource_changes() -> void:
	if _pending_changes.is_empty():
		return
	var changes: Array = []
	for pos in _pending_changes.keys():
		var data = _pending_changes[pos]
		var server_pos = pos + map_origin_tile
		changes.append({
			"x": server_pos.x,
			"y": server_pos.y,
			"typeId": data["type_id"]
		})
	var payload = {
		"changes": changes
	}
	var message = RESOURCE_EDIT_PREFIX + JSON.stringify(payload)
	var err = _udp.put_packet(message.to_utf8_buffer())
	if err != OK:
		push_warning("WorldResources: failed to send resource update (err %s)" % err)
		return
	_request_chunks_for_changes(changes)
	_pending_changes.clear()

func discard_resource_changes() -> void:
	_pending_changes.clear()
	_reload_visible_chunks_from_server()

func _place_resource_at(world_pos: Vector2) -> void:
	var local_pos = to_local(world_pos)
	var cell = local_to_map(local_pos)
	_queue_resource_change(cell, _selected_type_id)

func _queue_resource_change(tile_pos: Vector2i, type_id: String) -> void:
	if type_id == "__remove__":
		_pending_changes[tile_pos] = {
			"type_id": type_id
		}
		_clear_resource_at(tile_pos)
		return
	if not _type_tiles.has(type_id):
		return
	_pending_changes[tile_pos] = {
		"type_id": type_id
	}
	_apply_resource_update(tile_pos, type_id)

func _clear_resource_at(tile_pos: Vector2i) -> void:
	for type_id in _type_tiles.keys():
		var tiles: Array = _type_tiles[type_id]
		for tile in tiles:
			var offset: Vector2i = tile.get("offset", Vector2i.ZERO)
			var pos = tile_pos + offset
			erase_cell(0, pos)
			_remove_collision_at(pos)

func _ensure_player() -> void:
	if _player != null:
		return
	if player_path == NodePath():
		return
	_player = get_node_or_null(player_path)
	if _player != null:
		_request_visible_chunks(true)

func _apply_resource_update(tile_pos: Vector2i, type_id: String) -> Array:
	var placed: Array = []
	if not _type_tiles.has(type_id):
		return placed
	var tiles: Array = _type_tiles[type_id]
	for tile in tiles:
		var index = int(tile.get("index", 0))
		var key = _tile_key(type_id, index)
		if not _tile_defs.has(key):
			continue
		var def = _tile_defs[key]
		var offset: Vector2i = def["offset"]
		var pos = tile_pos + offset
		set_cell(0, pos, def["source_id"], def["coords"])
		_set_collision_at(pos, bool(def["blocking"]))
		placed.append(pos)
	return placed

func _apply_pending_for_chunk(chunk: Vector2i) -> void:
	for pos in _pending_changes.keys():
		var server_pos = pos + map_origin_tile
		var cx = int(floor(server_pos.x / float(CHUNK_SIZE_TILES)))
		var cy = int(floor(server_pos.y / float(CHUNK_SIZE_TILES)))
		if cx == chunk.x and cy == chunk.y:
			var data = _pending_changes[pos]
			_apply_resource_update(pos, data["type_id"])

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
	_chunk_positions.clear()
	_last_player_chunk = Vector2i(2147483647, 2147483647)
	clear()
	_clear_all_collisions()
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

func _tile_key(type_id: String, index: int) -> String:
	return "%s:%s" % [type_id, index]

func _set_collision_at(tile_pos: Vector2i, blocking: bool) -> void:
	if not blocking:
		_remove_collision_at(tile_pos)
		return
	if _collision_nodes.has(tile_pos):
		return
	var body := StaticBody2D.new()
	body.position = map_to_local(tile_pos)
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(TILE_SIZE, TILE_SIZE)
	shape.shape = rect
	body.add_child(shape)
	add_child(body)
	_collision_nodes[tile_pos] = body

func _remove_collision_at(tile_pos: Vector2i) -> void:
	if not _collision_nodes.has(tile_pos):
		return
	var body = _collision_nodes[tile_pos]
	if body != null:
		body.queue_free()
	_collision_nodes.erase(tile_pos)

func _clear_all_collisions() -> void:
	for pos in _collision_nodes.keys():
		var body = _collision_nodes[pos]
		if body != null:
			body.queue_free()
	_collision_nodes.clear()
