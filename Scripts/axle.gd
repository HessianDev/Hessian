@tool
extends PartBody

@export var axle_length: float = 0.01:
	set(value):
		axle_length = value
		_update_editor()

func _ready() -> void:
	density = 7850
	_update_editor()

func _update_editor() -> void:
	if Engine.is_editor_hint() and is_node_ready():
		$axle.size.z = axle_length
		$axle.size.x = 0.003
		$axle.size.y = 0.003
		$axle.position.z = -axle_length / 2

func update(size_scale):
	mass = 0.07065 * axle_length
	$axle.size.z = axle_length * size_scale
	$axle.size.x = 0.003 * size_scale
	$axle.size.y = 0.003 * size_scale
	$axle.position.z = (-axle_length / 2) * size_scale
	$RayCast3D.target_position.y = axle_length * size_scale
	$axle_collision.shape.size.y = axle_length * size_scale
	$axle_collision.shape.size.x = 0.003 * size_scale
	$axle_collision.shape.size.z = 0.003 * size_scale
	$axle_collision.position.z = (-axle_length / 2) * size_scale
