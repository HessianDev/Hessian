extends Node3D
class_name RobotWorld3D

@export var zoom:float = 1.0

var robodata := []
var roboname = null

const SIZE_SCALE = 10
const TORQUE_SCALE = 10
const FORCE_SCALE = 10
const GRAVITY_SCALE = 1
const SPEED_SCALE = 1

func _process(delta: float) -> void:
	$Camera3D.look_at($Robot3D.global_position)
	var a = rad_to_deg(atan((100/(10*zoom))/$Camera3D.global_position.distance_to($Robot3D.global_position)))
	$Camera3D.fov = clampf(a,1,179)

func get_robodata(data, n):
	robodata = data
	roboname = n
	
	$Robot3D.set_robot(data)

func _on_back_pressed() -> void:
	var build_scene: PackedScene = load("res://Scenes/builder.tscn")
	var next_scene_instance = build_scene.instantiate()
	next_scene_instance.get_robodata(robodata, roboname)
	
	get_tree().root.add_child(next_scene_instance)
	get_tree().current_scene = next_scene_instance
	
	queue_free()
