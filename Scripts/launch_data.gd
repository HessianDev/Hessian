extends Node

var _pending_robodata: Array = []
var _pending_robot_name: String = ""
var has_pending_data: bool = false

func set_robodata(data: Array, robot_name: String = "") -> void:
	_pending_robodata = data
	_pending_robot_name = robot_name
	has_pending_data = true

func take_robodata() -> Dictionary:
	has_pending_data = false
	var result := {
		"data": _pending_robodata,
		"name": _pending_robot_name
	}
	_pending_robodata = []
	_pending_robot_name = ""
	return result
