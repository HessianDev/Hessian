class_name VisualCodeEditor
extends Control

const SAVE_DIR = "user://programs/"

const ProgramPresets: Dictionary = {
	"BasicProgram": preload("res://Presets/programs/BasicProgram.json"),
}

@export var context_menu: PopupMenu
@export var graph_edit: GraphEdit
var can_edit = true
var current_filename = ""
var selected_load_file = ""
var active_controller_capture_button: Button = null

signal program_saved(file_path: String)
signal program_loaded(file_path: String)

var history_stack: Array[Dictionary] = []
var history_index: int = -1
var saving_history: bool = false

var multi_source: Dictionary = {}
var multi_active: bool = false
var preview_line_end: Vector2 = Vector2.ZERO

static var Definitions = {
	"constants_varibles": {
		"title": "Constants",
		"color": Color(0.4, 0.4, 0.7),
		"blocks": {
			"constant_float": {
				"title": "Constant Number",
				"rows": [
					{"label": "Value", "input_type": "number", "default": 0.0},
					{"label": "Output", "slot_out": 1}
				],
				"eval": func(rt: BlockRuntime, node_name: String): return rt.input(node_name, 0, 0.0)
			},
			"constant_bool": {
				"title": "Constant Boolean",
				"rows": [
					{"label": "Value", "input_type": "custom_dropdown", "options": ["True", "False"]},
					{"label": "Output", "slot_out": 2}
				],
				"eval": func(rt:BlockRuntime, node_name:String): return rt._get_option_text(node_name, 0) == "True"
			},
		}
	},
	"input": {
		"title": "Input",
		"color": Color(0.0, 0.737, 0.945, 1.0),
		"blocks": {
			"controller_button": {
				"title": "Button Pressed?",
				"rows": [
					{"label": "Button", "input_type": "controller_capture"},
					{"label": "Pressed?", "slot_out": 2}
				],
				"eval": func(rt:BlockRuntime, node_name:String): return rt._get_controller_button(node_name)
			},
			"controller_button_pressed": {
				"title": "On Button Pressed",
				"rows": [
					{"label": "Button", "input_type": "controller_capture"},
					{"label": "Pressed", "slot_out": 0}
				]
			},
			"controller_button_released": {
				"title": "On Button Released",
				"rows": [
					{"label": "Button", "input_type": "controller_capture"},
					{"label": "Released", "slot_out": 0}
				]
			},
			"controller_axis": {
				"title": "Controller Axis",
				"rows": [
					{"label": "Axis", "input_type": "dropdown", "device_filter": "controller_axis"},
					{"label": "Position", "slot_out": 1}
				],
				"eval": func(rt:BlockRuntime, node_name:String): return rt._get_controller_axis(node_name)
			},
			"get_axis": {
				"title": "Get Axis",
				"rows": [
					{"label": "Positive", "slot_in": 2},
					{"label": "Negative", "slot_in": 2},
					{"label": "Axis Value", "slot_out": 1}
				],
			"eval": func(rt:BlockRuntime, node_name:String):
			var positive = bool(rt.input(node_name, "Positive", false))
			var negative = bool(rt.input(node_name, "Negative", false))
			if positive and not negative: return 1.0
			elif negative and not positive: return -1.0
			else: return 0.0
			},
		}
	},
	"events": {
		"title": "Events",
		"color": Color(0.2, 0.5, 0.8),
		"blocks": {
			"base_ready": {
				"title": "When Started (Once)",
				"rows": [{"label": "Ready", "slot_out": 0}]
			},
			"base_auton": {
				"title": "When Autonomous",
				"rows": [{"label": "Auton", "slot_out": 0}]
			},
			"base_driver": {
				"title": "When Driver Control",
				"rows": [{"label": "Driver", "slot_out": 0}]
			}
		}
	},
	"control": {
		"title": "Control",
		"color": Color(0.2, 0.5, 0.8),
		"blocks": {
			"wait": {
				"title": "Wait",
				"rows": [
					{"label": "Execute", "slot_in": 0, "slot_out": 0},
					{"label": "Seconds", "input_type": "number", "default": 1.0, "slot_in": 1}
				],
				"exec": func(rt, thread, new_threads):
			var node_name = thread.current_node
			var seconds = rt.input(node_name, "Seconds", 1.0)
			thread.wait_timer = max(0.0, float(seconds))
			},
			"wait_until": {
				"title": "Wait Until",
				"rows": [
					{"label": "Execute", "slot_in": 0, "slot_out": 0},
					{"label": "Condition", "slot_in": 2}
				],
				"exec": func(rt, thread, new_threads):
			var node_name = thread.current_node
			var condition = rt.input(node_name, "Condition", false)
			if condition:
				new_threads.append_array(rt._spawn_execution_flow(node_name, rt._out_port("wait_until", "Execute"), thread))
				thread.is_complete = true
			},
			"repeat_count": {
				"title": "Repeat Times",
				"rows": [
					{"label": "In", "slot_in": 0},
					{"label": "Times", "input_type": "number", "default": 10, "slot_in": 1},
						{"label": "Do Loop", "slot_out": 0},
					{"label": "On Finish", "slot_out": 0}
				],
				"exec": func(rt, thread, new_threads):
			var node_name = thread.current_node
			var count = int(rt.input(node_name, "Times", 10))
			if thread.loop_iterations < count:
				thread.loop_iterations += 1
				var child_threads = rt._spawn_execution_flow(node_name, rt._out_port("repeat_count", "Do Loop"), thread)
				for c in child_threads: c.loop_type = "count"
				new_threads.append_array(child_threads)
			else:
				new_threads.append_array(rt._spawn_execution_flow(node_name, rt._out_port("repeat_count", "On Finish"), thread))
				thread.is_complete = true
			},
			"loop_forever": {
				"title": "Forever Loop",
				"rows": [
					{"label": "In", "slot_in": 0},
					{"label": "Do Loop", "slot_out": 0}
				],
				"exec": func(rt, thread, new_threads):
			var node_name = thread.current_node
			var child_threads = rt._spawn_execution_flow(node_name, rt._out_port("loop_forever", "Do Loop"), thread)
			for c in child_threads: c.loop_type = "forever"
			new_threads.append_array(child_threads)
			},
			"repeat_until": {
				"title": "Repeat Until",
				"rows": [
					{"label": "In", "slot_in": 0},
					{"label": "Until Condition", "slot_in": 2},
					{"label": "Do Loop", "slot_out": 0},
					{"label": "On Finish", "slot_out": 0}
				],
				"exec": func(rt, thread, new_threads):
			var node_name = thread.current_node
			if not rt.input(node_name, "Until Condition", false):
				var child_threads = rt._spawn_execution_flow(node_name, rt._out_port("repeat_until", "Do Loop"), thread)
				for c in child_threads: c.loop_type = "count"
				new_threads.append_array(child_threads)
			else:
				new_threads.append_array(rt._spawn_execution_flow(node_name, rt._out_port("repeat_until", "On Finish"), thread))
				thread.is_complete = true
			},
			"while_loop": {
				"title": "While",
				"rows": [
					{"label": "In", "slot_in": 0},
					{"label": "While Condition", "slot_in": 2},
					{"label": "Do Loop", "slot_out": 0},
					{"label": "On Finish", "slot_out": 0}
				],
				"exec": func(rt, thread, new_threads):
			var node_name = thread.current_node
			if rt.input(node_name, "While Condition", false):
				var child_threads = rt._spawn_execution_flow(node_name, rt._out_port("while_loop", "Do Loop"), thread)
				for c in child_threads: c.loop_type = "while"
				new_threads.append_array(child_threads)
			else:
				new_threads.append_array(rt._spawn_execution_flow(node_name, rt._out_port("while_loop", "On Finish"), thread))
				thread.is_complete = true
			},
			"if_then": {
				"title": "If",
				"rows": [
					{"label": "In", "slot_in": 0},
					{"label": "If Condition", "slot_in": 2},
					{"label": "Then", "slot_out": 0},
					{"label": "Exit", "slot_out": 0}
				],
				"exec": func(rt, thread, new_threads):
			var node_name = thread.current_node
			var condition = rt.input(node_name, "If Condition", false)
			var branch = "Then" if condition else "Exit"
			new_threads.append_array(rt._spawn_execution_flow(node_name, rt._out_port("if_then", branch), thread))
			thread.is_complete = true
			},
			"if_else": {
				"title": "If / Else",
				"rows": [
					{"label": "In", "slot_in": 0},
					{"label": "If Condition", "slot_in": 2},
					{"label": "Then", "slot_out": 0},
					{"label": "Else", "slot_out": 0},
					{"label": "Exit", "slot_out": 0}
				],
				"exec": func(rt, thread, new_threads):
			var node_name = thread.current_node
			var condition = rt.input(node_name, "If Condition", false)
			var branch = "Then" if condition else "Else"
			new_threads.append_array(rt._spawn_execution_flow(node_name, rt._out_port("if_else", branch), thread))
			thread.is_complete = true
			},
			"if_else_if": {
				"title": "If / Else If / Else",
				"rows": [
					{"label": "In", "slot_in": 0},
					{"label": "If Condition", "slot_in": 2},
					{"label": "Then", "slot_out": 0},
					{"label": "Else If Condition", "slot_in": 2},
					{"label": "Then", "slot_out": 0},
					{"label": "Else", "slot_out": 0},
					{"label": "Exit", "slot_out": 0}
				],
				"exec": func(rt, thread, new_threads):
			var node_name = thread.current_node
			if rt.input(node_name, 1, false):
				new_threads.append_array(rt._spawn_execution_flow(node_name, rt._out_port_by_row("if_else_if", 2), thread))
			elif rt.input(node_name, 3, false):
				new_threads.append_array(rt._spawn_execution_flow(node_name, rt._out_port_by_row("if_else_if", 4), thread))
			else:
				new_threads.append_array(rt._spawn_execution_flow(node_name, rt._out_port_by_row("if_else_if", 5), thread))
			thread.is_complete = true
			},
			"for": {
				"title": "For",
				"rows": [
					{"label": "In", "slot_in": 0},
					{"label": "Exit", "slot_out": 0},
					{"label": "i", "slot_out": 1},
					{"label": "list", "slot_in": 4},
					{"label": "Repeat", "slot_out": 0}
				],
				"exec": func(rt, thread, new_threads):
			var node_name = thread.current_node
			if not rt._loop_lists.has(node_name):
				rt._loop_lists[node_name] = rt.input(node_name, "list", [])
			var list_val = rt._loop_lists[node_name]
			if list_val is Array and thread.loop_iterations < list_val.size():
				rt._loop_values[node_name] = list_val[thread.loop_iterations]
				thread.loop_iterations += 1
				var child_threads = rt._spawn_execution_flow(node_name, rt._out_port("for", "Repeat"), thread)
				for c in child_threads: c.loop_type = "for"
				new_threads.append_array(child_threads)
			else:
				rt._loop_lists.erase(node_name)
				new_threads.append_array(rt._spawn_execution_flow(node_name, rt._out_port("for", "Exit"), thread))
				thread.is_complete = true
			},
			"break": {
				"title": "Break Loop",
				"rows": [
					{"label": "Break Out", "slot_in": 0}
				],
				"exec": func(rt, thread, new_threads):
			var parent = thread.parent_thread
			while parent:
				if parent.loop_type != "":
					parent.is_complete = true
					thread.is_complete = true
					return
				parent = parent.parent_thread
			thread.is_complete = true
			}
		}
	},
	"pistons":{
		"title": "Pistons",
		"color": Color(0.165, 0.898, 1.0, 1.0),
		"blocks": {
			"piston_out": {
				"title": "Piston Out",
				"rows": [
					{"label": "Execute", "slot_in": 0, "slot_out": 0},
					{"label": "Piston", "input_type": "dropdown", "device_filter": "piston"},
				],
				"action": func(rt:BlockRuntime, node_name):
					var part_id = rt.resolve_piston(node_name, "Piston")
					rt._set_piston_extending(part_id,true)
					},
			"piston_in": {
				"title": "Piston In",
				"rows": [
					{"label": "Execute", "slot_in": 0, "slot_out": 0},
					{"label": "Piston", "input_type": "dropdown", "device_filter": "piston"},
				],
				"action": func(rt:BlockRuntime, node_name):
					var part_id = rt.resolve_piston(node_name, "Piston")
					rt._set_piston_extending(part_id,false)
					},
		},
	},
	"motors": {
		"title": "Motors",
		"color": Color(0.2, 0.5, 0.8),
		"blocks": {
			"motor_spin": {
				"title": "Spin Motor",
				"rows": [
					{"label": "Execute", "slot_in": 0, "slot_out": 0},
					{"label": "Motor", "input_type": "dropdown", "device_filter": "motor"},
					{"label": "Speed", "input_type": "number", "default": 50, "slot_in": 1}
				],
				"action": func(rt:BlockRuntime, node_name:String):
					var part_id = rt.resolve_motor(node_name, "Motor")
					var speed = rt.input(node_name, "Speed", 50.0)
					rt._set_motor_velocity(part_id, speed)
					},
			"motor_stop": {
				"title": "Stop Motor",
				"rows": [
					{"label": "Execute", "slot_in": 0, "slot_out": 0},
					{"label": "Motor", "input_type": "dropdown", "device_filter": "motor"}
				],
				"action": func(rt:BlockRuntime, node_name:String):
					var part_id = rt.resolve_motor(node_name, "Motor")
					rt._stop_motor(part_id)
					},
			"motor_set_position": {
				"title": "Set Position",
				"rows": [
					{"label": "Execute", "slot_in": 0, "slot_out": 0},
					{"label": "Motor", "input_type": "dropdown", "device_filter": "motor"},
					{"label": "Position", "input_type": "number", "default": 0, "slot_in": 1},
					{"label": "deg", "input_type": "none"}
				],
				"exec": func(rt, thread, new_threads):
					var node_name = thread.current_node
					var part_id = rt.resolve_motor(node_name, "Motor")
					var target = rt.input(node_name, "Position", 0.0)
					if rt.robot and rt.robot.has_method("start_motor_move_to_position"):
						rt.robot.start_motor_move_to_position(part_id, float(target), 50.0)
						thread.waiting_motor_id = part_id
					else:
						push_warning("motor_set_position: Robot3D is missing start_motor_move_to_position()")
						new_threads.append_array(rt._spawn_execution_flow(node_name, rt._out_port("motor_set_position", "Execute"), thread))
						thread.is_complete = true
					},
			"motor_set_velocity": {
				"title": "Set Velocity",
				"rows": [
					{"label": "Execute", "slot_in": 0, "slot_out": 0},
					{"label": "Motor", "input_type": "dropdown", "device_filter": "motor"},
					{"label": "Velocity", "input_type": "number", "default": 50, "slot_in": 1},
					{"label": "%", "input_type": "none"}
				],
				"action": func(rt:BlockRuntime, node_name:String):
					var part_id = rt.resolve_motor(node_name, "Motor")
					var speed = rt.input(node_name, "Velocity", 50.0)
					rt._set_motor_velocity(part_id, speed)
					},
			"motor_set_stopping": {
				"title": "Set Stopping Mode",
				"rows": [
					{"label": "Execute", "slot_in": 0, "slot_out": 0},
					{"label": "Motor", "input_type": "dropdown", "device_filter": "motor"},
					{"label": "Mode", "input_type": "custom_dropdown", "options": ["brake", "coast", "hold"]}
				],
				"action": func(rt:BlockRuntime, node_name:String):
					var part_id = rt.resolve_motor(node_name, "Motor")
					var mode = rt._get_option_text(node_name, rt._row("motor_set_stopping", "Mode"))
					rt._set_motor_brake_mode(part_id, mode)
					},
			"motor_set_max_torque": {
				"title": "Set Max Torque",
				"rows": [
					{"label": "Execute", "slot_in": 0, "slot_out": 0},
					{"label": "Motor", "input_type": "dropdown", "device_filter": "motor"},
					{"label": "Torque", "input_type": "number", "default": 50, "slot_in": 1},
					{"label": "%", "input_type": "none"}
				],
				"action": func(rt:BlockRuntime, node_name:String):
					var part_id = rt.resolve_motor(node_name, "Motor")
					var pct = rt.input(node_name, "Torque", 50.0)
					if rt.robot and rt.robot.has_method("set_motor_max_torque"):
						rt.robot.set_motor_max_torque(part_id, float(pct))
					},
			"motor_set_timeout": {
				"title": "Set Timeout",
				"rows": [
					{"label": "Execute", "slot_in": 0, "slot_out": 0},
					{"label": "Motor", "input_type": "dropdown", "device_filter": "motor"},
					{"label": "Timeout", "input_type": "number", "default": 1.0, "slot_in": 1},
					{"label": "sec", "input_type": "none"}
				],
				"action": func(rt:BlockRuntime, node_name:String):
					var part_id = rt.resolve_motor(node_name, "Motor")
					var secs = rt.input(node_name, "Timeout", 1.0)
					if rt.robot and rt.robot.has_method("set_motor_timeout"):
						rt.robot.set_motor_timeout(part_id, float(secs))
					},
			"motor_is_done": {
				"title": "Is Done?",
				"rows": [{"label": "Motor", "input_type": "dropdown", "device_filter": "motor", "slot_out": 2}],
				"eval": func(rt:BlockRuntime, node_name:String):
					var port = int(rt.input(node_name, 0, 0))
					return rt._is_motor_done(port)
					},
			"motor_is_spinning": {
				"title": "Is Spinning?",
				"rows": [{"label": "Motor", "input_type": "dropdown", "device_filter": "motor", "slot_out": 2}],
				"eval": func(rt:BlockRuntime, node_name:String):
					var port = int(rt.input(node_name, 0, 0))
					return rt._is_motor_spinning(port)
					},
			"motor_get_position": {
				"title": "Position (deg)",
				"rows": [{"label": "Motor", "input_type": "dropdown", "device_filter": "motor", "slot_out": 1}],
				"eval": func(rt:BlockRuntime, node_name:String):
					var port = int(rt.input(node_name, 0, 0))
					return rt._get_motor_degrees(port)
					},
			"motor_get_velocity": {
				"title": "Velocity (%)",
				"rows": [{"label": "Motor", "input_type": "dropdown", "device_filter": "motor", "slot_out": 1}],
				"eval": func(rt:BlockRuntime, node_name:String):
					var port = int(rt.input(node_name, 0, 0))
					return rt._get_motor_velocity_pct(port)
					},
			"motor_get_current": {
				"title": "Current (amps)",
				"rows": [{"label": "Motor", "input_type": "dropdown", "device_filter": "motor", "slot_out": 1}]
			},
			"motor_get_power": {
				"title": "Power (watts)",
				"rows": [{"label": "Motor", "input_type": "dropdown", "device_filter": "motor", "slot_out": 1}]
			},
			"motor_get_torque": {
				"title": "Torque (Nm)",
				"rows": [{"label": "Motor", "input_type": "dropdown", "device_filter": "motor", "slot_out": 1}]
			},
			"motor_get_efficiency": {
				"title": "Efficiency (%)",
				"rows": [{"label": "Motor", "input_type": "dropdown", "device_filter": "motor", "slot_out": 1}]
			},
			"motor_get_temperature": {
				"title": "Temperature (%)",
				"rows": [{"label": "Motor", "input_type": "dropdown", "device_filter": "motor", "slot_out": 1}]
			}
		}
	},
	"functions": {
		"title": "Functions",
		"color": Color(0.8, 0.2, 0.5),
		"blocks": {
			"func_def": {
				"title": "Define Function",
				"is_function_def": true,
				"rows": [
					{"label": "Name", "input_type": "line_edit", "default_text": "my_function"},
					{"label": "Return Type", "input_type": "return_type_dropdown"},
					{"label": "Run", "slot_out": 0}
				]
			}
		}
	},
	
	"basic_math": {
		"title": "Basic Arithmetic",
		"color": Color(0.2, 0.6, 0.8),
		"blocks": {
			"add": {
				"title": "Add (+)",
				"rows": [
					{"label": "A", "slot_in": 1},
					{"label": "B", "slot_in": 1},
					{"label": "Sum", "slot_out": 1}
				],
				"eval": func(rt:BlockRuntime, node_name:String): return rt.input(node_name, "A") + rt.input(node_name, "B")
			},
			"subtract": {
				"title": "Subtract (-)",
				"rows": [
					{"label": "A", "slot_in": 1},
					{"label": "B", "slot_in": 1},
					{"label": "Difference", "slot_out": 1}
				],
				"eval": func(rt:BlockRuntime, node_name:String): return rt.input(node_name, "A") - rt.input(node_name, "B")
			},
			"multiply": {
				"title": "Multiply (*)",
				"rows": [
					{"label": "A", "slot_in": 1},
					{"label": "B", "slot_in": 1},
					{"label": "Product", "slot_out": 1}
				],
				"eval": func(rt:BlockRuntime, node_name:String): return rt.input(node_name, "A") * rt.input(node_name, "B")
			},
			"divide": {
				"title": "Divide (÷)",
				"rows": [
					{"label": "A", "slot_in": 1},
					{"label": "B", "slot_in": 1},
					{"label": "Quotient", "slot_out": 1}
				],
				"eval": func(rt:BlockRuntime, node_name:String):
					var b = rt.input(node_name, "B")
					return rt.input(node_name, "A") / b if b != 0 else 0.0
					},
			"modulo": {
				"title": "Modulo (%)",
				"rows": [
					{"label": "A", "slot_in": 1},
					{"label": "B", "slot_in": 1},
					{"label": "Remainder", "slot_out": 1}
				],
				"eval": func(rt:BlockRuntime, node_name:String): return fmod(rt.input(node_name, "A"), rt.input(node_name, "B"))
			}
		}
	},
	"advanced_math": {
		"title": "Advanced Math",
		"color": Color(0.2, 0.4, 0.8),
		"blocks": {
			"abs": {"title": "Abs", "rows": [{"label": "Value", "slot_in": 1}, {"label": "Result", "slot_out": 1}], "eval": func(rt:BlockRuntime, node_name:String): return abs(rt.input(node_name, "Value"))},
			"neg": {"title": "Negative", "rows": [{"label": "Value", "slot_in": 1}, {"label": "Result", "slot_out": 1}], "eval": func(rt:BlockRuntime, node_name:String): return -rt.input(node_name, "Value")},
			"ceil": {"title": "Ceil", "rows": [{"label": "Value", "slot_in": 1}, {"label": "Result", "slot_out": 1}], "eval": func(rt:BlockRuntime, node_name:String): return ceil(rt.input(node_name, "Value"))},
			"floor": {"title": "Floor", "rows": [{"label": "Value", "slot_in": 1}, {"label": "Result", "slot_out": 1}], "eval": func(rt:BlockRuntime, node_name:String): return floor(rt.input(node_name, "Value"))},
			"round": {"title": "Round", "rows": [{"label": "Value", "slot_in": 1}, {"label": "Result", "slot_out": 1}], "eval": func(rt:BlockRuntime, node_name:String): return round(rt.input(node_name, "Value"))},
			"min": {"title": "Min", "rows": [{"label": "A", "slot_in": 1}, {"label": "B", "slot_in": 1}, {"label": "Min Value", "slot_out": 1}], "eval": func(rt:BlockRuntime, node_name:String): return min(rt.input(node_name, "A"), rt.input(node_name, "B"))},
			"max": {"title": "Max", "rows": [{"label": "A", "slot_in": 1}, {"label": "B", "slot_in": 1}, {"label": "Max Value", "slot_out": 1}], "eval": func(rt:BlockRuntime, node_name:String): return max(rt.input(node_name, "A"), rt.input(node_name, "B"))},
			"clamp": {"title": "Clamp", "rows": [{"label": "Value", "slot_in": 1}, {"label": "Min", "slot_in": 1}, {"label": "Max", "slot_in": 1}, {"label": "Result", "slot_out": 1}], "eval": func(rt:BlockRuntime, node_name:String): return clamp(rt.input(node_name, "Value"), rt.input(node_name, "Min"), rt.input(node_name, "Max"))},
			"lerp": {"title": "Lerp", "rows": [{"label": "From (A)", "slot_in": 1}, {"label": "To (B)", "slot_in": 1}, {"label": "Weight (Alpha)", "slot_in": 1}, {"label": "Result", "slot_out": 1}], "eval": func(rt:BlockRuntime, node_name:String): return lerp(rt.input(node_name, "From (A)"), rt.input(node_name, "To (B)"), rt.input(node_name, "Weight (Alpha)"))},
			"pow": {"title": "Power (Pow)", "rows": [{"label": "Base (X)", "slot_in": 1}, {"label": "Exponent (Y)", "slot_in": 1}, {"label": "Result", "slot_out": 1}], "eval": func(rt:BlockRuntime, node_name:String): return pow(rt.input(node_name, "Base (X)"), rt.input(node_name, "Exponent (Y)"))},
			"sqrt": {"title": "Square Root (Sqrt)", "rows": [{"label": "Value", "slot_in": 1}, {"label": "Result", "slot_out": 1}], "eval": func(rt:BlockRuntime, node_name:String): return sqrt(rt.input(node_name, "Value"))},
			"sin": {"title": "Sin", "rows": [{"label": "Angle (Rad)", "slot_in": 1}, {"label": "Result", "slot_out": 1}], "eval": func(rt:BlockRuntime, node_name:String): return sin(rt.input(node_name, "Angle (Rad)"))},
			"cos": {"title": "Cos", "rows": [{"label": "Angle (Rad)", "slot_in": 1}, {"label": "Result", "slot_out": 1}], "eval": func(rt:BlockRuntime, node_name:String): return cos(rt.input(node_name, "Angle (Rad)"))},
			"tan": {"title": "Tan", "rows": [{"label": "Angle (Rad)", "slot_in": 1}, {"label": "Result", "slot_out": 1}], "eval": func(rt:BlockRuntime, node_name:String): return tan(rt.input(node_name, "Angle (Rad)"))},
			"asin": {"title": "ASin", "rows": [{"label": "Value", "slot_in": 1}, {"label": "Angle (Rad)", "slot_out": 1}], "eval": func(rt:BlockRuntime, node_name:String): return asin(rt.input(node_name, "Value"))},
			"acos": {"title": "ACos", "rows": [{"label": "Value", "slot_in": 1}, {"label": "Angle (Rad)", "slot_out": 1}], "eval": func(rt:BlockRuntime, node_name:String): return acos(rt.input(node_name, "Value"))},
			"atan": {"title": "ATan", "rows": [{"label": "Value", "slot_in": 1}, {"label": "Angle (Rad)", "slot_out": 1}], "eval": func(rt:BlockRuntime, node_name:String): return atan(rt.input(node_name, "Value"))},
			"vector_length": {"title": "Vector Length", "rows": [{"label": "Vector", "slot_in": 3}, {"label": "Length", "slot_out": 1}], "eval": func(rt:BlockRuntime, node_name:String): return (rt.input(node_name, "Vector") as Vector3).length()},
			"distance": {"title": "Distance", "rows": [{"label": "Vector A", "slot_in": 3}, {"label": "Vector B", "slot_in": 3}, {"label": "Distance", "slot_out": 1}], "eval": func(rt:BlockRuntime, node_name:String): return (rt.input(node_name, "Vector A") as Vector3).distance_to(rt.input(node_name, "Vector B") as Vector3)},
			"dot_product": {"title": "Dot Product", "rows": [{"label": "Vector A", "slot_in": 3}, {"label": "Vector B", "slot_in": 3}, {"label": "Dot", "slot_out": 1}], "eval": func(rt:BlockRuntime, node_name:String): return (rt.input(node_name, "Vector A") as Vector3).dot(rt.input(node_name, "Vector B") as Vector3)},
			"cross_product": {"title": "Cross Product", "rows": [{"label": "Vector A", "slot_in": 3}, {"label": "Vector B", "slot_in": 3}, {"label": "Cross Vector", "slot_out": 3}], "eval": func(rt:BlockRuntime, node_name:String): return (rt.input(node_name, "Vector A") as Vector3).cross(rt.input(node_name, "Vector B") as Vector3)},
			"normalize": {"title": "Normalize", "rows": [{"label": "Vector", "slot_in": 3}, {"label": "Normalized", "slot_out": 3}], "eval": func(rt:BlockRuntime, node_name:String): return (rt.input(node_name, "Vector") as Vector3).normalized()},
			"rotate_vector": {"title": "Rotate Vector", "rows": [{"label": "Vector", "slot_in": 3}, {"label": "Axis", "slot_in": 3}, {"label": "Angle (Deg)", "slot_in": 1}, {"label": "Rotated Vector", "slot_out": 3}], "eval": func(rt:BlockRuntime, node_name:String): return (rt.input(node_name, "Vector") as Vector3).rotated((rt.input(node_name, "Axis") as Vector3).normalized(), deg_to_rad(rt.input(node_name, "Angle (Deg)")))}
		}
	},
	"comparisons": {
		"title": "Logic",
		"color": Color(0.2, 0.7, 0.3),
		"blocks": {
			"equal": {"title": "Equal (==)", "rows": [{"label": "A", "slot_in": 1}, {"label": "B", "slot_in": 1}, {"label": "Is Equal", "slot_out": 2}], "eval": func(rt:BlockRuntime, node_name:String): return rt.input(node_name, "A") == rt.input(node_name, "B")},
			"not_equal": {"title": "Not Equal (!=)", "rows": [{"label": "A", "slot_in": 1}, {"label": "B", "slot_in": 1}, {"label": "Not Equal", "slot_out": 2}], "eval": func(rt:BlockRuntime, node_name:String): return rt.input(node_name, "A") != rt.input(node_name, "B")},
			"greater_than": {"title": "Greater Than (>)", "rows": [{"label": "A", "slot_in": 1}, {"label": "B", "slot_in": 1}, {"label": "Result", "slot_out": 2}], "eval": func(rt:BlockRuntime, node_name:String): return rt.input(node_name, "A") > rt.input(node_name, "B")},
			"less_than": {"title": "Less Than (<)", "rows": [{"label": "A", "slot_in": 1}, {"label": "B", "slot_in": 1}, {"label": "Result", "slot_out": 2}], "eval": func(rt:BlockRuntime, node_name:String): return rt.input(node_name, "A") < rt.input(node_name, "B")},
			"greater_equal": {"title": "Greater Than or Equal (>=)", "rows": [{"label": "A", "slot_in": 1}, {"label": "B", "slot_in": 1}, {"label": "Result", "slot_out": 2}], "eval": func(rt:BlockRuntime, node_name:String): return rt.input(node_name, "A") >= rt.input(node_name, "B")},
			"less_equal": {"title": "Less Than or Equal (<=)", "rows": [{"label": "A", "slot_in": 1}, {"label": "B", "slot_in": 1}, {"label": "Result", "slot_out": 2}], "eval": func(rt:BlockRuntime, node_name:String): return rt.input(node_name, "A") <= rt.input(node_name, "B")},
			"and": {"title": "AND (&&)", "rows": [{"label": "Condition A", "slot_in": 2}, {"label": "Condition B", "slot_in": 2}, {"label": "Result", "slot_out": 2}], "eval": func(rt:BlockRuntime, node_name:String): return rt.input(node_name, "Condition A") and rt.input(node_name, "Condition B")},
			"or": {"title": "OR (||)", "rows": [{"label": "Condition A", "slot_in": 2}, {"label": "Condition B", "slot_in": 2}, {"label": "Result", "slot_out": 2}], "eval": func(rt:BlockRuntime, node_name:String): return rt.input(node_name, "Condition A") or rt.input(node_name, "Condition B")},
			"not": {"title": "NOT (!)", "rows": [{"label": "Condition", "slot_in": 2}, {"label": "Result", "slot_out": 2}], "eval": func(rt:BlockRuntime, node_name:String): return not rt.input(node_name, "Condition")}
		}
	},
	"lists": {
		"title": "Lists",
		"color": Color(0.542, 0.007, 0.708, 1.0),
		"blocks": {
			"range_block": {
				"title": "Range",
				"rows": [
					{"label": "Start", "input_type": "number", "default": 0, "slot_in": 1},
					{"label": "End", "input_type": "number", "default": 10, "slot_in": 1},
					{"label": "List", "slot_out": 4}
				],
				"eval": func(rt:BlockRuntime, node_name:String):
					var s = int(rt.input(node_name, "Start", 0))
					var e = int(rt.input(node_name, "End", 10))
					var arr = []
					for i in range(s, e): arr.append(i)
					return arr
					}
		}
	}
}

const SlotColors = {
	0: Color(1, 1, 1),
	1: Color(0.3, 0.8, 0.3),
	2: Color(0.8, 0.3, 0.3),
	3: Color(0.2, 0.6, 0.9),
	4: Color(0.795, 0.289, 0.997, 1.0),
}

var is_modified: bool = false
var pending_load_meta: Dictionary = {}

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	_copy_presets_to_user()
	graph_edit.connection_request.connect(_on_connection_request)
	graph_edit.disconnection_request.connect(_on_disconnection_request)
	graph_edit.end_node_move.connect(_save_history_state)
	
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	graph_edit.mouse_filter = Control.MOUSE_FILTER_STOP
	
	if not graph_edit.draw.is_connected(_on_graph_edit_draw):
		graph_edit.draw.connect(_on_graph_edit_draw)
	
	$save/save_close.pressed.connect(_close_save_panel)
	$load/load_close.pressed.connect(_close_load_panel)
	
	call_deferred("_save_history_state")

func _copy_presets_to_user() -> void:
	for preset_name in ProgramPresets.keys():
		var json_res: JSON = ProgramPresets[preset_name]
		if not json_res:
			continue
		var dest_path = SAVE_DIR + preset_name + ".json"
		if not FileAccess.file_exists(dest_path):
			var f = FileAccess.open(dest_path, FileAccess.WRITE)
			if f:
				f.store_string(JSON.stringify(json_res.data, "\t"))
				f.close()

func _input(event: InputEvent) -> void:
	if !visible:
		return
	
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_Z and (Input.is_key_pressed(KEY_CTRL) or event.ctrl_pressed or event.meta_pressed):
			if Input.is_key_pressed(KEY_SHIFT) or event.shift_pressed:
				redo()
			else:
				undo()
			get_viewport().set_input_as_handled()
			return

	if active_controller_capture_button:
		_handle_controller_capture(event)
		if active_controller_capture_button == null:
			return
			
	if event is InputEventMouseMotion and multi_active:
		preview_line_end = graph_edit.get_local_mouse_position()
		graph_edit.queue_redraw()
		return
	
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if $save.visible and not $save.get_global_rect().has_point(event.global_position):
			_close_save_panel()
		if $load.visible and not $load.get_global_rect().has_point(event.global_position):
			_close_load_panel()
		if $ask_save.visible and not $ask_save.get_global_rect().has_point(event.global_position):
			$ask_save.visible = false
			if active_controller_capture_button:
				active_controller_capture_button.button_pressed = false
				active_controller_capture_button = null

	if event is InputEventKey and event.pressed and event.keycode == KEY_DELETE:
		var screen_pos = graph_edit.get_local_mouse_position()
		var conn = _get_connection_at_screen_position(screen_pos)
		if not conn.is_empty():
			graph_edit.disconnect_node(conn["from_node"], conn["from_port"], conn["to_node"], conn["to_port"])
			is_modified = true
			_clear_multi_source()
			_save_history_state()
			get_viewport().set_input_as_handled()
		else:
			delete_selected_nodes()

	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if multi_active:
			_clear_multi_source()
			get_viewport().set_input_as_handled()

	var over_graph = graph_edit.get_global_rect().has_point(event.global_position) if event is InputEventMouse else false
	
	if over_graph and event is InputEventMouseButton and event.pressed:
		var screen_pos = graph_edit.get_local_mouse_position()
		var graph_pos = (graph_edit.scroll_offset + screen_pos) / graph_edit.zoom
		
		if event.button_index == MOUSE_BUTTON_RIGHT:
			var conn = _get_connection_at_screen_position(screen_pos)
			if not conn.is_empty():
				graph_edit.disconnect_node(conn["from_node"], conn["from_port"], conn["to_node"], conn["to_port"])
				is_modified = true
				_clear_multi_source()
				_save_history_state()
				get_viewport().set_input_as_handled()
				return
			else:
				if can_edit:
					_rebuild_context_menu()
					if context_menu:
						context_menu.set_meta("spawn_pos", graph_pos)
						context_menu.position = event.global_position
						context_menu.popup()
						get_viewport().set_input_as_handled()
				return
				
		if event.button_index == MOUSE_BUTTON_LEFT:
			var ctrl = Input.is_key_pressed(KEY_CTRL) or event.ctrl_pressed or event.meta_pressed
			var slot_info = _get_slot_at_screen_position(screen_pos)
			
			if ctrl and slot_info and slot_info["is_output"]:
				multi_source = {
					"node": str(slot_info["node"].name),
					"port_idx": slot_info["port_idx"],
					"row_idx": slot_info["row_idx"]
				}
				multi_active = true
				preview_line_end = screen_pos
				graph_edit.queue_redraw()
				get_viewport().set_input_as_handled()
				return
				
			if multi_active and slot_info and not slot_info["is_output"]:
				if not multi_source.is_empty():
					var from_node = multi_source["node"]
					var from_port = multi_source["port_idx"]
					var to_node = str(slot_info["node"].name)
					var to_port = slot_info["port_idx"]
					
					if from_node != to_node:
						var already = false
						for conn in graph_edit.get_connection_list():
							if str(conn["from_node"]) == from_node and conn["from_port"] == from_port and str(conn["to_node"]) == to_node and conn["to_port"] == to_port:
								already = true
								break
						if not already:
							graph_edit.connect_node(from_node, from_port, to_node, to_port)
							is_modified = true
							_save_history_state()
					graph_edit.queue_redraw()
					get_viewport().set_input_as_handled()
					return
			
			if not slot_info and multi_active:
				_clear_multi_source()

func _clear_multi_source() -> void:
	multi_source = {}
	multi_active = false
	preview_line_end = Vector2.ZERO
	graph_edit.queue_redraw()

func _rebuild_context_menu() -> void:
	if not context_menu:
		return
		
	context_menu.clear()
	for child in context_menu.get_children():
		if child is PopupMenu:
			child.queue_free()
			
	for cat_key in Definitions.keys():
		var category = Definitions[cat_key]
		var submenu = PopupMenu.new()
		submenu.name = "SubMenu_" + cat_key
		
		var local_id = 0
		
		for block_id in category["blocks"].keys():
			var block_def = category["blocks"][block_id]
			submenu.add_item(block_def["title"], local_id)
			submenu.set_item_metadata(local_id, block_id)
			local_id += 1
			
		if cat_key == "functions":
			var def_nodes = _find_all_func_def_nodes()
			if not def_nodes.is_empty():
				submenu.add_separator()
				local_id += 1
				for def_node in def_nodes:
					var func_name = _get_func_node_name(def_node)
					submenu.add_item("Call " + func_name, local_id)
					submenu.set_item_metadata(local_id, "call_node:" + str(def_node.get_path()))
					local_id += 1
					
		submenu.index_pressed.connect(func(idx: int):
			var meta = submenu.get_item_metadata(idx)
			_spawn_from_menu(meta)
		)
		
		context_menu.add_child(submenu)
		context_menu.add_submenu_node_item(category["title"], submenu)

func _spawn_from_menu(meta) -> void:
	if meta == null:
		push_error("Error: Metadata is null!")
		return
		
	var center_pos = (graph_edit.scroll_offset + (graph_edit.size / 2)) / graph_edit.zoom
	var spawn_pos = context_menu.get_meta("spawn_pos", center_pos)
	var new_node: GraphNode = null
	var meta_str = str(meta)
	
	if meta_str.begins_with("call_node:"):
		var node_path_str = meta_str.replace("call_node:", "")
		var def_node = get_node_or_null(node_path_str) as GraphNode
		
		if is_instance_valid(def_node):
			new_node = build_func_call_from_def(def_node)
		else:
			push_error("Error: Could not find definition node at path: " + node_path_str)
	else:
		new_node = build_block(meta_str)
		
	if new_node:
		graph_edit.add_child(new_node)
		new_node.position_offset = spawn_pos
		is_modified = true
		_save_history_state()

func build_func_call_from_def(def_node: GraphNode) -> GraphNode:
	if not is_instance_valid(def_node):
		return GraphNode.new()
		
	var func_name = _get_func_node_name(def_node)
	
	var node = GraphNode.new()
	node.title = "Call " + func_name
	node.name = "call_" + func_name + "_" + str(randi() % 10000)
	
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.8, 0.2, 0.5)
	node.add_theme_stylebox_override("titlebar", style)
	
	var row0 = HBoxContainer.new()
	var lbl = Label.new()
	lbl.text = "Execute"
	row0.add_child(lbl)
	node.add_child(row0)
	node.set_slot(0, true, 0, Color.WHITE, true, 0, SlotColors[0])
	
	var return_type = _get_func_return_type(def_node)
	var slot_idx = 1
	for child in def_node.get_children():
		if child.name.begins_with("param_row_"):
			var p_name_edit = child.get_node_or_null("param_name") as LineEdit
			var p_type_picker = child.get_node_or_null("type_picker") as OptionButton
			
			if p_name_edit and p_type_picker:
				var p_name = p_name_edit.text
				var slot_type = p_type_picker.get_selected_id()
				
				var row = HBoxContainer.new()
				var p_lbl = Label.new()
				p_lbl.text = p_name + ":"
				row.add_child(p_lbl)
				
				match slot_type:
					1:
						var sb = SpinBox.new()
						sb.allow_greater = true
						sb.allow_lesser = true
						sb.name = "input"
						row.add_child(sb)
					2:
						var cb = CheckBox.new()
						cb.name = "input"
						row.add_child(cb)
					3:
						var le = LineEdit.new()
						le.placeholder_text = "0,0,0"
						le.name = "input"
						row.add_child(le)
						
				node.add_child(row)
				node.set_slot(slot_idx, true, slot_type, SlotColors[slot_type], false, 0, Color.WHITE)
				slot_idx += 1
	
	if return_type != 0:
		var return_row = HBoxContainer.new()
		return_row.name = "return_row"
		var return_label = Label.new()
		return_label.text = "Return"
		return_row.add_child(return_label)
		node.add_child(return_row)
		node.set_slot(slot_idx, false, 0, Color.WHITE, true, return_type, SlotColors[return_type])
	
	return node

func _find_all_func_def_nodes() -> Array[GraphNode]:
	var list: Array[GraphNode] = []
	for child in graph_edit.get_children():
		if child is GraphNode and child.has_meta("block_id"):
			if child.get_meta("block_id") == "func_def":
				list.append(child)
	return list

func _get_func_node_name(def_node: GraphNode) -> String:
	var name_edit = def_node.get_node_or_null("row_0/input") as LineEdit
	if name_edit and name_edit.text.strip_edges() != "":
		return name_edit.text
	return "my_function"

func spawn_block(block_id: String) -> void:
	var new_node = build_block(block_id)
	graph_edit.add_child(new_node)
	new_node.position_offset = (graph_edit.scroll_offset + (graph_edit.size / 2)) / graph_edit.zoom
	is_modified = true
	_save_history_state()

func build_block(block_id: String) -> GraphNode:
	var def = {}
	var category_color = Color.DARK_GRAY
	
	for cat_key in Definitions.keys():
		if block_id in Definitions[cat_key]["blocks"]:
			def = Definitions[cat_key]["blocks"][block_id]
			category_color = Definitions[cat_key].get("color", Color.DARK_GRAY)
			break
			
	if def.is_empty():
		push_error("Block definition not found for: " + block_id)
		return GraphNode.new()
		
	var node = GraphNode.new()
	node.title = def["title"]
	node.name = block_id + "_" + str(randi() % 10000) 
	node.set_meta("block_id", block_id)
	
	var style = StyleBoxFlat.new()
	style.bg_color = category_color
	node.add_theme_stylebox_override("titlebar", style)

	var row_index = 0
	
	for row_def in def["rows"]:
		var row_container = HBoxContainer.new()
		row_container.name = "row_" + str(row_index)
		
		if "label" in row_def:
			var label = Label.new()
			label.text = row_def["label"]
			row_container.add_child(label)
			
		var input_control = null
		if "input_type" in row_def:
			match row_def["input_type"]:
				"number":
					input_control = SpinBox.new()
					input_control.value = row_def.get("default", 0)
					input_control.allow_greater = true
					input_control.allow_lesser = true
				"line_edit":
					input_control = LineEdit.new()
					input_control.text = row_def.get("default_text", "")
					input_control.expand_to_text_length = true
				"dropdown":
					input_control = OptionButton.new()
					var filter = row_def.get("device_filter", "")
					input_control.get_popup().about_to_popup.connect(func(): _refresh_dropdown(input_control, filter, node))
					_refresh_dropdown(input_control, filter, node)
				"custom_dropdown":
					input_control = OptionButton.new()
					for opt_name in row_def.get("options", []):
						input_control.add_item(opt_name)
				"controller_capture":
					input_control = Button.new()
					input_control.text = "Press a button..."
					input_control.toggle_mode = true
					input_control.name = "input"
					input_control.set_meta("captured_button", -1)
					input_control.set_meta("captured_button_name", "")
					input_control.pressed.connect(_on_controller_capture_pressed.bind(input_control))
				"return_type_dropdown":
					input_control = OptionButton.new()
					input_control.name = "input"
					input_control.add_item("None", 0)
					input_control.add_item("Number", 1)
					input_control.add_item("Boolean", 2)
					input_control.add_item("Vector3", 3)
					input_control.item_selected.connect(func(idx: int):
						var slot_type = input_control.get_item_id(idx)
						if slot_type == 0:
							node.set_slot(2, false, 0, Color.WHITE, true, 0, SlotColors[0])
							node.set_slot(3, false, 0, Color.WHITE, false, 0, Color.WHITE)
						else:
							node.set_slot(2, false, 0, Color.WHITE, true, 0, SlotColors[0])
							node.set_slot(3, false, 0, Color.WHITE, true, slot_type, SlotColors[slot_type])
					)
				"none":
					input_control = null

		if input_control:
			input_control.name = "input"
			row_container.add_child(input_control)
			
		node.add_child(row_container)
		
		var enable_left = row_def.has("slot_in")
		var type_left = row_def.get("slot_in", 0)
		var color_left = SlotColors.get(type_left, Color.WHITE)
		
		var enable_right = row_def.has("slot_out")
		var type_right = row_def.get("slot_out", 0)
		var color_right = SlotColors.get(type_right, Color.WHITE)
		
		node.set_slot(row_index, enable_left, type_left, color_left, enable_right, type_right, color_right)
		row_index += 1
	
	if def.get("is_function_def", false):
		node.set_meta("block_id", "func_def")
		var return_row = HBoxContainer.new()
		return_row.name = "return_row"
		var return_label = Label.new()
		return_label.text = "Return Value"
		return_row.add_child(return_label)
		node.add_child(return_row)
		node.set_slot(3, false, 0, Color.WHITE, true, 0, Color.WHITE)
		
		var btn_container = HBoxContainer.new()
		var add_btn = Button.new()
		add_btn.text = "+ Add Param"
		add_btn.pressed.connect(func(): _add_param_to_func_def(node))
		var rem_btn = Button.new()
		rem_btn.text = "- Remove"
		rem_btn.pressed.connect(func(): _remove_param_from_func_def(node))
		btn_container.add_child(add_btn)
		btn_container.add_child(rem_btn)
		node.add_child(btn_container)
	
	return node

func _add_param_to_func_def(node: GraphNode) -> void:
	var param_count = node.get_meta("param_count", 0) + 1
	node.set_meta("param_count", param_count)
	
	var row_index = node.get_child_count() - 1
	var row = HBoxContainer.new()
	row.name = "param_row_" + str(param_count)
	
	var name_edit = LineEdit.new()
	name_edit.text = "arg" + str(param_count)
	name_edit.expand_to_text_length = true
	name_edit.name = "param_name"
	
	var type_picker = OptionButton.new()
	type_picker.name = "type_picker"
	type_picker.add_item("Float", 1)
	type_picker.add_item("Boolean", 2)
	type_picker.add_item("Vector3", 3)
	
	var current_row_idx = row_index
	type_picker.item_selected.connect(func(index: int):
		var slot_type = type_picker.get_item_id(index)
		var slot_color = SlotColors.get(slot_type, Color.WHITE)
		node.set_slot(current_row_idx, false, 0, Color.WHITE, true, slot_type, slot_color)
	)
	
	row.add_child(name_edit)
	row.add_child(type_picker)
	
	node.add_child(row)
	node.move_child(row, row_index)
	
	node.set_slot(row_index, false, 0, Color.WHITE, true, 1, SlotColors[1])

func _remove_param_from_func_def(node: GraphNode) -> void:
	var param_count = node.get_meta("param_count", 0)
	if param_count <= 0:
		return
		
	node.set_meta("param_count", param_count - 1)
	var row_index = node.get_child_count() - 2
	var target_row = node.get_child(row_index)
	
	_clear_connections_for_slot(node.name, row_index)
	node.clear_slot(row_index)
	target_row.queue_free()

func _clear_connections_for_slot(node_name: StringName, slot_idx: int) -> void:
	var node = _get_graph_node(node_name)
	if not node: return
	
	for connection in graph_edit.get_connection_list():
		var match_from = (connection["from_node"] == node_name and node.get_output_port_slot(connection["from_port"]) == slot_idx)
		var match_to = (connection["to_node"] == node_name and node.get_input_port_slot(connection["to_port"]) == slot_idx)
		
		if match_from or match_to:
			graph_edit.disconnect_node(connection["from_node"], connection["from_port"], connection["to_node"], connection["to_port"])

func _refresh_dropdown(opt: OptionButton, filter: String, node: GraphNode = null) -> void:
	opt.clear()
	
	if filter == "function":
		var found_funcs = []
		for child in graph_edit.get_children():
			if child is GraphNode and child.has_meta("block_id"):
				if child.get_meta("block_id") == "func_def":
					var name_edit = child.get_node_or_null("row_0/input")
					if name_edit and name_edit.text.strip_edges() != "":
						found_funcs.append({"name": name_edit.text, "node": child})
						
		if found_funcs.is_empty():
			opt.add_item("No Functions Found")
			opt.disabled = true
		else:
			opt.disabled = false
			var idx = 0
			for fn in found_funcs:
				opt.add_item(fn["name"], idx)
				opt.set_item_metadata(idx, fn["node"])
				idx += 1

			if node != null:
				if not opt.item_selected.is_connected(_on_func_call_selected.bind(opt, node)):
					opt.item_selected.connect(_on_func_call_selected.bind(opt, node))
				_sync_call_node_params(node, opt)
		return
	
	if filter == "controller_axis":
		var axes = {
			"Left Stick X": 0, "Left Stick Y": 1, "Right Stick X": 2,
			"Right Stick Y": 3, "Left Trigger": 4, "Right Trigger": 5
		}
		for axis_name in axes.keys():
			opt.add_item(axis_name)
			opt.set_item_metadata(opt.item_count - 1, axes[axis_name])
		opt.disabled = false
		return
	
	var max_ports = 16 
	for i in range(1, max_ports + 1):
		var display_text = filter.capitalize() + " Port " + str(i)
		opt.add_item(display_text)
		opt.set_item_metadata(opt.get_item_count() - 1, i)
		
	opt.disabled = false

func _on_func_call_selected(index: int, opt: OptionButton, call_node: GraphNode) -> void:
	_sync_call_node_params(call_node, opt)

func _sync_call_node_params(call_node: GraphNode, opt: OptionButton) -> void:
	if opt.get_item_count() == 0 or opt.disabled:
		return
		
	var selected_idx = opt.get_selected_id()
	if selected_idx == -1:
		selected_idx = 0
		
	var def_node = opt.get_item_metadata(selected_idx) as GraphNode
	if not is_instance_valid(def_node):
		return
		
	for i in range(call_node.get_child_count() - 1, 1, -1):
		var child = call_node.get_child(i)
		_clear_connections_for_slot(call_node.name, i)
		call_node.clear_slot(i)
		child.queue_free()

	var param_index = 2
	
	for child in def_node.get_children():
		if child.name.begins_with("param_row_"):
			var param_name_node = child.get_node_or_null("param_name") as LineEdit
			var type_picker_node = child.get_node_or_null("type_picker") as OptionButton
			
			if param_name_node and type_picker_node:
				var p_name = param_name_node.text
				var slot_type = type_picker_node.get_selected_id()
				
				var row = HBoxContainer.new()
				row.name = "call_param_" + str(param_index)
				
				var label = Label.new()
				label.text = p_name + ":"
				row.add_child(label)
				
				match slot_type:
					1:
						var sb = SpinBox.new()
						sb.allow_greater = true
						sb.allow_lesser = true
						sb.name = "input"
						row.add_child(sb)
					2:
						var cb = CheckBox.new()
						cb.text = "True/False"
						cb.name = "input"
						row.add_child(cb)
					3:
						var v_edit = LineEdit.new()
						v_edit.placeholder_text = "0, 0, 0"
						v_edit.name = "input"
						row.add_child(v_edit)
				
				call_node.add_child(row)
				var slot_color = SlotColors.get(slot_type, Color.WHITE)
				call_node.set_slot(param_index, true, slot_type, slot_color, false, 0, Color.WHITE)
				param_index += 1

func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	graph_edit.connect_node(from_node, from_port, to_node, to_port)
	is_modified = true
	_save_history_state()

func _on_disconnection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	graph_edit.disconnect_node(from_node, from_port, to_node, to_port)
	is_modified = true
	_save_history_state()

func delete_selected_nodes() -> void:
	for child in graph_edit.get_children():
		if child is GraphNode and child.selected:
			_clear_connections_for_node(child.name)
			child.queue_free()
			is_modified = true
	_save_history_state()

func _clear_connections_for_node(node_name: StringName) -> void:
	for connection in graph_edit.get_connection_list():
		if connection["from_node"] == node_name or connection["to_node"] == node_name:
			graph_edit.disconnect_node(connection["from_node"], connection["from_port"], connection["to_node"], connection["to_port"])

func _process(_delta: float) -> void:
	if !visible:
		return
	
	$HBoxContainer/save.disabled = current_filename == ""
	$prog_name.text = "Untitled"
	if current_filename != "":
		$prog_name.text = current_filename.replace(".json", "")
	
	if is_modified:
		$prog_name.text += " *"

func _on_save_pressed() -> void:
	if current_filename != "":
		_save_program(current_filename)
	else:
		_on_save_as_pressed()

func _on_load_pressed() -> void:
	can_edit = false
	$load.visible = true
	selected_load_file = ""
	_refresh_load_list()

func _on_save_as_pressed() -> void:
	can_edit = false
	$save.visible = true
	$save/VBoxContainer/LineEdit.text = current_filename.replace(".json", "")

func _on_confirm_save_pressed() -> void:
	var name_input = $save/VBoxContainer/LineEdit
	if name_input and name_input.text.strip_edges() != "":
		var filename = name_input.text.strip_edges()
		if not filename.ends_with(".json"):
			filename += ".json"
		
		var full_path = SAVE_DIR + filename
		if FileAccess.file_exists(full_path):
			$ask_save.visible = true
			$ask_save/VBoxContainer/Label.text = "File already exists. Overwrite?"
			$ask_save.set_meta("pending_filename", filename)
			$ask_save.set_meta("pending_action", "save")
		else:
			_save_program(filename)
			current_filename = filename
			_close_save_panel()

func _on_confirm_save_yes_pressed() -> void:
	var filename = $ask_save.get_meta("pending_filename", "")
	var action = $ask_save.get_meta("pending_action", "save")
	
	if filename != "" or action == "new":
		match action:
			"save":
				_save_program(filename)
				current_filename = filename
				_close_save_panel()
			"overwrite":
				_save_program(filename)
				current_filename = filename
				_close_load_panel()
			"load":
				if current_filename != "":
					_save_program(current_filename)
				_do_load_program(pending_load_meta)
				_close_load_panel()
			"delete":
				_delete_program(filename)
				_refresh_load_list()
				selected_load_file = ""
				_update_load_buttons()
			"new":
				_do_new_program()
	
	$ask_save.visible = false

func _on_confirm_save_no_pressed() -> void:
	var action = $ask_save.get_meta("pending_action", "")
	var filename = $ask_save.get_meta("pending_filename", "")
	
	match action:
		"load":
			_do_load_program(pending_load_meta)
			_close_load_panel()
		"new":
			_do_new_program()
	
	$ask_save.visible = false

var selected_load_full_path: String = ""
var selected_load_is_preset: bool = false
var selected_load_json: String = ""

func _on_item_list_item_selected(index: int) -> void:
	var item_list = $load/VBoxContainer/ItemList
	if item_list:
		var meta = item_list.get_item_metadata(index)
		if meta is Dictionary:
			selected_load_file = meta["filename"]
			selected_load_full_path = meta.get("full_path", "")
			selected_load_is_preset = meta.get("is_preset", false)
			selected_load_json = meta.get("json_data", "")
			pending_load_meta = meta
		else:
			var filename = meta as String
			if filename == null or filename == "":
				filename = item_list.get_item_text(index) + ".json"
			selected_load_file = filename
			selected_load_full_path = SAVE_DIR + filename
			selected_load_is_preset = false
			selected_load_json = ""
			pending_load_meta = {
				"filename": filename,
				"is_preset": false,
				"full_path": selected_load_full_path,
				"json_data": ""
			}
		_update_load_buttons()

func _save_program(filename: String) -> void:
	is_modified = false
	var dir = DirAccess.open("user://")
	if not dir.dir_exists(SAVE_DIR):
		dir.make_dir_recursive(SAVE_DIR)
	
	var full_path = SAVE_DIR + filename
	var data = _get_graph_state()
	
	data["version"] = "1.0"
	data["filename"] = filename
	
	var file = FileAccess.open(full_path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, "\t"))
		file.close()
		program_saved.emit(full_path)
	else:
		push_error("Failed to save: " + full_path)

func _get_func_return_type(def_node: GraphNode) -> int:
	var row = def_node.get_node_or_null("row_1")
	if row:
		var dropdown = row.get_node_or_null("input")
		if dropdown is OptionButton:
			return dropdown.get_item_id(dropdown.selected)
	return 0 

func _save_row_data(row: HBoxContainer) -> Dictionary:
	var row_data = {"name": str(row.name), "values": {}}
	
	for child in row.get_children():
		if child.name == "input":
			if child is LineEdit:
				row_data["values"]["type"] = "LineEdit"
				row_data["values"]["text"] = child.text
			elif child is SpinBox:
				row_data["values"]["type"] = "SpinBox"
				row_data["values"]["value"] = child.value
			elif child is CheckBox:
				row_data["values"]["type"] = "CheckBox"
				row_data["values"]["pressed"] = child.button_pressed
			elif child is OptionButton:
				row_data["values"]["type"] = "OptionButton"
				row_data["values"]["selected"] = child.selected
				row_data["values"]["text"] = child.text
			elif child is Button and child.name == "input" and child.has_meta("captured_button"):
				row_data["values"]["type"] = "ControllerCapture"
				row_data["values"]["text"] = child.text
				row_data["values"]["button_index"] = child.get_meta("captured_button", -1)
				row_data["values"]["button_name"] = child.get_meta("captured_button_name", "")
	
	return row_data

func _load_program(filename: String) -> void:
	_load_program_from_path(SAVE_DIR + filename)

func _load_program_from_path(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var file = FileAccess.open(path, FileAccess.READ)
	if not file: return
	var json_string = file.get_as_text()
	file.close()
	_load_program_from_json(json_string)

func _load_program_from_json(json_string: String) -> void:
	var json = JSON.new()
	var error = json.parse(json_string)
	if error != OK:
		push_error("Invalid JSON data")
		return
	var data = json.get_data()
	_apply_graph_state(data)
	is_modified = false
	program_loaded.emit("")

func _restore_row_values(row: HBoxContainer, values: Dictionary) -> void:
	for child in row.get_children():
		if child.name == "input":
			match values.get("type", ""):
				"LineEdit":
					if child is LineEdit: child.text = values.get("text", "")
				"SpinBox":
					if child is SpinBox: child.value = values.get("value", 0)
				"CheckBox":
					if child is CheckBox: child.button_pressed = values.get("pressed", false)
				"OptionButton":
					if child is OptionButton: child.selected = values.get("selected", 0)
				"ControllerCapture":
					if child is Button:
						var button_idx = values.get("button_index", -1)
						var button_name = values.get("button_name", "")
						child.set_meta("captured_button", button_idx)
						child.set_meta("captured_button_name", button_name)
						child.text = values.get("text", "Press a button...")

func _clear_graph() -> void:
	graph_edit.clear_connections()
	for child in graph_edit.get_children():
		if child is GraphNode:
			graph_edit.remove_child(child)
			child.queue_free()

func _close_save_panel() -> void:
	$save.visible = false
	can_edit = true

func _close_load_panel() -> void:
	$load.visible = false
	can_edit = true

func _refresh_load_list() -> void:
	var item_list = $load/VBoxContainer/ItemList
	if item_list:
		item_list.clear()
		
		var dir = DirAccess.open(SAVE_DIR)
		if dir:
			dir.list_dir_begin()
			var file_name = dir.get_next()
			while file_name != "":
				if not dir.current_is_dir() and file_name.ends_with(".json") and not file_name.begins_with("."):
					var display_name = file_name.replace(".json", "")
					if not ProgramPresets.has(display_name):
						item_list.add_item(display_name)
						item_list.set_item_metadata(item_list.item_count - 1, {
							"filename": file_name,
							"is_preset": false,
							"full_path": SAVE_DIR + file_name,
							"json_data": ""
						})
				file_name = dir.get_next()
			dir.list_dir_end()
		
		for preset_name in ProgramPresets.keys():
			var json_res: JSON = ProgramPresets[preset_name]
			if not json_res:
				continue
			item_list.add_item("[Preset] " + preset_name)
			item_list.set_item_metadata(item_list.item_count - 1, {
				"filename": preset_name + ".json",
				"is_preset": true,
				"full_path": "",
				"json_data": JSON.stringify(json_res.data)
			})
		
		if item_list.item_count == 0:
			item_list.add_item("No saved programs or presets found")
			item_list.set_item_disabled(0, true)
	_update_load_buttons()

func _update_load_buttons() -> void:
	var load_btn = $load/VBoxContainer/HBoxContainer/load_btn
	var overwrite_btn = $load/VBoxContainer/HBoxContainer/overwrite_btn
	var delete_btn = $load/VBoxContainer/HBoxContainer/delete_btn
	var has_selection = selected_load_file != "" and not selected_load_file.begins_with("No saved") and not selected_load_file.begins_with("Error")
	
	load_btn.disabled = not has_selection
	overwrite_btn.disabled = not has_selection or selected_load_is_preset
	delete_btn.disabled = not has_selection or selected_load_is_preset

func _delete_program(filename: String) -> void:
	var full_path = SAVE_DIR + filename
	if FileAccess.file_exists(full_path):
		var dir = DirAccess.open(SAVE_DIR)
		if dir:
			dir.remove(filename)
			if current_filename == filename:
				current_filename = ""
				is_modified = true

func _on_program_load_pressed() -> void:
	if selected_load_file == "": return
	if is_modified:
		$ask_save.visible = true
		$ask_save/VBoxContainer/Label.text = "Save current program before loading?"
		$ask_save.set_meta("pending_filename", selected_load_file)
		$ask_save.set_meta("pending_action", "load")
	else:
		_do_load_program(pending_load_meta)
		_close_load_panel()

func _do_load_program(meta: Dictionary) -> void:
	if meta.is_empty():
		return
	if meta.get("is_preset", false):
		var json_str = meta.get("json_data", "")
		if json_str != "":
			_load_program_from_json(json_str)
			current_filename = meta.get("filename", "")
		else:
			push_error("Preset has no JSON data")
	else:
		var path = meta.get("full_path", "")
		if path != "":
			_load_program_from_path(path)
			current_filename = meta.get("filename", "")

func _on_program_save_pressed() -> void:
	if selected_load_file == "" or selected_load_is_preset: return
	$ask_save.visible = true
	$ask_save/VBoxContainer/Label.text = "Overwrite '" + selected_load_file.replace(".json", "") + "' with current program?"
	$ask_save.set_meta("pending_filename", selected_load_file)
	$ask_save.set_meta("pending_action", "overwrite")

func _on_program_delete_pressed() -> void:
	if selected_load_file == "" or selected_load_is_preset: return
	$ask_save.visible = true
	$ask_save/VBoxContainer/Label.text = "Delete '" + selected_load_file.replace(".json", "") + "' permanently?"
	$ask_save.set_meta("pending_filename", selected_load_file)
	$ask_save.set_meta("pending_action", "delete")

func _on_controller_capture_pressed(button: Button) -> void:
	if active_controller_capture_button and active_controller_capture_button != button:
		active_controller_capture_button.button_pressed = false
		active_controller_capture_button.text = "Press a button..."
	if button.button_pressed:
		active_controller_capture_button = button
		button.text = "Listening..."
	else:
		if active_controller_capture_button == button:
			active_controller_capture_button = null
		var captured_name = button.get_meta("captured_button_name", "")
		if captured_name != "":
			button.text = captured_name

func _handle_controller_capture(event: InputEvent) -> void:
	if not active_controller_capture_button: return
	var captured = false
	var button_name = ""
	
	if event is InputEventKey and event.pressed:
		button_name = OS.get_keycode_string(event.keycode)
		captured = true
	elif event is InputEventJoypadButton and event.pressed:
		button_name = "JoyBtn " + str(event.button_index)
		captured = true
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT: button_name = "Mouse Left"
			MOUSE_BUTTON_RIGHT: button_name = "Mouse Right"
			MOUSE_BUTTON_MIDDLE: button_name = "Mouse Middle"
			MOUSE_BUTTON_WHEEL_UP: button_name = "Mouse Wheel Up"
			MOUSE_BUTTON_WHEEL_DOWN: button_name = "Mouse Wheel Down"
			_: button_name = "Mouse " + str(event.button_index)
		captured = true
	
	if captured:
		active_controller_capture_button.set_meta("captured_button", button_name)
		active_controller_capture_button.set_meta("captured_button_name", button_name)
		active_controller_capture_button.text = button_name
		active_controller_capture_button.button_pressed = false
		active_controller_capture_button = null
		is_modified = true

func _get_graph_node(name: StringName) -> GraphNode:
	for child in graph_edit.get_children():
		if child is GraphNode and child.name == name:
			return child
	return null

func _point_to_line_distance(point: Vector2, line_start: Vector2, line_end: Vector2) -> float:
	var line = line_end - line_start
	var len = line.length()
	if len == 0:
		return point.distance_to(line_start)
	
	var t = clamp(((point - line_start).dot(line) / (len * len)), 0.0, 1.0)
	var projection = line_start + t * line
	return point.distance_to(projection)

func _get_graph_state() -> Dictionary:
	var data = {
		"nodes": [],
		"connections": graph_edit.get_connection_list()
	}
	
	for child in graph_edit.get_children():
		if child is GraphNode:
			var node_data = {
				"name": child.name,
				"title": child.title,
				"position_offset": {
					"x": child.position_offset.x,
					"y": child.position_offset.y
				},
				"block_id": child.get_meta("block_id", ""),
				"rows": []
			}
			
			for row in child.get_children():
				if row is HBoxContainer and (row.name.begins_with("row_") or row.name.begins_with("param_row_") or row.name.begins_with("call_param_")):
					var row_data = _save_row_data(row)
					if row_data:
						node_data["rows"].append(row_data)
			
			data["nodes"].append(node_data)
	return data

func _apply_graph_state(data: Dictionary) -> void:
	saving_history = true
	_clear_graph()
	
	for node_data in data["nodes"]:
		var node = build_block(node_data["block_id"])
		if node:
			node.name = str(node_data["name"])
			node.position_offset = Vector2(
				node_data["position_offset"]["x"],
				node_data["position_offset"]["y"]
			)
			for row_data in node_data["rows"]:
				var row = node.get_node_or_null(str(row_data["name"]))
				if row and row_data.has("values"):
					_restore_row_values(row, row_data["values"])
			graph_edit.add_child(node)
	
	for conn in data["connections"]:
		var from_node_str = str(conn["from_node"])
		var to_node_str = str(conn["to_node"])
		if graph_edit.has_node(from_node_str) and graph_edit.has_node(to_node_str):
			graph_edit.connect_node(from_node_str, conn["from_port"], to_node_str, conn["to_port"])
			
	saving_history = false

func _save_history_state() -> void:
	if saving_history: return
	
	if history_index < history_stack.size() - 1:
		history_stack.resize(history_index + 1)
		
	history_stack.append(_get_graph_state())
	
	if history_stack.size() > 50:
		history_stack.pop_front()
	else:
		history_index += 1

func undo() -> void:
	if history_index > 0:
		history_index -= 1
		_apply_graph_state(history_stack[history_index])
		is_modified = true

func redo() -> void:
	if history_index < history_stack.size() - 1:
		history_index += 1
		_apply_graph_state(history_stack[history_index])
		is_modified = true

func _slot_to_port_index(node: GraphNode, target_slot: int, is_output: bool) -> int:
	var port_idx = 0
	for i in range(target_slot):
		if is_output:
			if node.is_slot_enabled_right(i):
				port_idx += 1
		else:
			if node.is_slot_enabled_left(i):
				port_idx += 1
	return port_idx

func _get_port_screen_pos(node_name: StringName, port_idx: int, is_output: bool) -> Vector2:
	var node = _get_graph_node(node_name)
	if not node: return Vector2.ZERO
	
	var port_local = node.get_output_port_position(port_idx) if is_output else node.get_input_port_position(port_idx)
	return node.position + (port_local * graph_edit.zoom)

func _get_slot_at_screen_position(screen_pos: Vector2) -> Dictionary:
	var threshold = 24.0
	for child in graph_edit.get_children():
		if child is GraphNode:
			for port_idx in range(child.get_output_port_count()):
				var port_pos = _get_port_screen_pos(child.name, port_idx, true)
				if screen_pos.distance_to(port_pos) < threshold:
					return {"node": child, "port_idx": port_idx, "row_idx": child.get_output_port_slot(port_idx), "is_output": true}
			
			for port_idx in range(child.get_input_port_count()):
				var port_pos = _get_port_screen_pos(child.name, port_idx, false)
				if screen_pos.distance_to(port_pos) < threshold:
					return {"node": child, "port_idx": port_idx, "row_idx": child.get_input_port_slot(port_idx), "is_output": false}
	return {}

func _get_connection_at_screen_position(screen_pos: Vector2) -> Dictionary:
	var closest_dist = 24.0 
	var closest_conn = {}
	
	for conn in graph_edit.get_connection_list():
		var start = _get_port_screen_pos(conn["from_node"], conn["from_port"], true)
		var end = _get_port_screen_pos(conn["to_node"], conn["to_port"], false)
		
		var dist = _point_to_bezier_distance(screen_pos, start, end)
		if dist < closest_dist:
			closest_dist = dist
			closest_conn = conn
	
	return closest_conn

func _on_graph_edit_draw() -> void:
	if not multi_active or multi_source.is_empty():
		return
	
	var start_screen = _get_port_screen_pos(multi_source["node"], multi_source["port_idx"], true)
	var end_screen = preview_line_end 
	
	graph_edit.draw_line(start_screen, end_screen, Color.YELLOW, 3.0 * graph_edit.zoom)

func _point_to_bezier_distance(point: Vector2, start: Vector2, end: Vector2) -> float:
	var min_dist = INF
	var steps = 15 
	var tension = abs(end.x - start.x) * 0.5
	var p0 = start
	var p1 = start + Vector2(tension, 0)
	var p2 = end - Vector2(tension, 0)
	var p3 = end
	
	var prev_point = p0
	for i in range(1, steps + 1):
		var t = i / float(steps)
		var q0 = p0.lerp(p1, t)
		var q1 = p1.lerp(p2, t)
		var q2 = p2.lerp(p3, t)
		var r0 = q0.lerp(q1, t)
		var r1 = q1.lerp(q2, t)
		var current_point = r0.lerp(r1, t)
		
		var dist = _point_to_line_distance(point, prev_point, current_point)
		if dist < min_dist:
			min_dist = dist
		prev_point = current_point
		
	return min_dist

func _on_new_pressed() -> void:
	if is_modified:
		$ask_save.visible = true
		$ask_save/VBoxContainer/Label.text = "Discard current program and start new?"
		$ask_save.set_meta("pending_action", "new")
	else:
		_do_new_program()

func _do_new_program() -> void:
	_clear_graph()
	history_stack.clear()
	history_index = -1
	current_filename = ""
	is_modified = false
	selected_load_file = ""
	_save_history_state()