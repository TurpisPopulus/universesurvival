extends Node2D

const NetworkCrypto = preload("res://NetworkCrypto.gd")

signal initial_load_progress(loaded: int, total: int)
signal initial_load_completed

const TILE_SIZE = 32
const CHUNK_SIZE_TILES = 100
const VIEW_DISTANCE_CHUNKS = 2
const CHUNK_POLL_SECONDS = 0.5
const BLOCKING_PREFIX = "BLOCKING"
const BLOCKING_EDIT_PREFIX = "BLOCKING_EDIT|"

@export var player_path: NodePath = NodePath()
@export var map_origin_tile: Vector2i = Vector2i(128, 128)
@export var server_address: String = "127.0.0.1"
@export var server_port: int = 7777
@export var types_path: String = "res://data/blocking_types.json"

var _player
var _loaded_chunks: Dictionary = {}
var _chunk_versions: Dictionary = {}
var _chunk_blocks: Dictionary = {}
var _chunk_confirmed: Dictionary = {}
var _udp = PacketPeerUDP.new()
var _edit_mode: bool = false
var _selected_type_id: String = "block_1x1"
var _pending_changes: Dictionary = {}
var _poll_accum: float = 0.0
var _last_player_chunk: Vector2i = Vector2i(2147483647, 2147483647)

var _block_types: Dictionary = {}
var _blocked_cells: Dictionary = {}
var _cell_to_base: Dictionary = {}
var _block_instances: Dictionary = {}
var _visual_nodes: Dictionary = {}
var _initial_required: Dictionary = {}
var _initial_total: int = 0
var _initial_loaded: bool = false
var _show_visual: bool = false

func _ready() -> void:
	_player = get_node_or_null(player_path)
	if _player == null:
		push_warning("WorldBlocking: player not found. Set player_path in the scene.")
	set_process_unhandled_input(false)

	var err := _udp.connect_to_host(server_address, server_port)
	if err != OK:
		push_warning("WorldBlocking: UDP connect failed: %s:%s (err %s)" % [server_address, server_port, err])

	_loaded_chunks.clear()
	_chunk_versions.clear()
	_chunk_blocks.clear()
	_chunk_confirmed.clear()
	_load_types()
	_request_visible_chunks(true)

func _process(delta: float) -> void:
	_ensure_player()
	_refresh_player_chunk()
	_poll_accum += delta
	if _poll_accum >= CHUNK_POLL_SECONDS:
		_poll_accum = 0.0
		_request_visible_chunks(false)
	_poll_chunk_responses()

func _unhandled_input(event: InputEvent) -> void:
	if not _edit_mode:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var world_pos = get_global_mouse_position()
		_place_block_at(world_pos)

func _load_types() -> void:
	_block_types.clear()
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
		if type_id == "":
			continue
		var size_arr = item.get("size", [1, 1])
		var size_x = 1
		var size_y = 1
		if typeof(size_arr) == TYPE_ARRAY and size_arr.size() >= 2:
			size_x = max(1, int(size_arr[0]))
			size_y = max(1, int(size_arr[1]))
		var color_str = str(item.get("color", "#FF000080"))
		_block_types[type_id] = {
			"size": Vector2i(size_x, size_y),
			"color": Color.from_string(color_str, Color(1, 0, 0, 0.5))
		}
	if _block_types.is_empty():
		_apply_default_types()

func _apply_default_types() -> void:
	_block_types["block_1x1"] = {"size": Vector2i(1, 1), "color": Color(1, 0, 0, 0.5)}
	_block_types["block_2x2"] = {"size": Vector2i(2, 2), "color": Color(1, 0, 0, 0.5)}

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
	var needed: Dictionary = {}

	for cy in range(player_chunk.y - VIEW_DISTANCE_CHUNKS, player_chunk.y + VIEW_DISTANCE_CHUNKS + 1):
		for cx in range(player_chunk.x - VIEW_DISTANCE_CHUNKS, player_chunk.x + VIEW_DISTANCE_CHUNKS + 1):
			var chunk = Vector2i(cx, cy)
			needed[chunk] = true
			_request_chunk(chunk, force)

	_track_initial_chunks(needed)
	var to_unload: Array = []
	for chunk in _loaded_chunks.keys():
		if not needed.has(chunk):
			to_unload.append(chunk)
	for chunk in to_unload:
		_unload_chunk(chunk)

func _request_chunk(chunk: Vector2i, force: bool) -> void:
	if not force and _chunk_confirmed.get(chunk, false):
		return
	var last_version = int(_chunk_versions.get(chunk, -1))
	var payload = "%s|%s|%s|%s" % [BLOCKING_PREFIX, chunk.x, chunk.y, last_version]
	var packet: PackedByteArray = NetworkCrypto.encode_message(payload)
	if packet.size() == 0:
		push_warning("WorldBlocking: failed to encrypt chunk request")
		return
	var err = _udp.put_packet(packet)
	if err != OK:
		push_warning("WorldBlocking: failed to request chunk %s (err %s)" % [chunk, err])

func _unload_chunk(chunk: Vector2i) -> void:
	_clear_loaded_chunk(chunk)
	_loaded_chunks.erase(chunk)
	_chunk_versions.erase(chunk)
	_chunk_confirmed.erase(chunk)

func _clear_loaded_chunk(chunk: Vector2i) -> void:
	if not _chunk_blocks.has(chunk):
		return
	for base_pos in _chunk_blocks[chunk]:
		_clear_block_instance(base_pos)
	_chunk_blocks.erase(chunk)

func _world_to_chunk(world: Vector2) -> Vector2i:
	var tile = _world_to_tile(world)
	var server_tile = tile + map_origin_tile
	return Vector2i(floor(server_tile.x / float(CHUNK_SIZE_TILES)), floor(server_tile.y / float(CHUNK_SIZE_TILES)))

func _world_to_tile(world: Vector2) -> Vector2i:
	return Vector2i(floor(world.x / float(TILE_SIZE)), floor(world.y / float(TILE_SIZE)))

func is_world_blocked(world: Vector2) -> bool:
	return _blocked_cells.has(_world_to_tile(world))

func _poll_chunk_responses() -> void:
	while _udp.get_available_packet_count() > 0:
		var data = _udp.get_packet()
		if _udp.get_packet_error() != OK:
			push_warning("WorldBlocking: UDP receive failed (err %s)" % _udp.get_packet_error())
			return
		var text: String = NetworkCrypto.decode_message(data)
		if text == "":
			push_warning("WorldBlocking: rejected insecure packet")
			continue
		var parsed = JSON.parse_string(text)
		if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
			continue
		var payload = parsed
		if not payload.has("x") or not payload.has("y") or not payload.has("blocks"):
			continue
		var chunk = Vector2i(int(payload["x"]), int(payload["y"]))
		var version = int(payload.get("version", 0))
		_apply_blocking_chunk(chunk, payload.get("blocks", []))
		if _edit_mode and not _pending_changes.is_empty():
			_apply_pending_for_chunk(chunk)
		_loaded_chunks[chunk] = true
		_chunk_versions[chunk] = version
		_chunk_confirmed[chunk] = true
		_update_initial_progress()

func _apply_blocking_chunk(chunk: Vector2i, blocks: Variant) -> void:
	if typeof(blocks) != TYPE_ARRAY:
		return
	_clear_loaded_chunk(chunk)
	var bases: Array = []
	for item in blocks:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		if not item.has("x") or not item.has("y") or not item.has("typeId"):
			continue
		var server_x = int(item["x"])
		var server_y = int(item["y"])
		var type_id = str(item["typeId"])
		var tile_pos = Vector2i(server_x, server_y) - map_origin_tile
		if _apply_block_update(tile_pos, type_id):
			bases.append(tile_pos)
	_chunk_blocks[chunk] = bases

func set_editor_mode(enabled: bool) -> void:
	_edit_mode = enabled
	_show_visual = enabled
	set_process_unhandled_input(enabled)
	_update_all_visuals()
	print("WorldBlocking: editor mode = ", enabled, ", unhandled_input = ", is_processing_input())

func set_selected_block(type_id: String) -> void:
	_selected_type_id = type_id
	print("WorldBlocking: selected block type = '", type_id, "'")

func save_blocking_changes() -> void:
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
	var payload = {"changes": changes}
	var message = BLOCKING_EDIT_PREFIX + JSON.stringify(payload)
	var packet: PackedByteArray = NetworkCrypto.encode_message(message)
	if packet.size() == 0:
		push_warning("WorldBlocking: failed to encrypt blocking update")
		return
	var err = _udp.put_packet(packet)
	if err != OK:
		push_warning("WorldBlocking: failed to send blocking update (err %s)" % err)
		return
	_request_chunks_for_changes(changes)
	_pending_changes.clear()

func discard_blocking_changes() -> void:
	_pending_changes.clear()
	_reload_visible_chunks_from_server()

func _place_block_at(world_pos: Vector2) -> void:
	var cell = _world_to_tile(world_pos)
	_queue_block_change(cell, _selected_type_id)

func _queue_block_change(tile_pos: Vector2i, type_id: String) -> void:
	if type_id == "__remove__":
		var base_pos = _resolve_base_for_removal(tile_pos)
		_pending_changes[base_pos] = {"type_id": "__remove__"}
		_clear_block_at(base_pos)
		return
	_pending_changes[tile_pos] = {"type_id": type_id}
	_apply_block_update(tile_pos, type_id)

func _clear_block_at(tile_pos: Vector2i) -> void:
	_clear_block_instance(tile_pos)

func _ensure_player() -> void:
	if _player != null:
		return
	if player_path == NodePath():
		return
	_player = get_node_or_null(player_path)
	if _player != null:
		_request_visible_chunks(true)

func _apply_block_update(tile_pos: Vector2i, type_id: String) -> bool:
	if type_id == "__remove__":
		_clear_block_instance(tile_pos)
		return false
	if not _block_types.has(type_id):
		return false
	var block_data = _block_types[type_id]
	var size: Vector2i = block_data["size"]
	var color: Color = block_data["color"]

	var positions: Array = []
	var bases_to_clear: Dictionary = {}
	for dy in range(size.y):
		for dx in range(size.x):
			var pos = tile_pos + Vector2i(dx, dy)
			positions.append(pos)
			if _cell_to_base.has(pos):
				bases_to_clear[_cell_to_base[pos]] = true

	for base in bases_to_clear.keys():
		_clear_block_instance(base)
	_clear_block_instance(tile_pos)

	for pos in positions:
		_blocked_cells[pos] = true
		_cell_to_base[pos] = tile_pos

	_block_instances[tile_pos] = {
		"type_id": type_id,
		"size": size,
		"cells": positions,
		"color": color
	}

	if _show_visual:
		_create_visual(tile_pos, size, color)

	return true

func _apply_pending_for_chunk(chunk: Vector2i) -> void:
	for pos in _pending_changes.keys():
		var server_pos = pos + map_origin_tile
		var cx = int(floor(server_pos.x / float(CHUNK_SIZE_TILES)))
		var cy = int(floor(server_pos.y / float(CHUNK_SIZE_TILES)))
		if cx == chunk.x and cy == chunk.y:
			var data = _pending_changes[pos]
			_apply_block_update(pos, data["type_id"])

func _request_chunks_for_changes(changes: Array) -> void:
	var requested: Dictionary = {}
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
	_chunk_blocks.clear()
	_chunk_confirmed.clear()
	_last_player_chunk = Vector2i(2147483647, 2147483647)
	_clear_all_blocks()
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

func _clear_block_instance(base_pos: Vector2i) -> void:
	if not _block_instances.has(base_pos):
		return
	var data = _block_instances[base_pos]
	for pos in data.get("cells", []):
		_blocked_cells.erase(pos)
		if _cell_to_base.get(pos) == base_pos:
			_cell_to_base.erase(pos)
	_block_instances.erase(base_pos)
	_remove_visual(base_pos)

func _clear_all_blocks() -> void:
	_block_instances.clear()
	_blocked_cells.clear()
	_cell_to_base.clear()
	_clear_all_visuals()

func _resolve_base_for_removal(tile_pos: Vector2i) -> Vector2i:
	if _cell_to_base.has(tile_pos):
		return _cell_to_base[tile_pos]
	if _block_instances.has(tile_pos):
		return tile_pos
	return tile_pos

func _create_visual(base_pos: Vector2i, size: Vector2i, color: Color) -> void:
	_remove_visual(base_pos)
	var container := Node2D.new()
	container.position = Vector2(base_pos.x * TILE_SIZE, base_pos.y * TILE_SIZE)

	var rect := ColorRect.new()
	rect.color = color
	rect.size = Vector2(size.x * TILE_SIZE, size.y * TILE_SIZE)
	container.add_child(rect)

	var label := Label.new()
	label.text = "B"
	label.add_theme_color_override("font_color", Color(1, 0.2, 0.2, 1))
	label.add_theme_font_size_override("font_size", 20)
	label.position = Vector2(size.x * TILE_SIZE * 0.5 - 7, size.y * TILE_SIZE * 0.5 - 10)
	container.add_child(label)

	add_child(container)
	_visual_nodes[base_pos] = container

func _remove_visual(base_pos: Vector2i) -> void:
	if not _visual_nodes.has(base_pos):
		return
	var node = _visual_nodes[base_pos]
	if node != null:
		node.queue_free()
	_visual_nodes.erase(base_pos)

func _clear_all_visuals() -> void:
	for pos in _visual_nodes.keys():
		var node = _visual_nodes[pos]
		if node != null:
			node.queue_free()
	_visual_nodes.clear()

func _update_all_visuals() -> void:
	_clear_all_visuals()
	if not _show_visual:
		return
	for base_pos in _block_instances.keys():
		var data = _block_instances[base_pos]
		_create_visual(base_pos, data["size"], data["color"])

func get_all_blocked_cells() -> Dictionary:
	return _blocked_cells.duplicate()
