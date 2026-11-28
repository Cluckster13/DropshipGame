class_name BuyZone
extends Area3D
## Put this on a base's Area3D. When the player's helicopter is inside the
## area and landed, BuyMenu (B) opens the requisition screen. Bought squads
## spawn beside the aircraft (or at spawn_point) and run to the door to board.
##
## Squad types: everything in squad_types_dir is listed automatically, or set
## squad_types by hand to limit what this base sells.

@export var squad_types : Array[SquadType] = []
@export_dir var squad_types_dir : String = "res://Resources/SquadTypes"
## Vehicles for sale. Empty = everything in vehicle_types_dir.
@export var vehicle_types : Array[VehicleType] = []
@export_dir var vehicle_types_dir : String = "res://Resources/VehicleTypes"
## Where bought ground vehicles appear and drive off from. Empty = in front
## of the aircraft.
@export var vehicle_spawn_point : Node3D
## Where bought sling loads (AA emplacements) appear. Empty = behind the
## aircraft, ready to hook.
@export var sling_spawn_point : Node3D
## Where vehicle nodes are added. Empty = the current scene root.
@export var vehicle_parent : Node
@export var troop_scene : PackedScene = preload("res://Scenes/Troop.tscn")
## The requisition screen and the on-screen "B - Requisition troops" prompt
## (both are scenes, edit their layout there)
@export var menu_scene : PackedScene = preload("res://Scenes/BuyMenu.tscn")
@export var prompt_scene : PackedScene = preload("res://Scenes/BuyPrompt.tscn")
## Where bought troops appear. Empty = beside the aircraft's loading door.
@export var spawn_point : Node3D
@export var spawn_distance_from_aircraft : float = 14.0
## Where new Squad nodes are added. Empty = the current scene root.
@export var squad_parent : Node
## Physics layer the helicopter is on (TestHelicopter uses 2). Added to this
## area's mask on start so it actually detects the aircraft.
@export_range(1, 32, 1) var aircraft_layer : int = 2
## Hull points repaired per second while the aircraft sits landed here
@export var repair_per_second : float = 50.0

var _aircraft : HeliBase = null
var _menu : BuyMenu
var _prompt_layer : CanvasLayer
var _prompt : Label
var _bought_count : int = 0
var _restore_mouse_mode : Input.MouseMode = Input.MOUSE_MODE_CAPTURED

func _ready() -> void:
	set_collision_mask_value(aircraft_layer, true)
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

	if squad_types.is_empty():
		for r in _load_dir(squad_types_dir):
			if r is SquadType:
				squad_types.append(r)
	if vehicle_types.is_empty():
		for r in _load_dir(vehicle_types_dir):
			if r is VehicleType:
				vehicle_types.append(r)
	var by_tier_then_cost := func(a, b): return a.tier < b.tier or (a.tier == b.tier and a.cost < b.cost)
	squad_types.sort_custom(by_tier_then_cost)
	vehicle_types.sort_custom(by_tier_then_cost)

	_menu = menu_scene.instantiate() as BuyMenu
	_menu.visible = false
	add_child(_menu)
	_menu.set_items(squad_types, vehicle_types)
	_menu.purchase_requested.connect(_buy)
	_menu.close_requested.connect(close_menu)

	_build_prompt()

func _process(delta: float) -> void:
	_update_prompt()
	if is_instance_valid(_aircraft) and _aircraft.is_landed():
		_aircraft.repair(repair_per_second * delta)
	if _menu.visible:
		if not _can_shop():
			close_menu()
		else:
			_refresh_menu()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("BuyMenu"):
		if _menu.visible:
			close_menu()
		elif _can_shop() and not _is_gunning():
			open_menu()
	elif event.is_action_pressed("ui_cancel") and _menu.visible:
		close_menu()
		get_viewport().set_input_as_handled()

# ---------------------------------------------------------------- menu

func open_menu() -> void:
	_restore_mouse_mode = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_refresh_menu()
	_menu.visible = true

func close_menu() -> void:
	if not _menu.visible:
		return
	_menu.visible = false
	Input.mouse_mode = _restore_mouse_mode

func _refresh_menu() -> void:
	var ph := _passengers()
	var free := ph.free_seat_count() if ph else -1
	var total := ph.seat_count() if ph else 0
	_menu.refresh(_economy().funds if _economy() else 0, free, total)

# ---------------------------------------------------------------- buying

func _buy(item: Resource) -> void:
	if item is VehicleType:
		_buy_vehicle(item)
	elif item is SquadType:
		_buy_squad(item)

func _buy_squad(t: SquadType) -> void:
	var ph := _passengers()
	var economy := _economy()
	if ph == null or economy == null or not _can_shop():
		return
	if t.size > ph.free_seat_count():
		return
	if not economy.spend(t.cost):
		return

	_bought_count += 1
	var squad := t.make_squad(troop_scene, Troop.TEAM_FRIENDLY,
		"%s_%d" % [t.display_name.replace(" ", ""), _bought_count], "%s %d" % [t.display_name, _bought_count])

	var origin := _spawn_origin()
	var facing := _spawn_facing(origin)
	var i := 0
	for troop in squad.get_children():
		(troop as Troop).position = _ground_point(origin + facing * _grid_offset(i))
		i += 1

	(squad_parent if squad_parent else get_tree().current_scene).add_child(squad)
	print("[BuyZone] Bought %s for $%d (funds %d)" % [squad.squad_name, t.cost, economy.funds])

	# Let navigation agents register for a frame, then send them to the door
	await get_tree().physics_frame
	var door := _nearest_door(origin)
	for troop in squad.members:
		var seat := ph.get_free_seat()
		if seat == "" or not ph.reserve_seat(seat, troop):
			break
		troop.command_board(ph, seat, door)
	_refresh_menu()

## Vehicles appear at base: ground vehicles in front of the aircraft (or at
## vehicle_spawn_point) and drive off on their own; sling loads behind it,
## packed, for the helicopter to hook and fly out.
func _buy_vehicle(t: VehicleType) -> void:
	var economy := _economy()
	if economy == null or not _can_shop() or t.scene == null:
		return
	if not economy.spend(t.cost):
		return
	_bought_count += 1
	var marker := sling_spawn_point if t.sling_loaded else vehicle_spawn_point
	var pos: Vector3
	var facing := _aircraft.global_basis.z   # aircraft nose is +Z
	facing.y = 0.0
	if marker:
		pos = marker.global_position
		facing = -marker.global_basis.z
	elif t.sling_loaded:
		pos = _aircraft.global_position - facing.normalized() * 22.0
	else:
		pos = _aircraft.global_position + facing.normalized() * 35.0
	# A few metres of scatter so repeat purchases don't stack up
	pos += Vector3(randf_range(-5, 5), 0.0, randf_range(-5, 5))
	pos = _ground_point(pos) - Vector3.UP * 0.8
	var parent := vehicle_parent if vehicle_parent else get_tree().current_scene
	var v := t.spawn(parent, Troop.TEAM_FRIENDLY, pos, facing,
		"%s_%d" % [t.display_name.replace(" ", ""), _bought_count], troop_scene,
		squad_parent if squad_parent else get_tree().current_scene)
	if v and t.sling_loaded:
		v.pack()
	print("[BuyZone] Bought %s for $%d (funds %d)" % [t.display_name, t.cost, economy.funds])
	_refresh_menu()

## 3 abreast, rows going back from the aircraft
func _grid_offset(i: int) -> Vector3:
	@warning_ignore("integer_division")
	var row := i / 3
	var col := (i % 3) - 1
	return Vector3(col * 1.6, 0.0, row * 1.6)

func _spawn_origin() -> Vector3:
	if spawn_point:
		return spawn_point.global_position
	# Beside the aircraft, out from the loading door
	var door := _nearest_door(_aircraft.global_position + _aircraft.global_basis.x * 10.0)
	var out := door - _aircraft.global_position
	out.y = 0.0
	return door + out.normalized() * spawn_distance_from_aircraft

## Basis whose +Z points away from the aircraft (so grid rows stack backwards)
func _spawn_facing(origin: Vector3) -> Basis:
	var away := origin - _aircraft.global_position
	away.y = 0.0
	if away.length_squared() < 0.01:
		return Basis.IDENTITY
	return Basis.looking_at(-away.normalized())

func _nearest_door(from: Vector3) -> Vector3:
	var ph := _passengers()
	var best := _aircraft.global_position
	var best_d := INF
	for door in [ph.left_door_node, ph.right_door_node]:
		if door and from.distance_squared_to(door.global_position) < best_d:
			best_d = from.distance_squared_to(door.global_position)
			best = door.global_position
	return best

## Drop a point onto the ground (terrain/buildings), standing height for a troop
func _ground_point(p: Vector3) -> Vector3:
	var query := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 100.0, p + Vector3.DOWN * 300.0)
	query.exclude = [_aircraft.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return (hit.position + Vector3.UP * 1.1) if not hit.is_empty() else p

# ---------------------------------------------------------------- state

func _can_shop() -> bool:
	return is_instance_valid(_aircraft) and _aircraft.is_landed() and _passengers() != null

func _is_gunning() -> bool:
	for c in _aircraft.get_children():
		if c is GunnerController and c.is_manning():
			return true
	return false

func _passengers() -> PassengerHandler:
	if not is_instance_valid(_aircraft):
		return null
	for c in _aircraft.get_children():
		if c is PassengerHandler:
			return c
	return null

func _economy() -> Node:
	return get_node_or_null("/root/Economy")

func _on_body_entered(body: Node3D) -> void:
	if body is HeliBase:
		_aircraft = body

func _on_body_exited(body: Node3D) -> void:
	if body == _aircraft:
		_aircraft = null
		close_menu()

## Every resource in a folder (SquadTypes, VehicleTypes)
func _load_dir(path: String) -> Array[Resource]:
	var out: Array[Resource] = []
	var dir := DirAccess.open(path)
	if dir == null:
		push_warning("BuyZone: can't open %s" % path)
		return out
	for file in dir.get_files():
		# Exported builds rename resources to *.tres.remap
		var res_path := path.path_join(file.trim_suffix(".remap"))
		if res_path.ends_with(".tres") or res_path.ends_with(".res"):
			var r := load(res_path)
			if r:
				out.append(r)
	return out

# ---------------------------------------------------------------- prompt

func _build_prompt() -> void:
	_prompt_layer = prompt_scene.instantiate() as CanvasLayer
	add_child(_prompt_layer)
	_prompt = _prompt_layer.get_node("%Prompt") as Label

func _update_prompt() -> void:
	if _menu.visible or not is_instance_valid(_aircraft):
		_prompt.visible = false
		return
	_prompt.visible = true
	if not _aircraft.is_landed():
		_prompt.text = "BASE  —  land to requisition troops"
	elif _is_gunning():
		_prompt.text = "Leave the gun (G) to requisition troops"
	else:
		_prompt.text = "B  —  Requisition troops"
