class_name BlockRuntime
extends RefCounted

var robot
var is_running: bool = false
var program_data: Dictionary = {}
var active_threads: Array = []
var node_cache: Dictionary = {}
var port_mapping: Dictionary = {}
var button_previous_state: Dictionary = {}

class ExecutionThread:
	var current_node: String
	var wait_timer: float = 0.0
	var waiting_motor_id: int = -1
	var loop_iterations: int = 0
	var max_iterations: int = 0
	var loop_type: String = ""
	var loop_condition_node: String = ""
	var parent_thread: ExecutionThread = null
	var is_complete: bool = false
	var event_type: String = ""
	var event_button: String = ""
	
	func _init(node: String = "") -> void:
		current_node = node

var _row_cache: Dictionary = {}
var _port_maps_cache: Dictionary = {}
var _warned_blocks: Dictionary = {}
var _loop_lists: Dictionary = {}
var _loop_values: Dictionary = {}

func _row(block_id: String, label: String) -> int:
	var key = block_id + ":" + label
	if _row_cache.has(key):
		return _row_cache[key]
	var idx = -1
	var def = _get_block_def(block_id)
	var rows = def.get("rows", [])
	for i in range(rows.size()):
		if rows[i].get("label", "") == label:
			idx = i
			break
	if idx == -1:
		push_warning("BlockRuntime: no row labeled '%s' on block '%s'" % [label, block_id])
	_row_cache[key] = idx
	return idx

func _get_port_maps(block_id: String) -> Dictionary:
	if _port_maps_cache.has(block_id):
		return _port_maps_cache[block_id]
	
	var def = _get_block_def(block_id)
	var rows = def.get("rows", [])
	var row_to_in := {}
	var row_to_out := {}
	var in_count := 0
	var out_count := 0
	
	for i in range(rows.size()):
		if rows[i].has("slot_in"):
			row_to_in[i] = in_count
			in_count += 1
		if rows[i].has("slot_out"):
			row_to_out[i] = out_count
			out_count += 1
	
	var maps = {"in": row_to_in, "out": row_to_out}
	_port_maps_cache[block_id] = maps
	return maps

func _in_port_by_row(block_id: String, row: int) -> int:
	if row == -1: return -1
	return _get_port_maps(block_id)["in"].get(row, -1)

func _out_port_by_row(block_id: String, row: int) -> int:
	if row == -1: return -1
	return _get_port_maps(block_id)["out"].get(row, -1)

func _in_port(block_id: String, label: String) -> int:
	return _in_port_by_row(block_id, _row(block_id, label))

func _out_port(block_id: String, label: String) -> int:
	return _out_port_by_row(block_id, _row(block_id, label))

func setup() -> void:
	pass

func load_from_file(file_path: String, ports: Dictionary = {}) -> void:
	port_mapping = ports
	
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		push_error("Failed to open program file: ", file_path)
		return
	
	var json_string = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var error = json.parse(json_string)
	
	if error != OK:
		push_error("Invalid JSON in program file: ", json.get_error_message())
		return
	
	program_data = json.get_data()
	_build_node_cache()
	_validate_program()
	start_program()

func _build_node_cache() -> void:
	node_cache.clear()
	if program_data.has("nodes"):
		for node in program_data["nodes"]:
			node_cache[node["name"]] = node

func start_program() -> void:
	active_threads.clear()
	is_running = true
	button_previous_state.clear()
	
	for node_name in node_cache:
		var node = node_cache[node_name]
		var block_id = node.get("block_id", "")
		if block_id in ["controller_button_pressed", "controller_button_released", "controller_button"]:
			var button_name = _get_button_name(node)
			if button_name != "" and not button_name in button_previous_state:
				button_previous_state[button_name] = _is_button_pressed(button_name)

func trigger_event(event_type: String) -> void:
	for node_name in node_cache:
		var node = node_cache[node_name]
		match node.get("block_id", ""):
			"base_ready":
				if event_type == "ready":
					_spawn_event_thread(node_name, "ready")
			"base_auton":
				if event_type == "auton":
					_spawn_event_thread(node_name, "auton")
			"base_driver":
				if event_type == "driver":
					_spawn_event_thread(node_name, "driver")

func process_input() -> void:
	if not is_running: return
	
	for node_name in node_cache:
		var node = node_cache[node_name]
		var block_id = node.get("block_id", "")
		
		match block_id:
			"controller_button_pressed":
				var button_name = _get_button_name(node)
				if button_name != "":
					var current = _is_button_pressed(button_name)
					var previous = button_previous_state.get(button_name, false)
					if current and not previous:
						_spawn_event_thread(node_name, "button_pressed", button_name)
					button_previous_state[button_name] = current
			"controller_button_released":
				var button_name = _get_button_name(node)
				if button_name != "":
					var current = _is_button_pressed(button_name)
					var previous = button_previous_state.get(button_name, false)
					if not current and previous:
						_spawn_event_thread(node_name, "button_released", button_name)
					button_previous_state[button_name] = current

func _spawn_event_thread(node_name: String, event_type: String, button_name: String = "") -> void:
	var thread = ExecutionThread.new(node_name)
	thread.event_type = event_type
	thread.event_button = button_name
	var child_threads = _spawn_execution_flow(node_name, 0, thread)
	for child in child_threads:
		active_threads.append(child)

func _get_button_name(node: Dictionary) -> String:
	for row in node.get("rows", []):
		var values = row.get("values", {})
		if values.get("type") == "ControllerCapture":
			return values.get("button_name", "")
	return ""

func _get_connections_from(from_node: String, from_port: int) -> Array:
	var result: Array = []
	for conn in program_data.get("connections", []):
		if conn["from_node"] == from_node and conn["from_port"] == from_port:
			result.append(conn)
	return result

func _get_connection_to(to_node: String, to_port: int) -> Dictionary:
	for conn in program_data.get("connections", []):
		if conn["to_node"] == to_node and conn["to_port"] == to_port:
			return conn
	return {}

func _get_input_value(node_name: String, row_idx: int, default_value = 0.0) -> Variant:
	var node = node_cache.get(node_name)
	if not node: return default_value
	
	var block_id = node.get("block_id", "")
	var in_port = _in_port_by_row(block_id, row_idx)
	
	if in_port != -1:
		var conn = _get_connection_to(node_name, in_port)
		if not conn.is_empty():
			return _evaluate_expression(conn["from_node"])
	
	var row_data = _get_row_for_index(node, row_idx)
	if row_data and row_data.has("values"):
		var values = row_data["values"]
		match values.get("type", ""):
			"SpinBox": return float(values.get("value", default_value))
			"CheckBox": return bool(values.get("pressed", false))
			"LineEdit": return values.get("text", "")
			"OptionButton": return int(values.get("selected", 0))
	
	return default_value

func _get_row_for_index(node: Dictionary, row_idx: int) -> Dictionary:
	var rows = node.get("rows", [])
	if row_idx >= 0 and row_idx < rows.size():
		return rows[row_idx]
	return {}

func _resolve_port_to_part_id(brain_port: int) -> int:
	if brain_port in port_mapping:
		return port_mapping[brain_port]
	return brain_port

func _evaluate_expression(node_name: String) -> Variant:
	var node = node_cache.get(node_name)
	if not node: return 0.0
	var block_id = node.get("block_id", "")
	var def = _get_block_def(block_id)
	if def.has("eval"):
		return def["eval"].call(self, node_name)
	if not _warned_blocks.has(block_id):
		_warned_blocks[block_id] = true
		push_warning("BlockRuntime: no 'eval' for expression block '%s'" % block_id)
	return 0.0

func _execute_node(thread: ExecutionThread, new_threads: Array) -> void:
	var node_name = thread.current_node
	var node = node_cache.get(node_name)
	if not node:
		thread.is_complete = true
		return
	var block_id = node.get("block_id", "")
	var def = _get_block_def(block_id)
	
	if def.has("action"):
		def["action"].call(self, node_name)
		new_threads.append_array(_spawn_execution_flow(node_name, _out_port(block_id, "Execute"), thread))
		thread.is_complete = true
		return

	if def.has("exec"):
		def["exec"].call(self, thread, new_threads)
		return
	if not _warned_blocks.has(block_id):
		_warned_blocks[block_id] = true
		push_warning("BlockRuntime: no handler for block '%s' - passing execution through" % block_id)
	var exec_port = _out_port(block_id, "Execute")
	new_threads.append_array(_spawn_execution_flow(node_name, exec_port if exec_port != -1 else 0, thread))
	thread.is_complete = true

func input(node_name: String, label, default = 0.0) -> Variant:
	var node = node_cache.get(node_name)
	if not node: return default
	var block_id = node.get("block_id", "")
	var row = label if label is int else _row(block_id, label)
	return _get_input_value(node_name, row, default)

func resolve_motor(node_name: String, label: String) -> int:
	return _resolve_port_to_part_id(int(input(node_name, label, 0)))

func resolve_piston(node_name: String, label: String) -> int:
	return _resolve_port_to_part_id(int(input(node_name, label, 0)))

func tick(delta: float) -> void:
	if not is_running: return
	
	var new_threads: Array = []
	
	for thread in active_threads:
		if thread.is_complete: continue
		
		if thread.waiting_motor_id != -1:
			if robot.is_motor_move_done(thread.waiting_motor_id):
				thread.waiting_motor_id = -1
				var block_id = node_cache.get(thread.current_node, {}).get("block_id", "")
				var exec_port = _out_port(block_id, "Execute")
				var child_threads = _spawn_execution_flow(thread.current_node, exec_port if exec_port != -1 else 0, thread)
				new_threads.append_array(child_threads)
				thread.is_complete = true
			else:
				new_threads.append(thread)
			continue
		
		if thread.wait_timer > 0:
			thread.wait_timer -= delta
			if thread.wait_timer <= 0:
				thread.wait_timer = 0
				var block_id = node_cache.get(thread.current_node, {}).get("block_id", "")
				var exec_port = _out_port(block_id, "Execute")
				var child_threads = _spawn_execution_flow(thread.current_node, exec_port if exec_port != -1 else 0, thread)
				new_threads.append_array(child_threads)
				thread.is_complete = true
			else:
				new_threads.append(thread)
			continue
		
		_execute_node(thread, new_threads)
		
		if not thread.is_complete:
			new_threads.append(thread)
	
	active_threads = new_threads

func _spawn_execution_flow(from_node: String, from_port: int, parent_thread: ExecutionThread) -> Array:
	var threads: Array = []
	var connections = _get_connections_from(from_node, from_port)
	for conn in connections:
		var child_thread = ExecutionThread.new(conn["to_node"])
		child_thread.parent_thread = parent_thread
		threads.append(child_thread)
	return threads

func _set_piston_extending(part_id: int, extending: bool) -> void:
	if robot and robot.pistons.has(part_id):
		if extending:
			robot.pistons[part_id].activate()
		else:
			robot.pistons[part_id].deactivate()

func _set_motor_velocity(part_id: int, speed: float) -> void:
	if robot and robot.motors.has(part_id):
		robot.motors[part_id].set_velocity(speed)
		robot.motors[part_id].spin()

func _stop_motor(part_id: int) -> void:
	if robot and robot.motors.has(part_id):
		robot.motors[part_id].set_velocity(0)
		robot.motors[part_id].brake()

func _set_motor_brake_mode(part_id: int, mode: String) -> void:
	if not robot or not robot.motors.has(part_id): return
	var motor = robot.motors[part_id]
	match mode.to_lower():
		"brake": motor.set_braking(robot.Motor.Brake.BRAKE)
		"coast": motor.set_braking(robot.Motor.Brake.COAST)
		"hold": motor.set_braking(robot.Motor.Brake.HOLD)

func _get_motor_degrees(part_id: int) -> float:
	if robot and robot.motors.has(part_id):
		var motor = robot.motors[part_id]
		if motor.axle: return rad_to_deg(motor.axle.rotation.z)
	return 0.0

func _get_motor_velocity_pct(part_id: int) -> float:
	if robot and robot.motors.has(part_id):
		var motor = robot.motors[part_id]
		if motor.axle:
			var max_rpm_rad = motor.rpm * PI / 30.0
			if max_rpm_rad > 0:
				return (motor.axle.angular_velocity.z / max_rpm_rad) * 100.0
	return 0.0

func _is_motor_done(part_id: int) -> bool:
	if robot and robot.motors.has(part_id):
		var motor = robot.motors[part_id]
		if motor.axle: return abs(motor.axle.angular_velocity.z) < 0.1
	return false

func _is_motor_spinning(part_id: int) -> bool:
	if robot and robot.motors.has(part_id):
		var motor = robot.motors[part_id]
		if motor.axle: return abs(motor.axle.angular_velocity.z) > 0.1
	return false

func _is_button_pressed(button_name: String) -> bool:
	if button_name.begins_with("JoyBtn "):
		var btn_idx = int(button_name.replace("JoyBtn ", ""))
		return Input.is_joy_button_pressed(0, btn_idx)
	
	if button_name.begins_with("Mouse "):
		var mouse_map = {
			"Mouse Left": MOUSE_BUTTON_LEFT,
			"Mouse Right": MOUSE_BUTTON_RIGHT,
			"Mouse Middle": MOUSE_BUTTON_MIDDLE,
			"Mouse Wheel Up": MOUSE_BUTTON_WHEEL_UP,
			"Mouse Wheel Down": MOUSE_BUTTON_WHEEL_DOWN,
		}
		if button_name in mouse_map:
			return Input.is_mouse_button_pressed(mouse_map[button_name])
	
	var keycode = OS.find_keycode_from_string(button_name)
	if keycode != KEY_NONE:
		return Input.is_key_pressed(keycode)
	
	for test_key in range(KEY_SPECIAL):
		if Input.is_key_pressed(test_key):
			var test_name = OS.get_keycode_string(test_key)
			if test_name == button_name:
				return true
	return false

func _get_controller_button(node_name: String) -> bool:
	var node = node_cache.get(node_name)
	if not node: return false
	for row in node.get("rows", []):
		var values = row.get("values", {})
		if values.get("type") == "ControllerCapture":
			return _is_button_pressed(values.get("button_name", ""))
	return false

func _get_controller_axis(node_name: String) -> float:
	var node = node_cache.get(node_name)
	if not node: return 0.0
	var rows = node.get("rows", [])
	if rows.size() > 0:
		var values = rows[0].get("values", {})
		if values.get("type") == "OptionButton":
			var axis_index = values.get("selected", 0)
			var axis_names = ["Left Stick X", "Left Stick Y", "Right Stick X", "Right Stick Y", "Left Trigger", "Right Trigger"]
			if axis_index < axis_names.size():
				if robot and robot.has_method("get_controller_input"):
					return robot.get_controller_input(axis_names[axis_index])
	return 0.0

func _get_option_text(node_name: String, row_index: int) -> String:
	var node = node_cache.get(node_name)
	if not node: return ""
	var rows = node.get("rows", [])
	if row_index < rows.size():
		return rows[row_index].get("values", {}).get("text", "")
	return ""

func _get_block_def(block_id: String) -> Dictionary:
	for cat in VisualCodeEditor.Definitions.values():
		if cat["blocks"].has(block_id):
			return cat["blocks"][block_id]
	return {}

func _validate_program() -> void:
	var issues := 0
	for node_name in node_cache:
		var node = node_cache[node_name]
		var block_id = node.get("block_id", "")
		var def = _get_block_def(block_id)
		if def.is_empty(): continue

		var rows = def.get("rows", [])
		var maps = _get_port_maps(block_id)

		var valid_out := {}
		var valid_in := {}
		for row_i in maps["out"].keys():
			valid_out[maps["out"][row_i]] = rows[row_i].get("label", "")
		for row_i in maps["in"].keys():
			valid_in[maps["in"][row_i]] = rows[row_i].get("label", "")

		for conn in program_data.get("connections", []):
			if conn["from_node"] == node_name and not valid_out.has(conn["from_port"]):
				push_warning("BlockRuntime: '%s' (%s) has an OUTGOING wire on port %d, but that block has no output there. Valid output ports: %s. This wire will never fire." % [node_name, block_id, conn["from_port"], str(valid_out)])
				issues += 1
			if conn["to_node"] == node_name and not valid_in.has(conn["to_port"]):
				push_warning("BlockRuntime: '%s' (%s) has an INCOMING wire on port %d, but that block has no input there. Valid input ports: %s. This wire will never be read." % [node_name, block_id, conn["to_port"], str(valid_in)])
				issues += 1

	if issues > 0:
		push_warning("BlockRuntime: found %d wire(s) pointing at nonexistent ports (see warnings above). Fix these in the editor and re-save." % issues)
