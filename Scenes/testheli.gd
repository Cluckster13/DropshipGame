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
## Adds back the lift lost when the rotor tilts, so pitching forward turns
## into forward acceleration instead of sinking. 0 = realistic (pilot must
## add collective), 1 = altitude fully held at any tilt. Capped at 60° tilt.
@export_range(0.0, 1.0, 0.05) var tilt_lift_compensation : float = 0.8
## Compensation is full up to this tilt...
@export var tilt_compensation_full_deg : float = 25.0
## ...and fades to nothing by this tilt. Past it the rotor behaves like a
## rotor: tip it way over and lift goes sideways, it doesn't become a jet.
@export var tilt_compensation_zero_deg : float = 50.0

## Never-exceed speed. Above it drag climbs steeply (retreating blade stall
## territory), so top speed in level flight lands a bit above this and even
## a full-power dive only goes ~15-20 km/h further.
@export var vne_kmh : float = 240.0
@export var vne_drag : float = 0.08
## Tilting far past a normal flying attitude turns the belly into the
## airflow: forward drag multiplies by up to 1 + this (at 80°+ tilt)
@export var belly_drag_multiplier : float = 6.0
@export var belly_drag_start_deg : float = 40.0
@export var ground_effect_max_height    : float = 4.0
@export var ground_effect_lift_bonus    : float = 0.18

## Directional drag — forward drag is much lower than lateral/vertical
## so the helicopter builds forward speed like a real aircraft instead of
## being slowed equally in all directions.
## Values are drag coefficients (force = -velocity * coefficient * mass)
## Drag is measured along the aircraft's flat heading (yaw only), NOT its
## tilted body, so pitching the nose down doesn't turn forward speed into
## "vertical" drag.
@export var drag_forward   : float = 0.01    ## Linear part — small, so it accelerates out of a hover briskly
## Quadratic part (× speed²) — negligible at low speed, sets top speed.
## 0.0006 ≈ 200 km/h at 10° nose-down, ~290 km/h at 20°.
@export var drag_forward_quadratic : float = 0.0006
## Sideways / vertical include the 0.1 that used to come from the project's
## hidden default damping, so they feel the same as before.
@export var drag_sideways  : float = 0.45   ## High — lateral movement resisted
@export var drag_vertical  : float = 0.30   ## Medium — vertical drift dampened (world up/down)

# ─── Rotor RPM ────────────────────────────────────────────────────────────────
@export var rotor_rpm_max          : float = 258.0
@export var rotor_rpm_idle         : float = 80.0
@export var rotor_spool_up_rate    : float = 60.0
@export var rotor_spool_down_rate  : float = 30.0

# ─── Landing (used to gate troop loading / unloading) ───────────────────────
@export var landed_check_distance : float = 1.5   ## Skids within this of the ground (m)
@export var landed_max_speed      : float = 1.5   ## And moving slower than this (m/s)

# ─── Damage ──────────────────────────────────────────────────────────────────
signal damaged(amount: float, source: Node)
signal destroyed
signal respawned

@export_group("Damage")
## Side the aircraft is on: enemy troops shoot at it
@export_range(-1, 1, 1) var team : int = 1
@export var max_health : float = 1000.0
## Rifle rounds do this fraction of their troop damage (armoured cabin)
@export var small_arms_multiplier : float = 0.25
## Height above the aircraft origin that shooters aim at (centre of the cabin)
@export var aim_height : float = 1.5
## Sudden speed change (m/s in one physics step) that starts hurting.
## A firm landing is ~4, slamming into the ground or a cliff is 10+.
@export var impact_damage_threshold : float = 7.0
## Damage per m/s of impact above the threshold
@export var impact_damage_per_speed : float = 80.0
## Seconds after being destroyed before a new aircraft appears at the start
## point. 0 = never respawn.
@export var respawn_delay : float = 10.0
@export_group("")

var health : float
var is_destroyed : bool = false
## Seconds until respawn (only meaningful while destroyed)
var respawn_time_left : float = 0.0
var _spawn_transform : Transform3D
var _last_velocity : Vector3 = Vector3.ZERO

var rotor_rpm_current : float = 0.0
var engine_on         : bool  = false

# Internal state
var _collective_current : float = 0.0
var _collective_target  : float = 0.0

func _ready() -> void:
	gravity_scale  = 1.0
	linear_damp    = 0.0   ## Disabled — we apply directional drag manually in _apply_drag()
	# REPLACE, not the default COMBINE: otherwise the project's default
	# linear damp (0.1) is still added on top and acts as hidden drag in
	# every direction, which was capping forward acceleration.
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp   = 3.5
	mass           = self.mass
	can_sleep      = false
	health = max_health
	_spawn_transform = global_transform
	add_to_group("Aircraft")

func _process(delta: float) -> void:
	_read_collective_input(delta)
	_update_rotor_rpm(delta)
	if is_destroyed and respawn_delay > 0.0:
		respawn_time_left = maxf(respawn_time_left - delta, 0.0)

func _physics_process(delta: float) -> void:
	_check_impact()
	if engine_on and not is_destroyed:
		_apply_collective(delta)
		_apply_cyclic(delta)
		_apply_antitorque(delta)
		_apply_hover_stability(delta)
	_apply_drag(delta)

# ─── Input ────────────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("EngineToggle") and not event.is_echo() and not is_destroyed:
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

	# Tilt compensation: lift / cos(tilt), blended by tilt_lift_compensation,
	# only for normal flying attitudes (fades out between full and zero deg)
	var tilt_cos : float = clampf(up_direction.dot(Vector3.UP), 0.5, 1.0)
	var comp := tilt_lift_compensation * (1.0 - smoothstep(tilt_compensation_full_deg, tilt_compensation_zero_deg, _tilt_deg()))
	lift_force *= lerpf(1.0, 1.0 / tilt_cos, comp)

	# Translational lift. The nose points +Z on this aircraft (verified in
	# flight), so forward speed is +local Z. Was -Z, which only gave the
	# bonus when flying backwards.
	var local_velocity : Vector3 = global_basis.inverse() * linear_velocity
	var forward_speed  : float   = max(local_velocity.z, 0.0)
	var etl_fraction   : float   = clampf(forward_speed / 12.0, 0.0, 1.0) * translational_lift_bonus
	lift_force += lift_force * etl_fraction

	var space_state := get_world_3d().direct_space_state
	var ray_params  := PhysicsRayQueryParameters3D.create(
			global_position,
			global_position + Vector3.DOWN * ground_effect_max_height)
	ray_params.exclude = [get_rid()]   # exclude wants RIDs, not nodes
	var ground_hit  := space_state.intersect_ray(ray_params)
	if ground_hit:
		var height_fraction : float = 1.0 - (global_position.distance_to(ground_hit.position) / ground_effect_max_height)
		lift_force += lift_force * ground_effect_lift_bonus * height_fraction

	apply_central_force(up_direction * lift_force)

func _apply_drag(_delta: float) -> void:
	# Decompose world velocity along the flat heading (yaw only): X = sideways,
	# Y = true vertical, Z = forward along the ground track
	var heading  : Basis   = Basis(Vector3.UP, global_rotation.y)
	var velocity : Vector3 = heading.inverse() * linear_velocity

	# Belly into the wind: way past a normal attitude, forward drag shoots up
	var belly := 1.0 + belly_drag_multiplier * smoothstep(belly_drag_start_deg, 80.0, _tilt_deg())
	var forward_drag := -velocity.z * drag_forward - velocity.z * absf(velocity.z) * drag_forward_quadratic * belly

	# Past VNE: steep extra drag that pins top speed (any direction)
	var vne := vne_kmh / 3.6
	var speed := linear_velocity.length()
	var vne_force := Vector3.ZERO
	if speed > vne:
		var over := speed - vne
		vne_force = -linear_velocity.normalized() * over * over * vne_drag * mass

	var drag_force : Vector3 = Vector3(
		-velocity.x * drag_sideways,
		-velocity.y * drag_vertical,
		forward_drag
	) * mass

	apply_central_force(heading * drag_force + vne_force)

## How far the rotor disc is tipped from level, in degrees
func _tilt_deg() -> float:
	return rad_to_deg(acos(clampf(global_basis.y.dot(Vector3.UP), -1.0, 1.0)))

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



# ─── Damage ──────────────────────────────────────────────────────────────────

func is_alive() -> bool:
	return not is_destroyed

## Where shooters aim and line-of-sight is checked to
func eye_position() -> Vector3:
	return global_position + global_basis.y * aim_height

func health_fraction() -> float:
	return clampf(health / max_health, 0.0, 1.0)

## Rifle fire from troops (and anything else with a source). Small arms are
## scaled by small_arms_multiplier; pass raw=true for damage already in hull
## points (impacts, explosions).
func take_damage(amount: float, source: Node = null, raw: bool = false) -> void:
	if is_destroyed:
		return
	# Our own troops' stray rounds don't hurt us
	if source and source.get("team") == team:
		return
	var dealt := amount if raw else amount * small_arms_multiplier
	health -= dealt
	damaged.emit(dealt, source)
	if health <= 0.0:
		health = 0.0
		_destroy()

## Patch up (e.g. while landed at base). Amount in hull points.
func repair(amount: float) -> void:
	if not is_destroyed:
		health = minf(health + amount, max_health)

## Hitting the ground or terrain hard: a big change of velocity in one step
func _check_impact() -> void:
	var change := (linear_velocity - _last_velocity).length()
	_last_velocity = linear_velocity
	if change > impact_damage_threshold and not freeze:
		take_damage((change - impact_damage_threshold) * impact_damage_per_speed, null, true)

func _destroy() -> void:
	is_destroyed = true
	engine_on = false
	print("[Heli] destroyed")
	# Everyone on board goes down with it
	for c in get_children():
		if c is PassengerHandler:
			for seat_name in c.seats:
				var occupant = c.seats[seat_name]["occupant"]
				if is_instance_valid(occupant) and occupant is Troop and occupant.state == Troop.States.PASSENGER:
					occupant.take_damage(INF, self)
	destroyed.emit()
	if respawn_delay > 0.0:
		respawn_time_left = respawn_delay
		await get_tree().create_timer(respawn_delay, false).timeout
		_respawn()

func _respawn() -> void:
	# Teleporting a RigidBody: freeze it, move it, clear its motion, unfreeze
	freeze = true
	global_transform = _spawn_transform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_last_velocity = Vector3.ZERO
	_collective_current = 0.0
	_collective_target = 0.0
	rotor_rpm_current = 0.0
	health = max_health
	is_destroyed = false
	await get_tree().physics_frame
	freeze = false
	print("[Heli] respawned")
	respawned.emit()

## On (or right above) the ground and nearly stopped. Troops may only board
## or get off while this is true.
func is_landed() -> bool:
	if linear_velocity.length() > landed_max_speed:
		return false
	var from := global_position + Vector3.UP * 0.5
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * (landed_check_distance + 0.5))
	query.exclude = [get_rid()]
	return not get_world_3d().direct_space_state.intersect_ray(query).is_empty()

func get_debug_info() -> Dictionary:
	return {
		"engine_on"          : engine_on,
		"collective_current" : snappedf(_collective_current, 0.01),
		"collective_target"  : snappedf(_collective_target,  0.01),
		"rotor_rpm"          : snappedf(rotor_rpm_current, 1.0),
		"linear_speed"       : linear_velocity.length(),
		"forward_speed_kmh"  : snappedf((global_basis.inverse() * linear_velocity).z * 3.6, 1.0),
		"altitude"           : global_position.y,
		"landed"             : is_landed(),
	}
