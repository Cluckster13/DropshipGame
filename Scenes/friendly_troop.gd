class_name FriendlyTroop
extends CharacterBody3D

enum States {IDLE, MOVING_TO_BOARD, PASSENGER, MOVING_TO_EXIT, MOVING_TO_OBJ, COMBAT}
var state: States = States.IDLE

@export var move_speed       : float = 15
@export var arrival_distance : float = 1.0

var acceleration_enabled : bool = true
var target_velocity : Vector3 = Vector3.ZERO
var current_lerp_velocity : Vector3 = Vector3.ZERO
var current_movement_speed : float = 4.0
var current_acceleration_multiplier : float = 14
var current_movement_speed_divisor : float = 1
var direction : Vector3 = Vector3.ZERO
var turn_speed: float = 8.0

var objectives : Array
var target_obj : Objective = null

var seat_marker        : Node3D = null
var assigned_seat_name : String = ""
var passenger_handler  : PassengerHandler = null

var _gravity : float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)

@onready var nav: NavigationAgent3D = $NavigationAgent3D

func _ready() -> void:
	nav.path_desired_distance = 1
	nav.target_desired_distance = arrival_distance
	nav.path_max_distance = 100.0

func _physics_process(delta: float) -> void:
	match state:
		States.PASSENGER:
			_snap_to_seat()
			
		States.MOVING_TO_BOARD, States.MOVING_TO_EXIT, States.MOVING_TO_OBJ:
			_update_navigation_direction()

		States.IDLE:
			direction = Vector3.ZERO

	_calculate_velocity(delta)
	move_and_slide()

func _change_state(state_change : States) -> void:
	state = state_change

func _find_nearest_objective() -> Objective:
	var best : Objective = null
	var best_dist := INF
	for node in get_tree().get_nodes_in_group("Objectives"):
		var obj := node as Objective
		if obj == null or obj.owner_team == 1:   # skip already-friendly
			continue
		var d := global_position.distance_squared_to(obj.global_position)
		if d < best_dist:
			best_dist = d
			best = obj
	return best

func command_move_to_objective(obj: Objective) -> void:
	_clear_target_obj()
	if obj == null:
		_change_state(States.IDLE)
		return
	target_obj = obj
	target_obj.captured.connect(_on_target_captured)
	nav.target_position = obj.global_position
	_change_state(States.MOVING_TO_OBJ)

func advance_to_nearest_objective() -> void:
	command_move_to_objective(_find_nearest_objective())

func _clear_target_obj() -> void:
	if target_obj and target_obj.captured.is_connected(_on_target_captured):
		target_obj.captured.disconnect(_on_target_captured)
	target_obj = null

func _on_target_captured(team: int) -> void:
	# Someone (us or a teammate) finished it, so pick the next one
	advance_to_nearest_objective()

func _update_navigation_direction() -> void:
	if nav.is_navigation_finished():
		direction = Vector3.ZERO
		_on_arrived()
		return

	var next_position: Vector3 = nav.get_next_path_position()

	var to_next: Vector3 = next_position - global_position
	to_next.y = 0.0

	if to_next.length_squared() > 0.001:
		direction = to_next.normalized()

		var target_angle: float = atan2(-direction.x, -direction.z)
		rotation.y = lerp_angle(
			rotation.y,
			target_angle,
			get_physics_process_delta_time() * turn_speed
		)
	else:
		direction = Vector3.ZERO

	if to_next.length_squared() > 0.001:
		direction = to_next.normalized()
	else:
		direction = Vector3.ZERO

func _calculate_velocity(delta: float) -> void:
	target_velocity.x = direction.x * (current_movement_speed / current_movement_speed_divisor)
	target_velocity.z = direction.z * (current_movement_speed / current_movement_speed_divisor)

	if acceleration_enabled:
		current_lerp_velocity = current_lerp_velocity.lerp(
			target_velocity,
			delta * current_acceleration_multiplier
		)

		velocity.x = current_lerp_velocity.x
		velocity.z = current_lerp_velocity.z
	else:
		velocity.x = target_velocity.x
		velocity.z = target_velocity.z
		
	if not is_on_floor():
		velocity.y -= _gravity * delta

func _on_arrived() -> void:
	match state:
		States.MOVING_TO_BOARD:
			_board_seat()
		States.MOVING_TO_EXIT:
			seat_marker = null
			advance_to_nearest_objective()   # leave the heli and head straight out
		States.MOVING_TO_OBJ:
			# Standing inside the capture zone now; Objective counts us via its Area3D
			_change_state(States.IDLE)

func _snap_to_seat() -> void:
	if seat_marker == null:
		return
	var seat_basis: Basis = seat_marker.global_transform.basis.orthonormalized()
	global_transform = Transform3D(seat_basis, seat_marker.global_position)
	velocity = Vector3.ZERO

func _board_seat() -> void:
	state = States.PASSENGER
	collision_layer = 0
	collision_mask  = 0

func command_board(handler: PassengerHandler, seat_name: String, door_position: Vector3) -> void:
	passenger_handler  = handler
	assigned_seat_name = seat_name
	seat_marker        = handler.seat_marker(seat_name)
	state = States.MOVING_TO_BOARD
	nav.target_position = door_position

func command_disembark(door_position: Vector3) -> void:
	if passenger_handler and assigned_seat_name != "":
		passenger_handler.vacate_seat(assigned_seat_name)

	seat_marker = null

	# Teleport out to the door threshold first — the same safe spot
	# boarding already walks up to — rather than starting the walk
	# from inside the hull's solid collision box.
	global_position = door_position


	state = States.MOVING_TO_EXIT
	#nav.target_position = Vector3.ZERO
	collision_layer  = 1
	collision_mask   = 1

func ai_debug_info() -> Dictionary:
	return {
		"State": States.keys()[state],
		"Nav_Target": nav.target_position,
		"Nav_Finished": nav.is_navigation_finished(),
		"Next_Path": nav.get_next_path_position(),
		"Position": global_position,
		"Velocity": velocity,
		"target_velocity": target_velocity,
		"Direction": direction,
		"On_Floor": is_on_floor(),
		"Map_Ready": NavigationServer3D.map_get_iteration_id(nav.get_navigation_map()) > 0
	}
