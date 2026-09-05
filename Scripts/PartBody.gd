class_name PartBody
extends AnimatableBody3D

@export var mass:float
@export var density:float
@export var center_of_mass:Vector3

var mounted_axle: PartBody = null
var connecting_to:Array[PartBody]
var can_slide = false
var can_rotate = false

enum Types {MOTOR, AXLE, OMNIWHEEL, GEAR, STATIC, PISTON, METAL, BRAIN}
@export var part_type:Types = Types.STATIC
@export var for_axle = false

var id = 0
static var id_count = 0

func _init() -> void:
	if not Engine.is_editor_hint():
		id = id_count
		id_count += 1
	sync_to_physics = false

func update(size):
	pass
