extends CharacterBody2D

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
@onready var appearance: Node = get_node_or_null("Appearance")

var _udp := PacketPeerUDP.new()
var _send_accum := 0.0
var _last_reply: String = ""
var _remotes: Dictionary[String, Node2D] = {}
var _remote_last_seen: Dictionary[String, int] = {}
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_rng.randomize()
	player_id = "p-" + str(_rng.randi_range(100000, 999999))
	var err := _udp.connect_to_host(server_address, server_port)
	if err != OK:
		push_warning("UDP connect failed: %s:%s (err %s)" % [server_address, server_port, err])
	if appearance != null and appearance_payload != "" and appearance.has_method("set_appearance_payload"):
		appearance.set_appearance_payload(appearance_payload)

func _physics_process(delta: float) -> void:
	var input := Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_down") - Input.get_action_strength("move_up")
	)

	if input.length() > 1.0:
		input = input.normalized()

	var target_velocity := input * speed
	if input == Vector2.ZERO:
		velocity = velocity.move_toward(Vector2.ZERO, deceleration * delta)
	else:
		velocity = velocity.move_toward(target_velocity, acceleration * delta)
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
	var err := _udp.put_packet(payload.to_utf8_buffer())
	if err != OK:
		push_warning("UDP send failed (err %s)" % err)

func _poll_server() -> void:
	var now_ms := Time.get_ticks_msec()
	while _udp.get_available_packet_count() > 0:
		var data := _udp.get_packet()
		if _udp.get_packet_error() != OK:
			push_warning("UDP receive failed (err %s)" % _udp.get_packet_error())
			return
		_last_reply = data.get_string_from_utf8()
		for line in _last_reply.split("\n", false):
			var parts := line.split("|")
			if parts.size() < 4:
				continue
			var id := parts[0].strip_edges()
			if id == "" or id == player_id:
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

func set_player_name(name: String) -> void:
	if name.strip_edges() != "":
		player_name = name.strip_edges()

func set_spawn_position(position: Vector2) -> void:
	global_position = position

func set_appearance_payload(payload: String) -> void:
	appearance_payload = payload
	if appearance != null and appearance.has_method("set_appearance_payload"):
		appearance.set_appearance_payload(payload)
