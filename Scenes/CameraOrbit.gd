## HeliCamera.gd
## Attach to a Camera3D that is a child of TestHelicopter (or any node).
## The camera orbits the helicopter at a configurable distance/height.
## Hold the 'freelook' input action to enter Free Look mode.
##
## Scene setup:
##   TestHelicopter (RigidBody3D)  ← HeliController.gd
##     └─ Camera3D                 ← HeliCamera.gd   (this script)

extends Camera3D
class_name CameraOrbit

# ─── Orbit settings ──────────────────────────────────────────────────────────
@export var orbit_distance   : float = 14.0   ## Meters behind/above
@export var orbit_height     : float = 4.5    ## Extra vertical offset
@export var orbit_smoothing  : float = 6.0    ## Lerp speed (higher = snappier)
@export var orbit_pitch_deg  : float = -15.0  ## Default downward angle

# ─── Mouse / input sensitivity ───────────────────────────────────────────────
@export var mouse_sensitivity : float = 0.003

# ─── Collision ───────────────────────────────────────────────────────────────
@export var collision_enabled : bool  = true
@export var collision_margin  : float = 0.4

# Internal
var _yaw   : float = 0.0
var _pitch : float = deg_to_rad(orbit_pitch_deg)
var _is_freelook : bool = false

var _desired_position : Vector3 = Vector3.ZERO
var _target_node      : Node3D

func _ready() -> void:
	_target_node = get_parent() as Node3D
	assert(_target_node != null, "HeliCamera must be a child of a Node3D")

	top_level = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# Initialise _yaw to match parent's current facing, offset by 180° to sit behind
	_yaw = _target_node.rotation.y + PI

func _input(event: InputEvent) -> void:
	if event.is_action("Freelook") and not event.is_echo():
		_set_freelook(event.is_action_pressed("Freelook"))

	if _is_freelook and event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_yaw   -= mm.relative.x * mouse_sensitivity
		_pitch -= mm.relative.y * mouse_sensitivity
		_pitch  = clampf(_pitch, deg_to_rad(-80.0), deg_to_rad(25.0))

func _physics_process(delta: float) -> void:
	if _target_node == null:
		return

	if not _is_freelook:
		# Follow the helicopter's yaw but stay behind it (+ PI offset)
		var target_yaw : float = _target_node.rotation.y + PI
		_yaw = lerp_angle(_yaw, target_yaw, delta * orbit_smoothing * 0.5)

	var offset := Vector3(
		sin(_yaw) * cos(_pitch),
		-sin(_pitch),
		cos(_yaw) * cos(_pitch)
	) * orbit_distance

	offset.y += orbit_height

	var raw_target_pos : Vector3 = _target_node.global_position + offset
	_desired_position = raw_target_pos

	if collision_enabled:
		_desired_position = _collide_camera(
				_target_node.global_position, raw_target_pos)

	global_position = global_position.lerp(_desired_position, delta * orbit_smoothing)
	look_at(_target_node.global_position, Vector3.UP)

# ─── Helpers ─────────────────────────────────────────────────────────────────

func _set_freelook(active: bool) -> void:
	_is_freelook = active
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _collide_camera(origin: Vector3, desired: Vector3) -> Vector3:
	var space_state := get_world_3d().direct_space_state
	var params      := PhysicsRayQueryParameters3D.create(origin, desired)
	params.exclude  = [_target_node]
	var result      := space_state.intersect_ray(params)
	if result:
		var to_cam : Vector3 = (desired - origin).normalized()
		return result.position - to_cam * collision_margin
	return desired

# ─── Public API ──────────────────────────────────────────────────────────────

func reset_orbit() -> void:
	_yaw = _target_node.rotation.y + PI
