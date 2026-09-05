@tool
extends PartBody

@export var radius = 0.02:
	set(value):
		radius = value
		_update_editor()

@export var height = 0.01:
	set(value):
		height = value
		_update_editor()

@export var connections: Array[PartBody]

func _ready() -> void:
	density = 1410
	_update_editor()

func _update_editor() -> void:
	if Engine.is_editor_hint() and is_node_ready():
		$CSGCylinder3D.radius = radius
		$CSGCylinder3D.height = height

func update(size_scale):
	mass = 1100 * PI * radius * radius * height
	$CSGCylinder3D.radius = radius * size_scale
	$CSGCylinder3D.height = height * size_scale
	$CollisionShape3D.shape.radius = radius * size_scale
	$CollisionShape3D.shape.height = height * size_scale
