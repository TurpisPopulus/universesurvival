extends TileMap

const TILE_SIZE = 32
const CHUNK_SIZE_TILES = 100
const VIEW_DISTANCE_CHUNKS = 2
const CHUNK_POLL_SECONDS = 0.5
const OBJECTS_PREFIX = "OBJECTS"
const OBJECT_EDIT_PREFIX = "OBJECT_EDIT|"

@export var player_path: NodePath = NodePath()
@export var map_origin_tile: Vector2i = Vector2i(128, 128)

@export var server_address: String = "127.0.0.1"
@export var server_port: int = 7777
@export var types_path: String = "res://data/object_types.json"

var _player
var _loaded_chunks = {}
var _chunk_versions: Dictionary = {}
var _chunk_positions: Dictionary = {}
var _udp = PacketPeerUDP.new()
var _edit_mode = false
var _selected_type_id = "wall_wood"
var _selected_rotation = 0
var _pending_changes: Dictionary = {}
var _poll_accum := 0.0
var _last_player_chunk = Vector2i(2147483647, 2147483647)
var _collision_nodes: Dictionary = {}

var _tile_defs: Dictionary = {}
var _type_atlas: Dictionary = {}
var _type_textures: Dictionary = {}
var _blocking_types: Dictionary = {}

func _ready() -> void:
	_player = get_node_or_null(player_path)
	if _player == null:
		push_warning("WorldObjects: player not found. Set player_path in the scene.")
	set_process_unhandled_input(false)

	var err := _udp.connect_to_host(server_address, server_port)
	if err != OK:
		push_warning("WorldObjects: UDP connect failed: %s:%s (err %s)" % [server_address, server_port, err])

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
		_place_object_at(world_pos)
		get_viewport().set_input_as_handled()

func _setup_tileset() -> void:
	var tileset = TileSet.new()
	tileset.tile_size = Vector2i(TILE_SIZE, TILE_SIZE)

	_tile_defs.clear()
	for type_id in _type_textures.keys():
		var texture = _load_texture(_type_textures[type_id])
		if texture == null:
			push_warning("WorldObjects: missing object texture %s" % _type_textures[type_id])
			continue

		var atlas = TileSetAtlasSource.new()
		atlas.texture = texture
		atlas.texture_region_size = Vector2i(TILE_SIZE, TILE_SIZE)
		var source_id = tileset.add_source(atlas)

		var columns = max(1, int(texture.get_size().x / TILE_SIZE))
		var rows = max(1, int(texture.get_size().y / TILE_SIZE))
		for y in range(rows):
			for x in range(columns):
				var coords = Vector2i(x, y)
				atlas.create_tile(coords)
				if _blocking_types.get(type_id, false):
					_add_blocking_collision(atlas, coords)

		if _type_atlas.has(type_id):
			var coords = _type_atlas[type_id]
			var key = _tile_key(type_id, 0)
			_tile_defs[key] = {
				"source_id": source_id,
				"coords": coords
			}
		else:
			for rotation in range(min(4, columns)):
				var key = _tile_key(type_id, rotation)
				_tile_defs[key] = {
					"source_id": source_id,
					"coords": Vector2i(rotation, 0)
				}

	tile_set = tileset

func _add_blocking_collision(atlas: TileSetAtlasSource, coords: Vector2i) -> void:
	var data = atlas.get_tile_data(coords, 0)
	if data == null:
		return
	data.set_collision_polygons_count(0, 1)
	data.set_collision_polygon_points(
		0,
		0,
		PackedVector2Array([
			Vector2(0, 0),
			Vector2(TILE_SIZE, 0),
			Vector2(TILE_SIZE, TILE_SIZE),
			Vector2(0, TILE_SIZE)
		])
	)

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
	_type_textures.clear()
	_blocking_types.clear()
	_type_atlas.clear()
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
		if type_id == "" or texture == "":
			continue
		_type_textures[type_id] = texture
		_blocking_types[type_id] = bool(item.get("isBlocking", false))
		if item.has("atlas"):
			var atlas = item.get("atlas")
			if typeof(atlas) == TYPE_ARRAY and atlas.size() >= 2:
				var ax = int(atlas[0])
				var ay = int(atlas[1])
				_type_atlas[type_id] = Vector2i(ax, ay)
	if _type_textures.is_empty():
		_apply_default_types()

func _apply_default_types() -> void:
	_type_textures["wall_wood"] = "res://tiles/object_wood_wall.png"
	_type_textures["wall_stone"] = "res://tiles/object_stone_wall.png"
	_blocking_types["wall_wood"] = true
	_blocking_types["wall_stone"] = true
	_type_atlas.clear()

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
	var last_version = int(_chunk_versions.get(chunk, -1))
	var payload = "%s|%s|%s|%s" % [OBJECTS_PREFIX, chunk.x, chunk.y, last_version]
	var err = _udp.put_packet(payload.to_utf8_buffer())
	if err != OK:
		push_warning("WorldObjects: failed to request chunk %s (err %s)" % [chunk, err])
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
			push_warning("WorldObjects: UDP receive failed (err %s)" % _udp.get_packet_error())
			return
		var text = data.get_string_from_utf8()
		var parsed = JSON.parse_string(text)
		if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
			continue
		var payload = parsed
		if not payload.has("x") or not payload.has("y") or not payload.has("objects"):
			continue
		var chunk = Vector2i(int(payload["x"]), int(payload["y"]))
		var version = int(payload.get("version", 0))
		_apply_object_chunk(chunk, payload.get("objects", []))
		if _edit_mode and not _pending_changes.is_empty():
			_apply_pending_for_chunk(chunk)
		_loaded_chunks[chunk] = true
		_chunk_versions[chunk] = version

func _apply_object_chunk(chunk: Vector2i, objects: Variant) -> void:
	if typeof(objects) != TYPE_ARRAY:
		return
	_clear_loaded_chunk(chunk)
	var positions: Array = []
	for item in objects:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		if not item.has("x") or not item.has("y") or not item.has("typeId"):
			continue
		var server_x = int(item["x"])
		var server_y = int(item["y"])
		var type_id = str(item["typeId"])
		var rotation = int(item.get("rotation", 0))
		var tile_pos = Vector2i(server_x, server_y) - map_origin_tile
		if _apply_object_update(tile_pos, type_id, rotation):
			positions.append(tile_pos)
	_chunk_positions[chunk] = positions

func set_editor_mode(enabled: bool) -> void:
	_edit_mode = enabled
	set_process_unhandled_input(enabled)
	if enabled and _tile_defs.is_empty():
		_load_types()
		_setup_tileset()

func set_selected_object(type_id: String, rotation: int) -> void:
	_selected_type_id = type_id
	_selected_rotation = clamp(rotation, 0, 3)
	if not _tile_defs.is_empty() and not _tile_defs.has(_tile_key(_selected_type_id, _selected_rotation)):
		if _tile_defs.has(_tile_key(_selected_type_id, 0)):
			_selected_rotation = 0

func save_object_changes() -> void:
	if _pending_changes.is_empty():
		return
	var changes: Array = []
	for pos in _pending_changes.keys():
		var data = _pending_changes[pos]
		var server_pos = pos + map_origin_tile
		changes.append({
			"x": server_pos.x,
			"y": server_pos.y,
			"typeId": data["type_id"],
			"rotation": data["rotation"]
		})
	var payload = {
		"changes": changes
	}
	var message = OBJECT_EDIT_PREFIX + JSON.stringify(payload)
	var err = _udp.put_packet(message.to_utf8_buffer())
	if err != OK:
		push_warning("WorldObjects: failed to send object update (err %s)" % err)
		return
	_request_chunks_for_changes(changes)
	_pending_changes.clear()

func discard_object_changes() -> void:
	_pending_changes.clear()
	_reload_visible_chunks_from_server()

func _place_object_at(world_pos: Vector2) -> void:
	var local_pos = to_local(world_pos)
	var cell = local_to_map(local_pos)
	_queue_object_change(cell, _selected_type_id, _selected_rotation)

func _queue_object_change(tile_pos: Vector2i, type_id: String, rotation: int) -> void:
	var resolved_rotation = _resolve_rotation(type_id, rotation)
	if resolved_rotation == null and _tile_defs.is_empty():
		_load_types()
		_setup_tileset()
		resolved_rotation = _resolve_rotation(type_id, rotation)
	if resolved_rotation == null:
		return
	_pending_changes[tile_pos] = {
		"type_id": type_id,
		"rotation": int(resolved_rotation)
	}
	_apply_object_update(tile_pos, type_id, int(resolved_rotation))

func _ensure_player() -> void:
	if _player != null:
		return
	if player_path == NodePath():
		return
	_player = get_node_or_null(player_path)
	if _player != null:
		_request_visible_chunks(true)

func _apply_object_update(tile_pos: Vector2i, type_id: String, rotation: int) -> bool:
	var key = _tile_key(type_id, rotation)
	if not _tile_defs.has(key):
		key = _tile_key(type_id, 0)
	if not _tile_defs.has(key):
		return false
	var data = _tile_defs[key]
	set_cell(0, tile_pos, data["source_id"], data["coords"])
	_set_collision_at(tile_pos, bool(_blocking_types.get(type_id, false)))
	return true

func _apply_pending_for_chunk(chunk: Vector2i) -> void:
	for pos in _pending_changes.keys():
		var server_pos = pos + map_origin_tile
		var cx = int(floor(server_pos.x / float(CHUNK_SIZE_TILES)))
		var cy = int(floor(server_pos.y / float(CHUNK_SIZE_TILES)))
		if cx == chunk.x and cy == chunk.y:
			var data = _pending_changes[pos]
			_apply_object_update(pos, data["type_id"], data["rotation"])

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

func _has_tile_definition(type_id: String, rotation: int) -> bool:
	return _tile_defs.has(_tile_key(type_id, rotation))

func _tile_key(type_id: String, rotation: int) -> String:
	return "%s:%s" % [type_id, clamp(rotation, 0, 3)]

func _resolve_rotation(type_id: String, rotation: int) -> Variant:
	if _has_tile_definition(type_id, rotation):
		return rotation
	if _has_tile_definition(type_id, 0):
		return 0
	return null

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
