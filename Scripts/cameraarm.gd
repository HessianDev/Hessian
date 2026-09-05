extends Node3D

@export var sensitivity: float = 0.25
@export var zoom_speed: float = 1.0
@export var min_zoom: float = 0.5
@export var max_zoom: float = 30.0

@onready var camera: Camera3D = $Camera3D

var orbit_active: bool = false
var pan_active: bool = false
var focus_tween: Tween

func _ready() -> void:
	camera.position = Vector3(0, 0, 1)

func focus_on(target_position: Vector3) -> void:
	if focus_tween:
		focus_tween.kill()
	focus_tween = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	focus_tween.tween_property(self, "global_position", target_position, 0.3)

func _unhandled_input(event: InputEvent) -> void:
	if $"../UI/CodeEditor".visible:
		return
	
	if event is InputEventMouseMotion and (orbit_active or pan_active):
		if focus_tween and focus_tween.is_running():
			focus_tween.kill()

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			orbit_active = event.pressed
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			pan_active = event.pressed
		
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera.position.z = clamp(camera.position.z - zoom_speed, min_zoom, max_zoom)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera.position.z = clamp(camera.position.z + zoom_speed, min_zoom, max_zoom)

	if event is InputEventMouseMotion:
		if orbit_active:
			var yaw = event.relative.x * sensitivity
			var pitch = event.relative.y * sensitivity
			pitch = clamp(pitch, -80.0, 80.0)
			
			rotation_degrees += Vector3(pitch, yaw, 0.0)
		elif pan_active:
			var right = camera.global_transform.basis.x
			var up = camera.global_transform.basis.y
			global_translate(-right * event.relative.x * 0.001 + up * event.relative.y * 0.001)
