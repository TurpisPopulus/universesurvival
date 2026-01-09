extends Node2D

@onready var label: Label = get_node_or_null("Label")
@onready var appearance: Node = get_node_or_null("Appearance")
var appearance_payload: String = ""
var _last_position := Vector2.ZERO

func set_display_name(name: String) -> void:
	if label != null:
		label.text = name

func set_appearance_payload(payload: String) -> void:
	appearance_payload = payload
	if appearance != null and appearance.has_method("set_appearance_payload"):
		appearance.set_appearance_payload(payload)

func _ready() -> void:
	_last_position = global_position
	if appearance != null and appearance_payload != "" and appearance.has_method("set_appearance_payload"):
		appearance.set_appearance_payload(appearance_payload)

func _process(delta: float) -> void:
	if appearance == null or not appearance.has_method("set_move_vector"):
		return
	var delta_pos := global_position - _last_position
	_last_position = global_position
	appearance.set_move_vector(delta_pos / max(delta, 0.001))
