extends Node3D

@onready var part_scenes: Array[PackedScene] = [
	preload("res://parts/axle.tscn"),
	preload("res://parts/brain.tscn"),
	preload("res://parts/gear.tscn"),
	preload("res://parts/metal.tscn"),
	preload("res://parts/omni_wheel.tscn"),
	preload("res://parts/piston.tscn"),
	preload("res://parts/roller.tscn"),
	preload("res://parts/smart_motor.tscn"),
]

var preset_robots: Dictionary[String, JSON] = {
	"BasicRobot": preload("res://Presets/robots/BasicRobot.json")
}

@onready var name_label: Label = $UI/robo_name
@onready var control_hints_label: Label = $UI/ControlHints

enum Mode { EDIT, BUILD }
var current_mode: Mode = Mode.EDIT

const SAVE_DIR = "user://robots/"

var loaded_parts: Dictionary = {}
var preset_list: Array = []

var selected_load_meta: Dictionary = {}

@export var workspace_node: Node3D 
@export var camera_3d: Camera3D 
@export var property_ui: Panel 
@onready var gizmo: Gizmo3D = $Gizmo3D

var selected_parts: Array[PartBody] = []
var drag_start_transforms: Dictionary = {}
var drag_cluster_extra_parts: Array[PartBody] = []
var preview_node: PartBody = null
var selected_part_name = ""

var is_duplicate_preview: bool = false
var duplicate_preview_parts: Array = []
var duplicate_relative_transforms: Dictionary = {}
var duplicate_source_parts: Array = []

var preview_rotation_basis: Basis = Basis.IDENTITY

var is_axle_locked: bool = false
var locked_axle_part: PartBody = null
@export var axle_unsnap_threshold: float = 0.15

var property_drag_start_val: float = 0.0

var assembly_id_counter: int = 0

var selected_part: PartBody = null
var target_part: PartBody = null
var target_shape_index: int = -1

var undo_stack: Array = []
var redo_stack: Array = []
const MAX_UNDO_DEPTH = 50

var awaiting_connection_selection: bool = false
var pending_connection_target: PartBody = null
var pending_connection_prop: String = ""

var assembly_view_active: bool = false
var assembly_color_cache: Dictionary = {}

var can_edit = true

# --- Performance caches ---
# Cached ghost materials so build-mode preview doesn't allocate a new
# StandardMaterial3D every single frame.
var _ghost_valid_mat: StandardMaterial3D
var _ghost_invalid_mat: StandardMaterial3D
# Cached selection-highlight material.
var _selection_mat: StandardMaterial3D
# Cached per-assembly-color materials for the "view assemblies" mode.
var _assembly_material_cache: Dictionary = {}
# Tracks whether the workspace has any placed part at all, so hot paths
# (per-frame checks) don't need to walk the whole part tree just to test
# for emptiness. Kept in sync at every point parts are added/removed.
var _has_any_placed_part: bool = false
# Last text written to the hint / name labels, so we only touch
# Label.text (which triggers a redraw/relayout) when it actually changes.
var _last_hint_text: String = ""
var _last_name_label_text: String = ""

func _ready() -> void:
	_ghost_valid_mat = StandardMaterial3D.new()
	_ghost_valid_mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	_ghost_valid_mat.albedo_color = Color(0.2, 0.8, 0.2, 0.5)

	_ghost_invalid_mat = StandardMaterial3D.new()
	_ghost_invalid_mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	_ghost_invalid_mat.albedo_color = Color(0.9, 0.1, 0.1, 0.5)

	_selection_mat = StandardMaterial3D.new()
	_selection_mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	_selection_mat.albedo_color = Color(0.2, 0.4, 0.9, 0.5)

	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	_copy_presets_to_user()
	
	loaded_parts.clear()
	for scene in part_scenes:
		if scene:
			var key = scene.get_path().get_file().get_basename()
			loaded_parts[key] = scene
	
	preset_list.clear()
	for name in preset_robots.keys():
		var json_res: JSON = preset_robots[name]
		if json_res and json_res.data is Array:
			preset_list.append({
				"name": name,
				"json_data": json_res.data
			})
	
	var existing_parts := get_all_placed_parts()
	for part in existing_parts:
		if part.has_method("update"):
			part.update(1)
	_has_any_placed_part = not existing_parts.is_empty()
	
	part_menu.clear()
	for part_name in loaded_parts.keys():
		part_menu.add_item(part_name)
	part_menu.index_pressed.connect(_on_part_menu_selected)
	
	if not property_ui:
		property_ui = $UI/EditPanel
	
	gizmo.hide()
	gizmo.transform_begin.connect(_on_gizmo_drag_started)
	gizmo.transform_end.connect(_on_gizmo_drag_ended)
	
	$UI/save/save_close.pressed.connect(_close_save_panel)
	$UI/load/load_close.pressed.connect(_close_load_panel)
	
	if GameData.has_pending_data:
		var payload := GameData.take_robodata()
		$UI/menu.visible = false
		if payload["data"] is Array and not payload["data"].is_empty():
			if payload["name"]:
				selected_load_file = payload["name"]
				current_robot_filename = payload["name"]
			load_robot(payload["data"])

func _copy_presets_to_user() -> void:
	for preset_name in preset_robots.keys():
		var json_res: JSON = preset_robots[preset_name]
		if not json_res:
			continue
		var dest_path = SAVE_DIR + preset_name + ".json"
		if not FileAccess.file_exists(dest_path):
			var f = FileAccess.open(dest_path, FileAccess.WRITE)
			if f:
				f.store_string(JSON.stringify(json_res.data, "\t"))
				f.close()

func _refresh_load_list() -> void:
	var item_list = $UI/load/VBoxContainer/ItemList
	if item_list:
		item_list.clear()
		
		var dir = DirAccess.open(SAVE_DIR)
		if dir:
			dir.list_dir_begin()
			var file_name = dir.get_next()
			while file_name != "":
				if not dir.current_is_dir() and file_name.ends_with(".json") and not file_name.begins_with("."):
					var display_name = file_name.replace(".json", "")
					if not preset_robots.has(display_name):
						item_list.add_item(display_name)
						item_list.set_item_metadata(item_list.item_count - 1, {
							"filename": file_name,
							"is_preset": false,
							"full_path": SAVE_DIR + file_name,
							"json_data": null
						})
				file_name = dir.get_next()
			dir.list_dir_end()
		
		for preset in preset_list:
			var display_name = "[Preset] " + preset.name
			item_list.add_item(display_name)
			item_list.set_item_metadata(item_list.item_count - 1, {
				"filename": preset.name + ".json",
				"is_preset": true,
				"full_path": "",
				"json_data": preset.json_data
			})
		
		if item_list.item_count == 0:
			item_list.add_item("No saved robots or presets found")
			item_list.set_item_disabled(0, true)
	
	_update_load_buttons()

func _on_item_list_item_selected(index: int) -> void:
	var item_list = $UI/load/VBoxContainer/ItemList
	if item_list:
		var meta = item_list.get_item_metadata(index)
		if meta is Dictionary:
			selected_load_meta = meta
			selected_load_file = meta.get("filename", "")
		else:
			var filename = meta as String
			if filename == null or filename == "":
				filename = item_list.get_item_text(index) + ".json"
			selected_load_meta = {
				"filename": filename,
				"is_preset": false,
				"full_path": SAVE_DIR + filename,
				"json_data": null
			}
			selected_load_file = filename
		_update_load_buttons()

func _update_load_buttons() -> void:
	var load_btn = $UI/load/VBoxContainer/HBoxContainer/load_btn
	var overwrite_btn = $UI/load/VBoxContainer/HBoxContainer/overwrite_btn
	var delete_btn = $UI/load/VBoxContainer/HBoxContainer/delete_btn
	var has_selection = selected_load_meta and selected_load_meta.get("filename") != "" and not selected_load_meta.get("filename", "").begins_with("No saved")
	load_btn.disabled = not has_selection
	overwrite_btn.disabled = not has_selection or (selected_load_meta and selected_load_meta.get("is_preset", false))
	delete_btn.disabled = not has_selection or (selected_load_meta and selected_load_meta.get("is_preset", false))

func _on_program_load_pressed() -> void:
	if not selected_load_meta: return
	if is_modified:
		$UI/ask_save.visible = true
		$UI/ask_save/VBoxContainer/Label.text = "Save current robot before loading?"
		$UI/ask_save.set_meta("pending_filename", selected_load_meta["filename"])
		$UI/ask_save.set_meta("pending_action", "load")
	else:
		_do_load_selected()
		_close_load_panel()

func _do_load_selected() -> void:
	if selected_load_meta.get("is_preset", false):
		var data: Array = selected_load_meta.get("json_data", [])
		if data is Array and not data.is_empty():
			load_robot(data, true)
			current_robot_filename = selected_load_meta["filename"]
			is_modified = false
	else:
		var path = selected_load_meta.get("full_path", "")
		if path != "":
			_load_robot_from_path(path)
			current_robot_filename = selected_load_meta["filename"]

func _on_program_save_pressed() -> void:
	if selected_load_meta.get("is_preset", false):
		return
	$UI/ask_save.visible = true
	$UI/ask_save/VBoxContainer/Label.text = "Overwrite '" + selected_load_meta["filename"].replace(".json", "") + "' with current robot?"
	$UI/ask_save.set_meta("pending_filename", selected_load_meta["filename"])
	$UI/ask_save.set_meta("pending_action", "overwrite")

func _on_program_delete_pressed() -> void:
	if selected_load_meta.get("is_preset", false):
		return
	$UI/ask_save.visible = true
	$UI/ask_save/VBoxContainer/Label.text = "Delete '" + selected_load_meta["filename"].replace(".json", "") + "' permanently?"
	$UI/ask_save.set_meta("pending_filename", selected_load_meta["filename"])
	$UI/ask_save.set_meta("pending_action", "delete")

func _on_confirm_save_yes_pressed() -> void:
	var filename = $UI/ask_save.get_meta("pending_filename", "")
	var action = $UI/ask_save.get_meta("pending_action", "")
	
	if filename != "":
		match action:
			"save":
				_save_robot_to_file(filename)
				current_robot_filename = filename
				_close_save_panel()
			"overwrite":
				_save_robot_to_file(filename)
				current_robot_filename = filename
				_close_load_panel()
			"load":
				if current_robot_filename != "":
					_save_robot_to_file(current_robot_filename)
				_do_load_selected()
				_close_load_panel()
			"delete":
				_delete_robot_file(filename)
				_refresh_load_list()
				selected_load_meta = {}
				_update_load_buttons()
	
	$UI/ask_save.visible = false

func _on_confirm_save_no_pressed() -> void:
	var action = $UI/ask_save.get_meta("pending_action", "")
	var filename = $UI/ask_save.get_meta("pending_filename", "")
	
	match action:
		"load":
			_do_load_selected()
			_close_load_panel()
	
	$UI/ask_save.visible = false

func _process(_delta: float) -> void:
	if $UI/CodeEditor.visible:
		if _last_hint_text != "Code Editor Active":
			control_hints_label.text = "Code Editor Active"
			_last_hint_text = "Code Editor Active"
		return

	if current_mode == Mode.BUILD and preview_node:
		update_preview_position()
	
	if gizmo and gizmo.visible and gizmo.editing and not drag_cluster_extra_parts.is_empty():
		_sync_axle_cluster_drag()
	
	$UI/HBoxContainer/save.disabled = current_robot_filename == ""
	
	var name_text: String
	if current_robot_filename == "":
		name_text = "Untitled"
	else:
		name_text = current_robot_filename.replace(".json", "")
	if is_modified:
		name_text += " *"
	if name_text != _last_name_label_text:
		name_label.text = name_text
		_last_name_label_text = name_text

	_update_control_hints()

func _is_axle_type(part: PartBody) -> bool:
	return is_instance_valid(part) and part.part_type == PartBody.Types.AXLE

func _find_touching_assembly_part(part: PartBody, exclude_assembly: Node, margin: float = ASSEMBLY_TOUCH_MARGIN) -> PartBody:
	if not is_instance_valid(part):
		return null
	if _is_axle_type(part):
		return null
	sync_shapes_to_physics_server(part)
	var space_state = get_world_3d().direct_space_state
	var exclude_rids: Array[RID] = _get_all_rids(part)
	for shape_node in _get_collision_shapes_recursive(part):
		if not shape_node.shape or shape_node.disabled:
			continue
		var query = PhysicsShapeQueryParameters3D.new()
		query.shape = shape_node.shape
		query.transform = shape_node.global_transform
		query.collide_with_bodies = true
		query.collide_with_areas = false
		query.margin = margin
		query.exclude = exclude_rids
		query.collision_mask = 1
		var results = space_state.intersect_shape(query, 8)
		for result in results:
			var collider = result.collider
			if not (collider is PartBody):
				continue
			if _is_axle_type(collider):
				continue
			var other_root = get_top_level_part(collider)
			if not other_root or _is_axle_type(other_root):
				continue
			var other_assembly = other_root.get_parent()
			if other_assembly and other_assembly != exclude_assembly:
				return other_root
	return null

func _refresh_placed_part_visuals() -> void:
	if not has_node("RobotWorkspace"):
		return

	for part in get_all_placed_parts():
		if not is_instance_valid(part):
			continue

		if assembly_view_active:
			var assembly = _get_root_assembly(part)
			var color = _get_assembly_color(assembly)
			_apply_material_override_recursive(part, _get_assembly_material(color))
		elif selected_parts.has(part):
			_apply_material_override_recursive(part, _selection_mat)
		else:
			_apply_material_override_recursive(part, null)

func _get_root_assembly(part: PartBody) -> Node:
	var current: Node = part

	while current.get_parent() != null:
		if current.get_parent() == $RobotWorkspace:
			return current
		current = current.get_parent()

	return current

func _apply_material_override_recursive(node: Node, material) -> void:
	if node is GeometryInstance3D:
		node.material_override = material
	for child in node.get_children():
		_apply_material_override_recursive(child, material)

func _get_assembly_color(assembly: Node) -> Color:
	if assembly_color_cache.has(assembly):
		return assembly_color_cache[assembly]
	var golden_ratio_conjugate = 0.61803398875
	var hue = fmod(assembly_color_cache.size() * golden_ratio_conjugate, 1.0)
	var color = Color.from_hsv(hue, 0.65, 0.95)
	assembly_color_cache[assembly] = color
	return color

func _get_assembly_material(color: Color) -> StandardMaterial3D:
	if _assembly_material_cache.has(color):
		return _assembly_material_cache[color]
	var mat = StandardMaterial3D.new()
	mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(color.r, color.g, color.b, 0.5)
	_assembly_material_cache[color] = mat
	return mat

func _enter_assembly_color_view() -> void:
	if assembly_view_active:
		return
	assembly_view_active = true
	_refresh_placed_part_visuals()

func _exit_assembly_color_view() -> void:
	if not assembly_view_active:
		return
	assembly_view_active = false
	_refresh_placed_part_visuals()

func get_all_placed_parts() -> Array[PartBody]:
	var parts: Array[PartBody] = []
	for child in $RobotWorkspace.get_children():
		parts.append_array(get_all_parts(child))
	return parts

func start_connection_selection(part: PartBody, prop: String) -> void:
	if not is_instance_valid(part):
		return
	awaiting_connection_selection = true
	pending_connection_target = part
	pending_connection_prop = prop

func update_gizmo_handles(part: PartBody) -> void:
	if not gizmo: return
	var is_metal = part.part_type == PartBody.Types.METAL if part else false
	if is_metal:
		gizmo.mode = Gizmo3D.ToolMode.MOVE | Gizmo3D.ToolMode.ROTATE
	else:
		gizmo.mode = Gizmo3D.ToolMode.MOVE
	
	var only_axles_selected = not selected_parts.is_empty()
	for p in selected_parts:
		if not is_instance_valid(p) or !p.for_axle:
			only_axles_selected = false
			break
	
	if only_axles_selected:
		gizmo.axes = Gizmo3D.AxisMode.Z
		gizmo.use_local_space = true
	else:
		gizmo.axes = Gizmo3D.AxisMode.ALL
		gizmo.use_local_space = false

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		var hovered = get_viewport().gui_get_hovered_control()
		if hovered != null:
			return
	
	if $UI/CodeEditor.visible:
		return
	
	if event is InputEventKey and event.keycode == KEY_B and event.pressed:
		part_menu.position = get_viewport().get_mouse_position()
		part_menu.popup()
		get_viewport().set_input_as_handled()
	
	if event is InputEventKey and event.pressed:
		if event.ctrl_pressed:
			if event.keycode == KEY_Z:
				if event.shift_pressed:
					redo()
				else:
					undo()
				get_viewport().set_input_as_handled()
				return

	if event is InputEventKey and event.pressed and not event.echo and not event.ctrl_pressed:
		var rotated = false
		var axis = Vector3.ZERO
		var angle = 0.0
		
		match event.physical_keycode:
			KEY_W:
				axis = Vector3.RIGHT
				angle = PI / 2
				rotated = true
			KEY_S:
				axis = Vector3.RIGHT
				angle = -PI / 2
				rotated = true
			KEY_A:
				axis = Vector3.UP
				angle = PI / 2
				rotated = true
			KEY_D:
				axis = Vector3.UP
				angle = -PI / 2
				rotated = true
			KEY_Q:
				axis = Vector3.BACK
				angle = PI / 2
				rotated = true
			KEY_E:
				axis = Vector3.BACK
				angle = -PI / 2
				rotated = true
		
		if rotated:
			if current_mode == Mode.BUILD and preview_node:
				preview_rotation_basis = (preview_rotation_basis * Basis().rotated(axis, angle)).orthonormalized()
				get_viewport().set_input_as_handled()
				return
			elif current_mode == Mode.EDIT and selected_part:
				var pre_transform = selected_part.global_transform
				selected_part.rotate_object_local(axis, angle)
				
				var moves := [{
					"node": selected_part,
					"old_transform": pre_transform,
					"new_transform": selected_part.global_transform
				}]
				
				var cluster_parts = _collect_axle_cluster([selected_part])
				if not cluster_parts.is_empty():
					var pivot = pre_transform.origin
					var rot_basis = selected_part.global_transform.basis * pre_transform.basis.inverse()
					for part in cluster_parts:
						if not is_instance_valid(part):
							continue
						var old_t = part.global_transform
						var new_t = Transform3D(rot_basis * old_t.basis, pivot + rot_basis * (old_t.origin - pivot))
						part.global_transform = new_t
						if part.has_method("update"):
							part.update(1)
						moves.append({
							"node": part,
							"old_transform": old_t,
							"new_transform": new_t
						})
				
				if moves.size() == 1:
					register_history_action({
						"type": "transform",
						"node": moves[0]["node"],
						"old_transform": moves[0]["old_transform"],
						"new_transform": moves[0]["new_transform"]
					})
				else:
					register_history_action({
						"type": "multi_transform",
						"moves": moves
					})
				get_viewport().set_input_as_handled()
				return

	if event is InputEventKey and event.physical_keycode == KEY_F and event.pressed:
		if current_mode == Mode.EDIT and selected_part:
			var camera_arm = camera_3d.get_parent()
			if camera_arm and camera_arm.has_method("focus_on"):
				camera_arm.focus_on(selected_part.global_position)
	
	if event is InputEventKey and event.physical_keycode == KEY_I and not event.echo:
		if event.pressed:
			_enter_assembly_color_view()
			get_viewport().set_input_as_handled()
		elif assembly_view_active:
			_exit_assembly_color_view()
			get_viewport().set_input_as_handled()
	
	if event.is_action_pressed("ui_cancel"):
		if current_mode == Mode.BUILD:
			cancel_build()
		elif current_mode == Mode.EDIT:
			deselect_part()

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		if current_mode == Mode.BUILD:
			cancel_build()

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if current_mode == Mode.BUILD and preview_node and preview_node.visible:
				if is_placement_valid():
					if is_duplicate_preview:
						place_duplicate_group()
					else:
						place_part()
			elif current_mode == Mode.EDIT:
				if gizmo and gizmo.visible and gizmo.editing:
					return
				try_select_part_in_scene(event.shift_pressed)

	if event is InputEventKey and event.physical_keycode == KEY_DELETE and event.pressed:
		if current_mode == Mode.EDIT and selected_part:
			delete_selected_part()
	
	if event is InputEventKey and event.physical_keycode == KEY_J and event.pressed and not event.echo:
		if current_mode == Mode.EDIT and not selected_parts.is_empty():
			try_join_selected_to_nearby_assembly()
			get_viewport().set_input_as_handled()
	
	if event is InputEventKey and event.physical_keycode == KEY_L and event.pressed and not event.echo:
		if current_mode == Mode.EDIT and is_instance_valid(selected_part):
			var assembly = selected_part.get_parent()
			if assembly:
				_apply_selection_with_history(get_all_parts(assembly))
				get_viewport().set_input_as_handled()
	
	if event is InputEventKey and event.physical_keycode == KEY_D and event.ctrl_pressed and event.pressed and not event.echo:
		if current_mode == Mode.EDIT and not selected_parts.is_empty():
			start_duplicate_preview()
			get_viewport().set_input_as_handled()

func register_history_action(action: Dictionary) -> void:
	is_modified = true
	undo_stack.append(action)
	for old_action in redo_stack:
		_clean_orphaned_node(old_action)
	redo_stack.clear()
	if undo_stack.size() > MAX_UNDO_DEPTH:
		var discarded = undo_stack.pop_front()
		_clean_orphaned_node(discarded)

func undo() -> void:
	if undo_stack.is_empty(): return
	clear_selection()
	var action = undo_stack.pop_back()
	redo_stack.append(action)
	
	if action.has("removed_assemblies"):
		_undo_removed_assemblies(action["removed_assemblies"])
	
	match action["type"]:
		"place":
			if is_instance_valid(action["node"]) and action["node"].is_inside_tree():
				action["node"].get_parent().remove_child(action["node"])
				_has_any_placed_part = not get_all_placed_parts().is_empty()
		"rename":
			if is_instance_valid(action["node"]) and action["node"].is_inside_tree():
				action["node"].name = action["old_name"]
				if property_ui and property_ui.current_part == action["node"]:
					property_ui.display_properties(action["node"])
		"delete":
			if is_instance_valid(action["node"]) and not action["node"].is_inside_tree():
				action["parent"].add_child(action["node"])
				action["node"].global_transform = action["transform"]
				if action["node"].has_method("update"):
					action["node"].update(1)
				_has_any_placed_part = true
		"reparent":
			if is_instance_valid(action["node"]) and action["node"].is_inside_tree():
				action["node"].reparent(action["old_parent"])
				action["node"].global_transform = action["transform"]
				if action["node"].has_method("update"):
					action["node"].update(1)
		"multi_reparent":
			for r in action["reparents"]:
				if is_instance_valid(r["node"]) and r["node"].is_inside_tree():
					r["node"].reparent(r["old_parent"])
					r["node"].global_transform = r["transform"]
					if r["node"].has_method("update"):
						r["node"].update(1)
		"transform":
			if is_instance_valid(action["node"]) and action["node"].is_inside_tree():
				action["node"].global_transform = action["old_transform"]
				if action["node"].has_method("update"):
					action["node"].update(1)
		"property_change":
			if is_instance_valid(action["node"]) and action["node"].is_inside_tree():
				action["node"].set(action["prop_name"], action["old_val"])
				if action["node"].has_method("update"):
					action["node"].update(1)
				if property_ui and property_ui.visible and property_ui.current_part == action["node"]:
					property_ui.display_properties(action["node"])
		"selection":
			_set_selection(action["old_selection"])
		"multi_transform":
			for move in action["moves"]:
				if is_instance_valid(move["node"]) and move["node"].is_inside_tree():
					move["node"].global_transform = move["old_transform"]
					if move["node"].has_method("update"):
						move["node"].update(1)
		"multi_place":
			for placement in action["placements"]:
				if is_instance_valid(placement["node"]) and placement["node"].is_inside_tree():
					placement["node"].get_parent().remove_child(placement["node"])
			_has_any_placed_part = not get_all_placed_parts().is_empty()
		"multi_delete":
			for deletion in action["deletions"]:
				if is_instance_valid(deletion["node"]) and not deletion["node"].is_inside_tree():
					deletion["parent"].add_child(deletion["node"])
					deletion["node"].global_transform = deletion["transform"]
					if deletion["node"].has_method("update"):
						deletion["node"].update(1)
			_has_any_placed_part = true
	_refresh_placed_part_visuals()

func redo() -> void:
	if redo_stack.is_empty(): return
	clear_selection()
	var action = redo_stack.pop_back()
	undo_stack.append(action)
	
	match action["type"]:
		"place":
			if is_instance_valid(action["node"]) and not action["node"].is_inside_tree():
				action["parent"].add_child(action["node"])
				action["node"].global_transform = action["transform"]
				if action["node"].has_method("update"):
					action["node"].update(1)
				_has_any_placed_part = true
		"rename":
			if is_instance_valid(action["node"]) and action["node"].is_inside_tree():
				action["node"].name = action["new_name"]
				if property_ui and property_ui.current_part == action["node"]:
					property_ui.display_properties(action["node"])
		"delete":
			if is_instance_valid(action["node"]) and action["node"].is_inside_tree():
				action["node"].get_parent().remove_child(action["node"])
				_has_any_placed_part = not get_all_placed_parts().is_empty()
		"transform":
			if is_instance_valid(action["node"]) and action["node"].is_inside_tree():
				action["node"].global_transform = action["new_transform"]
				if action["node"].has_method("update"):
					action["node"].update(1)
		"property_change":
			if is_instance_valid(action["node"]) and action["node"].is_inside_tree():
				action["node"].set(action["prop_name"], action["new_val"])
				if action["node"].has_method("update"):
					action["node"].update(1)
				if property_ui and property_ui.visible and property_ui.current_part == action["node"]:
					property_ui.display_properties(action["node"])
		"selection":
			_set_selection(action["new_selection"])
		"reparent":
			if is_instance_valid(action["node"]) and action["node"].is_inside_tree():
				action["node"].reparent(action["new_parent"])
				action["node"].global_transform = action["transform"]
				if action["node"].has_method("update"):
					action["node"].update(1)
		"multi_reparent":
			for r in action["reparents"]:
				if is_instance_valid(r["node"]) and r["node"].is_inside_tree():
					r["node"].reparent(r["new_parent"])
					r["node"].global_transform = r["transform"]
					if r["node"].has_method("update"):
						r["node"].update(1)
		"multi_transform":
			for move in action["moves"]:
				if is_instance_valid(move["node"]) and move["node"].is_inside_tree():
					move["node"].global_transform = move["new_transform"]
					if move["node"].has_method("update"):
						move["node"].update(1)
		"multi_place":
			for placement in action["placements"]:
				if is_instance_valid(placement["node"]) and not placement["node"].is_inside_tree():
					placement["parent"].add_child(placement["node"])
					placement["node"].global_transform = placement["transform"]
					if placement["node"].has_method("update"):
						placement["node"].update(1)
			_has_any_placed_part = true
		"multi_delete":
			for deletion in action["deletions"]:
				if is_instance_valid(deletion["node"]) and deletion["node"].is_inside_tree():
					deletion["node"].get_parent().remove_child(deletion["node"])
			_has_any_placed_part = not get_all_placed_parts().is_empty()
	
	if action.has("removed_assemblies"):
		_redo_removed_assemblies(action["removed_assemblies"])
	_refresh_placed_part_visuals()

func _clean_orphaned_node(action: Dictionary) -> void:
	match action.get("type", ""):
		"multi_place":
			for placement in action.get("placements", []):
				_free_if_orphaned(placement.get("node"))
		"multi_delete":
			for deletion in action.get("deletions", []):
				_free_if_orphaned(deletion.get("node"))
		_:
			_free_if_orphaned(action.get("node"))

	for r in action.get("removed_assemblies", []):
		_free_if_orphaned(r.get("node"))

func _free_if_orphaned(node) -> void:
	if is_instance_valid(node) and not node.is_inside_tree():
		node.queue_free()

func _find_captive_axles(node: Node) -> Array[PartBody]:
	var found: Array[PartBody] = []
	for child in node.get_children():
		if child is PartBody:
			if child.part_type == PartBody.Types.AXLE:
				found.append(child)
		else:
			found.append_array(_find_captive_axles(child))
	return found

func _get_parts_riding_on(part: PartBody) -> Array[PartBody]:
	var others: Array[PartBody] = []
	if not is_instance_valid(part):
		return others

	var axles: Array[PartBody] = []
	if part.part_type == PartBody.Types.AXLE:
		axles.append(part)
	axles.append_array(_find_captive_axles(part))

	for axle in axles:
		if not is_instance_valid(axle):
			continue
		for mounted in axle.connecting_to:
			if is_instance_valid(mounted) and mounted.is_inside_tree() and mounted != part and not others.has(mounted):
				others.append(mounted)
		var axle_parent = axle.get_parent()
		if axle_parent:
			for sibling in axle_parent.get_children():
				if sibling is PartBody and sibling != axle and sibling != part and not others.has(sibling):
					if sibling.mounted_axle == axle or sibling.connecting_to.has(axle):
						others.append(sibling)

	return others

func _collect_axle_cluster(primary_parts: Array) -> Array[PartBody]:
	var extra: Array[PartBody] = []
	var seen := {}
	for p in primary_parts:
		seen[p] = true

	var queue: Array[PartBody] = []
	for p in primary_parts:
		for other in _get_parts_riding_on(p):
			if not seen.has(other):
				seen[other] = true
				queue.append(other)
				extra.append(other)

	var i := 0
	while i < queue.size():
		var cur = queue[i]
		i += 1
		for other in _get_parts_riding_on(cur):
			if not seen.has(other):
				seen[other] = true
				queue.append(other)
				extra.append(other)

	return extra

func get_axle_sliding_segment(axle: PartBody) -> Dictionary:
	var axle_dir = -axle.global_transform.basis.z.normalized()
	var half_len = 0.25
	if "axle_length" in axle:
		half_len = axle.axle_length / 2.0
	elif "length" in axle:
		half_len = axle.length / 2.0
	
	var local_aabb = get_preview_local_aabb(axle, axle)
	var pivot_offset_z = 0.0
	if local_aabb.size != Vector3.ZERO:
		pivot_offset_z = local_aabb.position.z + local_aabb.size.z / 2.0
	
	var world_center = axle.global_transform * Vector3(0, 0, pivot_offset_z)
	return {
		"center": world_center,
		"dir": axle_dir,
		"half_len": half_len
	}

func cancel_build() -> void:
	is_axle_locked = false
	locked_axle_part = null
	
	if is_duplicate_preview:
		for part in duplicate_preview_parts:
			if is_instance_valid(part):
				part.queue_free()
		duplicate_preview_parts.clear()
		duplicate_relative_transforms.clear()
		duplicate_source_parts.clear()
		is_duplicate_preview = false
		preview_node = null
	elif preview_node:
		preview_node.queue_free()
		preview_node = null
	
	selected_part_name = ""
	current_mode = Mode.EDIT
	$UI/PartSelector.clear_selection()

func _get_collision_shapes_recursive(node: Node) -> Array:
	var arr = []
	if node is CollisionShape3D and node.shape:
		arr.append(node)
	for child in node.get_children():
		arr.append_array(_get_collision_shapes_recursive(child))
	return arr

func _placement_clips_other_parts() -> bool:
	if not is_instance_valid(preview_node):
		return false
	
	var space_state = get_world_3d().direct_space_state
	var exclude_rids: Array[RID] = _get_all_rids(preview_node)
	if is_duplicate_preview:
		for part in duplicate_preview_parts:
			if is_instance_valid(part):
				exclude_rids.append_array(_get_all_rids(part))
	
	if is_instance_valid(target_part):
		var resting_on = get_top_level_part(target_part)
		exclude_rids.append_array(_get_all_rids(resting_on if resting_on else target_part))
	
	if _shape_clips(preview_node, exclude_rids, space_state):
		return true
	
	if is_duplicate_preview:
		for part in duplicate_preview_parts:
			if part != preview_node and is_instance_valid(part) and part.visible:
				if _shape_clips(part, exclude_rids, space_state):
					return true
	
	return false

func _shape_clips(root: Node, exclude_rids: Array[RID], space_state: PhysicsDirectSpaceState3D) -> bool:
	for shape_node in _get_collision_shapes_recursive(root):
		var query = PhysicsShapeQueryParameters3D.new()
		query.shape = shape_node.shape
		query.transform = shape_node.global_transform
		query.collide_with_bodies = true
		query.collide_with_areas = false
		query.margin = 0.0
		query.exclude = exclude_rids
		query.collision_mask = 1
		
		var results = space_state.intersect_shape(query, 4)
		for result in results:
			if result.collider is PartBody:
				return true
	return false

func is_placement_valid(cached_result = null) -> bool:
	if not preview_node: 
		return false
	
	if not _has_any_placed_part and not is_duplicate_preview:
		return true
	
	var is_for_axle = preview_node.get("for_axle") == true
	var is_metal = preview_node.part_type == PartBody.Types.METAL
	
	if preview_node.part_type == PartBody.Types.AXLE:
		var result = cached_result if cached_result != null else raycast_from_mouse()
		if not result: 
			return false
		var hit_collider = result.collider
		if not ((hit_collider is PartBody) and hit_collider.part_type == PartBody.Types.METAL):
			return false
	
	if is_metal:
		var result = cached_result if cached_result != null else raycast_from_mouse()
		if not result: 
			return false
		var hit_collider = result.collider
		if not ((hit_collider is PartBody)):
			return false
		return not _placement_clips_other_parts()

	if is_for_axle:
		if not is_axle_locked or not is_instance_valid(locked_axle_part):
			return false
		return not _placement_clips_other_parts()
		
	if is_axle_locked or (is_instance_valid(target_part) and target_part.part_type == PartBody.Types.AXLE):
		return false
		
	var result = cached_result if cached_result != null else raycast_from_mouse()
	if not result: 
		return false
	
	var hit_collider = result.collider
	if hit_collider is PartBody and hit_collider.part_type == PartBody.Types.AXLE:
		return false
	
	if not ((hit_collider is PartBody)):
		return false
	
	return not _placement_clips_other_parts()

func update_preview_position() -> void:
	var mouse_pos = get_viewport().get_mouse_position()
	var ray_origin = camera_3d.project_ray_origin(mouse_pos)
	var ray_dir = camera_3d.project_ray_normal(mouse_pos).normalized()
	
	target_part = null
	target_shape_index = -1
	
	if not _has_any_placed_part and not is_duplicate_preview:
		preview_node.visible = true
		preview_node.global_position = Vector3.ZERO
		preview_node.global_transform.basis = preview_rotation_basis
		apply_ghost_material_recursive(preview_node, true)
		_sync_duplicate_group(true)
		return
	
	if is_axle_locked:
		if not is_instance_valid(locked_axle_part) or not locked_axle_part.is_inside_tree():
			is_axle_locked = false
			locked_axle_part = null
		else:
			var segment = get_axle_sliding_segment(locked_axle_part)
			var P2 = segment.center
			var axle_dir = segment.dir
			var half_len = segment.half_len
			
			var P1 = ray_origin
			var d1 = ray_dir
			var d2 = axle_dir
			var v = P1 - P2
			
			var b = d1.dot(d2)
			var d = d1.dot(v)
			var e = d2.dot(v)
			var denom = 1.0 - b * b
			
			var s = 0.0
			var t = 0.0
			
			if denom < 0.0001:
				t = e
				s = 0.0
			else:
				s = (b * e - d) / denom
				t = (e - b * d) / denom
			
			var closest_point_ray = P1 + s * d1
			var closest_point_axle = P2 + t * d2
			var distance_to_axle = closest_point_ray.distance_to(closest_point_axle)
			
			if distance_to_axle > axle_unsnap_threshold:
				is_axle_locked = false
				locked_axle_part = null
			else:
				var clamped_t = clamp(t, -half_len, half_len)
				var snapped_world_pos = P2 + clamped_t * axle_dir
				
				preview_node.visible = true
				
				var final_pos = snapped_world_pos
				if Input.is_key_pressed(KEY_CTRL):
					final_pos = snap_to_grid(final_pos)
				preview_node.global_position = final_pos
				
				var target_z = locked_axle_part.global_transform.basis.z.normalized()
				var temp_up = preview_rotation_basis.y.normalized()
				if abs(temp_up.dot(target_z)) > 0.99:
					temp_up = preview_rotation_basis.x.normalized()
				
				var target_x = temp_up.cross(target_z).normalized()
				var target_y = target_z.cross(target_x).normalized()
				var aligned_basis = Basis(target_x, target_y, target_z).orthonormalized()
				preview_node.global_transform.basis = aligned_basis
				
				var preview_local_aabb = get_preview_local_aabb(preview_node, preview_node)
				if preview_local_aabb.size != Vector3.ZERO:
					var radial_offset = Vector3(
						preview_local_aabb.position.x + preview_local_aabb.size.x / 2.0,
						preview_local_aabb.position.y + preview_local_aabb.size.y / 2.0,
						0.0
					)
					if radial_offset != Vector3.ZERO:
						preview_node.global_position -= preview_node.global_transform.basis * radial_offset
				
				target_part = locked_axle_part
				var valid = is_placement_valid()
				apply_ghost_material_recursive(preview_node, valid)
				_sync_duplicate_group(valid)
				return 
				
	var result = raycast_from_mouse()
	if result:
		preview_node.visible = true
		
		if result.collider is PartBody:
			var hit_part = result.collider
			if hit_part.part_type == PartBody.Types.AXLE:
				var is_for_axle = preview_node.get("for_axle") == true
				if is_for_axle:
					is_axle_locked = true
					locked_axle_part = hit_part
					update_preview_position()
					return
		
		var hit_pos = result.position
		var align_basis = get_align_basis(result.normal)
		
		preview_node.global_position = hit_pos
		
		if is_duplicate_preview:
			preview_node.global_transform.basis = preview_rotation_basis
		else:
			preview_node.global_transform.basis = align_basis * preview_rotation_basis
		
		var local_aabb = get_preview_local_aabb(preview_node)
		if is_duplicate_preview:
			for part in duplicate_preview_parts:
				if part != preview_node and is_instance_valid(part):
					var child_aabb = get_preview_local_aabb(part, preview_node)
					if child_aabb.size != Vector3.ZERO:
						local_aabb = local_aabb.merge(child_aabb)
		
		if local_aabb.size == Vector3.ZERO:
			local_aabb = AABB(Vector3(-0.05, -0.05, -0.05), Vector3(0.1, 0.1, 0.1))
		
		var corners = get_aabb_corners(local_aabb)
		var min_proj = INF
		var normal = result.normal.normalized()
		
		for corner in corners:
			var world_corner = preview_node.global_transform * corner
			var proj = world_corner.dot(normal)
			if proj < min_proj:
				min_proj = proj
		
		var target_proj = hit_pos.dot(normal)
		var offset_amount = target_proj - min_proj
		preview_node.global_position += normal * offset_amount
		if Input.is_key_pressed(KEY_CTRL):
			preview_node.global_position = snap_to_grid(preview_node.global_position, normal)
		
		target_part = result.collider
		_sync_duplicate_group(true)
		var valid = is_placement_valid(result)
		apply_ghost_material_recursive(preview_node, valid)
		_sync_duplicate_group(valid)
	else:
		preview_node.visible = false
		for part in duplicate_preview_parts:
			if part != preview_node and is_instance_valid(part):
				part.visible = false

func snap_to_grid(pos: Vector3, normal: Vector3 = Vector3.ZERO) -> Vector3:
	var grid_size := 0.02
	
	if normal == Vector3.ZERO:
		return Vector3(
			round(pos.x / grid_size) * grid_size,
			round(pos.y / grid_size) * grid_size,
			round(pos.z / grid_size) * grid_size
		)
	
	var n = normal.normalized()
	var normal_component = pos.dot(n) * n
	var tangential = pos - normal_component
	
	tangential = Vector3(
		round(tangential.x / grid_size) * grid_size,
		round(tangential.y / grid_size) * grid_size,
		round(tangential.z / grid_size) * grid_size
	)
	
	return tangential + normal_component

func _sync_duplicate_group(valid: bool) -> void:
	if not is_duplicate_preview:
		return
	for part in duplicate_preview_parts:
		if part == preview_node or not is_instance_valid(part):
			continue
		part.visible = preview_node.visible
		if preview_node.visible and duplicate_relative_transforms.has(part):
			part.global_transform = preview_node.global_transform * duplicate_relative_transforms[part]
		apply_ghost_material_recursive(part, valid)

func get_align_basis(normal: Vector3) -> Basis:
	var y_axis = normal.normalized()
	var x_axis = Vector3.RIGHT
	if abs(y_axis.dot(x_axis)) > 0.95:
		x_axis = Vector3.FORWARD
	var z_axis = x_axis.cross(y_axis).normalized()
	x_axis = y_axis.cross(z_axis).normalized()
	return Basis(x_axis, y_axis, z_axis)

func place_part() -> void:
	is_modified = true
	var new_part = loaded_parts[selected_part_name].instantiate() as PartBody
	new_part.name = generate_unique_part_name(selected_part_name)
	if new_part is AnimatableBody3D:
		new_part.sync_to_physics = true
	
	var placing_on_axle = is_axle_locked or (is_instance_valid(target_part) and target_part.part_type == PartBody.Types.AXLE)
	
	var target_parent = $RobotWorkspace
	
	if placing_on_axle:
		var new_assembly = Node3D.new()
		new_assembly.name = "Assembly_Axle_" + str(assembly_id_counter)
		assembly_id_counter += 1
		$RobotWorkspace.add_child(new_assembly)
		new_assembly.global_transform = preview_node.global_transform
		target_parent = new_assembly
		
		target_part.connecting_to.append(new_part)
		new_part.mounted_axle = target_part
	else:
		if not _has_any_placed_part:
			var new_assembly = Node3D.new()
			new_assembly.name = "Assembly_" + str(assembly_id_counter)
			assembly_id_counter += 1
			$RobotWorkspace.add_child(new_assembly)
			new_assembly.global_transform = preview_node.global_transform
			target_parent = new_assembly
			
			if new_part.part_type == PartBody.Types.AXLE and is_instance_valid(target_part):
				target_part.connecting_to.append(new_part)
				new_part.can_rotate = true
		elif new_part.part_type == PartBody.Types.AXLE and is_instance_valid(target_part):
			# Join the assembly of the part this axle is mounted through,
			# instead of creating a new disconnected assembly for it.
			target_parent = target_part.get_parent()
			if not target_parent:
				target_parent = $RobotWorkspace
			target_part.connecting_to.append(new_part)
			new_part.can_rotate = true
		else:
			var new_assembly = Node3D.new()
			new_assembly.name = "Assembly_" + str(assembly_id_counter)
			assembly_id_counter += 1
			$RobotWorkspace.add_child(new_assembly)
			new_assembly.global_transform = Transform3D.IDENTITY
			target_parent = new_assembly
	
	target_parent.add_child(new_part)
	new_part.global_transform = preview_node.global_transform
	new_part.reset_physics_interpolation()
	
	if new_part.has_method("update"):
		new_part.update(1)
		
	is_axle_locked = false
	locked_axle_part = null
	_has_any_placed_part = true
	
	register_history_action({
		"type": "place",
		"node": new_part,
		"parent": target_parent,
		"transform": new_part.global_transform
	})
	
	cancel_build()
	clear_selection()
	add_to_selection(new_part)

func create_custom_sub_assembly(target_node: Node) -> void:
	if not is_instance_valid(target_node):
		return
	var parent_node = target_node.get_parent()
	if not parent_node or parent_node == get_tree().root:
		return
	var new_assembly = Node3D.new()
	new_assembly.name = "Assembly_Sub_" + str(PartBody.id_count)
	parent_node.add_child(new_assembly)
	new_assembly.global_transform = target_node.global_transform
	var old_transform = target_node.global_transform
	target_node.reparent(new_assembly)
	target_node.global_transform = old_transform

func make_selected_part_new_assembly() -> void:
	if not is_instance_valid(selected_part):
		return
	var old_parent = selected_part.get_parent()
	if not old_parent:
		return
	var new_assembly = Node3D.new()
	new_assembly.name = "Assembly_" + selected_part.name + "_" + str(PartBody.id_count)
	$RobotWorkspace.add_child(new_assembly)
	new_assembly.global_transform = selected_part.global_transform
	var original_transform = selected_part.global_transform
	selected_part.reparent(new_assembly)
	selected_part.global_transform = original_transform

	var removed_assemblies = _remove_empty_assemblies([old_parent])
	var action := {
		"type": "reparent",
		"node": selected_part,
		"old_parent": old_parent,
		"new_parent": new_assembly,
		"transform": original_transform
	}
	if not removed_assemblies.is_empty():
		action["removed_assemblies"] = removed_assemblies
	register_history_action(action)

	cancel_build()
	clear_selection()
	add_to_selection(selected_part)

func deselect_part() -> void:
	clear_selection()

func _set_selection(new_parts: Array) -> void:
	selected_parts.clear()
	for part in new_parts:
		if is_instance_valid(part):
			selected_parts.append(part)
	if gizmo:
		gizmo.clear_selection()
		for part in selected_parts:
			gizmo.select(part)
		if selected_parts.is_empty():
			gizmo.hide()
		else:
			gizmo.show()
	if property_ui:
		if selected_parts.size() == 1:
			property_ui.display_properties(selected_parts[0])
		else:
			property_ui.hide()
	selected_part = selected_parts.back() if not selected_parts.is_empty() else null
	update_gizmo_handles(selected_part)
	_refresh_placed_part_visuals()

func _selections_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for part in a:
		if not b.has(part):
			return false
	return true

func _apply_selection_with_history(new_parts: Array) -> void:
	var old_selection = selected_parts.duplicate()
	if _selections_equal(old_selection, new_parts):
		return
	_set_selection(new_parts)
	register_history_action({
		"type": "selection",
		"old_selection": old_selection,
		"new_selection": selected_parts.duplicate()
	})

const GEAR_AXIS_PARALLEL_TOLERANCE = 0.99
const GEAR_PLANE_TOLERANCE = 0.02
const GEAR_MIN_HORIZ_DIST = 0.01

func try_select_part_in_scene(shift_pressed: bool = false) -> void:
	if awaiting_connection_selection:
		var result = raycast_from_mouse()
		if result and result.collider is PartBody:
			var top_part = get_top_level_part(result.collider)
			if top_part and top_part != pending_connection_target:
				if pending_connection_prop == "connections":
					var target_is_gear = ("radius" in pending_connection_target and "height" in pending_connection_target)
					var click_is_gear = ("radius" in top_part and "height" in top_part)
					if target_is_gear and click_is_gear:
						var axis_target = pending_connection_target.global_transform.basis.z.normalized()
						var axis_click = top_part.global_transform.basis.z.normalized()
						if abs(axis_target.dot(axis_click)) < GEAR_AXIS_PARALLEL_TOLERANCE:
							awaiting_connection_selection = false
							pending_connection_target = null
							pending_connection_prop = ""
							get_viewport().set_input_as_handled()
							return
						var axis = axis_target
						var pos_target = pending_connection_target.global_position
						var pos_click = top_part.global_position
						var proj_target = pos_target.dot(axis)
						var proj_click = pos_click.dot(axis)
						var axis_diff = abs(proj_target - proj_click)
						if axis_diff > GEAR_PLANE_TOLERANCE:
							awaiting_connection_selection = false
							pending_connection_target = null
							pending_connection_prop = ""
							get_viewport().set_input_as_handled()
							return
						var perp_vec = pos_click - pos_target
						var perp_dist = (perp_vec - perp_vec.project(axis)).length()
						if perp_dist < GEAR_MIN_HORIZ_DIST:
							awaiting_connection_selection = false
							pending_connection_target = null
							pending_connection_prop = ""
							get_viewport().set_input_as_handled()
							return

				if pending_connection_prop == "ports":
					var allowed_types = [PartBody.Types.PISTON, PartBody.Types.MOTOR]
					if top_part.part_type not in allowed_types:
						awaiting_connection_selection = false
						pending_connection_target = null
						pending_connection_prop = ""
						get_viewport().set_input_as_handled()
						return

				var arr = pending_connection_target.get(pending_connection_prop)
				if arr is Array:
					var old_arr = arr.duplicate()
					if not arr.has(top_part):
						arr.append(top_part)
						pending_connection_target.set(pending_connection_prop, arr)
						register_history_action({
							"type": "property_change",
							"node": pending_connection_target,
							"prop_name": pending_connection_prop,
							"old_val": old_arr,
							"new_val": arr.duplicate()
						})

						if pending_connection_prop == "connections":
							var other_arr = top_part.get(pending_connection_prop)
							if other_arr is Array and not other_arr.has(pending_connection_target):
								var old_other_arr = other_arr.duplicate()
								other_arr.append(pending_connection_target)
								top_part.set(pending_connection_prop, other_arr)
								register_history_action({
									"type": "property_change",
									"node": top_part,
									"prop_name": pending_connection_prop,
									"old_val": old_other_arr,
									"new_val": other_arr.duplicate()
								})
								
						if property_ui and property_ui.current_part == pending_connection_target:
							property_ui.display_properties(pending_connection_target)
						
				awaiting_connection_selection = false
				pending_connection_target = null
				pending_connection_prop = ""
				get_viewport().set_input_as_handled()
				return
		awaiting_connection_selection = false
		pending_connection_target = null
		pending_connection_prop = ""
		return

	var result = raycast_from_mouse()
	if result and result.collider is PartBody:
		var top_part = get_top_level_part(result.collider)
		if top_part:
			if shift_pressed:
				var new_selection = selected_parts.duplicate()
				if new_selection.has(top_part):
					new_selection.erase(top_part)
				else:
					new_selection.append(top_part)
				_apply_selection_with_history(new_selection)
			else:
				if not selected_parts.has(top_part):
					_apply_selection_with_history([top_part])
	else:
		if not shift_pressed:
			_apply_selection_with_history([])

func delete_selected_part() -> void:
	is_modified = true
	if selected_parts.is_empty(): return
	var parts_to_delete: Array = selected_parts.duplicate()
	
	var seen := {}
	for p in parts_to_delete:
		seen[p] = true
	var i := 0
	while i < parts_to_delete.size():
		var cur = parts_to_delete[i]
		i += 1
		if is_instance_valid(cur):
			for mounted in _get_parts_riding_on(cur):
				if is_instance_valid(mounted) and mounted.is_inside_tree() and not seen.has(mounted):
					seen[mounted] = true
					parts_to_delete.append(mounted)
	
	var affected_assemblies := []
	for part in parts_to_delete:
		var p = part.get_parent()
		if p and not affected_assemblies.has(p):
			affected_assemblies.append(p)
	clear_selection()
	var deletions := []
	for part in parts_to_delete:
		var parent = part.get_parent()
		var transform = part.global_transform
		parent.remove_child(part)
		deletions.append({
			"node": part,
			"parent": parent,
			"transform": transform
		})
	if not deletions.is_empty():
		var removed_assemblies = _remove_empty_assemblies(affected_assemblies)
		var action := {
			"type": "multi_delete",
			"deletions": deletions
		}
		if not removed_assemblies.is_empty():
			action["removed_assemblies"] = removed_assemblies
		register_history_action(action)
		_has_any_placed_part = not get_all_placed_parts().is_empty()
	_refresh_placed_part_visuals()

func toggle_part_selection(part: PartBody) -> void:
	if selected_parts.has(part):
		remove_from_selection(part)
	else:
		add_to_selection(part)

func add_to_selection(part: PartBody) -> void:
	if not selected_parts.has(part):
		var new_selection = selected_parts.duplicate()
		new_selection.append(part)
		_set_selection(new_selection)

func remove_from_selection(part: PartBody) -> void:
	if selected_parts.has(part):
		var new_selection = selected_parts.duplicate()
		new_selection.erase(part)
		_set_selection(new_selection)

func _get_local_assembly_parts(seed_parts: Array) -> Array:
	var result: Array = []
	for p in seed_parts:
		if not is_instance_valid(p):
			continue
		if not result.has(p):
			result.append(p)
		var parent = p.get_parent()
		if parent:
			for sibling in get_all_parts(parent):
				if not result.has(sibling):
					result.append(sibling)
	return result

func start_duplicate_preview() -> void:
	if selected_parts.is_empty(): return
	if current_mode != Mode.EDIT: return
	
	var anchor_source = selected_part
	if not is_instance_valid(anchor_source) or not selected_parts.has(anchor_source):
		anchor_source = selected_parts.back()
	var anchor_original_transform: Transform3D = anchor_source.global_transform
	
	var source_parts = selected_parts.duplicate()
	clear_selection()
	
	duplicate_preview_parts.clear()
	duplicate_relative_transforms.clear()
	duplicate_source_parts = source_parts.duplicate()
	var anchor_dup: PartBody = null
	
	var preview_parent = $RobotWorkspace if has_node("RobotWorkspace") else self
	
	for part in source_parts:
		var dup = part.duplicate() as PartBody
		preview_parent.add_child(dup)
		dup.global_transform = part.global_transform
		if dup.has_method("update"):
			dup.update(1)
		disable_physics_recursive(dup)
		apply_ghost_material_recursive(dup, true)
		duplicate_preview_parts.append(dup)
		duplicate_relative_transforms[dup] = anchor_original_transform.affine_inverse() * part.global_transform
		if part == anchor_source:
			anchor_dup = dup
	
	if not is_instance_valid(anchor_dup):
		anchor_dup = duplicate_preview_parts.back()
	
	is_duplicate_preview = true
	preview_node = anchor_dup
	preview_rotation_basis = anchor_original_transform.basis.orthonormalized()
	selected_part_name = ""
	is_axle_locked = false
	locked_axle_part = null
	current_mode = Mode.BUILD

func place_duplicate_group() -> void:
	is_modified = true
	var placed_parts: Array = []
	var placements := []
	
	for part in duplicate_preview_parts:
		if not is_instance_valid(part):
			continue
		enable_physics_recursive(part)
		if part is AnimatableBody3D:
			part.sync_to_physics = true
		_clear_material_override_recursive(part)
		if part.has_method("update"):
			part.update(1)
		part.reset_physics_interpolation()
		placed_parts.append(part)
		placements.append({
			"node": part,
			"parent": part.get_parent(),
			"transform": part.global_transform
		})
	
	if not placed_parts.is_empty():
		_has_any_placed_part = true
	
	if is_axle_locked and is_instance_valid(locked_axle_part) and is_instance_valid(preview_node):
		if not locked_axle_part.connecting_to.has(preview_node):
			locked_axle_part.connecting_to.append(preview_node)
		preview_node.mounted_axle = locked_axle_part

	is_axle_locked = false
	locked_axle_part = null
	
	if not placements.is_empty():
		register_history_action({
			"type": "multi_place",
			"placements": placements
		})
	
	is_duplicate_preview = false
	duplicate_preview_parts.clear()
	duplicate_relative_transforms.clear()
	duplicate_source_parts.clear()
	preview_node = null
	selected_part_name = ""
	current_mode = Mode.EDIT
	$UI/PartSelector.clear_selection()
	_set_selection(placed_parts)

func _clear_material_override_recursive(node: Node) -> void:
	if node is GeometryInstance3D:
		node.material_override = null
	for child in node.get_children():
		_clear_material_override_recursive(child)

func clear_selection() -> void:
	_set_selection([])

func _on_gizmo_drag_started(mode: int) -> void:
	drag_start_transforms.clear()
	drag_cluster_extra_parts.clear()
	for part in selected_parts:
		drag_start_transforms[part] = part.global_transform
		disable_physics_recursive(part)
	
	for part in _collect_axle_cluster(selected_parts):
		if is_instance_valid(part) and not drag_start_transforms.has(part):
			drag_start_transforms[part] = part.global_transform
			disable_physics_recursive(part)
			drag_cluster_extra_parts.append(part)

func _sync_axle_cluster_drag() -> void:
	if selected_parts.is_empty():
		return
	var leader: PartBody = selected_parts[0]
	if not is_instance_valid(leader) or not drag_start_transforms.has(leader):
		return
	var start_t: Transform3D = drag_start_transforms[leader]
	var delta_t: Transform3D = leader.global_transform * start_t.affine_inverse()
	for part in drag_cluster_extra_parts:
		if not is_instance_valid(part) or not drag_start_transforms.has(part):
			continue
		part.global_transform = delta_t * drag_start_transforms[part]

func _on_gizmo_drag_ended(mode: int) -> void:
	_sync_axle_cluster_drag()
	
	var all_dragged_parts: Array[PartBody] = selected_parts.duplicate()
	for part in drag_cluster_extra_parts:
		if is_instance_valid(part) and not all_dragged_parts.has(part):
			all_dragged_parts.append(part)
	
	for part in all_dragged_parts:
		if not is_instance_valid(part):
			continue
		enable_physics_recursive(part)
		if part.has_method("update"):
			part.update(1)
	
	var moves := []
	for part in all_dragged_parts:
		if not is_instance_valid(part) or not drag_start_transforms.has(part):
			continue
		var old_transform: Transform3D = drag_start_transforms[part]
		var new_transform: Transform3D = part.global_transform
		if not old_transform.is_equal_approx(new_transform):
			moves.append({
				"node": part,
				"old_transform": old_transform,
				"new_transform": new_transform
			})
	
	if not moves.is_empty():
		register_history_action({
			"type": "multi_transform",
			"moves": moves
		})
		var moved_assemblies := []
		for move in moves:
			var p = move["node"].get_parent()
			if p and not moved_assemblies.has(p):
				moved_assemblies.append(p)
		_split_floating_assemblies(moved_assemblies)
	
	drag_start_transforms.clear()
	drag_cluster_extra_parts.clear()

func raycast_gizmo() -> Dictionary:
	var mouse_pos = get_viewport().get_mouse_position()
	var ray_length = 50.0
	var from = camera_3d.project_ray_origin(mouse_pos)
	var to = from + camera_3d.project_ray_normal(mouse_pos) * ray_length
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	query.collision_mask = 4 
	return space_state.intersect_ray(query)

func raycast_from_mouse() -> Dictionary:
	var mouse_pos = get_viewport().get_mouse_position()
	var ray_origin = camera_3d.project_ray_origin(mouse_pos)
	var ray_dir = camera_3d.project_ray_normal(mouse_pos).normalized()
	var ray_end = ray_origin + ray_dir * 1000.0
	var query = PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	var exclude_list: Array[RID] = []
	if is_instance_valid(preview_node):
		exclude_list.append_array(_get_all_rids(preview_node))
	if is_duplicate_preview:
		for part in duplicate_preview_parts:
			if is_instance_valid(part):
				exclude_list.append_array(_get_all_rids(part))
	query.exclude = exclude_list
	var space_state = get_world_3d().direct_space_state
	return space_state.intersect_ray(query)

func _get_all_rids(node: Node) -> Array[RID]:
	var rids: Array[RID] = []
	if node is CollisionObject3D:
		rids.append(node.get_rid())
	for child in node.get_children():
		rids.append_array(_get_all_rids(child))
	return rids

func get_shape_node_by_index(root: Node, target_idx: int) -> CollisionShape3D:
	var shapes = get_direct_shapes(root)
	if target_idx >= 0 and target_idx < shapes.size():
		return shapes[target_idx]
	return null

func disable_physics_recursive(node: Node) -> void:
	if node is CollisionShape3D:
		node.disabled = true
	for child in node.get_children():
		disable_physics_recursive(child)

func enable_physics_recursive(node: Node) -> void:
	if node is CollisionShape3D:
		node.disabled = false
	for child in node.get_children():
		enable_physics_recursive(child)

func apply_ghost_material_recursive(node: Node, is_valid: bool = true) -> void:
	var mat := _ghost_valid_mat if is_valid else _ghost_invalid_mat
	if node is GeometryInstance3D:
		node.material_override = mat
	for child in node.get_children():
		apply_ghost_material_recursive(child, is_valid)

func get_preview_local_aabb(node: Node, parent_node: Node3D = null) -> AABB:
	if parent_node == null:
		parent_node = node
	var combined_aabb = AABB()
	var initialized = false
	
	if node is MeshInstance3D and node.mesh:
		var local_aabb = node.mesh.get_aabb()
		var to_parent = parent_node.global_transform.inverse() * node.global_transform
		local_aabb = to_parent * local_aabb
		combined_aabb = local_aabb
		initialized = true
	elif node is CollisionShape3D and node.shape:
		var local_aabb = AABB()
		if node.shape is BoxShape3D:
			var size = node.shape.size
			local_aabb = AABB(-size/2.0, size)
		elif node.shape is CylinderShape3D:
			var r = node.shape.radius
			var h = node.shape.height
			local_aabb = AABB(Vector3(-r, -h/2.0, -r), Vector3(r*2.0, h, r*2.0))
		elif node.shape is SphereShape3D:
			var r = node.shape.radius
			local_aabb = AABB(Vector3(-r, -r, -r), Vector3(r*2.0, r*2.0, r*2.0))
		if local_aabb.size != Vector3.ZERO:
			var to_parent = parent_node.global_transform.inverse() * node.global_transform
			local_aabb = to_parent * local_aabb
			combined_aabb = local_aabb
			initialized = true
	
	for child in node.get_children():
		var child_aabb = get_preview_local_aabb(child, parent_node)
		if child_aabb.size != Vector3.ZERO:
			if not initialized:
				combined_aabb = child_aabb
				initialized = true
			else:
				combined_aabb = combined_aabb.merge(child_aabb)
	return combined_aabb

func get_aabb_corners(aabb: AABB) -> Array[Vector3]:
	var corners: Array[Vector3] = []
	var min_p = aabb.position
	var max_p = aabb.position + aabb.size
	corners.append(Vector3(min_p.x, min_p.y, min_p.z))
	corners.append(Vector3(max_p.x, min_p.y, min_p.z))
	corners.append(Vector3(min_p.x, max_p.y, min_p.z))
	corners.append(Vector3(max_p.x, max_p.y, min_p.z))
	corners.append(Vector3(min_p.x, min_p.y, max_p.z))
	corners.append(Vector3(max_p.x, min_p.y, max_p.z))
	corners.append(Vector3(min_p.x, max_p.y, max_p.z))
	corners.append(Vector3(max_p.x, max_p.y, max_p.z))
	return corners

func get_top_level_part(node: Node) -> PartBody:
	if not node:
		return null
	var current = node
	var top_part: PartBody = null
	if current is PartBody:
		top_part = current
	while current and current != $RobotWorkspace and current != get_tree().root:
		var parent = current.get_parent()
		if parent is PartBody:
			top_part = parent
		current = parent
	return top_part

func get_all_parts(node: Node = null) -> Array[PartBody]:
	if node == null:
		node = $RobotWorkspace
	var parts: Array[PartBody] = []
	if node is PartBody:
		parts.append(node)
		return parts
	for child in node.get_children():
		parts.append_array(get_all_parts(child))
	return parts

func start_property_drag(part: PartBody, prop_name: String) -> void:
	property_drag_start_val = part.get(prop_name)

func check_part_clipping(part: PartBody) -> bool:
	if not is_instance_valid(part) or not part.is_inside_tree():
		return false
	sync_shapes_to_physics_server(part)
	var space_state = get_world_3d().direct_space_state
	var part_root = get_top_level_part(part)
	if not part_root:
		part_root = part
	var shapes = get_direct_shapes(part)
	var exclude_rids = [part.get_rid()]
	if preview_node:
		exclude_rids.append(preview_node.get_rid())

	var mounted_on_this_axle := {}
	if part.part_type == PartBody.Types.AXLE:
		for mounted in _collect_axle_cluster([part]):
			if is_instance_valid(mounted):
				mounted_on_this_axle[mounted] = true

	if part.get("for_axle") == true and "mounted_axle" in part:
		var own_axle: PartBody = part.mounted_axle
		if is_instance_valid(own_axle):
			exclude_rids.append_array(_get_all_rids(own_axle))

	for shape_node in shapes:
		if not shape_node.shape or shape_node.disabled:
			continue
		var query = PhysicsShapeQueryParameters3D.new()
		query.shape = shape_node.shape
		query.transform = shape_node.global_transform
		query.collide_with_bodies = true
		query.collide_with_areas = false
		query.margin = 0.0
		query.exclude = exclude_rids
		query.collision_mask = 1
		var results = space_state.intersect_shape(query, 8)
		for result in results:
			var collider = result.collider
			if not (collider is PartBody):
				continue
			var collider_root = get_top_level_part(collider)
			if not collider_root:
				collider_root = collider
			if collider_root == part_root:
				continue
			if mounted_on_this_axle.has(collider) or mounted_on_this_axle.has(collider_root):
				continue
			var collider_is_metal = (collider.part_type == PartBody.Types.METAL) or (collider_root.part_type == PartBody.Types.METAL)
			var collider_is_axle = (collider.get("part_type") == PartBody.Types.AXLE) or (collider_root.get("part_type") == PartBody.Types.AXLE)
			var part_is_metal = (part.part_type == PartBody.Types.METAL) or (part_root.part_type == PartBody.Types.METAL)
			var part_is_axle = (part.get("part_type") == PartBody.Types.AXLE) or (part_root.get("part_type") == PartBody.Types.AXLE)
			if (part_is_metal and collider_is_axle) or (collider_is_metal and part_is_axle):
				continue
			return true
	return false

func sync_shapes_to_physics_server(body: CollisionObject3D) -> void:
	body.force_update_transform()
	for owner_id in body.get_shape_owners():
		var owner_node = body.shape_owner_get_owner(owner_id)
		if owner_node is CollisionShape3D and owner_node.shape:
			var local_trans = body.global_transform.affine_inverse() * owner_node.global_transform
			body.shape_owner_set_transform(owner_id, local_trans)
			body.shape_owner_get_shape(owner_id, 0).emit_changed()

func end_property_drag(part: PartBody, prop_name: String) -> void:
	var final_val = part.get(prop_name)
	if not is_equal_approx(final_val, property_drag_start_val):
		register_history_action({
			"type": "property_change",
			"node": part,
			"prop_name": prop_name,
			"old_val": property_drag_start_val,
			"new_val": final_val
		})

func get_direct_shapes(node: Node) -> Array:
	var arr = []
	for child in node.get_children():
		if child is CollisionShape3D:
			arr.append(child)
	return arr

var current_robot_filename: String = ""
var selected_load_file: String = ""
var is_modified: bool = false

func save_robot() -> Array:
	var robodata: Array = []
	for assembly in $RobotWorkspace.get_children():
		var dict: Dictionary = {}
		for part in assembly.get_children():
			if not (part is PartBody):
				continue
			var id: int = part.id
			dict[id] = _serialize_part(part)
		robodata.append(dict)
	return robodata

func _serialize_part(part: PartBody) -> Dictionary:
	var data: Dictionary = {}

	if part.scene_file_path != "":
		data["scene"] = part.scene_file_path.get_file().get_basename()

	data["transform"] = _transform_to_dict(part.global_transform)
	data["name"] = part.name
	
	var connected_ids: Array[int] = []
	for connected in part.connecting_to:
		if is_instance_valid(connected):
			connected_ids.append(connected.id)
	if not connected_ids.is_empty():
		data["connecting_to"] = {"__refs__": connected_ids}
	
	if "mounted_axle" in part:
		var axle = part.mounted_axle
		if is_instance_valid(axle):
			data["mounted_axle"] = {"__ref__": axle.id}
	
	data["can_slide"] = part.can_slide
	data["can_rotate"] = part.can_rotate
	
	for prop in part.get_property_list():
		if not (prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var prop_name: String = prop.name
		if prop_name in ["id", "scene_file_path", "transform"]:
			continue
		var value = part.get(prop_name)
		if value == null:
			continue

		if value is Array and value.all(func(x): return x is PartBody):
			var ref_ids: Array[int] = []
			for ref_part in value:
				if is_instance_valid(ref_part):
					ref_ids.append(ref_part.id)
			data[prop_name] = {"__refs__": ref_ids}
		elif value is PartBody:
			if is_instance_valid(value):
				data[prop_name] = {"__ref__": value.id}
		elif value is Node or value is Resource:
			continue
		else:
			data[prop_name] = value

	if part.part_type == PartBody.Types.BRAIN or part.part_type == PartBody.Types.STATIC:
		var port_ids: Array[int] = []
		for p in part.ports:
			if is_instance_valid(p):
				port_ids.append(p.id)
		data["ports"] = {"__refs__": port_ids}

	if part.part_type == PartBody.Types.GEAR:
		var conn_ids: Array[int] = []
		for c in part.connections:
			if is_instance_valid(c):
				conn_ids.append(c.id)
		data["connections"] = {"__refs__": conn_ids}

	return data

func load_robot(robodata: Array, clear_existing: bool = true) -> void:
	if current_mode == Mode.BUILD:
		cancel_build()
	clear_selection()

	if clear_existing:
		_clear_workspace()

	undo_stack.clear()
	redo_stack.clear()
	assembly_id_counter = 0

	var id_to_part: Dictionary = {}
	var part_data_by_id: Dictionary = {}

	for assembly_data in robodata:
		if not (assembly_data is Dictionary):
			continue

		var assembly := Node3D.new()
		assembly.name = "LoadedAssembly_" + str(id_to_part.size())
		$RobotWorkspace.add_child(assembly)

		for raw_id in assembly_data.keys():
			var old_id: int = int(str(raw_id))
			var part_data: Dictionary = assembly_data[raw_id]

			var scene: PackedScene = _get_scene_for_part_data(part_data)
			if not scene:
				push_warning("RobotLoader: No scene for part data: ", part_data)
				continue

			var part: PartBody = scene.instantiate() as PartBody
			if not part:
				continue

			assembly.add_child(part)

			for prop_name in part_data.keys():
				if prop_name in ["transform", "scene", "type"]:
					continue
				var value = part_data[prop_name]
				if value is Dictionary and (value.has("__refs__") or value.has("__ref__")):
					continue
				if prop_name in part:
					part.set(prop_name, value)
				else:
					push_warning("RobotLoader: Property not found on part: ", prop_name)

			if part is AnimatableBody3D:
				part.sync_to_physics = true
			part.reset_physics_interpolation()
			if part.has_method("update"):
				part.update(1)
			
			if part_data.has("name"):
				var saved_name: String = part_data["name"]
				if saved_name != "":
					part.name = saved_name
			
			if part_data.has("transform"):
				var transform_data = part_data["transform"]
				if transform_data is Dictionary:
					var t = _dict_to_transform(transform_data)
					part.global_transform = t
				else:
					push_warning("RobotLoader: Transform is not a dictionary (old save file). Please re-save.")

			id_to_part[old_id] = part
			part_data_by_id[old_id] = part_data

	for old_id in id_to_part.keys():
		var part: PartBody = id_to_part[old_id]
		var part_data: Dictionary = part_data_by_id[old_id]

		for prop_name in part_data.keys():
			var value = part_data[prop_name]
			
			if value is Dictionary and value.has("__refs__"):
				var refs: Array = []
				for ref_id in value["__refs__"]:
					var ref_id_int: int = int(str(ref_id))
					if id_to_part.has(ref_id_int):
						refs.append(id_to_part[ref_id_int])
					else:
						push_warning("RobotLoader: Reference ID %d not found for %s.%s" % [ref_id_int, part.name, prop_name])
				if prop_name in part:
					var typed_refs: Array[PartBody] = []
					typed_refs.assign(refs)
					part.set(prop_name, typed_refs)
				else:
					push_warning("RobotLoader: Reference property not found: %s" % prop_name)
			elif value is Dictionary and value.has("__ref__"):
				var ref_id_int: int = int(str(value["__ref__"]))
				if id_to_part.has(ref_id_int):
					if prop_name in part:
						part.set(prop_name, id_to_part[ref_id_int])
				else:
					push_warning("RobotLoader: Reference ID %d not found for %s.%s" % [ref_id_int, part.name, prop_name])
	
	_has_any_placed_part = not get_all_placed_parts().is_empty()
	is_modified = false

func _clear_workspace() -> void:
	if not has_node("RobotWorkspace"):
		return
	for child in $RobotWorkspace.get_children():
		$RobotWorkspace.remove_child(child)
		child.queue_free()
	_has_any_placed_part = false

func _get_scene_for_part_data(part_data: Dictionary) -> PackedScene:
	if part_data.has("scene"):
		var scene_name: String = part_data["scene"]
		if loaded_parts.has(scene_name):
			return loaded_parts[scene_name]

	if part_data.has("type"):
		var part_type: int = int(part_data["type"])
		return _get_scene_for_type(part_type)

	return null

var _part_type_scene_cache: Dictionary = {}

func _get_scene_for_type(part_type: int) -> PackedScene:
	if _part_type_scene_cache.has(part_type):
		return _part_type_scene_cache[part_type]

	for scene in loaded_parts.values():
		var tmp := scene.instantiate() as PartBody
		if tmp and tmp.part_type == part_type:
			_part_type_scene_cache[part_type] = scene
			tmp.free()
			return scene
		if tmp:
			tmp.free()

	return null

func _on_save_pressed() -> void:
	if current_robot_filename != "":
		_save_robot_to_file(current_robot_filename)
	else:
		_on_save_as_pressed()

func _on_load_pressed() -> void:
	$UI/menu.visible = false
	can_edit = false
	$UI/load.visible = true
	selected_load_file = ""
	_refresh_load_list()

func _transform_to_dict(t: Transform3D) -> Dictionary:
	return {
		"basis_x": [t.basis.x.x, t.basis.x.y, t.basis.x.z],
		"basis_y": [t.basis.y.x, t.basis.y.y, t.basis.y.z],
		"basis_z": [t.basis.z.x, t.basis.z.y, t.basis.z.z],
		"origin": [t.origin.x, t.origin.y, t.origin.z]
	}

func _dict_to_transform(d: Dictionary) -> Transform3D:
	var basis_x = Vector3(d["basis_x"][0], d["basis_x"][1], d["basis_x"][2])
	var basis_y = Vector3(d["basis_y"][0], d["basis_y"][1], d["basis_y"][2])
	var basis_z = Vector3(d["basis_z"][0], d["basis_z"][1], d["basis_z"][2])
	var origin = Vector3(d["origin"][0], d["origin"][1], d["origin"][2])
	return Transform3D(Basis(basis_x, basis_y, basis_z), origin)

func _on_save_as_pressed() -> void:
	can_edit = false
	$UI/save.visible = true
	$UI/save/VBoxContainer/LineEdit.text = current_robot_filename.replace(".json", "")

func _on_confirm_save_pressed() -> void:
	var name_input = $UI/save/VBoxContainer/LineEdit
	if name_input and name_input.text.strip_edges() != "":
		var filename = name_input.text.strip_edges()
		if not filename.ends_with(".json"):
			filename += ".json"
		
		var full_path = SAVE_DIR + filename
		if FileAccess.file_exists(full_path):
			$UI/ask_save.visible = true
			$UI/ask_save/VBoxContainer/Label.text = "File already exists. Overwrite?"
			$UI/ask_save.set_meta("pending_filename", filename)
			$UI/ask_save.set_meta("pending_action", "save")
		else:
			_save_robot_to_file(filename)
			current_robot_filename = filename
			_close_save_panel()

func _close_save_panel() -> void:
	$UI/save.visible = false
	can_edit = true

func _close_load_panel() -> void:
	$UI/load.visible = false
	can_edit = true

func _save_robot_to_file(filename: String) -> void:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	var data = save_robot()
	var full_path = SAVE_DIR + filename
	var file = FileAccess.open(full_path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, "\t"))
		file.close()
		is_modified = false
	else:
		push_error("Failed to save robot: " + full_path)

func _load_robot_from_file(filename: String) -> void:
	_load_robot_from_path(SAVE_DIR + filename)

func _delete_robot_file(filename: String) -> void:
	var full_path = SAVE_DIR + filename
	if FileAccess.file_exists(full_path):
		var dir = DirAccess.open(SAVE_DIR)
		if dir:
			dir.remove(filename)
			if current_robot_filename == filename:
				current_robot_filename = ""
				is_modified = true

func start_build_with_part(part_name: String) -> void:
	cancel_build()
	clear_selection()

	selected_part_name = part_name
	preview_node = loaded_parts[part_name].instantiate()
	
	if preview_node.has_method("update"):
		preview_node.update(1)
	
	disable_physics_recursive(preview_node)
	
	add_child(preview_node)
	
	current_mode = Mode.BUILD

@onready var part_menu: PopupMenu = $PartPopup

func _on_part_menu_selected(index: int) -> void:
	var part_name = part_menu.get_item_text(index)
	start_build_with_part(part_name)

func _update_control_hints() -> void:
	if not control_hints_label:
		return

	var hint_text: String

	if awaiting_connection_selection:
		hint_text = "Click a Part to connect\nRight Click: Cancel"
	elif current_mode == Mode.BUILD:
		if is_duplicate_preview:
			hint_text = "Left Click: Place Duplicates\nRight Click / Esc: Cancel\nWASD/QE: Rotate\nCtrl: Snap to Grid"
		else:
			hint_text = "Left Click: Place Part\nRight Click / Esc: Cancel\nWASD/QE: Rotate\nCtrl: Snap to Grid"
	elif gizmo and gizmo.visible and gizmo.editing:
		hint_text = "Gizmo active: Move/Rotate\nRelease mouse to apply"
	elif selected_parts.is_empty():
		hint_text = "Left Click: Select Part\nShift+Click: Multi‑Select\nI: Hold to View Assemblies\nB: Add Part\nCtrl+Z: Undo\nCtrl+Y: Redo"
	else:
		hint_text = "Gizmo: Move/Rotate\nWASD/QE: Rotate\nF: Focus\nI: Hold to View Assemblies\nDelete: Delete\nCtrl+D: Duplicate\nShift+Click: Multi‑Select"
		if selected_parts.size() == 1:
			hint_text += "\nRight Click: Deselect"
		else:
			hint_text += "\nJ: Join Selected Assemblies"

	if hint_text != _last_hint_text:
		control_hints_label.text = hint_text
		_last_hint_text = hint_text

func _on_play_pressed() -> void:
	GameData.set_robodata(save_robot(), selected_load_file)
	get_tree().change_scene_to_file("res://Scenes/main.tscn")

func _on_new_pressed() -> void:
	$UI/menu.visible = false
	if is_modified:
		$UI/ask_save.visible = true
		$UI/ask_save/VBoxContainer/Label.text = "Discard current robot and start new?"
		$UI/ask_save.set_meta("pending_action", "new")
	else:
		_do_new_robot()

func _do_new_robot() -> void:
	cancel_build()
	_clear_workspace()
	clear_selection()
	undo_stack.clear()
	redo_stack.clear()
	assembly_id_counter = 0
	current_robot_filename = ""
	is_modified = false

const ASSEMBLY_TOUCH_MARGIN: float = 0.001

func _parts_touching(part_a: PartBody, part_b: PartBody, margin: float = ASSEMBLY_TOUCH_MARGIN, skip_sync: bool = false) -> bool:
	if not is_instance_valid(part_a) or not is_instance_valid(part_b):
		return false
	if not skip_sync:
		sync_shapes_to_physics_server(part_a)
	var space_state = get_world_3d().direct_space_state
	var exclude_rids: Array[RID] = _get_all_rids(part_a)
	for shape_node in _get_collision_shapes_recursive(part_a):
		if not shape_node.shape or shape_node.disabled:
			continue
		var query = PhysicsShapeQueryParameters3D.new()
		query.shape = shape_node.shape
		query.transform = shape_node.global_transform
		query.collide_with_bodies = true
		query.collide_with_areas = false
		query.margin = margin
		query.exclude = exclude_rids
		query.collision_mask = 1
		var results = space_state.intersect_shape(query, 8)
		for result in results:
			var collider = result.collider
			if collider is PartBody and get_top_level_part(collider) == part_b:
				return true
	return false

func _is_part_connected_to_its_assembly(part: PartBody) -> bool:
	var assembly = part.get_parent()
	if not assembly:
		return true
	sync_shapes_to_physics_server(part)
	var has_other_parts = false
	for sibling in assembly.get_children():
		if sibling != part and sibling is PartBody:
			has_other_parts = true
			if _parts_touching(part, sibling, ASSEMBLY_TOUCH_MARGIN, true):
				return true
	return not has_other_parts

func _split_part_into_new_assembly(part: PartBody) -> Dictionary:
	if not is_instance_valid(part):
		return {}
	var old_parent = part.get_parent()
	if not old_parent or old_parent == $RobotWorkspace:
		return {}
	var new_assembly = Node3D.new()
	new_assembly.name = "Assembly_Float_" + str(assembly_id_counter)
	assembly_id_counter += 1
	$RobotWorkspace.add_child(new_assembly)
	var world_transform = part.global_transform
	new_assembly.global_transform = world_transform
	part.reparent(new_assembly)
	part.global_transform = world_transform
	return {
		"node": part,
		"old_parent": old_parent,
		"new_parent": new_assembly,
		"transform": world_transform
	}

func _split_floating_assemblies(candidate_assemblies: Array) -> void:
	var seen := {}
	var reparents := []

	for assembly in candidate_assemblies:
		if not is_instance_valid(assembly) or seen.has(assembly):
			continue
		seen[assembly] = true
		if not assembly.is_inside_tree() or assembly == $RobotWorkspace:
			continue

		var parts: Array = []
		for child in assembly.get_children():
			if child is PartBody:
				parts.append(child)
		if parts.size() <= 1:
			continue

		# Sync each part's collision shapes to the physics server once up
		# front, rather than re-syncing on every pairwise touch check below
		# (which was previously O(n^2) force_update_transform calls).
		for part in parts:
			sync_shapes_to_physics_server(part)

		var groups: Array = []
		for part in parts:
			var joined_group = null
			for group in groups:
				for other in group:
					if _parts_touching(part, other, ASSEMBLY_TOUCH_MARGIN, true):
						joined_group = group
						break
				if joined_group:
					break
			if joined_group:
				joined_group.append(part)
			else:
				groups.append([part])

		var merged := true
		while merged:
			merged = false
			for i in range(groups.size()):
				for j in range(groups.size() - 1, i, -1):
					var connected = false
					for a in groups[i]:
						for b in groups[j]:
							if _parts_touching(a, b, ASSEMBLY_TOUCH_MARGIN, true):
								connected = true
								break
						if connected:
							break
					if connected:
						groups[i].append_array(groups[j])
						groups.remove_at(j)
						merged = true

		if groups.size() <= 1:
			continue

		groups.sort_custom(func(a, b): return a.size() > b.size())
		for i in range(1, groups.size()):
			var new_assembly = Node3D.new()
			new_assembly.name = "Assembly_Float_" + str(assembly_id_counter)
			assembly_id_counter += 1
			$RobotWorkspace.add_child(new_assembly)
			new_assembly.global_transform = groups[i][0].global_transform
			for part in groups[i]:
				var world_t = part.global_transform
				var old_parent = part.get_parent()
				part.reparent(new_assembly)
				part.global_transform = world_t
				reparents.append({
					"node": part,
					"old_parent": old_parent,
					"new_parent": new_assembly,
					"transform": world_t
				})

	if reparents.is_empty():
		return

	is_modified = true
	register_history_action({
		"type": "multi_reparent",
		"reparents": reparents
	})
	
	_refresh_placed_part_visuals()

func _check_and_split_floating_parts(parts: Array) -> void:
	var split_actions := []
	for part in parts:
		if not is_instance_valid(part):
			continue
		if not _is_part_connected_to_its_assembly(part):
			var info = _split_part_into_new_assembly(part)
			if not info.is_empty():
				split_actions.append(info)
	if split_actions.is_empty():
		return
	is_modified = true
	if split_actions.size() == 1:
		register_history_action({
			"type": "reparent",
			"node": split_actions[0]["node"],
			"old_parent": split_actions[0]["old_parent"],
			"new_parent": split_actions[0]["new_parent"],
			"transform": split_actions[0]["transform"]
		})
	else:
		register_history_action({
			"type": "multi_reparent",
			"reparents": split_actions
		})

func try_join_selected_to_nearby_assembly() -> void:
	if selected_parts.is_empty():
		return

	var source_assemblies := []
	for part in selected_parts:
		if not is_instance_valid(part):
			continue
		var assembly = part.get_parent()
		if assembly and not source_assemblies.has(assembly):
			source_assemblies.append(assembly)

	if source_assemblies.size() < 2:
		return

	# Pre-sync all candidate parts' collision shapes once. Positions don't
	# change during this function (only reparenting, with global_transform
	# explicitly preserved), so a single sync per part up front is enough
	# for every pairwise touch check below.
	for assembly in source_assemblies:
		if not is_instance_valid(assembly):
			continue
		for child in assembly.get_children():
			if child is PartBody:
				sync_shapes_to_physics_server(child)

	var target_assembly: Node = source_assemblies[0]
	var remaining: Array = source_assemblies.slice(1)
	var reparents := []
	var merged_assemblies := []

	var merged_this_round := true
	while merged_this_round and not remaining.is_empty():
		merged_this_round = false
		var still_remaining := []
		for other_assembly in remaining:
			if not is_instance_valid(other_assembly) or not other_assembly.is_inside_tree():
				continue

			var touching = false
			for part_a in target_assembly.get_children():
				if not (part_a is PartBody):
					continue
				for part_b in other_assembly.get_children():
					if not (part_b is PartBody):
						continue
					if _parts_touching(part_a, part_b, ASSEMBLY_TOUCH_MARGIN, true):
						touching = true
						break
				if touching:
					break

			if not touching:
				still_remaining.append(other_assembly)
				continue

			var other_parts: Array = []
			for child in other_assembly.get_children():
				if child is PartBody:
					other_parts.append(child)

			for part in other_parts:
				var world_t = part.global_transform
				part.reparent(target_assembly)
				part.global_transform = world_t
				reparents.append({
					"node": part,
					"old_parent": other_assembly,
					"new_parent": target_assembly,
					"transform": world_t
				})

			merged_assemblies.append(other_assembly)
			merged_this_round = true

		remaining = still_remaining

	if reparents.is_empty():
		return

	is_modified = true
	var removed_assemblies = _remove_empty_assemblies(merged_assemblies)

	var action := {
		"type": "multi_reparent",
		"reparents": reparents
	}
	if not removed_assemblies.is_empty():
		action["removed_assemblies"] = removed_assemblies
	register_history_action(action)
	_refresh_placed_part_visuals()

func _find_empty_assemblies(candidates: Array) -> Array:
	var empties := []
	var seen := {}
	for node in candidates:
		if not is_instance_valid(node) or seen.has(node):
			continue
		seen[node] = true
		if node == $RobotWorkspace or not node.is_inside_tree():
			continue
		var has_parts = false
		for child in node.get_children():
			if child is PartBody:
				has_parts = true
				break
		if not has_parts:
			empties.append(node)
	return empties

func _remove_empty_assemblies(candidates: Array) -> Array:
	var removed := []
	for assembly in _find_empty_assemblies(candidates):
		var parent = assembly.get_parent()
		if parent:
			parent.remove_child(assembly)
			removed.append({"node": assembly, "parent": parent})
	return removed

func _undo_removed_assemblies(removed: Array) -> void:
	for r in removed:
		if is_instance_valid(r["node"]) and not r["node"].is_inside_tree():
			r["parent"].add_child(r["node"])

func _redo_removed_assemblies(removed: Array) -> void:
	for r in removed:
		if is_instance_valid(r["node"]) and r["node"].is_inside_tree():
			r["node"].get_parent().remove_child(r["node"])

func rename_part(part: PartBody, new_name: String) -> bool:
	if not is_instance_valid(part):
		return false
	new_name = new_name.strip_edges()
	if new_name == "":
		return false

	for other in get_all_placed_parts():
		if other != part and other.name == new_name:
			return false

	var old_name = part.name
	part.name = new_name

	register_history_action({
		"type": "rename",
		"node": part,
		"old_name": old_name,
		"new_name": new_name
	})
	return true

func generate_unique_part_name(base_name: String) -> String:
	var existing_names := {}
	for part in get_all_placed_parts():
		existing_names[part.name] = true

	var counter := 1
	var candidate := base_name + str(counter)
	while existing_names.has(candidate):
		counter += 1
		candidate = base_name + str(counter)
	return candidate

func _load_robot_from_path(path: String) -> void:
	if not FileAccess.file_exists(path):
		push_warning("File not found: " + path)
		return
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("Failed to open: " + path)
		return
	var json_string = file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(json_string)
	if parsed == null or not (parsed is Array):
		push_error("Invalid robot save data: " + path)
		return
	load_robot(parsed, true)
	is_modified = false
