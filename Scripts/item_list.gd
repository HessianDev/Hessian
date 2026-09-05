extends ItemList

@onready var builder_manager = $"../../"

var last_selected_index: int = -1

func _ready() -> void:
	await get_tree().process_frame
	clear()
	
	for part_name in builder_manager.loaded_parts.keys():
		add_item(part_name)
		
	item_clicked.connect(_on_item_clicked)
	empty_clicked.connect(_on_empty_clicked)

func _on_item_clicked(index: int, _at_position: Vector2, mouse_button_index: int) -> void:
	if mouse_button_index == MOUSE_BUTTON_LEFT:
		if last_selected_index == index:
			cancel_selection()
			return
			
		last_selected_index = index
		var part_name = get_item_text(index)
		
		builder_manager.clear_selection()
		
		if builder_manager.preview_node:
			builder_manager.preview_node.queue_free()
			
		builder_manager.selected_part_name = part_name
		builder_manager.preview_node = builder_manager.loaded_parts[part_name].instantiate()
		
		if builder_manager.preview_node.has_method("update"):
			builder_manager.preview_node.update(1)
		
		builder_manager.disable_physics_recursive(builder_manager.preview_node)
		
		builder_manager.add_child(builder_manager.preview_node)
		
		builder_manager.current_mode = builder_manager.Mode.BUILD

func _on_empty_clicked(_at_position: Vector2, mouse_button_index: int) -> void:
	if mouse_button_index == MOUSE_BUTTON_LEFT:
		cancel_selection()

func cancel_selection() -> void:
	deselect_all()
	last_selected_index = -1
	builder_manager.cancel_build()

func clear_selection() -> void:
	deselect_all()
	last_selected_index = -1
