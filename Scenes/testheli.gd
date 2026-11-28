## HeliBase: helicopter flight model, Arma / Wardogs style.
## Attach to the helicopter's RigidBody3D (needs a CollisionShape3D child).
##
## Controls:
##   Shift / Ctrl   - Collective up / down. Released: returns to hover power
##                    in the air, to ground idle on the ground.
##   W / S          - Pitch (nose down / up)
##   Q / E          - Roll (bank left / right)
##   A / D          - Pedals (yaw left / right)
##   EngineToggle   - Start / shut down engine
##
## How it flies (deliberately few moving parts):
##   - ONE force holds it up: rotor thrust along the aircraft's up axis.
##     Neutral collective = exactly its weight. Tilt the rotor and part of
##     that thrust goes sideways instead of up, so you sink unless you pull
##     more collective. No hidden lift compensation.
##   - Two real rotor effects add a little: translational lift (cleaner air
##     once moving) and flare lift (pull the nose up at speed and air rams
##     up through the disc, so the aircraft balloons, like Arma flares).
##   - Fuselage drag per body axis: slim nose-on, big side-on and belly-on.
##     Momentum carries; going sideways or belly-first bleeds speed fast.
##   - Cyclic and pedals command a rotation RATE. Let go and the aircraft
##     holds its attitude (it doesn't auto-level), like Arma's standard model.
##   - The tail weathervanes the nose into the airflow at speed unless you
##     hold a pedal, which is what makes banked turns and J-hooks work.

extends RigidBody3D
class_name HeliBase

# ─── Rotor ────────────────────────────────────────────────────────────────────
@export_group("Rotor")
## Thrust at full collective, in multiples of the aircraft's weight.
## 1.6 = can climb hard and hold altitude up to ~50° of tilt.
@export var max_thrust_g : float = 1.6
## Thrust at bottom collective (fast descent, never zero)
@export var min_thrust_g : float = 0.3
## How fast the collective moves while a key is held (full travel per second)
@export var collective_rate : float = 1.0
## How fast it returns to hover / ground idle when keys are released
@export var collective_return_rate : float = 1.5
## Extra thrust once moving through clean air (0.06 = +6%). Keep it small:
## it's what lets a tilted aircraft hold altitude without extra collective.
@export var translational_lift_bonus : float = 0.06
## Heave damping: thrust lost per m/s of climb (and gained per m/s of
## descent), in g. Makes vertical speed settle quickly once you let go of
## the collective instead of coasting. Sets max climb/descent rate too:
## (max_thrust_g - 1) / this = 15 m/s climb, (1 - min_thrust_g) / this = 17 m/s sink.
@export var heave_damping : float = 0.04
## Speed range (m/s) over which translational lift builds up
@export var translational_lift_speeds : Vector2 = Vector2(8.0, 22.0)
## Flare lift: extra thrust (in g) per m/s of air coming up through the rotor
## disc. Nose up at speed = air rams up through the disc = balloon.
@export var flare_lift_gain : float = 0.008
@export var flare_lift_max_g : float = 0.5
@export var ground_effect_max_height : float = 4.0
@export var ground_effect_lift_bonus : float = 0.12

# ─── Controls ─────────────────────────────────────────────────────────────────
@export_group("Controls")
## Rotation rate at full stick / pedal (degrees per second)
@export var pitch_rate_deg : float = 50.0
@export var roll_rate_deg  : float = 80.0
@export var yaw_rate_deg   : float = 70.0
## How snappily the aircraft reaches the commanded rate (higher = twitchier)
@export var control_response : float = 5.0
## At speed, turns the nose into the airflow when no pedal is held.
## Degrees/s of yaw per degree of sideslip.
@export var weathervane_strength : float = 1.2
## Speed (m/s) at which weathervaning is at full strength
@export var weathervane_full_speed : float = 30.0

# ─── Fuselage drag ────────────────────────────────────────────────────────────
@export_group("Drag")
## Overall drag. With the areas below, top level-flight speed is ~270 km/h.
@export var drag_coefficient : float = 0.0022
## Relative areas facing each direction: nose-on, side-on, belly/top-on
@export var area_front    : float = 0.3
@export var area_side     : float = 1.0
@export var area_vertical : float = 1.2
## Small linear drag so a hover settles instead of drifting forever
@export var low_speed_drag : float = 0.05

# ─── Rotor RPM ────────────────────────────────────────────────────────────────
@export_group("Engine")
@export var rotor_rpm_max          : float = 258.0
@export var rotor_rpm_idle         : float = 80.0
@export var rotor_spool_up_rate    : float = 60.0
@export var rotor_spool_down_rate  : float = 30.0

# ─── Landing (used to gate troop loading / unloading) ───────────────────────
@export_group("Landing")
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
## No crash damage this soon after (re)spawning, so settling onto the pad
## from wherever it was placed doesn't count as a crash
const IMPACT_GRACE_TIME := 2.0
var _impact_grace : float = IMPACT_GRACE_TIME

var rotor_rpm_current : float = 0.0
var engine_on         : bool  = false

# Collective: 0 = bottom, 0.5 = hover thrust (1 g), 1 = max thrust
var _collective_current : float = 0.0
var _collective_target  : float = 0.0
var _on_ground : bool = true
# Read in _process, used in _integrate_forces
var _input_pitch : float = 0.0
var _input_roll  : float = 0.0
var _input_yaw   : float = 0.0

func _ready() -> void:
	gravity_scale = 1.0
	linear_damp = 0.0
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE    # all drag is ours
	angular_damp = 0.0
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE   # rate control does the damping
	can_sleep = false
	health = max_health
	_spawn_transform = global_transform
	add_to_group("Aircraft")

func _process(delta: float) -> void:
	_on_ground = is_landed()
	_read_input(delta)
	_update_rotor_rpm(delta)
	if is_destroyed and respawn_delay > 0.0:
		respawn_time_left = maxf(respawn_time_left - delta, 0.0)

func _physics_process(delta: float) -> void:
	_impact_grace = maxf(_impact_grace - delta, 0.0)
	_check_impact()

# ─── Input ────────────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("EngineToggle") and not event.is_echo() and not is_destroyed:
		engine_on = !engine_on

func _read_input(delta: float) -> void:
	var flying := engine_on and not is_destroyed
	_input_pitch = (Input.get_action_strength("RollForward") - Input.get_action_strength("RollBack")) if flying else 0.0
	_input_roll  = (Input.get_action_strength("RollRight") - Input.get_action_strength("RollLeft")) if flying else 0.0
	_input_yaw   = (Input.get_action_strength("YawLeft") - Input.get_action_strength("YawRight")) if flying else 0.0

	if not flying:
		_collective_target = 0.0
	elif Input.is_action_pressed("Collective+"):
		_collective_target = move_toward(_collective_target, 1.0, collective_rate * delta)
	elif Input.is_action_pressed("Collective-"):
		_collective_target = move_toward(_collective_target, 0.0, collective_rate * delta)
	else:
		# Hands off: hover power in the air, ground idle when sitting on the ground
		var rest := 0.0 if _on_ground else 0.5
		_collective_target = move_toward(_collective_target, rest, collective_return_rate * delta)
	_collective_current = move_toward(_collective_current, _collective_target, 3.0 * delta)

# ─── RPM ─────────────────────────────────────────────────────────────────────

func _update_rotor_rpm(delta: float) -> void:
	var target_rpm := rotor_rpm_max if (engine_on and not is_destroyed) else 0.0
	var rate := rotor_spool_up_rate if target_rpm > rotor_rpm_current else rotor_spool_down_rate
	rotor_rpm_current = move_toward(rotor_rpm_current, target_rpm, rate * delta)

## 0..1: how much of the rotor's power is available (thrust goes with rpm²)
func rotor_fraction() -> float:
	return clampf(rotor_rpm_current / rotor_rpm_max, 0.0, 1.0)

# ─── Flight model ────────────────────────────────────────────────────────────

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var b := state.transform.basis.orthonormalized()
	var g := state.total_gravity.length()
	var weight := mass * g
	var vel := state.linear_velocity
	var v_body := b.inverse() * vel          # x = side, y = up, z = forward (nose is +Z)
	var speed := vel.length()
	var rotor := rotor_fraction()

	# --- Rotor thrust: the only thing holding us up
	var thrust_g := _collective_to_thrust(_collective_current)
	var horizontal_speed := Vector2(vel.x, vel.z).length()
	thrust_g *= 1.0 + translational_lift_bonus * smoothstep(translational_lift_speeds.x, translational_lift_speeds.y, horizontal_speed)
	# Climbing eats thrust, descending adds it (world vertical speed only, so
	# level forward flight isn't affected)
	thrust_g -= vel.y * heave_damping
	# Flare: air coming UP through the disc (moving opposite to the rotor's up axis)
	var inflow_up := -vel.dot(b.y)
	if inflow_up > 0.0:
		thrust_g += minf(inflow_up * flare_lift_gain, flare_lift_max_g)
	thrust_g *= 1.0 + ground_effect_lift_bonus * _ground_effect(state)
	thrust_g = maxf(thrust_g, 0.0) * rotor * rotor
	state.apply_central_force(b.y * thrust_g * weight)

	# --- Fuselage drag, per body axis, quadratic (+ a touch of linear)
	var areas := Vector3(area_side, area_vertical, area_front)
	var drag_body := -Vector3(
		v_body.x * absf(v_body.x) * areas.x,
		v_body.y * absf(v_body.y) * areas.y,
		v_body.z * absf(v_body.z) * areas.z) * drag_coefficient
	drag_body -= v_body * low_speed_drag
	state.apply_central_force(b * drag_body * mass)

	# --- Attitude: cyclic / pedals command rotation rates
	if rotor > 0.05 and not is_destroyed:
		var desired := Vector3(
			_input_pitch * deg_to_rad(pitch_rate_deg),
			_input_yaw   * deg_to_rad(yaw_rate_deg),
			_input_roll  * deg_to_rad(roll_rate_deg))
		# Weathervane: with no pedal held, the tail swings the nose into the
		# airflow (sideslip angle, scaled in by speed)
		if horizontal_speed > 3.0:
			var sideslip := atan2(v_body.x, maxf(absf(v_body.z), 0.1) * signf(v_body.z + 0.001))
			var strength := weathervane_strength * smoothstep(3.0, weathervane_full_speed, horizontal_speed)
			desired.y += sideslip * strength * (1.0 - absf(_input_yaw))
		var av_body := b.inverse() * state.angular_velocity
		var k := 1.0 - exp(-control_response * rotor * state.step)
		av_body = av_body.lerp(desired, k)
		state.angular_velocity = b * av_body

func _collective_to_thrust(c: float) -> float:
	# 0 -> min, 0.5 -> exactly hover (1 g), 1 -> max
	if c < 0.5:
		return lerpf(min_thrust_g, 1.0, c * 2.0)
	return lerpf(1.0, max_thrust_g, (c - 0.5) * 2.0)

func _ground_effect(state: PhysicsDirectBodyState3D) -> float:
	var from := state.transform.origin
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * ground_effect_max_height)
	query.exclude = [get_rid()]
	var hit := state.get_space_state().intersect_ray(query)
	if hit.is_empty():
		return 0.0
	return 1.0 - from.distance_to(hit.position) / ground_effect_max_height

## How far the rotor disc is tipped from level, in degrees
func tilt_deg() -> float:
	return rad_to_deg(acos(clampf(global_basis.y.dot(Vector3.UP), -1.0, 1.0)))

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
	if change > impact_damage_threshold and not freeze and _impact_grace <= 0.0:
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
	_impact_grace = IMPACT_GRACE_TIME
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
		"collective"         : snappedf(_collective_current, 0.01),
		"thrust_g"           : snappedf(_collective_to_thrust(_collective_current) * rotor_fraction() * rotor_fraction(), 0.01),
		"rotor_rpm"          : snappedf(rotor_rpm_current, 1.0),
		"tilt_deg"           : snappedf(tilt_deg(), 1.0),
		"linear_speed"       : linear_velocity.length(),
		"forward_speed_kmh"  : snappedf((global_basis.inverse() * linear_velocity).z * 3.6, 1.0),
		"altitude"           : global_position.y,
		"landed"             : is_landed(),
	}
