class_name Troop
extends CharacterBody3D
## A single infantry unit (replaces FriendlyTroop). Team-aware, so the same scene works for friendlies
## (team 1) and enemies (team -1).
##
## Two ways to drive it:
##   - In a Squad: the squad hands out orders (move_to / stop) and decides
##     what to do after landing or capturing.
##   - Solo (no squad): after disembarking it heads for the nearest
##     objective its team doesn't own, same as the old FriendlyTroop.

signal arrived(troop: Troop)       ## finished a MOVING order
signal disembarked(troop: Troop)   ## walked clear of the helicopter after unloading
signal died(troop: Troop)

enum States {IDLE, MOVING, MOVING_TO_BOARD, PASSENGER, MOVING_TO_EXIT, COMBAT, DEAD}

const TEAM_FRIENDLY := 1
const TEAM_ENEMY    := -1

@export_group("Team")
## 1 = friendly, -1 = enemy (same convention as Objective.owner_team)
@export_range(-1, 1, 1) var team: int = TEAM_FRIENDLY:
	set(value):
		team = value
		if is_node_ready():
			_apply_team_tint()
## Optional mesh recoloured blue/red by team on spawn
@export var tint_mesh: MeshInstance3D

@export_group("Movement")
@export var move_speed       : float = 4.0
@export var acceleration     : float = 14.0
@export var turn_speed       : float = 8.0
@export var arrival_distance : float = 1.0
## If boxed in by other troops this close to the goal, count it as arrived
@export var close_enough_distance : float = 3.0
## ...after being stalled (barely moving) for this long
@export var stuck_time_limit : float = 0.75

@export_group("Combat")
@export var max_health : float = 100.0

## Multiplier on move_speed. Squads use this to pace the leader and let
## followers speed up / ease off to hold formation.
var speed_scale : float = 1.0

var state  : States = States.IDLE
var health : float
var squad  : Squad = null

# Solo-mode objective (unused while in a squad; the squad tracks that)
var target_obj : Objective = null

# Transport
var passenger_handler  : PassengerHandler = null
var assigned_seat_name : String = ""
var seat_marker        : Node3D = null

var direction : Vector3 = Vector3.ZERO
var _smoothed_velocity : Vector3 = Vector3.ZERO
var _gravity : float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _default_layer : int
var _default_mask  : int
var _stuck_time    : float = 0.0

@onready var nav: NavigationAgent3D = $NavigationAgent3D

func _ready() -> void:
	health = max_health
	_default_layer = collision_layer
	_default_mask  = collision_mask
	nav.path_desired_distance   = 1.0
	nav.target_desired_distance = arrival_distance
	add_to_group("Troops")
	_apply_team_tint()

func _physics_process(delta: float) -> void:
	match state:
		States.PASSENGER:
			_snap_to_seat()
			return   # riding along: no gravity, no move_and_slide
		States.DEAD:
			return
		States.MOVING, States.MOVING_TO_BOARD, States.MOVING_TO_EXIT:
			_update_navigation_direction()
		_:
			direction = Vector3.ZERO

	_apply_velocity(delta)
	move_and_slide()

# ---------------------------------------------------------------- queries

func is_alive() -> bool:
	return state != States.DEAD

## Free to take a ground order (not riding, boarding or unloading)
func is_available() -> bool:
	return state == States.IDLE or state == States.MOVING or state == States.COMBAT

# ---------------------------------------------------------------- orders

func move_to(pos: Vector3) -> void:
	if not is_available():
		return
	nav.target_position = pos
	_stuck_time = 0.0
	state = States.MOVING

func stop() -> void:
	if is_available():
		state = States.IDLE

func command_board(handler: PassengerHandler, seat_name: String, door_position: Vector3) -> void:
	_clear_target_obj()
	passenger_handler  = handler
	assigned_seat_name = seat_name
	seat_marker        = handler.seat_marker(seat_name)
	nav.target_position = door_position
	state = States.MOVING_TO_BOARD

## door_position: where to appear (outside the hull collision)
## rally_position: where to walk to before counting as "disembarked"
func command_disembark(door_position: Vector3, rally_position: Vector3) -> void:
	_leave_seat()
	speed_scale = 1.0

	global_position = door_position
	global_basis = Basis(Vector3.UP, global_rotation.y)   # stand upright, keep facing
	velocity = Vector3.ZERO
	_smoothed_velocity = Vector3.ZERO
	collision_layer = _default_layer
	collision_mask  = _default_mask

	nav.target_position = rally_position
	state = States.MOVING_TO_EXIT

func take_damage(amount: float, _source: Node = null) -> void:
	if not is_alive():
		return
	health -= amount
	if health <= 0.0:
		_die()

# ---------------------------------------------------------------- solo behaviour

func advance_to_nearest_objective() -> void:
	_clear_target_obj()
	var obj := Objective.nearest_not_owned_by(get_tree(), global_position, team)
	if obj == null:
		stop()
		return
	target_obj = obj
	target_obj.captured.connect(_on_target_captured)
	move_to(obj.global_position)

func _on_target_captured(_by_team: int) -> void:
	advance_to_nearest_objective()

func _clear_target_obj() -> void:
	if target_obj and is_instance_valid(target_obj) and target_obj.captured.is_connected(_on_target_captured):
		target_obj.captured.disconnect(_on_target_captured)
	target_obj = null

# ---------------------------------------------------------------- internals

func _on_arrived() -> void:
	match state:
		States.MOVING_TO_BOARD:
			_board_seat()
		States.MOVING_TO_EXIT:
			state = States.IDLE
			disembarked.emit(self)
			if squad == null:
				advance_to_nearest_objective()
		States.MOVING:
			state = States.IDLE
			arrived.emit(self)

func _board_seat() -> void:
	state = States.PASSENGER
	collision_layer = 0
	collision_mask  = 0

func _leave_seat() -> void:
	if passenger_handler and assigned_seat_name != "":
		passenger_handler.vacate_seat(assigned_seat_name)
	passenger_handler  = null
	assigned_seat_name = ""
	seat_marker        = null

func _snap_to_seat() -> void:
	if seat_marker == null:
		return
	# Seat markers sit under a 0.015-scaled node, so strip the scale
	global_transform = Transform3D(seat_marker.global_basis.orthonormalized(), seat_marker.global_position)
	velocity = Vector3.ZERO

func _die() -> void:
	_leave_seat()
	_clear_target_obj()
	state = States.DEAD
	collision_layer = 0
	collision_mask  = 0
	died.emit(self)
	queue_free()   # placeholder until there's a death animation / ragdoll

func _update_navigation_direction() -> void:
	if nav.is_navigation_finished() or _is_stuck_near_goal():
		direction = Vector3.ZERO
		_stuck_time = 0.0
		_on_arrived()
		return

	var to_next: Vector3 = nav.get_next_path_position() - global_position
	to_next.y = 0.0
	if to_next.length_squared() <= 0.001:
		direction = Vector3.ZERO
		return

	direction = to_next.normalized()
	var target_angle: float = atan2(-direction.x, -direction.z)
	rotation.y = lerp_angle(rotation.y, target_angle, get_physics_process_delta_time() * turn_speed)

## Troops crowding the same area shove each other and can orbit a goal
## forever. Close to the target and not making progress = good enough.
## Never applies to boarding, which has to reach the actual door.
func _is_stuck_near_goal() -> bool:
	if state == States.MOVING_TO_BOARD:
		return false
	var flat_speed := Vector2(velocity.x, velocity.z).length()
	if flat_speed < move_speed * 0.25 and nav.distance_to_target() < close_enough_distance:
		_stuck_time += get_physics_process_delta_time()
	else:
		_stuck_time = 0.0
	return _stuck_time >= stuck_time_limit

func _apply_velocity(delta: float) -> void:
	var target_velocity := direction * move_speed * speed_scale
	_smoothed_velocity = _smoothed_velocity.lerp(target_velocity, minf(delta * acceleration, 1.0))
	velocity.x = _smoothed_velocity.x
	velocity.z = _smoothed_velocity.z
	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= _gravity * delta

func _apply_team_tint() -> void:
	if tint_mesh == null:
		return
	var mat := tint_mesh.get_surface_override_material(0)
	mat = mat.duplicate() if mat else StandardMaterial3D.new()   # scene material is shared: copy it
	(mat as StandardMaterial3D).albedo_color = Color(0, 0, 1) if team == TEAM_FRIENDLY else Color(1, 0, 0)
	tint_mesh.set_surface_override_material(0, mat)

func ai_debug_info() -> Dictionary:
	return {
		"Team": team,
		"Squad": squad.squad_name if squad else "-",
		"State": States.keys()[state],
		"Health": health,
		"Nav_Target": nav.target_position,
		"Nav_Finished": nav.is_navigation_finished(),
		"Position": global_position,
		"Velocity": velocity,
		"On_Floor": is_on_floor(),
	}
