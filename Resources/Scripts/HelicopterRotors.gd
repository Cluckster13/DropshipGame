## HelicopterRotors.gd
## Attach to the Node3D that is the parent of your rotor meshes.
## Reads rotor_rpm_current from HeliBase and spins the meshes accordingly.
##
## Scene setup:
##   TestHelicopter (RigidBody3D — HeliBase)
##     └─ [your rotors node] (Node3D — this script)
##          ├─ RotorMain
##          └─ TailRotor_TailRotorShader_0_001

extends Node3D
class_name HelicopterRotors

## How many degrees the tail rotor spins relative to the main rotor.
## Real tail rotors turn ~5–6× faster than the main rotor.
@export var tail_rotor_speed_multiplier : float = 5.5

## Flip either axis if your mesh spins the wrong way
@export var main_rotor_clockwise  : bool = false
@export var tail_rotor_clockwise  : bool = true

@onready var rotor_main  : MeshInstance3D = $RotorMain
@onready var tail_rotor  : MeshInstance3D = $TailRotor_TailRotorShader_0_001

# Cached reference to the helicopter controller
var _helicopter : HeliBase

func _ready() -> void:
	_helicopter = get_parent() as HeliBase
	assert(_helicopter != null, "HelicopterRotors must be a child of a node using HeliBase (RigidBody3D)")

func _process(delta: float) -> void:
	if _helicopter == null:
		return

	# Convert RPM to degrees per second, then to radians per frame
	# RPM × 360° / 60s = degrees per second
	var main_degrees_per_second : float = (_helicopter.rotor_rpm_current / 60.0) * 360.0
	var tail_degrees_per_second : float = main_degrees_per_second * tail_rotor_speed_multiplier

	var main_radians_this_frame : float = deg_to_rad(main_degrees_per_second * delta)
	var tail_radians_this_frame : float = deg_to_rad(tail_degrees_per_second * delta)

	# Apply direction
	if main_rotor_clockwise:
		main_radians_this_frame = -main_radians_this_frame
	if tail_rotor_clockwise:
		tail_radians_this_frame = -tail_radians_this_frame

	# Main rotor spins on local Y axis
	rotor_main.rotate_object_local(Vector3.UP, main_radians_this_frame)

	# Tail rotor spins on local X axis (mounted on the side of the tail boom)
	tail_rotor.rotate_object_local(Vector3.RIGHT, tail_radians_this_frame)
