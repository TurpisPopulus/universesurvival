extends Node2D

const NetworkCrypto = preload("res://NetworkCrypto.gd")

signal initial_load_progress(loaded: int, total: int)
signal initial_load_completed

const TILE_SIZE = 32
const CHUNK_SIZE_TILES = 100
const VIEW_DISTANCE_CHUNKS = 2
const CHUNK_POLL_SECONDS = 0.5
const RESOURCES_PREFIX = "RESOURCES"
const RESOURCE_EDIT_PREFIX = "RESOURCE_EDIT|"

@export var player_path: NodePath = NodePath()
@export var bottom_map_path: NodePath = NodePath("ResourcesBottom")
@export var top_map_path: NodePath = NodePath("ResourcesTop")
@export var map_origin_tile: Vector2i = Vector2i(128, 128)
@export var server_address: String = "127.0.0.1"
@export var server_port: int = 7777
@export var types_path: String = "res://data/resource_types.json"

var _player
var _bottom_map: TileMap
var _top_map: TileMap
var _loaded_chunks = {}
var _chunk_versions: Dictionary = {}
var _chunk_resources: Dictionary = {}
var _udp = PacketPeerUDP.new()
var _edit_mode = false
var _selected_type_id = "tree_oak"
var _pending_changes: Dictionary = {}
var _poll_accum := 0.0
var _last_player_chunk = Vector2i(2147483647, 2147483647)

var _type_textures: Dictionary = {}
var _tile_defs: Dictionary = {}
var _type_sizes: Dictionary = {}
var _resource_instances: Dictionary = {}
var _blocked_cells: Dictionary = {}
var _cell_to_base: Dictionary = {}
var _initial_required: Dictionary = {}
var _initial_total := 0
var _initial_loaded := false

func _ready() -> void:
	_player = get_node_or_null(player_path)
	if _player == null:
		push_warning("WorldResources: player not found. Set player_path in the scene.")
	_bottom_map = get_node_or_null(bottom_map_path)
	_top_map = get_node_or_null(top_map_path)
	if _bottom_map == null or _top_map == null:
		push_warning("WorldResources: missing resource tilemaps. Check bottom_map_path/top_map_path.")
	set_process_unhandled_input(false)

	var err := _udp.connect_to_host(server_address, server_port)
	if err != OK:
		push_warning("WorldResources: UDP connect failed: %s:%s (err %s)" % [server_address, server_port, err])

	_loaded_chunks.clear()
	_chunk_versions.clear()
	_chunk_resources.clear()
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
	if _bottom_map == null or _top_map == null:
		return
	var tileset = TileSet.new()
	tileset.tile_size = Vector2i(TILE_SIZE, TILE_SIZE)
	_tile_defs.clear()
	_type_sizes.clear()

	var sources: Dictionary = {}
	for type_id in _type_textures.keys():
		var texture_path = _type_textures[type_id]
		var texture = _load_texture(texture_path)
		if texture == null:
			push_warning("WorldResources: missing texture %s" % texture_path)
			continue
		var source_data = _ensure_source(tileset, sources, texture_path, texture)
		if source_data == null:
			continue
		var source_id = int(source_data["source_id"])
		var atlas_source: TileSetAtlasSource = source_data["atlas"]

		var tex_size = texture.get_size()
		var cols = max(1, int(ceil(tex_size.x / float(TILE_SIZE))))
		var rows = max(1, int(ceil(tex_size.y / float(TILE_SIZE))))
		_type_sizes[type_id] = Vector2i(cols, rows)
		var entries: Array = []
		for row in range(rows):
			for col in range(cols):
				var coords = Vector2i(col, row)
				atlas_source.create_tile(coords)
				var offset = Vector2i(col, row - (rows - 1))
				var is_top = row < rows - 1
				entries.append({
					"source_id": source_id,
					"coords": coords,
					"offset": offset,
					"is_top": is_top,
					"blocking": row == rows - 1
				})
		if entries.is_empty():
			continue
		_tile_defs[type_id] = entries

	_bottom_map.tile_set = tileset
	_top_map.tile_set = tileset

func _ensure_source(tileset: TileSet, sources: Dictionary, texture_path: String, texture: Texture2D) -> Variant:
	if sources.has(texture_path):
		return sources[texture_path]
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
	_type_textures.clear()
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
	if _type_textures.is_empty():
		_apply_default_types()

func _apply_default_types() -> void:
	_type_textures.clear()
	_type_textures["tree_oak"] = "res://resources/tree_oak.png"
	_type_textures["tree_pine"] = "res://resources/tree_pine.png"

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
	var packet: PackedByteArray = NetworkCrypto.encode_message(payload)
	if packet.size() == 0:
		push_warning("WorldResources: failed to encrypt chunk request")
		return
	var err = _udp.put_packet(packet)
	if err != OK:
		push_warning("WorldResources: failed to request chunk %s (err %s)" % [chunk, err])
		return

func _unload_chunk(chunk: Vector2i) -> void:
	_clear_loaded_chunk(chunk)
	_loaded_chunks.erase(chunk)
	_chunk_versions.erase(chunk)

func _clear_loaded_chunk(chunk: Vector2i) -> void:
	if not _chunk_resources.has(chunk):
		return
	for base_pos in _chunk_resources[chunk]:
		_clear_resource_instance(base_pos)
	_chunk_resources.erase(chunk)

func _world_to_chunk(world: Vector2) -> Vector2i:
	if _bottom_map == null:
		return Vector2i.ZERO
	var local_pos = _bottom_map.to_local(world)
	var tile = _bottom_map.local_to_map(local_pos)
	var server_tile = tile + map_origin_tile
	return Vector2i(floor(server_tile.x / CHUNK_SIZE_TILES), floor(server_tile.y / CHUNK_SIZE_TILES))

func _world_to_tile(world: Vector2) -> Vector2i:
	if _bottom_map == null:
		return Vector2i.ZERO
	var local_pos = _bottom_map.to_local(world)
	return _bottom_map.local_to_map(local_pos)

func is_world_blocked(world: Vector2) -> bool:
	return _blocked_cells.has(_world_to_tile(world))

func _poll_chunk_responses() -> void:
	while _udp.get_available_packet_count() > 0:
		var data = _udp.get_packet()
		if _udp.get_packet_error() != OK:
			push_warning("WorldResources: UDP receive failed (err %s)" % _udp.get_packet_error())
			return
		var text: String = NetworkCrypto.decode_message(data)
		if text == "":
			push_warning("WorldResources: rejected insecure packet")
			continue
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
	var bases: Array = []
	for item in resources:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		if not item.has("x") or not item.has("y") or not item.has("typeId"):
			continue
		var server_x = int(item["x"])
		var server_y = int(item["y"])
		var type_id = str(item["typeId"])
		var tile_pos = Vector2i(server_x, server_y) - map_origin_tile
		if _apply_resource_update(tile_pos, type_id):
			bases.append(tile_pos)
	_chunk_resources[chunk] = bases

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
	var packet: PackedByteArray = NetworkCrypto.encode_message(message)
	if packet.size() == 0:
		push_warning("WorldResources: failed to encrypt resource update")
		return
	var err = _udp.put_packet(packet)
	if err != OK:
		push_warning("WorldResources: failed to send resource update (err %s)" % err)
		return
	_request_chunks_for_changes(changes)
	_pending_changes.clear()

func discard_resource_changes() -> void:
	_pending_changes.clear()
	_reload_visible_chunks_from_server()

func _place_resource_at(world_pos: Vector2) -> void:
	if _bottom_map == null:
		return
	var cell = _world_to_tile(world_pos)
	_queue_resource_change(cell, _selected_type_id)

func _queue_resource_change(tile_pos: Vector2i, type_id: String) -> void:
	var base_pos = tile_pos
	if type_id == "__remove__":
		base_pos = _resolve_base_for_removal(tile_pos)
	else:
		base_pos = _get_centered_base(tile_pos, type_id)
	_pending_changes[base_pos] = {
		"type_id": type_id
	}
	if type_id == "__remove__":
		_clear_resource_at(base_pos)
		return
	_apply_resource_update(base_pos, type_id)

func _clear_resource_at(tile_pos: Vector2i) -> void:
	_clear_resource_instance(tile_pos)

func _ensure_player() -> void:
	if _player != null:
		return
	if player_path == NodePath():
		return
	_player = get_node_or_null(player_path)
	if _player != null:
		_request_visible_chunks(true)

func _apply_resource_update(tile_pos: Vector2i, type_id: String) -> bool:
	if _bottom_map == null or _top_map == null:
		return false
	if type_id == "__remove__":
		_clear_resource_instance(tile_pos)
		return false
	if not _tile_defs.has(type_id):
		return false
	var tiles: Array = _tile_defs[type_id]
	var positions: Array = []
	var bases_to_clear := {}
	for tile in tiles:
		var offset: Vector2i = tile.get("offset", Vector2i.ZERO)
		var pos = tile_pos + offset
		positions.append(pos)
		if _cell_to_base.has(pos):
			bases_to_clear[_cell_to_base[pos]] = true
	for base in bases_to_clear.keys():
		_clear_resource_instance(base)
	_clear_resource_instance(tile_pos)
	var bottom_cells: Array = []
	var top_cells: Array = []
	var blocked_cells: Array = []
	for tile in tiles:
		var offset: Vector2i = tile.get("offset", Vector2i.ZERO)
		var pos = tile_pos + offset
		if tile.get("is_top", false):
			_top_map.set_cell(0, pos, tile["source_id"], tile["coords"])
			top_cells.append(pos)
		else:
			_bottom_map.set_cell(0, pos, tile["source_id"], tile["coords"])
			bottom_cells.append(pos)
		if tile.get("blocking", false):
			_blocked_cells[pos] = true
			blocked_cells.append(pos)
	_cell_to_base[Vector2i(tile_pos.x, tile_pos.y)] = tile_pos
	for pos in positions:
		_cell_to_base[pos] = tile_pos
	_resource_instances[tile_pos] = {
		"bottom": bottom_cells,
		"top": top_cells,
		"blocked": blocked_cells,
		"cells": positions
	}
	return true

func _apply_pending_for_chunk(chunk: Vector2i) -> void:
	for pos in _pending_changes.keys():
		var server_pos = pos + map_origin_tile
		var cx = int(floor(server_pos.x / float(CHUNK_SIZE_TILES)))
		var cy = int(floor(server_pos.y / float(CHUNK_SIZE_TILES)))
		if cx == chunk.x and cy == chunk.y:
			var data = _pending_changes[pos]
			_apply_resource_update(pos, data["type_id"])
			if data["type_id"] == "__remove__":
				continue
			if not _chunk_resources.has(chunk):
				_chunk_resources[chunk] = []
			if not _chunk_resources[chunk].has(pos):
				_chunk_resources[chunk].append(pos)

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
	_chunk_resources.clear()
	_last_player_chunk = Vector2i(2147483647, 2147483647)
	_clear_all_resources()
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

func _clear_resource_instance(base_pos: Vector2i) -> void:
	if not _resource_instances.has(base_pos):
		return
	var data = _resource_instances[base_pos]
	for pos in data.get("bottom", []):
		_bottom_map.erase_cell(0, pos)
	for pos in data.get("top", []):
		_top_map.erase_cell(0, pos)
	for pos in data.get("blocked", []):
		_blocked_cells.erase(pos)
	for pos in data.get("cells", []):
		if _cell_to_base.get(pos) == base_pos:
			_cell_to_base.erase(pos)
	_resource_instances.erase(base_pos)

func _clear_all_resources() -> void:
	_resource_instances.clear()
	_blocked_cells.clear()
	_cell_to_base.clear()
	if _bottom_map != null:
		_bottom_map.clear()
	if _top_map != null:
		_top_map.clear()

func _get_centered_base(tile_pos: Vector2i, type_id: String) -> Vector2i:
	var size: Vector2i = _type_sizes.get(type_id, Vector2i.ONE)
	var offset_x = int(floor(size.x / 2.0))
	return Vector2i(tile_pos.x - offset_x, tile_pos.y)

func _resolve_base_for_removal(tile_pos: Vector2i) -> Vector2i:
	if _cell_to_base.has(tile_pos):
		return _cell_to_base[tile_pos]
	if _resource_instances.has(tile_pos):
		return tile_pos
	return tile_pos
