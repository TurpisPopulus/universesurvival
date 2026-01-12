extends Node2D

const NetworkCrypto = preload("res://NetworkCrypto.gd")

signal initial_load_progress(loaded: int, total: int)
signal initial_load_completed

const TILE_SIZE = 32
const CHUNK_SIZE_TILES = 100
const VIEW_DISTANCE_CHUNKS = 2
const CHUNK_POLL_SECONDS = 0.5
const SURFACE_PREFIX = "SURFACE"
const SURFACE_EDIT_PREFIX = "SURFACE_EDIT|"

@export var player_path: NodePath = NodePath()
@export var map_origin_tile: Vector2i = Vector2i(128, 128)
@export var server_address: String = "127.0.0.1"
@export var server_port: int = 7777
@export var types_path: String = "res://data/surface_types.json"

var _player
var _loaded_chunks: Dictionary = {}
var _chunk_versions: Dictionary = {}
var _chunk_surfaces: Dictionary = {}
var _chunk_confirmed: Dictionary = {}
var _udp = PacketPeerUDP.new()
var _edit_mode: bool = false
var _selected_surface_id: int = 0
var _pending_changes: Dictionary = {}
var _poll_accum: float = 0.0
var _last_player_chunk: Vector2i = Vector2i(2147483647, 2147483647)

var _surface_types: Dictionary = {}
var _surface_cells: Dictionary = {}
var _visual_nodes: Dictionary = {}
var _initial_required: Dictionary = {}
var _initial_total: int = 0
var _initial_loaded: bool = false
var _show_visual: bool = false

func _ready() -> void:
	_player = get_node_or_null(player_path)
	if _player == null:
		push_warning("WorldSurface: player not found. Set player_path in the scene.")
	set_process_unhandled_input(false)

	var err := _udp.connect_to_host(server_address, server_port)
	if err != OK:
		push_warning("WorldSurface: UDP connect failed: %s:%s (err %s)" % [server_address, server_port, err])

	_loaded_chunks.clear()
	_chunk_versions.clear()
	_chunk_surfaces.clear()
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
		_place_surface_at(world_pos)

func _load_types() -> void:
	_surface_types.clear()
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
		var surface_id = int(item.get("surfaceId", 0))
		var name_str = str(item.get("name", "ground"))
		var display_name = str(item.get("displayName", name_str))
		var color_str = str(item.get("color", "#8B451380"))
		var speed_mod = float(item.get("speedMod", 1.0))
		var damage = float(item.get("damage", 0.0))
		var blocking = bool(item.get("blocking", false))
		_surface_types[surface_id] = {
			"name": name_str,
			"displayName": display_name,
			"color": Color.from_string(color_str, Color(0.55, 0.27, 0.07, 0.5)),
			"speedMod": speed_mod,
			"damage": damage,
			"blocking": blocking
		}
	if _surface_types.is_empty():
		_apply_default_types()

func _apply_default_types() -> void:
	_surface_types[0] = {"name": "ground", "displayName": "Ground", "color": Color(0.55, 0.27, 0.07, 0.5), "speedMod": 1.0, "damage": 0.0, "blocking": false}
	_surface_types[1] = {"name": "water_shallow", "displayName": "Shallow Water", "color": Color(0.53, 0.81, 0.92, 0.5), "speedMod": 0.7, "damage": 0.0, "blocking": false}
	_surface_types[2] = {"name": "water_deep", "displayName": "Deep Water", "color": Color(0, 0, 0.5, 0.75), "speedMod": 0.3, "damage": 1.0, "blocking": true}

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
	var payload = "%s|%s|%s|%s" % [SURFACE_PREFIX, chunk.x, chunk.y, last_version]
	var packet: PackedByteArray = NetworkCrypto.encode_message(payload)
	if packet.size() == 0:
		push_warning("WorldSurface: failed to encrypt chunk request")
		return
	var err = _udp.put_packet(packet)
	if err != OK:
		push_warning("WorldSurface: failed to request chunk %s (err %s)" % [chunk, err])

func _unload_chunk(chunk: Vector2i) -> void:
	_clear_loaded_chunk(chunk)
	_loaded_chunks.erase(chunk)
	_chunk_versions.erase(chunk)
	_chunk_confirmed.erase(chunk)

func _clear_loaded_chunk(chunk: Vector2i) -> void:
	if not _chunk_surfaces.has(chunk):
		return
	var positions = _chunk_surfaces[chunk]
	for pos in positions:
		_surface_cells.erase(pos)
		_remove_visual(pos)
	_chunk_surfaces.erase(chunk)

func _world_to_chunk(world: Vector2) -> Vector2i:
	var tile = _world_to_tile(world)
	var server_tile = tile + map_origin_tile
	return Vector2i(floor(server_tile.x / float(CHUNK_SIZE_TILES)), floor(server_tile.y / float(CHUNK_SIZE_TILES)))

func _world_to_tile(world: Vector2) -> Vector2i:
	return Vector2i(floor(world.x / float(TILE_SIZE)), floor(world.y / float(TILE_SIZE)))

func is_blocking(world: Vector2) -> bool:
	var tile = _world_to_tile(world)
	var surface_id = _surface_cells.get(tile, 0)
	if not _surface_types.has(surface_id):
		return false
	return _surface_types[surface_id].get("blocking", false)

func get_surface_at(world: Vector2) -> Dictionary:
	var tile = _world_to_tile(world)
	var surface_id = _surface_cells.get(tile, 0)
	if not _surface_types.has(surface_id):
		return {"surfaceId": 0, "speedMod": 1.0, "damage": 0.0, "blocking": false}
	var data = _surface_types[surface_id]
	return {
		"surfaceId": surface_id,
		"speedMod": data.get("speedMod", 1.0),
		"damage": data.get("damage", 0.0),
		"blocking": data.get("blocking", false)
	}

func get_surface_types() -> Dictionary:
	return _surface_types.duplicate()

func is_world_blocked(world: Vector2) -> bool:
	var surface_data = get_surface_at(world)
	return surface_data.get("blocking", false)

func _poll_chunk_responses() -> void:
	while _udp.get_available_packet_count() > 0:
		var data = _udp.get_packet()
		if _udp.get_packet_error() != OK:
			push_warning("WorldSurface: UDP receive failed (err %s)" % _udp.get_packet_error())
			return
		var text: String = NetworkCrypto.decode_message(data)
		if text == "":
			push_warning("WorldSurface: rejected insecure packet")
			continue
		var parsed = JSON.parse_string(text)
		if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
			continue
		var payload = parsed
		if not payload.has("x") or not payload.has("y") or not payload.has("surfaces"):
			continue
		var chunk = Vector2i(int(payload["x"]), int(payload["y"]))
		var version = int(payload.get("version", 0))
		_apply_surface_chunk(chunk, payload.get("surfaces", []))
		if _edit_mode and not _pending_changes.is_empty():
			_apply_pending_for_chunk(chunk)
		_loaded_chunks[chunk] = true
		_chunk_versions[chunk] = version
		_chunk_confirmed[chunk] = true
		_update_initial_progress()

func _apply_surface_chunk(chunk: Vector2i, surfaces: Variant) -> void:
	if typeof(surfaces) != TYPE_ARRAY:
		return
	_clear_loaded_chunk(chunk)
	var positions: Array = []
	for item in surfaces:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		if not item.has("x") or not item.has("y") or not item.has("surfaceId"):
			continue
		var server_x = int(item["x"])
		var server_y = int(item["y"])
		var surface_id = int(item["surfaceId"])
		var tile_pos = Vector2i(server_x, server_y) - map_origin_tile
		_apply_surface_update(tile_pos, surface_id)
		positions.append(tile_pos)
	_chunk_surfaces[chunk] = positions

func set_editor_mode(enabled: bool) -> void:
	_edit_mode = enabled
	_show_visual = enabled
	set_process_unhandled_input(enabled)
	_update_all_visuals()
	print("WorldSurface: editor mode = ", enabled, ", unhandled_input = ", is_processing_input())

func set_selected_surface(surface_id: int) -> void:
	_selected_surface_id = surface_id
	print("WorldSurface: selected surface ID = ", surface_id)

func save_surface_changes() -> void:
	if _pending_changes.is_empty():
		return
	var changes: Array = []
	for pos in _pending_changes.keys():
		var surface_id = _pending_changes[pos]
		var server_pos = pos + map_origin_tile
		changes.append({
			"x": server_pos.x,
			"y": server_pos.y,
			"surfaceId": surface_id
		})
	var payload = {"changes": changes}
	var message = SURFACE_EDIT_PREFIX + JSON.stringify(payload)
	var packet: PackedByteArray = NetworkCrypto.encode_message(message)
	if packet.size() == 0:
		push_warning("WorldSurface: failed to encrypt surface update")
		return
	var err = _udp.put_packet(packet)
	if err != OK:
		push_warning("WorldSurface: failed to send surface update (err %s)" % err)
		return
	_request_chunks_for_changes(changes)
	_pending_changes.clear()

func discard_surface_changes() -> void:
	_pending_changes.clear()
	_reload_visible_chunks_from_server()

func _place_surface_at(world_pos: Vector2) -> void:
	var cell = _world_to_tile(world_pos)
	_queue_surface_change(cell, _selected_surface_id)

func _queue_surface_change(tile_pos: Vector2i, surface_id: int) -> void:
	_pending_changes[tile_pos] = surface_id
	_apply_surface_update(tile_pos, surface_id)

func _ensure_player() -> void:
	if _player != null:
		return
	if player_path == NodePath():
		return
	_player = get_node_or_null(player_path)
	if _player != null:
		_request_visible_chunks(true)

func _apply_surface_update(tile_pos: Vector2i, surface_id: int) -> void:
	_surface_cells[tile_pos] = surface_id
	if _show_visual:
		_update_visual(tile_pos, surface_id)

func _apply_pending_for_chunk(chunk: Vector2i) -> void:
	for pos in _pending_changes.keys():
		var server_pos = pos + map_origin_tile
		var cx = int(floor(server_pos.x / float(CHUNK_SIZE_TILES)))
		var cy = int(floor(server_pos.y / float(CHUNK_SIZE_TILES)))
		if cx == chunk.x and cy == chunk.y:
			var surface_id = _pending_changes[pos]
			_apply_surface_update(pos, surface_id)

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
	_chunk_surfaces.clear()
	_chunk_confirmed.clear()
	_last_player_chunk = Vector2i(2147483647, 2147483647)
	_clear_all_surfaces()
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

func _clear_all_surfaces() -> void:
	_surface_cells.clear()
	_clear_all_visuals()

func _update_visual(tile_pos: Vector2i, surface_id: int) -> void:
	_remove_visual(tile_pos)
	if surface_id == 0:
		return
	if not _surface_types.has(surface_id):
		return
	var surface_data = _surface_types[surface_id]
	var color: Color = surface_data.get("color", Color(0.5, 0.5, 0.5, 0.5))
	var name_str: String = surface_data.get("name", "")
	var display_name: String = surface_data.get("displayName", "")

	var container := Node2D.new()
	container.position = Vector2(tile_pos.x * TILE_SIZE, tile_pos.y * TILE_SIZE)

	var rect := ColorRect.new()
	rect.color = color
	rect.size = Vector2(TILE_SIZE, TILE_SIZE)
	container.add_child(rect)

	var letter := ""
	var letter_color := Color.WHITE

	if "deep" in name_str.to_lower() or "deep" in display_name.to_lower():
		letter = "D"
		letter_color = Color(0.2, 0.2, 1, 1)
	elif "shallow" in name_str.to_lower() or "shallow" in display_name.to_lower():
		letter = "S"
		letter_color = Color(0.5, 0.8, 1, 1)
	elif "water" in name_str.to_lower():
		letter = "W"
		letter_color = Color(0.3, 0.6, 1, 1)
	elif "ice" in name_str.to_lower() or "ice" in display_name.to_lower():
		letter = "I"
		letter_color = Color(0.7, 1, 1, 1)
	elif "mud" in name_str.to_lower() or "mud" in display_name.to_lower() or "болото" in display_name.to_lower():
		letter = "M"
		letter_color = Color(0.4, 0.2, 0.1, 1)
	elif surface_id != 0:
		letter = str(surface_id)
		letter_color = Color.WHITE

	if letter != "":
		var label := Label.new()
		label.text = letter
		label.add_theme_color_override("font_color", letter_color)
		label.add_theme_font_size_override("font_size", 20)
		label.position = Vector2(TILE_SIZE * 0.5 - 7, TILE_SIZE * 0.5 - 10)
		container.add_child(label)

	add_child(container)
	_visual_nodes[tile_pos] = container

func _remove_visual(tile_pos: Vector2i) -> void:
	if not _visual_nodes.has(tile_pos):
		return
	var node = _visual_nodes[tile_pos]
	if node != null:
		node.queue_free()
	_visual_nodes.erase(tile_pos)

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
	for pos in _surface_cells.keys():
		var surface_id = _surface_cells[pos]
		if surface_id != 0:
			_update_visual(pos, surface_id)
