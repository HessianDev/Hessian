@tool
extends PartBody

@onready var roller = preload("res://parts/omni_roller.tscn")
var r_mass = 0.0035

@export var r_length:float = 0.014:
	set(value):
		r_length = value
		_update_editor()

@export var radius: float = 0.05:
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
		$omni_wheel.radius = radius
		$omni_wheel.height = length
		
		update_rollers(1)

func update_rollers(size_scale: float) -> void:
	for i in $omni_wheel/Wp.get_children():
		i.queue_free()
	for i in $omni_wheel/Wn.get_children():
		i.queue_free()
	
	$omni_wheel/Wp.position.y = ((length / 2.0) - 0.005) * size_scale
	$omni_wheel/Wn.position.y = -((length / 2.0) - 0.005) * size_scale
	
	var r_radius = length / 3
	var axis_radius: float = radius - r_radius
	
	var half_angle: float = asin((r_length / 2.0) / axis_radius)
	var r_count: int = int(PI / half_angle)
	
	var step_angle: float = (2.0 * PI) / float(r_count)
	
	$omni_wheel/Wn.rotation.y = step_angle / 2.0

	for i in range(r_count):
		var angle: float = float(i) * step_angle
		var pos_x: float = (axis_radius + 0.004) * cos(angle) * size_scale
		var pos_z: float = (axis_radius + 0.004) * sin(angle) * size_scale
		
		var rP: RigidBody3D = roller.instantiate()
		rP.mass = r_mass
		rP.freeze = true
		$omni_wheel/Wp.add_child(rP)
		rP.position = Vector3(pos_x, 0, pos_z)
		rP.rotate_y(-angle - (PI / 2.0))
		
		var rN: RigidBody3D = roller.instantiate()
		rN.mass = r_mass
		rN.freeze = true
		$omni_wheel/Wn.add_child(rN)
		rN.position = Vector3(pos_x, 0, pos_z)
		rN.rotate_y(-angle - (PI / 2.0))
		
		var radi = r_radius * size_scale
		var leng = (1 / (((r_radius * size_scale) * 2) / (r_length * size_scale)))
		
		rP.find_child("CollisionShape3D").shape.radius = radi
		rP.find_child("CollisionShape3D").scale.y = leng
		rP.find_child("CSGSphere3D").radius = radi
		rP.find_child("CSGSphere3D").scale.y = leng
		
		rN.find_child("CollisionShape3D").shape.radius = radi
		rN.find_child("CollisionShape3D").scale.y = leng
		rN.find_child("CSGSphere3D").radius = radi
		rN.find_child("CSGSphere3D").scale.y = leng

func update(size_scale):
	mass = density * PI * length * pow(radius, 2)
	$omni_wheel.radius = radius * size_scale
	$omni_wheel.height = length * size_scale
	
	$CollisionShape3D.shape.radius = radius * size_scale
	$CollisionShape3D.shape.height = length * size_scale
	
	update_rollers(size_scale)
