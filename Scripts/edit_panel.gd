extends Panel

@onready var properties_container: VBoxContainer = $VBox/PropertiesContainer
@onready var delete_button: Button = $VBox/DeleteButton
@onready var create_assembly_button: Button = $VBox/CreateAssemblyButton

var builder_manager: Node3D
var current_part: PartBody = null

const EXPOSED_PROPERTIES = {
	"axle_length": {"type": TYPE_FLOAT, "min": 0.01, "max": 0.5, "step": 0.005},
	"radius": {"type": TYPE_FLOAT, "min": 0.01, "max": 0.2, "step": 0.005},
	"height": {"type": TYPE_FLOAT, "min": 0.005, "max": 0.1, "step": 0.005},
	"length": {"type": TYPE_FLOAT, "min": 0.01, "max": 1.0, "step": 0.005},
	"width": {"type": TYPE_FLOAT, "min": 0.01, "max": 0.5, "step": 0.005},
	"SideLength_R": {"type": TYPE_FLOAT, "min": 0.005, "max": 0.2, "step": 0.005},
	"SideLength_L": {"type": TYPE_FLOAT, "min": 0.005, "max": 0.2, "step": 0.005},
	"extend": {"type": TYPE_FLOAT, "min": 0.0, "max": 1.0, "step": 0.05},
	"plate": {"type": TYPE_BOOL},
	"ratio_in": {"type": TYPE_INT, "min": 1, "max": 32, "step": 1},
	"ratio_out": {"type": TYPE_INT, "min": 1, "max": 32, "step": 1},
}

const PROGRAM_FOLDER = "user://programs/"

func _ready() -> void:
	builder_manager = $"../../" 
	hide()
	delete_button.pressed.connect(func(): builder_manager.delete_selected_part())
	create_assembly_button.pressed.connect(_on_create_assembly_pressed)
	name_lineedit.text_submitted.connect(_on_name_submitted)
	name_lineedit.focus_exited.connect(_on_name_focus_exited)

func _on_create_assembly_pressed() -> void:
	if current_part and builder_manager:
		builder_manager.selected_part = current_part 
		builder_manager.make_selected_part_new_assembly()
		display_properties(current_part)

func display_properties(part: PartBody) -> void:
	self.show()
	current_part = part
	create_assembly_button.visible = true
	$VBox/to_editor.visible = false
	
	name_lineedit.text = part.name
	
	for child in properties_container.get_children():
		child.queue_free()

	for prop_name in EXPOSED_PROPERTIES.keys():
		if prop_name in part:
			var config = EXPOSED_PROPERTIES[prop_name]
			create_ui_element(prop_name, config)
	
	match part.part_type:
		PartBody.Types.GEAR:
			_add_connection_list_ui(part, "connections", "Gear Connections")
		PartBody.Types.BRAIN:
			$VBox/to_editor.visible = true
			if "ports" in part:
				_add_connection_list_ui(part, "ports", "Ports")
			if "program_name" in part:
				_add_program_dropdown(part)
		PartBody.Types.STATIC:
			if "ports" in part:
				_add_connection_list_ui(part, "ports", "Ports")
			if "program_name" in part:
				_add_program_dropdown(part)

func _add_connection_list_ui(part: PartBody, prop_name: String, label_text: String) -> void:
	var section = VBoxContainer.new()
	var label = Label.new()
	label.text = label_text + ":"
	section.add_child(label)

	var list_container = VBoxContainer.new()
	var arr = part.get(prop_name)
	if arr is Array:
		for item in arr:
			if is_instance_valid(item):
				var hbox = HBoxContainer.new()
				var item_label = Label.new()
				item_label.text = item.name
				item_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				hbox.add_child(item_label)

				var remove_btn = Button.new()
				remove_btn.text = "✕"
				remove_btn.pressed.connect(func():
					var old_arr = arr.duplicate()
					arr.erase(item)
					part.set(prop_name, arr)
					builder_manager.register_history_action({
						"type": "property_change",
						"node": part,
						"prop_name": prop_name,
						"old_val": old_arr,
						"new_val": arr.duplicate()
					})
					display_properties(part)
				)
				hbox.add_child(remove_btn)
				list_container.add_child(hbox)

	section.add_child(list_container)

	var add_btn = Button.new()
	add_btn.text = "Add " + label_text
	add_btn.pressed.connect(func():
		builder_manager.start_connection_selection(part, prop_name)
	)
	section.add_child(add_btn)

	properties_container.add_child(section)

func _add_program_dropdown(part: PartBody) -> void:
	var hbox = HBoxContainer.new()
	var label = Label.new()
	label.text = "Program: "
	label.custom_minimum_size.x = 80
	hbox.add_child(label)

	var dropdown = OptionButton.new()
	dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var dir = DirAccess.open(PROGRAM_FOLDER)
	var programs: Array[String] = []
	if dir:
		dir.list_dir_begin()
		var file = dir.get_next()
		while file != "":
			if not dir.current_is_dir():
				programs.append(file)
			file = dir.get_next()
		dir.list_dir_end()
	else:
		var err = DirAccess.make_dir_recursive_absolute(PROGRAM_FOLDER)

	dropdown.add_item("None")
	for prog in programs:
		dropdown.add_item(prog.replace(".json",""))

	var current_prog = part.get("program_name")
	if current_prog == null:
		current_prog = ""
	var selected_idx = 0
	if current_prog != "":
		for i in range(dropdown.item_count):
			if dropdown.get_item_text(i) == current_prog:
				selected_idx = i
				break
		if selected_idx == 0 and dropdown.get_item_text(0) != current_prog:
			part.set("program_name", "")
	dropdown.select(selected_idx)

	dropdown.item_selected.connect(func(selected_idx: int):
		var old_val = part.get("program_name")
		var selected = dropdown.get_item_text(selected_idx)
		if selected == "None":
			selected = ""
		part.set("program_name", selected)
		builder_manager.register_history_action({
			"type": "property_change",
			"node": part,
			"prop_name": "program_name",
			"old_val": old_val,
			"new_val": selected
		})
	)

	hbox.add_child(dropdown)
	properties_container.add_child(hbox)

func create_ui_element(prop_name: String, config: Dictionary) -> void:
	var hbox = HBoxContainer.new()
	var label = Label.new()
	label.text = prop_name.capitalize() + ": "
	label.custom_minimum_size.x = 80
	hbox.add_child(label)
	
	if config["type"] == TYPE_FLOAT or config["type"] == TYPE_INT:
		var slider = HSlider.new()
		slider.min_value = config["min"]
		slider.max_value = config["max"]
		slider.step = config["step"]
		slider.value = current_part.get(prop_name)
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		
		var value_label = Label.new()
		value_label.text = "%0.3f" % slider.value
		
		slider.drag_started.connect(func():
			if builder_manager.has_method("start_property_drag"):
				builder_manager.start_property_drag(current_part, prop_name)
		)
		
		slider.value_changed.connect(func(val):
			if is_equal_approx(current_part.get(prop_name), val):
				return
			var accepted := true
			if builder_manager.has_method("resize_property_smooth"):
				accepted = builder_manager.resize_property_smooth(current_part, prop_name, val)
			else:
				current_part.set(prop_name, val)
				if current_part.has_method("update"):
					current_part.update(1)
			value_label.text = "%0.3f" % current_part.get(prop_name)
			if not accepted:
				slider.set_value_no_signal(current_part.get(prop_name))
		)
		
		slider.drag_ended.connect(func(_value_changed: bool):
			if builder_manager.has_method("end_property_drag"):
				builder_manager.end_property_drag(current_part, prop_name)
		)
		
		hbox.add_child(slider)
		hbox.add_child(value_label)
		
	elif config["type"] == TYPE_BOOL:
		var checkbox = CheckButton.new()
		checkbox.button_pressed = current_part.get(prop_name)
		checkbox.toggled.connect(func(pressed):
			current_part.set(prop_name, pressed)
			if current_part.has_method("update"):
				current_part.update(1)
		)
		hbox.add_child(checkbox)
		
	properties_container.add_child(hbox)

func _on_to_editor_pressed() -> void:
	$"../CodeEditor".visible = true

func _on_exit_coder_pressed() -> void:
	$"../CodeEditor".visible = false

func _on_name_submitted(new_text: String) -> void:
	_commit_name(new_text)

@onready var name_lineedit: LineEdit = $VBox/Name

func _on_name_focus_exited() -> void:
	if current_part and name_lineedit.text != current_part.name:
		_commit_name(name_lineedit.text)

func _commit_name(new_name: String) -> void:
	if current_part == null:
		return
	new_name = new_name.strip_edges()
	if new_name == "":
		name_lineedit.text = current_part.name
		return
	if new_name == current_part.name:
		return
	if builder_manager and builder_manager.rename_part(current_part, new_name):
		pass
	else:
		name_lineedit.text = current_part.name
