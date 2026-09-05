@tool
extends PartBody

@export var axle_length: float = 0.065:
	set(value):
		axle_length = value
		_update_editor()
@export var ratio_in:int = 18
@export var ratio_out:int = 1

@export var port: int = 0

func _ready() -> void:
	_update_editor()

func _update_editor() -> void:
	density = 1145
	if Engine.is_editor_hint() and is_node_ready():
		$motor_mesh.scale = Vector3.ONE
		$spin_lock.position = Vector3(0.013, 0, 0.022)
		$spin.global_transform = $spin_lock.global_transform
		$spin.global_position += -$spin_lock.global_basis.z * 0.01
		$spin.axle_length = axle_length

func update(size_scale):
	$motor_mesh.scale = Vector3.ONE * size_scale
	$CollisionShape3D.shape.size = Vector3(0.0573, 0.033, 0.061248004) * size_scale
	$spin_lock.position = Vector3(0.013, 0, 0.022) * size_scale
	
	mass = 0.155
	$spin.global_transform = $spin_lock.global_transform
	$spin.global_position += -$spin_lock.global_basis.z * 0.01
	$spin.axle_length = axle_length
	$spin.update(size_scale)
