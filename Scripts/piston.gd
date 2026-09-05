@tool
extends PartBody

@export var length = 0.02:
	set(value):
		length = value
		_update_editor()

@export var extend = 0.0:
	set(value):
		extend = value
		_update_editor()

@export var port: int = 0

func _ready() -> void:
	_update_editor()

func _update_editor() -> void:
	density = 2150
	if Engine.is_editor_hint() and is_node_ready():
		var f_ext = clampf(extend, 0, 1) * (length / 2)
		$CSGCylinder3D.height = (length / 2)
		$CSGCylinder3D.position.y = (length / 4)
		$CSGCylinder3D.radius = 0.005
		
		$push.position.y = f_ext
		$push.axle_length = (length / 2)

func update(size_scale):
	var f_ext = clampf(extend, 0, 1) * (length / 2)
	
	$CSGCylinder3D.height = (length / 2) * size_scale
	$CSGCylinder3D.position.y = (length / 4) * size_scale
	$CSGCylinder3D.radius = 0.005 * size_scale
	
	$CollisionShape3D.shape.radius = 0.005 * size_scale
	$CollisionShape3D.shape.height = (length / 2) * size_scale
	$CollisionShape3D.position.y = (length / 4) * size_scale
	
	$push.position.y = f_ext * size_scale
	$push.axle_length = (length / 2)
	$push.update(size_scale)
	
	mass = (0.205 * length) + 0.027
