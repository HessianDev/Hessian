@tool
extends PartBody

@export var ports: Array[PartBody]
@export var program_name = "Driver"

func _ready() -> void:
	density = 608.1
	if Engine.is_editor_hint() and is_node_ready():
		$brain_mesh.scale = Vector3.ONE
		$CollisionShape3D.shape.size = Vector3(0.137922, 0.099822, 0.031559)

func update(size_scale):
	mass = 0.285
	$brain_mesh.scale = Vector3.ONE * size_scale
	$CollisionShape3D.shape.size = Vector3(0.137922, 0.099822, 0.031559) * size_scale
