class_name Robot3D
extends Node3D

const SAVE_DIR = "user://programs/"

@export var start_frozen: bool = false
@export var freeze_all:bool = false
@export var simulate_individual_rollers:bool = true

var assemblies:Array[PartAssembly]
var motors:Dictionary[int,Motor]
var pistons:Dictionary[int,Piston]
var brains:Array[Brain]
var main_assembely:PartAssembly
var _all_gears:Array[Gear] = []

var set_up = false
const PART_DETECTION_MASK = 12

var loaded = false

var loaded_parts: Dictionary = {}
var _part_type_scene_cache: Dictionary = {}

var debug_colors = false

var roboworld:RobotWorld3D

class Brain:
	var program_name = ""
	var ports:Dictionary[int,int] = {}
	
	func _init(n,p) -> void:
		program_name = n
		var c = 0
		for i in p:
			if i:
				ports[c] = i.id
				c += 1

static func _basis_from_z_axis(axis:Vector3) -> Basis:
	var z := axis.normalized()
	var up := Vector3.UP
	if absf(z.dot(up)) > 0.99:
		up = Vector3.RIGHT
	var x := up.cross(z).normalized()
	var y := z.cross(x).normalized()
	return Basis(x, y, z)

static func _basis_from_x_axis(axis:Vector3) -> Basis:
	var x := axis.normalized()
	var up := Vector3.UP
	if absf(x.dot(up)) > 0.99:
		up = Vector3.RIGHT
	var z := x.cross(up).normalized()
	var y := z.cross(x).normalized()
	return Basis(x, y, z)

static func make_hinge(a: RigidBody3D, b: RigidBody3D, anchor: Vector3, axis_dir: Vector3) -> JoltHingeJoint3D:
	if not a or not b:
		push_error("Cannot create hinge joint with null bodies")
		return null
		
	var j := JoltHingeJoint3D.new()

	var bas := _basis_from_z_axis(axis_dir)
	var world_frame := Transform3D(bas, anchor)
	
	j.name = "HingeJoint_" + str(a.name) + "_" + str(b.name)
	j.top_level = true
	j.global_transform = world_frame

	j.node_a = a.get_path()
	j.node_b = b.get_path()
	j.exclude_nodes_from_collision = true
	
	a.add_child(j)
	
	print("Created hinge joint: ", j.name)
	print("  Node A: ", j.node_a)
	print("  Node B: ", j.node_b)
	print("  Transform: ", j.global_transform)
	
	return j

static func make_slider(a:RigidBody3D, b:RigidBody3D, anchor:Vector3, axis_dir:Vector3) -> JoltSliderJoint3D:
	if not a or not b:
		push_error("Cannot create slider joint with null bodies")
		return null
		
	var j := JoltSliderJoint3D.new()
	j.name = "SliderJoint_" + str(a.name) + "_" + str(b.name)
	j.top_level = true
	j.global_transform = Transform3D(_basis_from_z_axis(axis_dir), anchor)
	j.node_a = a.get_path()
	j.node_b = b.get_path()
	a.add_child(j)
	j.exclude_nodes_from_collision = true
	
	print("Created slider joint: ", j.name)
	print("  Node A: ", j.node_a)
	print("  Node B: ", j.node_b)
	print("  Transform: ", j.global_transform)
	
	return j

class Piston extends JoltGeneric6DOFJoint3D:
	var axle:RigidBody3D
	
	var length:float
	var out = false
	
	var part_id = 0
	
	var velocity = 1.4
	var force = 54
	
	var roboworld:RobotWorld3D
	
	func _init(w,a,b,l,id,pos,axis) -> void:
		roboworld = w
		length = l
		part_id = id
		
		name = "Piston_" + str(id)
		top_level = true
		global_transform = Transform3D(Robot3D._basis_from_z_axis(axis), pos)
		node_a = a.get_path()
		node_b = b.get_path()

		exclude_nodes_from_collision = true
		
		set("linear_limit_y/lower", 0.0)
		set("linear_limit_y/upper", length * roboworld.SIZE_SCALE)
		set("linear_motor_y/max_force", force * roboworld.FORCE_SCALE)
		
		a.add_child(self)
		
		print("Created piston: ", name)
		print("  Node A: ", node_a)
		print("  Node B: ", node_b)
		print("  Transform: ", global_transform)
	
	func activate(rev=false):
		set("linear_motor_y/enabled", true)
		if rev:
			set("linear_motor_y/target_velocity", -velocity * roboworld.SPEED_SCALE)
		else:
			set("linear_motor_y/target_velocity", velocity * roboworld.SPEED_SCALE)
	
	func deactivate():
		set("linear_motor_y/enabled", false)
		set("linear_motor_y/target_velocity", 0)
	
	func lock():
		pass
	
	func unlock():
		pass
	
	func toggle():
		if out:
			activate()
		else:
			activate(true)
		out = !out

class Motor extends JoltHingeJoint3D:
	enum Brake {COAST, BRAKE, HOLD}
	var brake_mode:Brake = Brake.COAST
	
	var part_id = 0
	
	var inital_rpm = 3600
	var inital_toruque = 0.058
	var torque = 2.1
	var rpm = 100
	var efficency = 1.0
	
	var max_torque_pct := 100.0
	var timeout_sec := 1.0
	var target_position_deg := 0.0
	var position_move_active := false
	var move_start_ms := 0
	
	var axle:RigidBody3D
	var roboworld:RobotWorld3D

	func set_max_torque(pct: float) -> void:
		max_torque_pct = clampf(pct, 0.0, 100.0)

	func spin():
		motor_max_torque = torque * 10 * (max_torque_pct / 100.0) * roboworld.TORQUE_SCALE * roboworld.TORQUE_SCALE
		motor_enabled = true
		if motor_target_velocity == 0:
			motor_target_velocity = rpm * PI / 30.0
	
	func _init(w,a,b,id,ri,ro,pos,axis) -> void:
		roboworld = w
		part_id = id
		
		torque = inital_toruque * ri * ro
		rpm = inital_rpm / (ri * ro)
		
		name = "Motor_" + str(id)
		top_level = true
		global_transform = Transform3D(Robot3D._basis_from_z_axis(axis), pos)
		node_a = a.get_path()
		node_b = b.get_path()
		a.add_child(self)

		exclude_nodes_from_collision = true
		
		print("Created motor: ", name)
		print("  Node A: ", node_a)
		print("  Node B: ", node_b)
		print("  Transform: ", global_transform)
	
	func set_velocity(p:float):
		var max_speed = rpm * PI / 30.0
		motor_target_velocity = (clampf(p, -127.0, 127.0) / 127.0) * max_speed
	
	func set_braking(n:Brake):
		brake_mode = n
	
	func brake():
		motor_target_velocity = 0
		match brake_mode:
			Brake.BRAKE:
				motor_enabled = true
			Brake.COAST:
				motor_enabled = false

class Axle extends PartAssembly:
	pass

class PartAssembly extends RigidBody3D:
	var part_ids:Array = []
	var id:int
	var root_assembely:PartAssembly
	var material:StandardMaterial3D
	var spinning_connections_to_make:Dictionary[int,Transform3D]
	var sliding_connections_to_make:Dictionary[int,Transform3D]
	
	static var ids:int = 0
	
	func _init(world:RobotWorld3D, root_assmeb:PartAssembly = null) -> void:
		gravity_scale = world.GRAVITY_SCALE
		freeze = true
		top_level = true
		continuous_cd = true
		
		root_assembely = root_assmeb
		
		id = ids
		ids += 1
		
		var hue = fmod(id * 0.618033988749895, 1.0)
		var color = Color.from_hsv(hue, 0.8, 0.9, 0.0)
		material = StandardMaterial3D.new()
		material.albedo_color = color
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	
	func activate_body():
		freeze = false
		for i in get_children():
			if i is RigidBody3D:
				i.freeze = false
	
	func final_setup():
		for i in get_children():
			if i is GeometryInstance3D:
				i.material_overlay = material
	
	func set_colors(a = 1.0):
		material.albedo_color.a = a

class Gear extends PartAssembly:
	@export var radius: float = 1.0
	@export var teeth: int = 20

	var spin_axis: Vector3 = Vector3.FORWARD
	var current_speed: float = 0.0

	var mount_joint: JoltHingeJoint3D = null
	var mount_partner: PartAssembly = null
	var mount_axis_sign: float = 1.0

	var meshed_connections: Array[Gear] = []
	var chain_connection_ids: Array = []
	var chain_connections: Array[Gear] = []

class OmniWheel extends PartAssembly:
	var rolling_axis:Vector3
	
	func _init(world, r, root_assmeb:PartAssembly = null) -> void:
		super(world, root_assmeb)
		rolling_axis = r.normalized()
	
	func _ready() -> void:
		physics_material_override = PhysicsMaterial.new()
	
	func _physics_process(delta):
		physics_material_override.friction = 0.5

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

func _ready() -> void:
	roboworld = get_node(".").owner   
	loaded_parts.clear()
	for scene in part_scenes:
		if scene:
			var key = scene.get_path().get_file().get_basename()
			loaded_parts[key] = scene
	
	if not loaded:
		compile_robot()

func attach_shapes(target: RigidBody3D, part: PartBody):
	var candidates: Array = part.get_children()
	part.set_collision_layer_value(PART_DETECTION_MASK, true)
	
	for child in candidates:
		if child is GeometryInstance3D or child is CollisionShape3D:
			var child_global = child.global_transform
			var fresh = child.duplicate(true)
			target.add_child(fresh)
			fresh.transform = target.transform.affine_inverse() * child_global
			
			if part.part_type == PartBody.Types.OMNIWHEEL and fresh.name == "omni_wheel":
				if simulate_individual_rollers:
					for i:RigidBody3D in fresh.get_node("Wp").get_children():
						i.reparent(target)
						i.top_level = true
						i.freeze = true
						i.gravity_scale = roboworld.GRAVITY_SCALE
						i.continuous_cd = true
						
						make_hinge(target, i, i.global_position, i.global_basis.z)
					
					for i:RigidBody3D in fresh.get_node("Wn").get_children():
						i.reparent(target)
						i.top_level = true
						i.freeze = true
						i.gravity_scale = roboworld.GRAVITY_SCALE
						i.continuous_cd = true
						
						make_hinge(target, i, i.global_position, i.global_basis.z)
				else:
					for i:RigidBody3D in fresh.get_node("Wp").get_children():
						for v in i.get_children():
							v.reparent(target)
					
					for i:RigidBody3D in fresh.get_node("Wn").get_children():
						for v in i.get_children():
							v.reparent(target)

func set_robot(d):
	loaded = true
	
	clear_robot()
	if is_inside_tree():
		build_robot(d)
	else:
		call_deferred("build_robot", d)

func clear_robot() -> void:
	for child in get_children():
		remove_child(child)
		child.free()
	
	assemblies.clear()
	motors.clear()
	pistons.clear()
	brains.clear()
	runtime = null
	set_up = false
	PartAssembly.ids = 0

func build_robot(robodata):
	var id_to_part: Dictionary = {}
	var part_data_by_id: Dictionary = {}

	for assembly_data in robodata:
		if not (assembly_data is Dictionary):
			continue

		var assembly := Node3D.new()
		assembly.name = "LoadedAssembly_" + str(id_to_part.size())
		add_child(assembly)

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
				if value is Dictionary and value.has("__refs__"):
					continue
				if prop_name in part:
					part.set(prop_name, value)
				else:
					push_warning("RobotLoader: Property not found on part: ", prop_name)

			if part_data.has("transform"):
				var transform_data = part_data["transform"]
				if transform_data is Dictionary:
					var t = _dict_to_transform(transform_data)
					part.global_transform = t
					part.reset_physics_interpolation()
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
				if prop_name in part:
					if prop_name == "ports" or prop_name == "connections" or prop_name == "connecting_to":
						var typed_refs: Array[PartBody] = []
						typed_refs.assign(refs)
						part.set(prop_name, typed_refs)
					else:
						part.set(prop_name, refs)
				else:
					push_warning("RobotLoader: Reference property not found: ", prop_name)
	
	call_deferred("compile_robot")

func _dict_to_transform(d: Dictionary) -> Transform3D:
	var basis_x = Vector3(d["basis_x"][0], d["basis_x"][1], d["basis_x"][2])
	var basis_y = Vector3(d["basis_y"][0], d["basis_y"][1], d["basis_y"][2])
	var basis_z = Vector3(d["basis_z"][0], d["basis_z"][1], d["basis_z"][2])
	var origin = Vector3(d["origin"][0], d["origin"][1], d["origin"][2])
	return Transform3D(Basis(basis_x, basis_y, basis_z), origin)

func _get_scene_for_type(part_type: int) -> PackedScene:
	if _part_type_scene_cache.has(part_type):
		return _part_type_scene_cache[part_type]

	for scene in loaded_parts.values():
		var tmp = scene.instantiate() as PartBody
		if tmp and tmp.part_type == part_type:
			_part_type_scene_cache[part_type] = scene
			tmp.free()
			return scene
		if tmp:
			tmp.free()
	return null

func _get_scene_for_part_data(part_data: Dictionary) -> PackedScene:
	if part_data.has("scene"):
		var scene_name: String = part_data["scene"]
		if loaded_parts.has(scene_name):
			return loaded_parts[scene_name]

	if part_data.has("type"):
		var part_type: int = int(part_data["type"])
		return _get_scene_for_type(part_type)

	return null

func create_axle(orig:PartBody, parent:PartBody, root = null):
	var axle:Axle = Axle.new(roboworld, root)
	
	if parent:
		axle.name = parent.name + "-axle"
	else:
		axle.name = orig.name
	
	assemblies.append(axle)
	axle.global_position = orig.find_child("axle", false).global_position
	axle.part_ids.append(orig.id)
	axle.reset_physics_interpolation()
	
	attach_shapes(axle, orig)
	add_child(axle)
	
	return axle

func get_axle_connect_to(axle:PartBody):
	var cast:RayCast3D = axle.find_child("RayCast3D")
	var coll_assembely:PartBody = null
	
	cast.add_exception_rid(axle.get_rid())
	cast.collide_with_areas = false
	cast.collide_with_bodies = true
	cast.set_collision_mask_value(PART_DETECTION_MASK, true)
	cast.force_raycast_update()
	
	if cast.is_colliding():
		print("Raycast hit: ", cast.get_collider())
		coll_assembely = cast.get_collider()
	else:
		print("Raycast missed for axle: ", axle.name)
	
	var joints:Dictionary[int,Transform3D]
	
	while coll_assembely:
		var pos = cast.get_collision_point()
		var nor = (cast.get_collision_point() - cast.global_position).normalized()
		if coll_assembely.for_axle:
			pos = coll_assembely.global_position
		
		var transf = Transform3D(_basis_from_z_axis(nor), pos)
		joints[coll_assembely.id] = transf
		
		cast.add_exception_rid(coll_assembely.get_rid())
		cast.force_raycast_update()
		coll_assembely = cast.get_collider()
	
	print("Found ", joints.size(), " connections for axle: ", axle.name)
	return joints

func compile_robot():
	print("Starting robot compilation...")
	var all_nodes = get_children()
	var groups = []
	var axle_parts:Array[PartBody]
	for node in all_nodes:
		if node is Area3D:
			groups.append([node])
		elif node is Node3D and node.get_child_count() > 0:
			groups.append(node.get_children())
	
	print("Found ", groups.size(), " groups")
	
	for parts in groups:
		for part:PartBody in parts:
			part.position *= roboworld.SIZE_SCALE * 1.0
			if part.has_method("update"):
				part.update(roboworld.SIZE_SCALE)
	
	var min_y = INF
	var bottom_point = Vector3.ZERO
	
	for assembly in all_nodes:
		for part in assembly.get_children():
			for child in part.get_children():
				if child is VisualInstance3D:
					var local_aabb: AABB = child.get_aabb()
					for i in range(8):
						var corner = local_aabb.get_endpoint(i)
						var global_corner = child.global_transform * corner
						
						if global_corner.y < min_y:
							min_y = global_corner.y
							bottom_point = global_corner
	
	global_position.y -= bottom_point.y - 2
	
	for assembely_parts in groups:
		var assembely:RigidBody3D
		
		if assembely_parts.size() == 1 and assembely_parts[0].part_type == PartBody.Types.OMNIWHEEL:
			assembely = OmniWheel.new(roboworld, assembely_parts[0].global_basis.z)
		elif assembely_parts.size() == 1 and assembely_parts[0].part_type == PartBody.Types.GEAR:
			assembely = Gear.new(roboworld)
			assembely.radius = assembely_parts[0].radius
			assembely.teeth = round(1889.76 * assembely_parts[0].radius)
			assembely.spin_axis = -(assembely_parts[0].global_basis.z)
			for i in assembely_parts[0].connections:
				assembely.chain_connection_ids.append(i.id)
		else:
			assembely = PartAssembly.new(roboworld)
		
		var n = assembely_parts[0].get_parent().name
		assembely_parts[0].get_parent().name = "temp"
		assembely.name = n
		assembely.top_level = true
		assemblies.append(assembely)
		
		var avg_pos = Vector3.ZERO
		var axle_count = 0
		for part in assembely_parts:
			if part.part_type != PartBody.Types.AXLE:
				avg_pos += part.to_global(part.center_of_mass)
			else:
				axle_count += 1
		if assembely_parts.size() - axle_count > 0:
			avg_pos /= assembely_parts.size() - axle_count
		assembely.global_position = avg_pos
		
		add_child(assembely)
		
		print("Created assembly: ", assembely.name, " at position: ", avg_pos)
		
		for part:PartBody in assembely_parts:
			if part.part_type != PartBody.Types.AXLE:
				assembely.part_ids.append(part.id)
			
			if part.part_type == PartBody.Types.PISTON:
				var push_node := part.get_node("push")
				var push_axis = part.get_node("push_lock").global_basis.z
				var axle:PartAssembly = create_axle(push_node, part, assembely)
				
				axle_parts.append(push_node)
				await get_tree().process_frame
				
				var pis := Piston.new(roboworld, assembely, axle, part.length / 2, part.id, axle.global_position, push_axis)
				pistons[part.id] = pis
				pis.axle = axle
				pis.name = part.name + "-axle_connect"
				
			elif part.part_type == PartBody.Types.MOTOR:
				var spin_node := part.get_node("spin")
				var spin_axis = part.get_node("spin_lock").global_basis.z
				var axle:PartAssembly = create_axle(spin_node, part, assembely)
				
				axle_parts.append(spin_node)
				await get_tree().process_frame
				
				var mot := Motor.new(roboworld, assembely, axle, part.id, part.ratio_in, part.ratio_out, axle.global_position, spin_axis)
				motors[part.id] = mot
				mot.axle = axle
				mot.name = part.name + "-axle_connect"
				
			elif part.part_type == PartBody.Types.AXLE:
				var axle_axis = -(part.global_basis.z)
				var axle:PartAssembly = create_axle(part, null, assembely)
				
				axle_parts.append(part)
				
				var joint := Robot3D.make_hinge(assembely, axle, axle.global_position, axle_axis)
				if joint:
					joint.name = part.name + "-axle_connect"
			elif part.part_type == PartBody.Types.BRAIN:
				if not main_assembely:
					main_assembely = assembely
				
				var b = Brain.new(part.program_name, part.ports)
				brains.append(b)
			
			if not part.part_type == PartBody.Types.AXLE:
				attach_shapes(assembely, part)
		
	print("Waiting for physics frames...")
	for i in range(2):
		await get_tree().physics_frame
	
	print("Creating axle connections...")
	for axle in axle_parts:
		var parts:Dictionary[int,Transform3D] = get_axle_connect_to(axle)
		for id in parts.keys():
			var a_assemb:PartAssembly
			var b_assemb:PartAssembly
			
			for a:PartAssembly in assemblies:
				if a.part_ids.has(id):
					b_assemb = a
					break
			for a:PartAssembly in assemblies:
				if a.part_ids.has(axle.id):
					a_assemb = a
					break
			
			if a_assemb and b_assemb and (not a_assemb == b_assemb) and (not a_assemb.root_assembely == b_assemb):
				print("Creating connection between ", a_assemb.name, " and ", b_assemb.name)
				var h = make_hinge(a_assemb, b_assemb, parts[id].origin, -parts[id].basis.z)
				if h:
					h.limit_enabled = true
					_wire_gear_mount(a_assemb, b_assemb, h)
	
	for assembely in assemblies:
		if assembely is Gear:
			for i in assembely.chain_connection_ids:
				for connect_assemb in assemblies:
					if connect_assemb.part_ids.has(i):
						if !assembely.chain_connections.has(connect_assemb):
							assembely.chain_connections.append(connect_assemb)
						if connect_assemb is Gear and !connect_assemb.chain_connections.has(assembely):
							connect_assemb.chain_connections.append(assembely)
						break
	
	_rebuild_axle_to_motor()
	
	_all_gears.clear()
	for a in assemblies:
		if a is Gear:
			_all_gears.append(a)
	
	if brains.size() > 0:
		runtime = BlockRuntime.new()
		runtime.robot = self
		runtime.setup()
		
		for brain in brains:
			var file_path = SAVE_DIR + brain.program_name + ".json"
			if FileAccess.file_exists(file_path):
				runtime.load_from_file(file_path, brain.ports)
			else:
				push_warning("Program file not found: ", file_path)
	
	for i in all_nodes:
		i.queue_free()
	
	print("Robot compilation complete. Created ", motors.size(), " motors, ", pistons.size(), " pistons")
	setup()

func _wire_gear_mount(a_assemb: PartAssembly, b_assemb: PartAssembly, hinge: JoltHingeJoint3D) -> void:
	for pair in [[a_assemb, b_assemb], [b_assemb, a_assemb]]:
		var gear := pair[0] as Gear
		if gear and gear.mount_joint == null:
			gear.mount_joint = hinge
			gear.mount_partner = pair[1]
			gear.mount_axis_sign = signf(hinge.global_basis.z.dot(gear.spin_axis))

const GEAR_MESH_AXIS_TOLERANCE := 0.98
const GEAR_MESH_DISTANCE_SLACK := 0.15

func _update_gear_meshing() -> void:
	for gear in _all_gears:
		gear.meshed_connections.clear()
	
	for i in range(_all_gears.size()):
		var ga := _all_gears[i]
		for j in range(i + 1, _all_gears.size()):
			var gb := _all_gears[j]
			
			if absf(ga.spin_axis.dot(gb.spin_axis)) < GEAR_MESH_AXIS_TOLERANCE:
				continue
			
			var expected_dist = (ga.radius + gb.radius) * roboworld.SIZE_SCALE
			var actual_dist = ga.global_position.distance_to(gb.global_position)
			
			if absf(actual_dist - expected_dist) <= expected_dist * GEAR_MESH_DISTANCE_SLACK:
				ga.meshed_connections.append(gb)
				gb.meshed_connections.append(ga)

var _axle_to_motor: Dictionary = {}

func _rebuild_axle_to_motor() -> void:
	_axle_to_motor.clear()
	for m in motors.values():
		_axle_to_motor[m.axle] = m

func setup():
	print("Waiting for physics frames... again...")
	for i in range(2):
		await get_tree().physics_frame
	
	for i:Piston in pistons.values():
		i.activate()
	
	if runtime:
		runtime.trigger_event("ready")
	
	if !freeze_all:
		for i in assemblies:
			if i == main_assembely:
				if !start_frozen:
					i.activate_body()
			else:
				i.activate_body()
	
	set_up = true

func _process(delta: float) -> void:
	if Input.is_action_just_pressed("debug_colors"):
		if debug_colors:
			debug_colors = false
			for a in assemblies:
				a.set_colors(0.0)
		else:
			debug_colors = true
			for a in assemblies:
				a.set_colors(1.0)

func _physics_process(delta: float) -> void:
	if not set_up:
		return
	
	if assemblies.size() > 0:
		var avg_pos = Vector3.ZERO
		for i in assemblies:
			avg_pos += i.global_position
		
		global_position = avg_pos / float(assemblies.size())
	
	if runtime:
		runtime.trigger_event("driver")
		if runtime.is_running:
			runtime.tick(delta)
	
	_update_gear_meshing()
	drive_gear_train(delta)

func _input(event: InputEvent) -> void:
	if runtime and runtime.is_running:
		runtime.process_input()

const GEAR_MESH_CORRECTION := 1.0

func drive_gear_train(delta: float) -> void:
	var done := {}
	for ga in _all_gears:
		for gb in (ga.meshed_connections + ga.chain_connections):
			var key = [ga, gb] if ga.get_instance_id() < gb.get_instance_id() else [gb, ga]
			if done.has(key):
				continue
			done[key] = true

			var is_chain = gb in ga.chain_connections
			var w_a = ga.angular_velocity.dot(ga.spin_axis)
			var w_b = gb.angular_velocity.dot(gb.spin_axis)
			var alignment = ga.spin_axis.dot(gb.spin_axis)
			var dir = 1.0 if is_chain else -1.0
			var flip = dir if alignment > 0 else -dir

			var tangential_a = w_a * ga.radius
			var tangential_b = flip * w_b * gb.radius
			var error = tangential_a - tangential_b

			var dw_a = -error / ga.radius * GEAR_MESH_CORRECTION
			var dw_b = flip * error / gb.radius * GEAR_MESH_CORRECTION
			
			ga.apply_torque(ga.spin_axis * dw_a)
			gb.apply_torque(gb.spin_axis * dw_b)

var runtime: BlockRuntime
var active_program_path: String = ""
var controller_inputs: Dictionary = {}

func load_program(file_path: String) -> void:
	if runtime:
		runtime.load_from_file(file_path)
		active_program_path = file_path

func set_motor_max_torque(motor_id: int, pct: float) -> void:
	if motors.has(motor_id):
		motors[motor_id].set_max_torque(pct)
		motors[motor_id].spin()

func set_motor_timeout(motor_id: int, seconds: float) -> void:
	if motors.has(motor_id):
		motors[motor_id].timeout_sec = seconds

func start_motor_move_to_position(motor_id: int, target_deg: float, velocity_pct: float) -> void:
	if not motors.has(motor_id):
		return
	var m = motors[motor_id]
	m.target_position_deg = target_deg
	m.position_move_active = true
	m.move_start_ms = Time.get_ticks_msec()
	var dir = 1.0 if target_deg >= get_motor_position(motor_id) else -1.0
	set_motor_velocity(motor_id, abs(velocity_pct) * dir)

func is_motor_move_done(motor_id: int) -> bool:
	if not motors.has(motor_id):
		return true
	var m = motors[motor_id]
	if not m.position_move_active:
		return true
	var elapsed = (Time.get_ticks_msec() - m.move_start_ms) / 1000.0
	var arrived = abs(get_motor_position(motor_id) - m.target_position_deg) < 2.0
	if arrived or elapsed >= m.timeout_sec:
		m.position_move_active = false
		set_motor_velocity(motor_id, 0)
		m.brake()
		return true
	return false

func set_motor_velocity(motor_id: int, speed_pct: float) -> void:
	if motors.has(motor_id):
		motors[motor_id].set_velocity(speed_pct)
		motors[motor_id].spin()

func set_piston_state(piston_id: int, extend: bool) -> void:
	if pistons.has(piston_id):
		if extend != pistons[piston_id].out:
			pistons[piston_id].toggle()

func get_motor_position(motor_id: int) -> float:
	if motors.has(motor_id):
		return motors[motor_id].axle.rotation_degrees.z
	return 0.0

func get_motor_velocity(motor_id: int) -> float:
	if motors.has(motor_id):
		return motors[motor_id].axle.get_angular_velocity().z
	return 0.0
