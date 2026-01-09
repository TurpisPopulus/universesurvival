extends Control

const SERVER_ADDRESS := "127.0.0.1"
const SERVER_PORT := 7777
const REQUEST_TIMEOUT_SEC := 1.5
const APPEARANCE_TILE_W := 64
const APPEARANCE_TILE_H := 128
const APPEARANCE_FRAME_COUNT := 6
const APPEARANCE_FRAME_TIME := 0.18
const BODY_ATLAS_PATHS := [
	"res://characters/body_skinny.png",
	"res://characters/body_normal.png",
	"res://characters/body_fat.png"
]
const HEAD_ATLAS_PATH := "res://characters/heads.png"
const HAIR_MALE_ATLAS_PATH := "res://characters/hair_male.png"
const HAIR_FEMALE_ATLAS_PATH := "res://characters/hair_female.png"
const BEARD_ATLAS_PATH := "res://characters/beards.png"
const EYES_ATLAS_PATH := "res://characters/eyes.png"
const NOSES_ATLAS_PATH := "res://characters/noses.png"
const MOUTHS_ATLAS_PATH := "res://characters/mouths.png"

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
@onready var appearance_gender: OptionButton = $CreateOverlay/CreatePanel/CreateVBox/AppearanceRow/AppearanceControls/GenderRow/GenderOption
@onready var appearance_body: SpinBox = $CreateOverlay/CreatePanel/CreateVBox/AppearanceRow/AppearanceControls/BodyRow/BodySpin
@onready var appearance_head: SpinBox = $CreateOverlay/CreatePanel/CreateVBox/AppearanceRow/AppearanceControls/HeadRow/HeadSpin
@onready var appearance_hair: SpinBox = $CreateOverlay/CreatePanel/CreateVBox/AppearanceRow/AppearanceControls/HairRow/HairSpin
@onready var appearance_eyes: SpinBox = $CreateOverlay/CreatePanel/CreateVBox/AppearanceRow/AppearanceControls/EyesRow/EyesSpin
@onready var appearance_nose: SpinBox = $CreateOverlay/CreatePanel/CreateVBox/AppearanceRow/AppearanceControls/NoseRow/NoseSpin
@onready var appearance_mouth: SpinBox = $CreateOverlay/CreatePanel/CreateVBox/AppearanceRow/AppearanceControls/MouthRow/MouthSpin
@onready var appearance_beard: SpinBox = $CreateOverlay/CreatePanel/CreateVBox/AppearanceRow/AppearanceControls/BeardRow/BeardSpin
@onready var preview_body: TextureRect = $CreateOverlay/CreatePanel/CreateVBox/AppearanceRow/AppearancePreview/PreviewCenter/PreviewRoot/BodyLayer
@onready var preview_head: TextureRect = $CreateOverlay/CreatePanel/CreateVBox/AppearanceRow/AppearancePreview/PreviewCenter/PreviewRoot/HeadLayer
@onready var preview_eyes: TextureRect = $CreateOverlay/CreatePanel/CreateVBox/AppearanceRow/AppearancePreview/PreviewCenter/PreviewRoot/EyesLayer
@onready var preview_nose: TextureRect = $CreateOverlay/CreatePanel/CreateVBox/AppearanceRow/AppearancePreview/PreviewCenter/PreviewRoot/NoseLayer
@onready var preview_mouth: TextureRect = $CreateOverlay/CreatePanel/CreateVBox/AppearanceRow/AppearancePreview/PreviewCenter/PreviewRoot/MouthLayer
@onready var preview_beard: TextureRect = $CreateOverlay/CreatePanel/CreateVBox/AppearanceRow/AppearancePreview/PreviewCenter/PreviewRoot/BeardLayer
@onready var preview_hair: TextureRect = $CreateOverlay/CreatePanel/CreateVBox/AppearanceRow/AppearancePreview/PreviewCenter/PreviewRoot/HairLayer

@onready var login_overlay: CenterContainer = $LoginOverlay
@onready var login_name: LineEdit = $LoginOverlay/LoginPanel/LoginVBox/NameInput
@onready var login_password: LineEdit = $LoginOverlay/LoginPanel/LoginVBox/PasswordInput
@onready var login_status: Label = $LoginOverlay/LoginPanel/LoginVBox/StatusLabel
@onready var login_ok: Button = $LoginOverlay/LoginPanel/LoginVBox/Buttons/LoginConfirm
@onready var login_back: Button = $LoginOverlay/LoginPanel/LoginVBox/Buttons/LoginBack

var _status_check_in_flight := false
var _appearance_textures := {}
var _appearance_frame := 0
var _appearance_anim_time := 0.0
var _appearance_payload := ""

func _ready() -> void:
	enter_button.pressed.connect(_on_enter_pressed)
	create_button.pressed.connect(_on_create_pressed)
	settings_button.pressed.connect(_on_settings_pressed)
	exit_button.pressed.connect(_on_exit_pressed)
	create_ok.pressed.connect(_on_create_confirm_pressed)
	create_back.pressed.connect(_on_create_back_pressed)
	login_ok.pressed.connect(_on_login_confirm_pressed)
	login_back.pressed.connect(_on_login_back_pressed)

	_setup_appearance_ui()

	settings_button.disabled = true
	enter_button.disabled = false
	create_overlay.visible = false
	login_overlay.visible = false
	server_status.text = "Server: checking..."
	status_timer.timeout.connect(_on_status_timer_timeout)
	_refresh_server_status()

func _process(delta: float) -> void:
	if not create_overlay.visible:
		return
	_appearance_anim_time += delta
	if _appearance_anim_time >= APPEARANCE_FRAME_TIME:
		_appearance_anim_time = 0.0
		_appearance_frame = (_appearance_frame + 1) % APPEARANCE_FRAME_COUNT
		_update_appearance_preview()

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
	_appearance_frame = 0
	_appearance_anim_time = 0.0
	appearance_gender.selected = 0
	appearance_body.value = 1
	appearance_head.value = 1
	appearance_hair.value = 1
	appearance_eyes.value = 1
	appearance_nose.value = 1
	appearance_mouth.value = 1
	appearance_beard.value = 1
	_update_appearance_preview()
	create_overlay.visible = true

func _on_settings_pressed() -> void:
	pass

func _on_exit_pressed() -> void:
	get_tree().quit()

func _on_create_confirm_pressed() -> void:
	var name := create_name.text.strip_edges()
	var password := create_password.text
	var confirm := create_confirm.text
	_appearance_payload = _build_appearance_payload()

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
	var result := await _request_register(name, password, _appearance_payload)
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
	_appearance_payload = str(result.get("appearance", ""))
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

func _setup_appearance_ui() -> void:
	appearance_gender.clear()
	appearance_gender.add_item("Male", 0)
	appearance_gender.add_item("Female", 1)
	appearance_gender.selected = 0

	appearance_gender.item_selected.connect(_on_appearance_changed)
	appearance_body.value_changed.connect(_on_appearance_changed)
	appearance_head.value_changed.connect(_on_appearance_changed)
	appearance_hair.value_changed.connect(_on_appearance_changed)
	appearance_eyes.value_changed.connect(_on_appearance_changed)
	appearance_nose.value_changed.connect(_on_appearance_changed)
	appearance_mouth.value_changed.connect(_on_appearance_changed)
	appearance_beard.value_changed.connect(_on_appearance_changed)

	_preview_layers_setup()
	_load_appearance_textures()
	_update_appearance_preview()

func _preview_layers_setup() -> void:
	var layers := [preview_body, preview_head, preview_eyes, preview_nose, preview_mouth, preview_beard, preview_hair]
	for layer in layers:
		layer.expand_mode = TextureRect.EXPAND_KEEP_SIZE
		layer.stretch_mode = TextureRect.STRETCH_KEEP

func _load_appearance_textures() -> void:
	var body_textures: Array[Texture2D] = []
	for path in BODY_ATLAS_PATHS:
		var tex := load(path) as Texture2D
		if tex != null:
			body_textures.append(tex)
	_appearance_textures["body"] = body_textures
	_appearance_textures["head"] = load(HEAD_ATLAS_PATH) as Texture2D
	_appearance_textures["hair_male"] = load(HAIR_MALE_ATLAS_PATH) as Texture2D
	_appearance_textures["hair_female"] = load(HAIR_FEMALE_ATLAS_PATH) as Texture2D
	_appearance_textures["beard"] = load(BEARD_ATLAS_PATH) as Texture2D
	_appearance_textures["eyes"] = load(EYES_ATLAS_PATH) as Texture2D
	_appearance_textures["nose"] = load(NOSES_ATLAS_PATH) as Texture2D
	_appearance_textures["mouth"] = load(MOUTHS_ATLAS_PATH) as Texture2D

func _on_appearance_changed(_value := 0) -> void:
	_update_appearance_preview()

func _update_appearance_preview() -> void:
	var body_index := int(appearance_body.value) - 1
	var head_index := int(appearance_head.value) - 1
	var hair_index := int(appearance_hair.value) - 1
	var eyes_index := int(appearance_eyes.value) - 1
	var nose_index := int(appearance_nose.value) - 1
	var mouth_index := int(appearance_mouth.value) - 1
	var beard_index := int(appearance_beard.value) - 1

	var body_textures: Array = _appearance_textures.get("body", [])
	if body_index >= 0 and body_index < body_textures.size():
		preview_body.texture = _atlas_frame(body_textures[body_index], 0, _appearance_frame)

	var head_tex: Texture2D = _appearance_textures.get("head")
	preview_head.texture = _atlas_frame(head_tex, head_index, _appearance_frame)

	var hair_tex: Texture2D = _appearance_textures.get("hair_male")
	if appearance_gender.selected == 1:
		hair_tex = _appearance_textures.get("hair_female")
	preview_hair.texture = _atlas_frame(hair_tex, hair_index, _appearance_frame)

	var beard_tex: Texture2D = _appearance_textures.get("beard")
	preview_beard.texture = _atlas_frame(beard_tex, beard_index, _appearance_frame)

	var eyes_tex: Texture2D = _appearance_textures.get("eyes")
	preview_eyes.texture = _atlas_frame(eyes_tex, eyes_index, _appearance_frame)

	var nose_tex: Texture2D = _appearance_textures.get("nose")
	preview_nose.texture = _atlas_frame(nose_tex, nose_index, _appearance_frame)

	var mouth_tex: Texture2D = _appearance_textures.get("mouth")
	preview_mouth.texture = _atlas_frame(mouth_tex, mouth_index, _appearance_frame)

func _atlas_frame(texture: Texture2D, row_index: int, frame_index: int) -> Texture2D:
	if texture == null:
		return null
	if row_index < 0:
		row_index = 0
	if frame_index < 0:
		frame_index = 0
	frame_index %= APPEARANCE_FRAME_COUNT
	var atlas := AtlasTexture.new()
	atlas.atlas = texture
	atlas.region = Rect2(frame_index * APPEARANCE_TILE_W, row_index * APPEARANCE_TILE_H, APPEARANCE_TILE_W, APPEARANCE_TILE_H)
	return atlas

func _build_appearance_payload() -> String:
	var appearance := {
		"gender": appearance_gender.selected,
		"body": int(appearance_body.value),
		"head": int(appearance_head.value),
		"hair": int(appearance_hair.value),
		"eyes": int(appearance_eyes.value),
		"nose": int(appearance_nose.value),
		"mouth": int(appearance_mouth.value),
		"beard": int(appearance_beard.value)
	}
	var json := JSON.stringify(appearance)
	return Marshalls.utf8_to_base64(json)

func _ping_server() -> bool:
	var reply := await _send_request("PING")
	return reply == "PONG"

func _request_register(name: String, password: String, appearance_payload: String = "") -> int:
	var message := "REGISTER|%s|%s" % [name, password]
	if appearance_payload != "":
		message += "|" + appearance_payload
	var reply := await _send_request(message)
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
		"access_level": 5,
		"appearance": ""
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
			if parts.size() >= 5:
				result["appearance"] = parts[4]
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
		if player.has_method("set_appearance_payload"):
			player.set_appearance_payload(_appearance_payload)
		else:
			player.set("appearance_payload", _appearance_payload)
		if player.has_method("set_spawn_position"):
			player.set_spawn_position(position)
		else:
			player.set("global_position", position)
	get_tree().root.add_child(scene)
	var previous := get_tree().current_scene
	get_tree().current_scene = scene
	if previous != null:
		previous.queue_free()
