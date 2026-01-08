extends Node2D

@onready var label: Label = get_node_or_null("Label")

func set_display_name(name: String) -> void:
	if label != null:
		label.text = name
