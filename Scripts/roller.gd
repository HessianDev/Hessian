@tool
extends PartBody

@export var radius: float = 0.01:
	set(value):
		radius = value
		_update_editor()

@export var length: float = 0.03:
	set(value):
		length = value
		_update_editor()

func _ready() -> void:
	density = 445.63
	_update_editor()

func _update_editor() -> void:
	if Engine.is_editor_hint() and is_node_ready():
		$CSGCylinder3D.radius = radius
		$CSGCylinder3D.height = length

func update(size_scale):
	mass = density * PI * length * pow(radius, 2)
	$CSGCylinder3D.radius = radius * size_scale
	$CSGCylinder3D.height = length * size_scale
	
	$CollisionShape3D.shape.radius = radius * size_scale
	$CollisionShape3D.shape.height = length * size_scale
