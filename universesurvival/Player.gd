extends CharacterBody2D

@export var speed: float = 220.0
@export var server_address: String = "127.0.0.1"
@export var server_port: int = 7777
@export var player_id: String = "player-1"
@export var player_name: String = "Ari"
@export var send_rate_hz: float = 10.0
@export var remote_scene: PackedScene = preload("res://remote_player.tscn")
@onready var sprite: Sprite2D = get_node_or_null("Sprite2D")

var _udp := PacketPeerUDP.new()
var _send_accum := 0.0
var _last_reply: String = ""
var _remotes: Dictionary[String, Node2D] = {}
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_rng.randomize()
	player_id = "p-" + str(_rng.randi_range(100000, 999999))
	var err := _udp.connect_to_host(server_address, server_port)
	if err != OK:
		push_warning("UDP connect failed: %s:%s (err %s)" % [server_address, server_port, err])

func _physics_process(delta: float) -> void:
	var input := Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_down") - Input.get_action_strength("move_up")
	)

	if input.length() > 1.0:
		input = input.normalized()

	velocity = input * speed
	move_and_slide()

	# Flip sprite based on horizontal movement.
	if sprite != null and input.x != 0.0:
		sprite.flip_h = input.x < 0.0

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
	var err := _udp.put_packet(payload.to_utf8_buffer())
	if err != OK:
		push_warning("UDP send failed (err %s)" % err)

func _poll_server() -> void:
	var seen: Dictionary = {}
	while _udp.get_available_packet_count() > 0:
		var data := _udp.get_packet()
		if _udp.get_packet_error() != OK:
			push_warning("UDP receive failed (err %s)" % _udp.get_packet_error())
			return
		_last_reply = data.get_string_from_utf8()
		for line in _last_reply.split("\n", false):
			var parts := line.split("|")
			if parts.size() != 4:
				continue
			var id := parts[0].strip_edges()
			if id == "" or id == player_id:
				continue
			seen[id] = true
			var node: Node2D = _remotes.get(id) as Node2D
			if node == null:
				if remote_scene == null:
					continue
				node = remote_scene.instantiate() as Node2D
				node.name = "Remote_" + id
				get_parent().add_child(node)
				_remotes[id] = node
			var x := parts[2].to_float()
			var y := parts[3].to_float()
			node.global_position = Vector2(x, y)
			if node.has_method("set_display_name"):
				node.set_display_name(parts[1])

	var to_remove: Array = []
	for id in _remotes.keys():
		if not seen.has(id):
			to_remove.append(id)
			var node: Node2D = _remotes.get(id) as Node2D
			if node != null:
				node.queue_free()
	for id in to_remove:
		_remotes.erase(id)

func _fmt(value: float) -> String:
	return String.num(value, 3)

func set_player_name(name: String) -> void:
	if name.strip_edges() != "":
		player_name = name.strip_edges()

func set_spawn_position(position: Vector2) -> void:
	global_position = position
