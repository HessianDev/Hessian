@tool
extends PartBody

const THICKNESS = 0.0016

@export var plate: bool = false:
	set(value):
		plate = value
		_update_editor()

@export_range(0.01, 1, 0.005) var length: float = 0.2:
	set(value):
		length = value
		_update_editor()

@export_range(0.01, 1, 0.005) var width: float = 0.02:
	set(value):
		width = value
		_update_editor()

@export_range(0.005, 1, 0.005) var SideLength_R: float = 0.01:
	set(value):
		SideLength_R = value
		_update_editor()

@export_range(0.005, 1, 0.005) var SideLength_L: float = 0.01:
	set(value):
		SideLength_L = value
		_update_editor()

func _ready() -> void:
	density = 2680
	_update_editor()

func _update_editor() -> void:
	if Engine.is_editor_hint() and is_node_ready():
		$base.size = Vector3(width, THICKNESS, length)
		$right.size = Vector3(length, THICKNESS, SideLength_R)
		$left.size = Vector3(length, THICKNESS, SideLength_L)
		$base.position = Vector3(0, THICKNESS/2, 0)
		$left.position = Vector3(-(width/2)+(THICKNESS/2), SideLength_L/2, 0)
		$right.position = Vector3((width/2)-(THICKNESS/2), SideLength_R/2, 0)
		if plate:
			$right.visible = false
			$left.visible = false
		else:
			$right.visible = true
			$left.visible = true

func update(size_scale):
	if plate:
		$right.visible = false
		$left.visible = false
		$rightC.disabled = true
		$leftC.disabled = true
	else:
		$right.visible = true
		$left.visible = true
		$rightC.disabled = false
		$leftC.disabled = false
	
	$base.size = Vector3(width, THICKNESS, length) * size_scale
	$right.size = Vector3(length, THICKNESS, SideLength_R) * size_scale
	$left.size = Vector3(length, THICKNESS, SideLength_L) * size_scale
	
	$baseC.shape.size = Vector3(width, THICKNESS, length) * size_scale
	$rightC.shape.size = Vector3(length, THICKNESS, SideLength_R) * size_scale
	$leftC.shape.size = Vector3(length, THICKNESS, SideLength_L) * size_scale
	
	$base.position = Vector3(0, THICKNESS/2, 0) * size_scale
	$left.position = Vector3(-(width/2)+(THICKNESS/2), SideLength_L/2, 0) * size_scale
	$right.position = Vector3((width/2)-(THICKNESS/2), SideLength_R/2, 0) * size_scale
	
	$baseC.position = Vector3(0, THICKNESS/2, 0) * size_scale
	$leftC.position = Vector3(-(width/2)+(THICKNESS/2), SideLength_L/2, 0) * size_scale
	$rightC.position = Vector3((width/2)-(THICKNESS/2), SideLength_R/2, 0) * size_scale
	
	var bmass = compute_mass(width, length)
	var lmass = compute_mass(length, SideLength_L)
	var rmass = compute_mass(length, SideLength_R)
	if plate:
		mass = bmass
	else:
		mass = bmass + rmass + lmass
	center_of_mass = (((bmass * $base.position) + (rmass * $right.position) + (bmass * $left.position)) / mass)

func compute_mass(w, h):
	var plate_volume = w * h * THICKNESS
	return plate_volume * density * 0.7
