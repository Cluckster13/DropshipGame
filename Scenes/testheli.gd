## HeliController.gd
## Attach to your TestHelicopter (RigidBody3D).
## Requires: RigidBody3D as root, CollisionShape3D child.
##
## Controls:
##   Shift / Ctrl   — Collective up / down  (gradual spool)
##   A / D          — Anti-torque (yaw left / right)
##   W / S          — Cyclic pitch (nose down / up)
##   Q / E          — Cyclic roll (bank left / right)
##   EngineToggle   — Start / shut down engine

extends RigidBody3D
class_name HeliBase

# ─── Collective ───────────────────────────────────────────────────────────────
## All force/torque values are multipliers of the helicopter's weight force (mass × gravity).
## This makes them scale correctly regardless of what mass is set to.
## Weight force at default 800 kg = 800 × 9.8 = 7840 N
@export var collective_max_force    : float = 1.2
@export var collective_spool_speed  : float = 0.8    ## How fast collective responds (0–1 per second)
@export var collective_decay_rate   : float = 0.3    ## How fast collective bleeds off when idle
@export var collective_idle : float = 0.5

# ─── Cyclic (pitch / roll) ────────────────────────────────────────────────────
@export var cyclic_pitch_strength   : float = 3.0    ## Forward/back torque multiplier
@export var cyclic_roll_strength    : float = 0.8    ## Left/right torque multiplier — lower = less twitchy
@export var cyclic_angular_damping  : float = 0.25   ## Resistive torque multiplier — prevents spin-out

# ─── Anti-torque (yaw / tail rotor) ──────────────────────────────────────────
@export var antitorque_strength         : float = 1.5
@export var antitorque_auto_correction  : float = 0.1

# ─── Feel / Physics ───────────────────────────────────────────────────────────
@export var hover_stability_strength    : float = 3.0
@export var translational_lift_bonus    : float = 0.15
@export var ground_effect_max_height    : float = 4.0
@export var ground_effect_lift_bonus    : float = 0.18

## Directional drag — forward drag is much lower than lateral/vertical
## so the helicopter builds forward speed like a real aircraft instead of
## being slowed equally in all directions.
## Values are drag coefficients (force = -velocity * coefficient * mass)
@export var drag_forward   : float = 0.05   ## Low — allows ~280 km/h cruise
@export var drag_sideways  : float = 0.35   ## High — lateral movement resisted
@export var drag_vertical  : float = 0.20   ## Medium — vertical drift dampened

# ─── Rotor RPM ────────────────────────────────────────────────────────────────
@export var rotor_rpm_max          : float = 258.0
@export var rotor_rpm_idle         : float = 80.0
@export var rotor_spool_up_rate    : float = 60.0
@export var rotor_spool_down_rate  : float = 30.0

var rotor_rpm_current : float = 0.0
var engine_on         : bool  = false

# Internal state
var _collective_current : float = 0.0
var _collective_target  : float = 0.0

func _ready() -> void:
	gravity_scale  = 1.0
	linear_damp    = 0.0   ## Disabled — we apply directional drag manually in _apply_drag()
	angular_damp   = 3.5
	mass           = self.mass
	can_sleep      = false

func _process(delta: float) -> void:
	_read_collective_input(delta)
	_update_rotor_rpm(delta)

func _physics_process(delta: float) -> void:
	if engine_on:
		_apply_collective(delta)
		_apply_cyclic(delta)
		_apply_antitorque(delta)
		_apply_hover_stability(delta)
	_apply_drag(delta)

# ─── Input ────────────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("EngineToggle") and not event.is_echo():
		engine_on = !engine_on

func _read_collective_input(delta: float) -> void:
	if not engine_on:
		_collective_target  = move_toward(_collective_target,  0.0, collective_decay_rate * delta)
		_collective_current = move_toward(_collective_current, 0.0, collective_spool_speed * delta)
		return

	if Input.is_action_pressed("Collective+"):
		_collective_target = move_toward(_collective_target, 1.0, collective_spool_speed * delta)
	elif Input.is_action_pressed("Collective-"):
		_collective_target = move_toward(_collective_target, 0.0, collective_spool_speed * delta)
	else:
		_collective_target = move_toward(_collective_target, collective_idle, collective_decay_rate * delta)

	_collective_current = move_toward(_collective_current, _collective_target, collective_spool_speed * delta)

# ─── RPM ─────────────────────────────────────────────────────────────────────

func _update_rotor_rpm(delta: float) -> void:
	if engine_on:
		var target_rpm : float = lerpf(rotor_rpm_idle, rotor_rpm_max, _collective_current)
		var spool_rate : float = rotor_spool_up_rate if target_rpm > rotor_rpm_current \
							   else rotor_spool_down_rate
		rotor_rpm_current = move_toward(rotor_rpm_current, target_rpm, spool_rate * delta)
	else:
		rotor_rpm_current = move_toward(rotor_rpm_current, 0.0, rotor_spool_down_rate * delta)

# ─── Forces ──────────────────────────────────────────────────────────────────

func _apply_collective(_delta: float) -> void:
	if _collective_current <= 0.01:
		return

	var weight_force : float   = mass * 9.8
	var up_direction : Vector3 = global_transform.basis.y
	var lift_force   : float   = _collective_current * collective_max_force * weight_force

	var local_velocity : Vector3 = global_basis.inverse() * linear_velocity
	var forward_speed  : float   = max(-local_velocity.z, 0.0)
	var etl_fraction   : float   = clampf(forward_speed / 12.0, 0.0, 1.0) * translational_lift_bonus
	lift_force += lift_force * etl_fraction

	var space_state := get_world_3d().direct_space_state
	var ray_params  := PhysicsRayQueryParameters3D.create(
			global_position,
			global_position + Vector3.DOWN * ground_effect_max_height)
	ray_params.exclude = [self]
	var ground_hit  := space_state.intersect_ray(ray_params)
	if ground_hit:
		var height_fraction : float = 1.0 - (global_position.distance_to(ground_hit.position) / ground_effect_max_height)
		lift_force += lift_force * ground_effect_lift_bonus * height_fraction

	apply_central_force(up_direction * lift_force)

func _apply_drag(_delta: float) -> void:
	# Decompose world velocity into the helicopter's local axes
	var local_velocity  : Vector3 = global_basis.inverse() * linear_velocity

	# Build a drag force in local space using per-axis coefficients
	var local_drag_force : Vector3 = Vector3(
		-local_velocity.x * drag_sideways,   ## X — lateral (strafe)
		-local_velocity.y * drag_vertical,   ## Y — vertical
		-local_velocity.z * drag_forward     ## Z — forward/back (nose direction)
	) * mass

	# Transform back to world space and apply
	apply_central_force(global_basis * local_drag_force)

func _apply_cyclic(_delta: float) -> void:
	var pitch_input  : float   = Input.get_action_strength("RollForward") \
							   - Input.get_action_strength("RollBack")
	var roll_input   : float   = Input.get_action_strength("RollRight")   \
							   - Input.get_action_strength("RollLeft")
	var right_axis   : Vector3 = global_transform.basis.x
	var forward_axis : Vector3 = -global_transform.basis.z
	var weight_force : float   = mass * 9.8

	apply_torque(right_axis   *  pitch_input * cyclic_pitch_strength * weight_force)
	apply_torque(forward_axis * -roll_input  * cyclic_roll_strength  * weight_force)

	var angular_vel : Vector3 = angular_velocity
	apply_torque(-right_axis   * angular_vel.dot(right_axis)   * cyclic_angular_damping * weight_force)
	apply_torque(-forward_axis * angular_vel.dot(forward_axis) * cyclic_angular_damping * weight_force)

func _apply_antitorque(_delta: float) -> void:
	var pedal_input  : float   = Input.get_action_strength("YawLeft")  \
							   - Input.get_action_strength("YawRight")
	var up_axis      : Vector3 = global_transform.basis.y
	var weight_force : float   = mass * 9.8

	apply_torque(up_axis *  pedal_input         * antitorque_strength        * weight_force)
	apply_torque(up_axis * -_collective_current * antitorque_auto_correction * weight_force)

func _apply_hover_stability(_delta: float) -> void:
	if _collective_current < 0.05:
		return
	var weight_force : float   = mass * 9.8
	var current_up   : Vector3 = global_transform.basis.y
	var level_up     : Vector3 = Vector3.UP
	var correction   : Vector3 = current_up.cross(level_up)
	apply_torque(correction * hover_stability_strength * _collective_current * weight_force)



func get_debug_info() -> Dictionary:
	return {
		"engine_on"          : engine_on,
		"collective_current" : snappedf(_collective_current, 0.01),
		"collective_target"  : snappedf(_collective_target,  0.01),
		"rotor_rpm"          : snappedf(rotor_rpm_current, 1.0),
		"linear_speed"       : linear_velocity.length(),
		"forward_speed_kmh"  : snappedf((global_basis.inverse() * linear_velocity).z * -3.6, 1.0),
		"altitude"           : global_position.y,
	}
