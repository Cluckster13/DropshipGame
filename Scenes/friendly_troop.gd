class_name FriendlyTroop
extends CharacterBody3D

enum States {IDLE, MOVING_TO_BOARD, PASSENGER, MOVING_TO_EXIT}
var state: States = States.IDLE

@export var move_speed       : float = 15
@export var arrival_distance : float = 1.0

var seat_marker        : Node3D = null
var assigned_seat_name : String = ""
var passenger_handler  : PassengerHandler = null

var _gravity : float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)

@onready var nav: NavigationAgent3D = $NavigationAgent3D

func _ready() -> void:
	nav.path_desired_distance   = 0.5
	nav.target_desired_distance = arrival_distance

func _physics_process(delta: float) -> void:
	match state:
		States.PASSENGER:
			_snap_to_seat()
		States.MOVING_TO_BOARD, States.MOVING_TO_EXIT:
			_move_along_nav(delta)
		States.IDLE:
			nav.target_position = Vector3(1,0,1)

func _apply_gravity_only(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
	else:
		velocity.y = 0.0
	velocity.x = 0.0
	velocity.z = 0.0
	move_and_slide()

func _move_along_nav(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
	else:
		velocity.y = 0.0

	#if nav.is_navigation_finished():
		#velocity.x = 0.0
		#velocity.z = 0.0
		#move_and_slide()
		#_on_arrived()
		#return

	var next_pos: Vector3 = nav.get_next_path_position()
	var to_next : Vector3 = next_pos - global_position
	to_next.y = 0.0

	if to_next.length() > 0.01:
		var dir: Vector3 = to_next.normalized()
		velocity.x = dir.x * move_speed
		velocity.z = dir.z * move_speed
		look_at(global_position + dir, Vector3.UP)
	#else:
		#velocity.x = 0.0
		#velocity.z = 0.0

	move_and_slide()

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
	return{
		"State: " : state,
		"Nav_Target: " : nav.target_position
		}
