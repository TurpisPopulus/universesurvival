extends Node2D

@onready var label: Label = get_node_or_null("Label")
@onready var appearance: Node = get_node_or_null("Appearance")
@export var interpolation_delay_ms: int = 160
@export var snap_distance: float = 120.0
var appearance_payload: String = ""
var _last_position := Vector2.ZERO
var _prev_position := Vector2.ZERO
var _next_position := Vector2.ZERO
var _prev_time_ms: int = 0
var _next_time_ms: int = 0
var _has_samples := false

func set_display_name(name: String) -> void:
	if label != null:
		label.text = name

func set_appearance_payload(payload: String) -> void:
	appearance_payload = payload
	if appearance != null and appearance.has_method("set_appearance_payload"):
		appearance.set_appearance_payload(payload)

func _ready() -> void:
	_last_position = global_position
	_prev_position = global_position
	_next_position = global_position
	_prev_time_ms = Time.get_ticks_msec()
	_next_time_ms = _prev_time_ms
	_has_samples = true
	if appearance != null and appearance_payload != "" and appearance.has_method("set_appearance_payload"):
		appearance.set_appearance_payload(appearance_payload)

func _process(delta: float) -> void:
	if _has_samples:
		var render_time := Time.get_ticks_msec() - interpolation_delay_ms
		if _next_time_ms == _prev_time_ms:
			global_position = _next_position
		elif render_time <= _prev_time_ms:
			global_position = _prev_position
		elif render_time >= _next_time_ms:
			global_position = _next_position
		else:
			var t := float(render_time - _prev_time_ms) / float(_next_time_ms - _prev_time_ms)
			global_position = _prev_position.lerp(_next_position, t)
	if appearance == null or not appearance.has_method("set_move_vector"):
		_last_position = global_position
		return
	var delta_pos := global_position - _last_position
	_last_position = global_position
	appearance.set_move_vector(delta_pos / max(delta, 0.001))

func set_remote_sample(position: Vector2, timestamp_ms: int) -> void:
	if not _has_samples:
		global_position = position
		_last_position = position
		_prev_position = position
		_next_position = position
		_prev_time_ms = timestamp_ms
		_next_time_ms = timestamp_ms
		_has_samples = true
		return

	if snap_distance > 0.0 and global_position.distance_to(position) > snap_distance:
		global_position = position
		_last_position = position
		_prev_position = position
		_next_position = position
		_prev_time_ms = timestamp_ms
		_next_time_ms = timestamp_ms
		return

	if timestamp_ms <= _next_time_ms:
		return
	_prev_position = _next_position
	_prev_time_ms = _next_time_ms
	_next_position = position
	_next_time_ms = timestamp_ms
