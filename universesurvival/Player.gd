extends CharacterBody2D

const NetworkCrypto = preload("res://NetworkCrypto.gd")

@export var speed: float = 220.0
@export var acceleration: float = 2000.0
@export var deceleration: float = 2000.0
@export var server_address: String = "127.0.0.1"
@export var server_port: int = 7777
@export var player_id: String = "player-1"
@export var player_name: String = "Ari"
@export var send_rate_hz: float = 30.0
@export var remote_timeout_sec: float = 3.0
@export var remote_scene: PackedScene = preload("res://remote_player.tscn")
@export var appearance_payload: String = ""
@export var resources_path: NodePath = NodePath("../WorldResources")
@export var blocking_path: NodePath = NodePath("../WorldBlocking")
@export var surface_path: NodePath = NodePath("../WorldSurface")
@export var feet_block_tile_size: float = 32.0
@onready var appearance: Node = get_node_or_null("Appearance")
@onready var _collision_shape: CollisionShape2D = get_node_or_null("CollisionShape2D")

signal first_state_sent
signal server_confirmed

var _udp := PacketPeerUDP.new()
var _send_accum := 0.0
var _last_reply: String = ""
var _remotes: Dictionary[String, Node2D] = {}
var _remote_last_seen: Dictionary[String, int] = {}
var _rng := RandomNumberGenerator.new()
var _loading_blocked := true
var _initial_state_sent := false
var _server_confirmed := false
var _resources
var _blocking
var _surface
var _feet_offset := Vector2.ZERO
var _current_speed_mod := 1.0
var _current_damage := 0.0

func _ready() -> void:
	_rng.randomize()
	player_id = "p-" + str(_rng.randi_range(100000, 999999))
	var err := _udp.connect_to_host(server_address, server_port)
	if err != OK:
		push_warning("UDP connect failed: %s:%s (err %s)" % [server_address, server_port, err])
	_resources = get_node_or_null(resources_path)
	_blocking = get_node_or_null(blocking_path)
	_surface = get_node_or_null(surface_path)
	_feet_offset = _compute_feet_offset()
	if appearance != null and appearance_payload != "" and appearance.has_method("set_appearance_payload"):
		appearance.set_appearance_payload(appearance_payload)

func _physics_process(delta: float) -> void:
	if _loading_blocked:
		return
	var input := Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_down") - Input.get_action_strength("move_up")
	)

	if input.length() > 1.0:
		input = input.normalized()

	_update_surface_effects(delta)
	var effective_speed = speed * _current_speed_mod
	var target_velocity: Vector2 = input * effective_speed
	if input == Vector2.ZERO:
		velocity = velocity.move_toward(Vector2.ZERO, deceleration * delta)
	else:
		velocity = velocity.move_toward(target_velocity, acceleration * delta)
	_apply_resource_blocking(delta)
	_apply_blocking_check(delta)
	move_and_slide()

	if appearance != null and appearance.has_method("set_move_vector"):
		appearance.set_move_vector(velocity)

	_send_accum += delta
	if send_rate_hz > 0.0 and _send_accum >= 1.0 / send_rate_hz:
		_send_accum = 0.0
		_send_state()

	_poll_server()

func _send_state() -> void:
	var payload := "%s|%s|%s|%s" % [
		player_id,
		player_name,
		_fmt(global_position.x),
		_fmt(global_position.y)
	]
	if appearance_payload != "":
		payload += "|" + appearance_payload
	var packet: PackedByteArray = NetworkCrypto.encode_message(payload)
	if packet.size() == 0:
		push_warning("UDP send failed: encryption error")
		return
	var err := _udp.put_packet(packet)
	if err != OK:
		push_warning("UDP send failed (err %s)" % err)
		return
	if not _initial_state_sent:
		_initial_state_sent = true
		emit_signal("first_state_sent")

func _poll_server() -> void:
	var now_ms := Time.get_ticks_msec()
	while _udp.get_available_packet_count() > 0:
		var data := _udp.get_packet()
		if _udp.get_packet_error() != OK:
			push_warning("UDP receive failed (err %s)" % _udp.get_packet_error())
			return
		var decoded := NetworkCrypto.decode_message(data)
		if decoded == "":
			push_warning("UDP packet rejected (invalid or insecure)")
			continue
		_last_reply = decoded
		for line in _last_reply.split("\n", false):
			var parts := line.split("|")
			if parts.size() < 4:
				continue
			var id := parts[0].strip_edges()
			if id == "":
				continue
			if id == player_id:
				if not _server_confirmed:
					_server_confirmed = true
					emit_signal("server_confirmed")
				continue
			_remote_last_seen[id] = now_ms
			var node: Node2D = _remotes.get(id) as Node2D
			if node == null:
				if remote_scene == null:
					continue
				node = remote_scene.instantiate() as Node2D
				node.name = "Remote_" + id
				get_parent().add_child(node)
				_remotes[id] = node
				_remote_last_seen[id] = now_ms
			var x := parts[2].to_float()
			var y := parts[3].to_float()
			var target := Vector2(x, y)
			if node.has_method("set_remote_sample"):
				node.set_remote_sample(target, now_ms)
			elif node.has_method("set_target_position"):
				node.set_target_position(target)
			else:
				node.global_position = target
			if parts.size() >= 5 and node.has_method("set_appearance_payload"):
				node.set_appearance_payload(parts[4])
			if node.has_method("set_display_name"):
				node.set_display_name(parts[1])

	var timeout_ms := int(remote_timeout_sec * 1000.0)
	var to_remove: Array = []
	for id in _remotes.keys():
		var last_seen: int = int(_remote_last_seen.get(id, 0))
		if timeout_ms > 0 and now_ms - last_seen > timeout_ms:
			to_remove.append(id)
			var node: Node2D = _remotes.get(id) as Node2D
			if node != null:
				node.queue_free()
	for id in to_remove:
		_remotes.erase(id)
		_remote_last_seen.erase(id)

func _fmt(value: float) -> String:
	return String.num(value, 3)

func _apply_resource_blocking(delta: float) -> void:
	if _resources == null or not _resources.has_method("is_world_blocked"):
		return
	if velocity == Vector2.ZERO:
		return
	var next_pos = global_position + velocity * delta
	if not _is_blocked_at(next_pos):
		return
	var allow_x = not _is_blocked_at(Vector2(next_pos.x, global_position.y))
	var allow_y = not _is_blocked_at(Vector2(global_position.x, next_pos.y))
	if allow_x and not allow_y:
		velocity.y = 0.0
	elif allow_y and not allow_x:
		velocity.x = 0.0
	else:
		velocity = Vector2.ZERO

func _get_feet_at(body_pos: Vector2) -> Vector2:
	return body_pos + _feet_offset

func _is_blocked_at(body_pos: Vector2) -> bool:
	var feet = _get_feet_at(body_pos)
	var half = max(1.0, feet_block_tile_size * 0.5)
	var sample_y = feet.y - half
	var sample_points = [
		Vector2(feet.x - half + 1.0, sample_y),
		Vector2(feet.x, sample_y),
		Vector2(feet.x + half - 1.0, sample_y)
	]
	for point in sample_points:
		if _resources != null and _resources.has_method("is_world_blocked") and _resources.is_world_blocked(point):
			return true
		if _blocking != null and _blocking.has_method("is_world_blocked") and _blocking.is_world_blocked(point):
			return true
		if _surface != null and _surface.has_method("is_world_blocked") and _surface.is_world_blocked(point):
			return true
	return false

func _apply_blocking_check(delta: float) -> void:
	if _blocking == null or not _blocking.has_method("is_world_blocked"):
		return
	if velocity == Vector2.ZERO:
		return
	var next_pos = global_position + velocity * delta
	var feet = _get_feet_at(next_pos)
	if not _blocking.is_world_blocked(feet):
		return
	var allow_x = not _blocking.is_world_blocked(_get_feet_at(Vector2(next_pos.x, global_position.y)))
	var allow_y = not _blocking.is_world_blocked(_get_feet_at(Vector2(global_position.x, next_pos.y)))
	if allow_x and not allow_y:
		velocity.y = 0.0
	elif allow_y and not allow_x:
		velocity.x = 0.0
	else:
		velocity = Vector2.ZERO

func _update_surface_effects(delta: float) -> void:
	_current_speed_mod = 1.0
	_current_damage = 0.0
	if _surface == null or not _surface.has_method("get_surface_at"):
		return
	var feet = _get_feet_at(global_position)
	var surface_data = _surface.get_surface_at(feet)
	if surface_data == null or typeof(surface_data) != TYPE_DICTIONARY:
		return
	_current_speed_mod = float(surface_data.get("speedMod", 1.0))
	_current_damage = float(surface_data.get("damage", 0.0))
	if _current_damage > 0.0:
		pass

func _compute_feet_offset() -> Vector2:
	if appearance != null:
		var body_sprite: Sprite2D = appearance.get_node_or_null("Body")
		if body_sprite != null and body_sprite.texture != null:
			var size = body_sprite.texture.get_size()
			return body_sprite.position + Vector2(0.0, size.y * 0.5 * body_sprite.scale.y)
	if _collision_shape == null:
		return Vector2.ZERO
	var shape = _collision_shape.shape
	if shape is CapsuleShape2D:
		var capsule := shape as CapsuleShape2D
		return _collision_shape.position + Vector2(0.0, capsule.height * 0.5 + capsule.radius)
	if shape is RectangleShape2D:
		var rect := shape as RectangleShape2D
		return _collision_shape.position + Vector2(0.0, rect.size.y * 0.5)
	if shape is CircleShape2D:
		var circle := shape as CircleShape2D
		return _collision_shape.position + Vector2(0.0, circle.radius)
	return _collision_shape.position

func set_player_name(name: String) -> void:
	if name.strip_edges() != "":
		player_name = name.strip_edges()

func set_spawn_position(position: Vector2) -> void:
	global_position = position

func set_appearance_payload(payload: String) -> void:
	appearance_payload = payload
	if appearance != null and appearance.has_method("set_appearance_payload"):
		appearance.set_appearance_payload(payload)

func set_loading_blocked(blocked: bool) -> void:
	if _loading_blocked == blocked:
		return
	_loading_blocked = blocked
	if blocked:
		velocity = Vector2.ZERO
		if appearance != null and appearance.has_method("set_move_vector"):
			appearance.set_move_vector(Vector2.ZERO)
	else:
		_send_accum = 0.0
		_send_state()
