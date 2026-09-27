class_name FriendlyTroop
extends CharacterBody3D

enum States {IDLE, MOVING_TO_BOARD, PASSENGER, MOVING_TO_EXIT}
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

var seat_marker        : Node3D = null
var assigned_seat_name : String = ""
var passenger_handler  : PassengerHandler = null

var _gravity : float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)

@onready var nav: NavigationAgent3D = $NavigationAgent3D

func _ready() -> void:
	nav.path_desired_distance = 0.5
	nav.target_desired_distance = arrival_distance
	nav.path_max_distance = 100.0

func _physics_process(delta: float) -> void:
	match state:
		States.PASSENGER:
			_snap_to_seat()
		States.MOVING_TO_BOARD:
			direction = owner.global_position.direction_to(nav.target_position)
		States.IDLE:
			pass
	_calculate_velocity(delta)

func _apply_gravity_only(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
	else:
		velocity.y = 0.0
	velocity.x = 0.0
	velocity.z = 0.0
	move_and_slide()


func _calculate_velocity(delta : float) -> void:
	
	target_velocity.x = direction.x * (current_movement_speed/current_movement_speed_divisor)
	target_velocity.z = direction.z * (current_movement_speed/current_movement_speed_divisor)
	
	if acceleration_enabled:
		current_lerp_velocity = current_lerp_velocity.lerp(target_velocity,delta * current_acceleration_multiplier)
		velocity.x = current_lerp_velocity.x
		velocity.z = current_lerp_velocity.z
	else:
		velocity.x = target_velocity.x
		velocity.z = target_velocity.z

	if is_on_floor():
		return
		
	_apply_gravity_only(delta)

#func _move_along_nav(delta: float) -> void:
	#if not is_on_floor():
		#velocity.y -= _gravity * delta
	#else:
		#velocity.y = 0.0

	#var next_pos: Vector3 = nav.get_next_path_position()
	#var to_next : Vector3 = next_pos - global_position
	#to_next.y = 0.0

	#var horizontal_dist_to_target := (nav.target_position - global_position)
	#horizontal_dist_to_target.y = 0.0

	#if nav.is_navigation_finished() or horizontal_dist_to_target.length() <= arrival_distance:
		#velocity.x = 0.0
		#velocity.z = 0.0
		#move_and_slide()
		#_on_arrived()
		#print("arrived")
		#return


	#var dir: Vector3 = to_next.normalized()
	#velocity.x = dir.x * move_speed
	#velocity.z = dir.z * move_speed
	#look_at(global_position + dir, Vector3.UP)
	#print("velocity")

	#move_and_slide()

func _on_arrived() -> void:
	match state:
		States.MOVING_TO_BOARD:
			_board_seat()
		States.MOVING_TO_EXIT:
			state = States.IDLE
			seat_marker = null

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

func command_disembark(exit_position: Vector3) -> void:
	if passenger_handler and assigned_seat_name != "":
		passenger_handler.vacate_seat(assigned_seat_name)

	seat_marker = null
	collision_layer = 1
	collision_mask  = 1
	state = States.MOVING_TO_EXIT
	nav.target_position = exit_position

func ai_debug_info() -> Dictionary:
	return {
		"State": States.keys()[state],
		"Nav_Target": nav.target_position,
		"Nav_Finished": nav.is_navigation_finished(),
		"Next_Path": nav.get_next_path_position(),
		"Position": global_position,
		"Velocity": velocity,
		"On_Floor": is_on_floor(),
		"Map_Ready": NavigationServer3D.map_get_iteration_id(nav.get_navigation_map()) > 0
	}
