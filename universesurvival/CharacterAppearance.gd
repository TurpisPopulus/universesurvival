extends Node2D

const APPEARANCE_TILE_W := 64
const APPEARANCE_TILE_H := 128
const APPEARANCE_FRAME_COUNT := 6
const APPEARANCE_FRAME_TIME := 0.18

const BODY_ATLASES := [
	preload("res://characters/body_skinny.png"),
	preload("res://characters/body_normal.png"),
	preload("res://characters/body_fat.png")
]
const HEAD_ATLAS := preload("res://characters/heads.png")
const HAIR_MALE_ATLAS := preload("res://characters/hair_male.png")
const HAIR_FEMALE_ATLAS := preload("res://characters/hair_female.png")
const BEARD_ATLAS := preload("res://characters/beards.png")
const EYES_ATLAS := preload("res://characters/eyes.png")
const NOSES_ATLAS := preload("res://characters/noses.png")
const MOUTHS_ATLAS := preload("res://characters/mouths.png")

@onready var body_layer: Sprite2D = $Body
@onready var head_layer: Sprite2D = $Head
@onready var eyes_layer: Sprite2D = $Eyes
@onready var nose_layer: Sprite2D = $Nose
@onready var mouth_layer: Sprite2D = $Mouth
@onready var beard_layer: Sprite2D = $Beard
@onready var hair_layer: Sprite2D = $Hair

var _appearance := {
	"gender": 0,
	"body": 1,
	"head": 1,
	"hair": 1,
	"eyes": 1,
	"nose": 1,
	"mouth": 1,
	"beard": 1
}
var _textures := {}
var _frame := 0
var _anim_time := 0.0
var _moving := false
var _facing_left := false
var _pending_payload := ""

func _ready() -> void:
	_load_textures()
	_update_layers()
	if _pending_payload != "":
		_apply_payload(_pending_payload)
		_pending_payload = ""

func _process(delta: float) -> void:
	if not _moving:
		return
	_anim_time += delta
	if _anim_time >= APPEARANCE_FRAME_TIME:
		_anim_time = 0.0
		_frame = (_frame + 1) % APPEARANCE_FRAME_COUNT
		_update_layers()

func set_move_vector(vector: Vector2) -> void:
	var moving := vector.length() > 0.5
	if moving != _moving:
		_moving = moving
		if not _moving:
			_frame = 0
			_anim_time = 0.0
			_update_layers()
	if vector.x != 0.0:
		_facing_left = vector.x < 0.0
	_apply_flip()

func set_appearance_payload(payload: String) -> void:
	if payload == "":
		return
	if not is_inside_tree():
		_pending_payload = payload
		return
	_apply_payload(payload)

func _apply_payload(payload: String) -> void:
	var json := Marshalls.base64_to_utf8(payload)
	var data = JSON.parse_string(json)
	if typeof(data) != TYPE_DICTIONARY:
		return
	_appearance["gender"] = int(data.get("gender", _appearance["gender"]))
	_appearance["body"] = int(data.get("body", _appearance["body"]))
	_appearance["head"] = int(data.get("head", _appearance["head"]))
	_appearance["hair"] = int(data.get("hair", _appearance["hair"]))
	_appearance["eyes"] = int(data.get("eyes", _appearance["eyes"]))
	_appearance["nose"] = int(data.get("nose", _appearance["nose"]))
	_appearance["mouth"] = int(data.get("mouth", _appearance["mouth"]))
	_appearance["beard"] = int(data.get("beard", _appearance["beard"]))
	_update_layers()

func _load_textures() -> void:
	_textures["body"] = BODY_ATLASES
	_textures["head"] = HEAD_ATLAS
	_textures["hair_male"] = HAIR_MALE_ATLAS
	_textures["hair_female"] = HAIR_FEMALE_ATLAS
	_textures["beard"] = BEARD_ATLAS
	_textures["eyes"] = EYES_ATLAS
	_textures["nose"] = NOSES_ATLAS
	_textures["mouth"] = MOUTHS_ATLAS

func _update_layers() -> void:
	var body_index := int(_appearance["body"]) - 1
	var head_index := int(_appearance["head"]) - 1
	var hair_index := int(_appearance["hair"]) - 1
	var eyes_index := int(_appearance["eyes"]) - 1
	var nose_index := int(_appearance["nose"]) - 1
	var mouth_index := int(_appearance["mouth"]) - 1
	var beard_index := int(_appearance["beard"]) - 1
	var gender := int(_appearance["gender"])

	var body_textures: Array = _textures.get("body", [])
	if body_index >= 0 and body_index < body_textures.size():
		body_layer.texture = _atlas_frame(body_textures[body_index], 0)

	head_layer.texture = _atlas_frame(_textures.get("head"), head_index)

	var hair_tex: Texture2D = _textures.get("hair_male")
	if gender == 1:
		hair_tex = _textures.get("hair_female")
	hair_layer.texture = _atlas_frame(hair_tex, hair_index)

	beard_layer.texture = _atlas_frame(_textures.get("beard"), beard_index)
	eyes_layer.texture = _atlas_frame(_textures.get("eyes"), eyes_index)
	nose_layer.texture = _atlas_frame(_textures.get("nose"), nose_index)
	mouth_layer.texture = _atlas_frame(_textures.get("mouth"), mouth_index)
	_apply_flip()

func _atlas_frame(texture: Texture2D, row_index: int) -> Texture2D:
	if texture == null:
		return null
	if row_index < 0:
		row_index = 0
	var atlas := AtlasTexture.new()
	atlas.atlas = texture
	atlas.region = Rect2(_frame * APPEARANCE_TILE_W, row_index * APPEARANCE_TILE_H, APPEARANCE_TILE_W, APPEARANCE_TILE_H)
	return atlas

func _apply_flip() -> void:
	var layers := [body_layer, head_layer, eyes_layer, nose_layer, mouth_layer, beard_layer, hair_layer]
	for layer in layers:
		if layer != null:
			layer.flip_h = _facing_left
