class_name Vehicle
extends CharacterBody3D
## A ground vehicle or emplacement, for either team. Same script for the APC,
## tank, AA vehicle and AA emplacement: each scene sets the exports.
##
## Scene layout (see APC.tscn etc.):
##   Vehicle (CharacterBody3D, this script)
##     CollisionShape3D
##     Model         - visuals; tilts to the ground. Put your real model here
##     Turret        - swung by a VehicleWeapon (optional)
##       ...VehicleWeapon nodes with Muzzle children
##     Seats         - Marker3D per passenger (APC)
##     Exit          - where passengers get out (APC)
##     SlingPoint    - where the helicopter hook attaches (sling loads)
##     NavigationAgent3D
##
## Armour: each damage type (Damage.Type) is multiplied by its armour value.
## 0 = immune. Tanks ignore everything but AT; APCs and AA barely notice rifles.
##
## Driving AI (role):
##   ASSAULT - head for the nearest objective its team doesn't own
##   DEFEND  - park at the nearest objective its team owns (AA cover)
##   STATIC  - never moves (emplacements)
## An APC carrying a squad unloads it near the objective (or when shot at),
## then follows the squad to give fire support.

signal destroyed(vehicle: Vehicle)   ## blown up (the wreck stays a while)

enum Role { ASSAULT, DEFEND, STATIC }

@export var display_name : String = "Vehicle"

@export_group("Team")
@export_range(-1, 1, 1) var team : int = 1:
	set(value):
		team = value
		if is_node_ready():
			_apply_team_colors()
## Meshes recoloured by team (their material is copied per vehicle)
@export var tint_meshes : Array[MeshInstance3D] = []
@export var friendly_color : Color = Color(0.3, 0.38, 0.5)
@export var enemy_color : Color = Color(0.5, 0.3, 0.26)

@export_group("Armour")
@export var max_health : float = 200.0
@export var bullet_armour : float = 0.02
@export var at_armour : float = 1.0
@export var charge_armour : float = 1.0
@export var flak_armour : float = 0.3
## Infantry can walk up and plant a demolition charge on it
@export var chargeable : bool = false
## Height (m) shooters aim at and sight lines are checked to
@export var aim_height : float = 1.5
## Roughly how far the hull reaches from the centre (for sappers, spacing)
@export var hull_radius : float = 3.0

@export_group("Physics")
## Own physics layer (4). Kept off layer 1 so troops (layer 1) don't
## collide with vehicles: no shoving them through the ground. Rays still hit it.
@export_flags_3d_physics var vehicle_layers : int = 8
## What it drives on: layer 2 is the terrain (and aircraft), not troops
@export_flags_3d_physics var vehicle_mask : int = 2

@export_group("Driving")
@export var role : Role = Role.ASSAULT
@export var max_speed : float = 9.0
@export var acceleration : float = 4.0
@export var turn_rate_deg : float = 40.0
## Close enough to a drive goal (m)
@export var arrival_distance : float = 6.0
## Park this far from an objective's centre, so troops have the middle
@export var objective_standoff : float = 20.0
## Seconds between decisions about where to go
@export var think_interval : float = 3.0
## Halt while any weapon is firing (APC / AA). Tanks keep rolling.
@export var stop_to_fight : bool = false
## Tilted to match the ground under the vehicle (purely visual)
@export var model : Node3D
@export var tilt_speed : float = 4.0

@export_group("Passengers")
## Marker3D children = seats. Empty = carries nobody.
@export var seats_root : Node3D
## Where passengers appear when they get out
@export var exit_point : Node3D
## Unload once this close (m) to the target objective
@export var unload_distance : float = 70.0
@export var unload_stagger : float = 0.35
## Follow the unloaded squad, staying about this far (m) behind it
@export var support_distance : float = 25.0

@export_group("Sling load")
## Can be picked up by a helicopter's SlingHook
@export var sling_loadable : bool = false
## Attach point for the hook
@export var sling_point : Node3D
## Load weight as a fraction of the helicopter's own
@export var sling_weight_fraction : float = 0.3
## Weapons stay off until it has sat on the ground this long after being
## set down (setting up the emplacement)
@export var deploy_time : float = 3.0
## Landing faster than this (m/s) damages it
@export var drop_damage_speed : float = 10.0

@export_group("Wreck")
## Seconds a wreck stays before it's removed
@export var wreck_time : float = 25.0
@export var wreck_color : Color = Color(0.07, 0.07, 0.07)
## Hidden when destroyed (e.g. the turret barrel)
@export var hide_when_destroyed : Array[Node3D] = []
@export var explosion_scene : PackedScene = preload("res://Scenes/Vehicles/Explosion.tscn")

var health : float
var is_destroyed : bool = false
## The squad riding inside (APC), or the one it dropped off and now supports
var squad : Squad = null
var passengers : Array[Troop] = []
## Troop currently planting a charge on us (only one at a time)
var sapper : Troop = null
var target_obj : Objective = null
var deployed : bool = true

var _carried : bool = false
var _deploy_timer : float = 0.0
var _weapons : Array[VehicleWeapon] = []
var _seats : Array[Node3D] = []
var _gravity : float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _speed : float = 0.0
var _has_goal : bool = false
var _goal : Vector3
var _think_timer : float = 0.0
var _unloading : bool = false
var _reverse_time : float = 0.0
var _stuck_time : float = 0.0
var _last_fall_speed : float = 0.0
var _default_layer : int
var _default_mask : int

@onready var nav : NavigationAgent3D = get_node_or_null("NavigationAgent3D")

func _ready() -> void:
	health = max_health
	add_to_group("Vehicles")
	if sling_loadable:
		add_to_group("SlingLoads")
	collision_layer = vehicle_layers
	collision_mask = vehicle_mask
	_default_layer = collision_layer
	_default_mask = collision_mask
	for w in find_children("*", "VehicleWeapon", true, false):
		_weapons.append(w)
	if seats_root:
		for s in seats_root.get_children():
			if s is Node3D:
				_seats.append(s)
	if nav:
		nav.path_desired_distance = 3.0
		nav.target_desired_distance = arrival_distance
	_think_timer = randf() * think_interval
	floor_snap_length = 1.5
	floor_max_angle = deg_to_rad(50.0)
	_apply_team_colors()

# ---------------------------------------------------------------- queries

func is_alive() -> bool:
	return not is_destroyed

func eye_position() -> Vector3:
	return global_position + Vector3.UP * aim_height

func health_fraction() -> float:
	return clampf(health / max_health, 0.0, 1.0)

func is_carried() -> bool:
	return _carried

## Guns are live: alive, on the ground and set up
func weapons_active() -> bool:
	return not is_destroyed and not _carried and deployed

func is_engaging() -> bool:
	for w in _weapons:
		if w.is_engaging():
			return true
	return false

func armour_for(type: Damage.Type) -> float:
	match type:
		Damage.Type.AT: return at_armour
		Damage.Type.CHARGE: return charge_armour
		Damage.Type.FLAK: return flak_armour
	return bullet_armour

## Can infantry rifles hurt this at all? (otherwise rifle troops ignore it)
func rifle_vulnerable() -> bool:
	return bullet_armour > 0.0

func seat_count() -> int:
	return _seats.size()

# ---------------------------------------------------------------- damage

func take_damage(amount: float, source: Node = null, type: Damage.Type = Damage.Type.BULLET) -> void:
	if is_destroyed:
		return
	if source and source.get("team") == team:
		return   # no friendly fire
	health -= amount * armour_for(type)
	if health <= 0.0:
		health = 0.0
		_destroy(source)
		return
	# Under fire with troops aboard: let them out to fight
	if not passengers.is_empty() and type != Damage.Type.BULLET:
		unload()

func _destroy(killer: Node) -> void:
	is_destroyed = true
	remove_from_group("Vehicles")
	remove_from_group("SlingLoads")
	print("[Vehicle] %s (%s) destroyed by %s" % [name, "friendly" if team == 1 else "enemy",
		str(killer.name) if is_instance_valid(killer) else "?"])
	_has_goal = false
	_speed = 0.0
	for n in hide_when_destroyed:
		if n: n.visible = false
	for m in tint_meshes:
		if m:
			var mat := StandardMaterial3D.new()
			mat.albedo_color = wreck_color
			m.material_override = mat
	Explosion.spawn(explosion_scene, get_tree().current_scene, eye_position(), 4.0)
	# Whoever's inside bails out, hurt
	var riders := passengers.duplicate()
	passengers.clear()
	for i in riders.size():
		var t: Troop = riders[i]
		if is_instance_valid(t) and t.is_alive():
			_let_out(t, i)
			t.take_damage(randf_range(30.0, 80.0), killer)
	destroyed.emit(self)
	await get_tree().create_timer(wreck_time, false).timeout
	queue_free()

# ---------------------------------------------------------------- passengers

## Put a whole squad inside (APC). Extra troops beyond the seats walk.
func load_squad(s: Squad) -> void:
	squad = s
	for t in s.members:
		if passengers.size() >= _seats.size():
			break
		t.board_vehicle(_seats[passengers.size()])
		passengers.append(t)

func unload() -> void:
	if _unloading or passengers.is_empty():
		return
	_unloading = true
	_has_goal = false
	_speed = 0.0
	var baker := get_tree().get_first_node_in_group("NavPatchBaker")
	if baker and baker.has_method("request_area"):
		baker.request_area(global_position)   # default radius (in tiles)
	var riders := passengers.duplicate()
	for i in riders.size():
		var t: Troop = riders[i]
		if is_destroyed:
			break
		if is_instance_valid(t) and t.is_alive() and t.state == Troop.States.PASSENGER:
			_let_out(t, i)
		passengers.erase(t)
		await get_tree().create_timer(unload_stagger, false).timeout
	passengers.clear()
	_unloading = false
	print("[Vehicle] %s unloaded %s" % [name, squad.squad_name if is_instance_valid(squad) else "troops"])

func _let_out(t: Troop, i: int) -> void:
	var exit := exit_point.global_position if exit_point else global_position + global_basis.z * (hull_radius + 1.0)
	var back := global_basis.z
	back.y = 0.0
	back = back.normalized() if back.length_squared() > 0.01 else Vector3.BACK
	var side := back.cross(Vector3.UP).normalized()
	@warning_ignore("integer_division")
	var row := i / 3
	var rally := exit + back * (4.0 + row * 1.6) + side * ((i % 3) - 1) * 1.8
	t.command_disembark(_ground(exit), _ground(rally))

# ---------------------------------------------------------------- sling load

## Hooked under (or released from) a helicopter. While carried, the hook
## moves us; physics and weapons are off.
func set_carried(value: bool, release_velocity: Vector3 = Vector3.ZERO) -> void:
	_carried = value
	if value:
		collision_layer = 0
		collision_mask = 0
		deployed = false
		velocity = Vector3.ZERO
	else:
		collision_layer = _default_layer
		collision_mask = _default_mask
		velocity = release_velocity
		_deploy_timer = 0.0

## World position the hook should hold to put sling_point at `hook_pos`
func carried_origin_for(point_pos: Vector3) -> Vector3:
	var offset := sling_point.global_position - global_position if sling_point else Vector3.UP * aim_height
	return point_pos - offset

func sling_point_position() -> Vector3:
	return sling_point.global_position if sling_point else eye_position()

## Start packed (not firing) until set down: emplacements bought at base
func pack() -> void:
	deployed = false
	_deploy_timer = 0.0

# ---------------------------------------------------------------- driving

func drive_to(pos: Vector3) -> void:
	_goal = pos
	_has_goal = true
	_stuck_time = 0.0
	if nav:
		nav.target_position = pos

func stop_driving() -> void:
	_has_goal = false

func _physics_process(delta: float) -> void:
	if _carried:
		return   # the SlingHook moves us
	if is_destroyed:
		_fall(delta)
		move_and_slide()
		return

	if not deployed:
		if is_on_floor():
			_deploy_timer += delta
			if _deploy_timer >= deploy_time:
				deployed = true
				print("[Vehicle] %s deployed" % name)
		else:
			_deploy_timer = 0.0

	if role != Role.STATIC:
		_think_timer -= delta
		if _think_timer <= 0.0:
			_think_timer = think_interval
			_think()
		_drive(delta)
	_fall(delta)
	move_and_slide()
	_tilt_model(delta)

func _fall(delta: float) -> void:
	if is_on_floor():
		if _last_fall_speed > drop_damage_speed:
			take_damage((_last_fall_speed - drop_damage_speed) * 25.0, null, Damage.Type.CHARGE)
		_last_fall_speed = 0.0
		velocity.y = minf(velocity.y, 0.0)
	else:
		velocity.y -= _gravity * delta
		_last_fall_speed = maxf(_last_fall_speed, -velocity.y)
	if not is_on_floor() and _speed == 0.0:
		# Released from a sling: drift to a stop through the air
		velocity.x = move_toward(velocity.x, 0.0, delta * 2.0)
		velocity.z = move_toward(velocity.z, 0.0, delta * 2.0)

func _drive(delta: float) -> void:
	var want_speed := 0.0
	var turn := 0.0
	var halt := stop_to_fight and is_engaging()
	if _reverse_time > 0.0:
		_reverse_time -= delta
		want_speed = -max_speed * 0.4
		turn = 1.0
	elif _has_goal and not halt and not _unloading:
		var next := _next_point()
		var to_next := next - global_position
		to_next.y = 0.0
		var dist_goal := _flat_dist(_goal, global_position)
		if dist_goal <= arrival_distance:
			_has_goal = false
			_on_arrived()
		elif to_next.length_squared() > 0.01:
			var heading := -global_basis.z
			heading.y = 0.0
			var angle := heading.normalized().signed_angle_to(to_next.normalized(), Vector3.UP)
			turn = clampf(angle / deg_to_rad(20.0), -1.0, 1.0)
			# Slow right down for sharp turns, ease off near the goal
			var facing := clampf(cos(angle), 0.0, 1.0)
			want_speed = max_speed * facing * facing * clampf(dist_goal / 20.0, 0.3, 1.0)

	rotation.y += turn * deg_to_rad(turn_rate_deg) * delta
	_speed = move_toward(_speed, want_speed, acceleration * delta)
	var forward := -global_basis.z
	velocity.x = forward.x * _speed
	velocity.z = forward.z * _speed

	# Stuck on something: back up and turn for a moment
	var actual := Vector2(get_real_velocity().x, get_real_velocity().z).length()
	if want_speed > 1.0 and actual < 0.5:
		_stuck_time += delta
		if _stuck_time > 2.0:
			_stuck_time = 0.0
			_reverse_time = 1.5
	else:
		_stuck_time = 0.0

func _tilt_model(delta: float) -> void:
	if model == null or not is_on_floor():
		return
	var n := get_floor_normal()
	# Floor normal in our own (yaw-only) space
	var local_n := global_basis.inverse() * n
	var target_basis := Basis(Quaternion(Vector3.UP, local_n.normalized()))
	model.basis = model.basis.slerp(target_basis, clampf(tilt_speed * delta, 0.0, 1.0)).orthonormalized()

# ---------------------------------------------------------------- navigation

const DIRECT_CHECK_INTERVAL := 1.5
const PATH_REACH_TOLERANCE := 6.0
var _direct_mode : bool = true
var _direct_timer : float = 0.0

func _next_point() -> Vector3:
	if nav == null:
		return _goal
	_direct_timer -= get_physics_process_delta_time()
	if _direct_timer <= 0.0:
		_direct_timer = DIRECT_CHECK_INTERVAL * randf_range(0.8, 1.2)
		_direct_mode = not _path_reaches_goal()
	if _direct_mode or nav.is_navigation_finished():
		return _goal
	return nav.get_next_path_position()

func _path_reaches_goal() -> bool:
	var map := nav.get_navigation_map()
	if NavigationServer3D.map_get_iteration_id(map) == 0:
		return false
	var path := NavigationServer3D.map_get_path(map, global_position, _goal, true)
	if path.is_empty():
		return false
	return _flat_dist(path[0], global_position) <= PATH_REACH_TOLERANCE \
		and _flat_dist(path[path.size() - 1], _goal) <= PATH_REACH_TOLERANCE

func _flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

# ---------------------------------------------------------------- AI

func _think() -> void:
	if _unloading:
		return
	# APC: get the squad out near the objective, or as soon as we're in a fight
	if not passengers.is_empty():
		var near := target_obj != null and _flat_dist(target_obj.global_position, global_position) <= unload_distance
		if near or is_engaging():
			unload()
			return
	# Squad dropped off: shadow it with the guns
	if passengers.is_empty() and is_instance_valid(squad) and not squad.alive_members().is_empty():
		var c := squad.centroid()
		if _flat_dist(c, global_position) > support_distance * 1.5:
			var back := (global_position - c)
			back.y = 0.0
			drive_to(c + back.normalized() * support_distance)
		return

	var obj := _choose_objective()
	if obj == null:
		return
	if obj != target_obj or not _has_goal:
		var standoff := objective_standoff
		if _flat_dist(obj.global_position, global_position) <= standoff + arrival_distance and obj == target_obj:
			return   # already parked here
		target_obj = obj
		var from_obj := global_position - obj.global_position
		from_obj.y = 0.0
		if from_obj.length_squared() < 1.0:
			from_obj = Vector3.FORWARD
		var side := from_obj.normalized().cross(Vector3.UP) * randf_range(-8.0, 8.0)
		drive_to(obj.global_position + from_obj.normalized() * standoff + side)

func _choose_objective() -> Objective:
	match role:
		Role.ASSAULT:
			var obj := Objective.nearest_not_owned_by(get_tree(), global_position, team)
			return obj if obj else _nearest_objective(func(_o): return true)
		Role.DEFEND:
			var own := _nearest_objective(func(o): return o.owner_team == team)
			if own:
				return own
			# Nothing held yet: hang back behind whatever the squads are taking
			return null
	return null

func _nearest_objective(filter: Callable) -> Objective:
	var best : Objective = null
	var best_d := INF
	for node in get_tree().get_nodes_in_group("Objectives"):
		var o := node as Objective
		if o and filter.call(o):
			var d := global_position.distance_squared_to(o.global_position)
			if d < best_d:
				best_d = d
				best = o
	return best

func _on_arrived() -> void:
	_speed = 0.0
	var baker := get_tree().get_first_node_in_group("NavPatchBaker")
	if baker and baker.has_method("request_area"):
		baker.request_area(global_position)

# ---------------------------------------------------------------- helpers

func _ground(p: Vector3) -> Vector3:
	var query := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 20.0, p + Vector3.DOWN * 60.0)
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return p
	return (hit.position as Vector3) + Vector3.UP * 1.1

func _apply_team_colors() -> void:
	var col := friendly_color if team == Troop.TEAM_FRIENDLY else enemy_color
	for m in tint_meshes:
		if m == null:
			continue
		var mat := m.get_surface_override_material(0)
		mat = mat.duplicate() if mat else StandardMaterial3D.new()
		(mat as StandardMaterial3D).albedo_color = col
		m.set_surface_override_material(0, mat)

func debug_info() -> Dictionary:
	return {
		"Vehicle": display_name,
		"Team": team,
		"Health": health,
		"Goal": _goal if _has_goal else "-",
		"Direct": _direct_mode,
		"Passengers": passengers.size(),
		"Engaging": is_engaging(),
		"Deployed": deployed,
		"Carried": _carried,
	}
