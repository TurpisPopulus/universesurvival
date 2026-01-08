extends Control

const SERVER_ADDRESS := "127.0.0.1"
const SERVER_PORT := 7777
const REQUEST_TIMEOUT_SEC := 1.5

@onready var enter_button: Button = $Center/MenuVBox/EnterButton
@onready var create_button: Button = $Center/MenuVBox/CreateButton
@onready var settings_button: Button = $Center/MenuVBox/SettingsButton
@onready var exit_button: Button = $Center/MenuVBox/ExitButton
@onready var server_status: Label = $ServerStatus
@onready var status_timer: Timer = $StatusTimer

@onready var create_overlay: CenterContainer = $CreateOverlay
@onready var create_name: LineEdit = $CreateOverlay/CreatePanel/CreateVBox/NameInput
@onready var create_password: LineEdit = $CreateOverlay/CreatePanel/CreateVBox/PasswordInput
@onready var create_confirm: LineEdit = $CreateOverlay/CreatePanel/CreateVBox/ConfirmInput
@onready var create_status: Label = $CreateOverlay/CreatePanel/CreateVBox/StatusLabel
@onready var create_ok: Button = $CreateOverlay/CreatePanel/CreateVBox/Buttons/CreateConfirm
@onready var create_back: Button = $CreateOverlay/CreatePanel/CreateVBox/Buttons/CreateBack

@onready var login_overlay: CenterContainer = $LoginOverlay
@onready var login_name: LineEdit = $LoginOverlay/LoginPanel/LoginVBox/NameInput
@onready var login_password: LineEdit = $LoginOverlay/LoginPanel/LoginVBox/PasswordInput
@onready var login_status: Label = $LoginOverlay/LoginPanel/LoginVBox/StatusLabel
@onready var login_ok: Button = $LoginOverlay/LoginPanel/LoginVBox/Buttons/LoginConfirm
@onready var login_back: Button = $LoginOverlay/LoginPanel/LoginVBox/Buttons/LoginBack

var _status_check_in_flight := false

func _ready() -> void:
	enter_button.pressed.connect(_on_enter_pressed)
	create_button.pressed.connect(_on_create_pressed)
	settings_button.pressed.connect(_on_settings_pressed)
	exit_button.pressed.connect(_on_exit_pressed)
	create_ok.pressed.connect(_on_create_confirm_pressed)
	create_back.pressed.connect(_on_create_back_pressed)
	login_ok.pressed.connect(_on_login_confirm_pressed)
	login_back.pressed.connect(_on_login_back_pressed)

	settings_button.disabled = true
	enter_button.disabled = false
	create_overlay.visible = false
	login_overlay.visible = false
	server_status.text = "Server: checking..."
	status_timer.timeout.connect(_on_status_timer_timeout)
	_refresh_server_status()

func _on_enter_pressed() -> void:
	login_status.text = ""
	login_name.text = ""
	login_password.text = ""
	login_overlay.visible = true

func _on_create_pressed() -> void:
	create_status.text = ""
	create_name.text = ""
	create_password.text = ""
	create_confirm.text = ""
	create_overlay.visible = true

func _on_settings_pressed() -> void:
	pass

func _on_exit_pressed() -> void:
	get_tree().quit()

func _on_create_confirm_pressed() -> void:
	var name := create_name.text.strip_edges()
	var password := create_password.text
	var confirm := create_confirm.text

	if name.is_empty():
		create_status.text = "Name is required."
		return
	if password.is_empty():
		create_status.text = "Password is required."
		return
	if password != confirm:
		create_status.text = "Passwords do not match."
		return

	create_status.text = "Creating..."
	var result := await _request_register(name, password)
	match result:
		0:
			create_overlay.visible = false
		1:
			create_status.text = "Player already exists."
		2:
			create_status.text = "Invalid name or password."
		_:
			create_status.text = "Server not available."

func _on_create_back_pressed() -> void:
	create_overlay.visible = false

func _on_login_confirm_pressed() -> void:
	var name := login_name.text.strip_edges()
	var password := login_password.text

	if name.is_empty() or password.is_empty():
		login_status.text = "Name and password are required."
		return

	login_status.text = "Checking server..."
	var result := await _request_login(name, password)
	var status := int(result.get("status", -1))
	var position: Vector2 = Vector2.ZERO
	var access_level := int(result.get("access_level", 5))
	if result.has("position") and result["position"] is Vector2:
		position = result["position"]
	match status:
		0:
			login_overlay.visible = false
			_enter_game(name, position, access_level)
		1:
			login_status.text = "Player already online."
		2:
			login_status.text = "Wrong password."
		3:
			login_status.text = "Player not found."
		4:
			login_status.text = "Invalid login."
		_:
			login_status.text = "Server not available."

func _on_login_back_pressed() -> void:
	login_overlay.visible = false

func _on_status_timer_timeout() -> void:
	_refresh_server_status()

func _refresh_server_status() -> void:
	if _status_check_in_flight:
		return
	_status_check_in_flight = true
	var online := await _ping_server()
	if online:
		server_status.text = "Server: online"
	else:
		server_status.text = "Server: offline"
	_status_check_in_flight = false

func _ping_server() -> bool:
	var reply := await _send_request("PING")
	return reply == "PONG"

func _request_register(name: String, password: String) -> int:
	var reply := await _send_request("REGISTER|%s|%s" % [name, password])
	if reply == "OK":
		return 0
	if reply.begins_with("ERR|exists"):
		return 1
	if reply.begins_with("ERR|bad_register"):
		return 2
	return -1

func _request_login(name: String, password: String) -> Dictionary:
	var result := {
		"status": -1,
		"position": Vector2.ZERO,
		"access_level": 5
	}
	var reply := await _send_request("LOGIN|%s|%s" % [name, password])
	if reply == "OK":
		result["status"] = 0
		return result
	if reply.begins_with("OK|"):
		var parts := reply.split("|")
		if parts.size() >= 3:
			result["status"] = 0
			var x := parts[1].to_float()
			var y := parts[2].to_float()
			result["position"] = Vector2(x, y)
			if parts.size() >= 4:
				result["access_level"] = int(parts[3])
		return result
	if reply.begins_with("ERR|name_taken"):
		result["status"] = 1
		return result
	if reply.begins_with("ERR|wrong_password"):
		result["status"] = 2
		return result
	if reply.begins_with("ERR|not_found"):
		result["status"] = 3
		return result
	if reply.begins_with("ERR|bad_login"):
		result["status"] = 4
		return result
	return result

func _send_request(payload: String) -> String:
	var peer := PacketPeerUDP.new()
	var err := peer.connect_to_host(SERVER_ADDRESS, SERVER_PORT)
	if err != OK:
		return ""
	peer.put_packet(payload.to_utf8_buffer())
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < int(REQUEST_TIMEOUT_SEC * 1000.0):
		if peer.get_available_packet_count() > 0:
			return peer.get_packet().get_string_from_utf8()
		await get_tree().process_frame
	return ""

func _enter_game(name: String, position: Vector2, access_level: int) -> void:
	var packed := load("res://main.tscn") as PackedScene
	if packed == null:
		login_status.text = "Failed to load game scene."
		return
	var scene := packed.instantiate()
	scene.set("access_level", access_level)
	var player := scene.get_node_or_null("Player")
	if player != null:
		if player.has_method("set_player_name"):
			player.set_player_name(name)
		else:
			player.set("player_name", name)
		if player.has_method("set_spawn_position"):
			player.set_spawn_position(position)
		else:
			player.set("global_position", position)
	get_tree().root.add_child(scene)
	var previous := get_tree().current_scene
	get_tree().current_scene = scene
	if previous != null:
		previous.queue_free()
