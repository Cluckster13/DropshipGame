# friendly_troop.gd
class_name FriendlyTroop
extends RigidBody3D

enum States {IDLE, PASSENGER, MOVING}
var state : States = States.IDLE
var target_nav : Vector3

var seat_marker : Node3D = null

@onready var nav: NavigationAgent3D = $NavigationAgent3D

func _ready() -> void:
	pass

func _physics_process(_delta: float) -> void:
	if state == States.PASSENGER and seat_marker:
		var seat_basis := seat_marker.global_transform.basis.orthonormalized()
		global_transform = Transform3D(seat_basis, seat_marker.global_position)
		linear_velocity  = Vector3.ZERO
		angular_velocity = Vector3.ZERO

func _set_move_target(target: Vector3) -> void:
	nav.target_position = target

func enter_vehicle(marker: Node3D) -> void:
	seat_marker = marker
	state = States.PASSENGER

	nav.target_position = global_position  # cancel any in-flight pathing

	freeze = true
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	collision_layer = 0
	collision_mask  = 0

func exit_vehicle() -> void:
	seat_marker = null
	state = States.IDLE

	freeze = false
	collision_layer = 1
	collision_mask  = 1
