class_name Troop
extends CharacterBody3D
## A single infantry unit. Team-aware, so the same scene works for friendlies
## (team 1) and enemies (team -1).
##
## Two ways to drive it:
##   - In a Squad: the squad hands out orders (move_to / stop) and decides
##     what to do after landing, capturing, or making contact.
##   - Solo (no squad): after disembarking it heads for the nearest
##     objective its team doesn't own.
##
## Combat: every perception tick the troop looks for the nearest enemy it has
## line of sight to. On contact it drops into COMBAT: stops, turns, and fires
## a hitscan rifle until the target dies or is out of sight for a while, then
## goes back to whatever it was doing (including any order it got mid-fight).

signal arrived(troop: Troop)       ## finished a MOVING order
signal disembarked(troop: Troop)   ## walked clear of the helicopter after unloading
signal died(troop: Troop)
signal contact(troop: Troop, enemy: Node3D)  ## just started fighting (a Troop or an aircraft)
signal combat_ended(troop: Troop)            ## no more targets, back to previous task

enum States {IDLE, MOVING, MOVING_TO_BOARD, PASSENGER, MOVING_TO_EXIT, COMBAT, DEAD, SAPPING}

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

@export_group("Health")
@export var max_health : float = 100.0
## Falling below this world height kills the troop
@export var kill_height : float = -300.0

@export_group("Perception")
## How far this troop can spot enemies (m). Also the rifle's effective range.
@export var sight_range : float = 60.0
## Seconds between scans for enemies (staggered per troop)
@export var perception_interval : float = 0.25
## Height of the eyes / muzzle above the body origin
@export var eye_height : float = 0.6
## Out of sight this long with no other target = disengage
@export var lose_target_time : float = 2.0
## Once alerted (fighting, or squad in contact) sight range is multiplied by
## this, so troops can engage enemies just past where they first spotted one
@export var alert_range_multiplier : float = 1.3

@export_group("Rifle")
@export var fire_rate : float = 2.0          ## shots per second
@export var damage : float = 25.0
## Seconds from spotting a target to the first shot
@export var reaction_time : float = 0.4
## Cone half-angle at point blank (degrees).
## Tuned so 1v1 time-to-kill is ~2s at 30m, ~4s at 45m, ~10s at 60m.
@export var base_spread_deg : float = 0.5
## Extra spread per metre to target (degrees)
@export var spread_per_meter_deg : float = 0.02
## Overall soldier quality. 1 = baseline. Divides spread and reaction time,
## so 0.8 = sloppier/slower, 1.25 = sharper/faster. Squads set this on
## their members (see Squad.skill).
@export_range(0.25, 2.0, 0.05) var skill : float = 1.0
## Spread multiplier when firing while still moving
@export var moving_spread_multiplier : float = 2.0
## Must be facing within this angle of the target to fire (degrees)
@export var fire_cone_deg : float = 15.0
## Won't fire if a friendly is this close (m) to the line of fire;
## sidesteps to find a clear lane instead
@export var friendly_clearance : float = 1.2

@export_group("Anti-tank")
## Carries a rocket launcher: goes after vehicles first, fires rockets at
## them (rifle for everything else)
@export var anti_tank : bool = false:
	set(value):
		anti_tank = value
		if is_node_ready() and launcher_mesh:
			launcher_mesh.visible = value
## Shown only on anti-tank troops (the launcher on the shoulder)
@export var launcher_mesh : Node3D
@export var rocket_scene : PackedScene = preload("res://Scenes/Vehicles/Rocket.tscn")
@export var rocket_range : float = 220.0
## Seconds to reload between rockets
@export var rocket_reload : float = 6.0
@export var rocket_spread_deg : float = 0.8

@export_group("Demolition")
## Walks up to enemy vehicles marked chargeable (AA) and blows them up
@export var can_plant_charges : bool = true
## Goes for a chargeable vehicle this close (m)
@export var charge_seek_range : float = 50.0
@export var charge_plant_time : float = 3.0
@export var charge_damage : float = 1000.0


## Multiplier on move_speed. Squads use this to pace the leader and let
## followers speed up / ease off to hold formation.
var speed_scale : float = 1.0

var state  : States = States.IDLE
var health : float
var squad  : Squad = null
## Who we're shooting at (COMBAT only): a Troop or an aircraft (HeliBase).
## Anything with team, is_alive() and eye_position() can be a target.
var target : Node3D = null

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

# Combat bookkeeping
var _resume_state     : States = States.IDLE   # what to go back to after COMBAT
var _perception_timer : float = 0.0
var _fire_cooldown    : float = 0.0
var _reaction_left    : float = 0.0
var _target_visible   : bool  = false
var _lost_sight_time  : float = 0.0
var _rocket_cooldown  : float = 0.0
var _last_floor_position : Vector3 = Vector3.INF

# Demolition
var _charge_target : Vehicle = null
var _plant_left    : float = -1.0   # < 0 = still walking up to it

@onready var nav: NavigationAgent3D = $NavigationAgent3D

func _ready() -> void:
	health = max_health
	_default_layer = collision_layer
	_default_mask  = collision_mask
	nav.path_desired_distance   = 1.0
	nav.target_desired_distance = arrival_distance
	_perception_timer = randf() * perception_interval   # spread scans across frames
	add_to_group("Troops")
	_apply_team_tint()
	if launcher_mesh:
		launcher_mesh.visible = anti_tank

func _physics_process(delta: float) -> void:
	if state == States.DEAD:
		return
	if state == States.PASSENGER:
		_snap_to_seat()
		return   # riding along: no gravity, no move_and_slide, no shooting

	# Fell out of the world (spawned off the terrain, pushed through it...)
	if global_position.y < kill_height:
		push_warning("Troop %s fell out of the world (last on the ground at %s, state %s)" % [
			name, _last_floor_position, States.keys()[state]])
		_die()
		return
	if is_on_floor():
		_last_floor_position = global_position

	_perception_timer -= delta
	if _perception_timer <= 0.0:
		_perception_timer = perception_interval
		_perceive()

	_rocket_cooldown -= delta
	match state:
		States.COMBAT:
			_combat_tick(delta)
		States.SAPPING:
			_sap_tick(delta)
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

## States in which this troop will look for / shoot at enemies
func can_fight() -> bool:
	return state == States.IDLE or state == States.MOVING or state == States.MOVING_TO_EXIT or state == States.COMBAT

func is_enemy_of(other: Node) -> bool:
	var their_team = other.get("team")
	return their_team is int and their_team != team and their_team != 0 and team != 0

## Something we can shoot at right now: an enemy troop on the ground, or an
## enemy aircraft that's still flying. Untyped: may be a freed object.
func is_valid_enemy(t) -> bool:
	if not is_instance_valid(t) or t == self or not t.has_method("is_alive") or not t.is_alive():
		return false
	if t is Troop and t.state == States.PASSENGER:
		return false   # inside an aircraft: shoot the aircraft instead
	if t is Vehicle and (t.is_carried() or not (anti_tank or t.rifle_vulnerable())):
		return false   # rifles can't hurt a tank: leave it to anti-tank troops
	return is_enemy_of(t)

func is_alerted() -> bool:
	return state == States.COMBAT or (squad != null and squad.in_contact)

## Current spotting / engagement range: wider once alerted
func current_sight_range() -> float:
	return sight_range * alert_range_multiplier if is_alerted() else sight_range

func eye_position() -> Vector3:
	return global_position + Vector3.UP * eye_height

func can_see(other: Node3D) -> bool:
	var query := PhysicsRayQueryParameters3D.create(eye_position(), other.eye_position())
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return hit.is_empty() or hit.collider == other

## Nearest enemy (troop, vehicle or aircraft) in range with clear line of
## sight, or null. Anti-tank troops look further for vehicles and pick them
## first; riflemen only bother with a vehicle when nothing softer is around.
func find_visible_enemy() -> Node3D:
	var candidates: Array = []
	var scan_range := current_sight_range()
	var others := get_tree().get_nodes_in_group("Troops") + get_tree().get_nodes_in_group("Aircraft") \
		+ get_tree().get_nodes_in_group("Vehicles")
	for node in others:
		if not is_valid_enemy(node):
			continue
		var d := eye_position().distance_to(node.eye_position())
		var reach := scan_range
		if node is Vehicle:
			if anti_tank:
				reach = maxf(scan_range, rocket_range)
				d *= 0.2
			else:
				d *= 3.0
		if eye_position().distance_to(node.eye_position()) <= reach:
			candidates.append([d, node])
	candidates.sort_custom(func(a, b): return a[0] < b[0])
	# Only ray-test the closest few; keeps big battles cheap
	for i in mini(candidates.size(), 4):
		if can_see(candidates[i][1]):
			return candidates[i][1]
	return null

# ---------------------------------------------------------------- orders

## While fighting, a move order is remembered and carried out once the
## fight is over rather than breaking off mid-engagement.
func move_to(pos: Vector3) -> void:
	if not is_available():
		return
	nav.target_position = pos
	_stuck_time = 0.0
	if state == States.COMBAT:
		_resume_state = States.MOVING
	else:
		state = States.MOVING

func stop() -> void:
	if state == States.COMBAT:
		_resume_state = States.IDLE
	elif is_available():
		state = States.IDLE

func command_board(handler: PassengerHandler, seat_name: String, door_position: Vector3) -> void:
	_clear_target_obj()
	target = null
	passenger_handler  = handler
	assigned_seat_name = seat_name
	seat_marker        = handler.seat_marker(seat_name)
	nav.target_position = door_position
	state = States.MOVING_TO_BOARD

## Aircraft left before we got aboard: give the seat back and stand down
func cancel_board() -> void:
	if state != States.MOVING_TO_BOARD:
		return
	_leave_seat()
	state = States.IDLE

## door_position: where to appear (outside the hull collision)
## rally_position: where to walk to before counting as "disembarked"
func command_disembark(door_position: Vector3, rally_position: Vector3) -> void:
	_leave_seat()
	speed_scale = 1.0
	visible = true   # hidden while riding inside a vehicle

	global_position = door_position
	global_basis = Basis(Vector3.UP, global_rotation.y)   # stand upright, keep facing
	velocity = Vector3.ZERO
	_smoothed_velocity = Vector3.ZERO
	collision_layer = _default_layer
	collision_mask  = _default_mask

	nav.target_position = rally_position
	state = States.MOVING_TO_EXIT

func take_damage(amount: float, source: Node = null) -> void:
	if not is_alive():
		return
	health -= amount
	if health <= 0.0:
		_die(source)
		return
	# Getting shot gives away the shooter's position (troop or aircraft)
	if state != States.COMBAT and can_fight() and is_valid_enemy(source):
		_enter_combat(source)

# ---------------------------------------------------------------- combat

func _perceive() -> void:
	if not can_fight():
		return
	if can_plant_charges and not anti_tank:
		var charge_target := _find_charge_target()
		if charge_target:
			_begin_sapping(charge_target)
			return
	if state != States.COMBAT:
		var enemy := find_visible_enemy()
		if enemy:
			_enter_combat(enemy)
		return

	var target_ok := is_valid_enemy(target)
	_target_visible = target_ok and can_see(target)
	if _target_visible:
		_lost_sight_time = 0.0
		return

	_lost_sight_time += perception_interval
	var other := find_visible_enemy()
	if other:
		_set_target(other)
	elif not target_ok or _lost_sight_time >= lose_target_time:
		_exit_combat()

func _enter_combat(enemy: Node3D) -> void:
	if state != States.COMBAT:
		_resume_state = state
		state = States.COMBAT
	_set_target(enemy)
	_reaction_left = reaction_time / skill
	contact.emit(self, enemy)

func _set_target(enemy: Node3D) -> void:
	if enemy != target:
		_reaction_left = maxf(_reaction_left, reaction_time * 0.5 / skill)   # re-aim on switch
	target = enemy
	_target_visible = true
	_lost_sight_time = 0.0

func _exit_combat() -> void:
	target = null
	_target_visible = false
	_stuck_time = 0.0
	state = _resume_state
	combat_ended.emit(self)

func _combat_tick(delta: float) -> void:
	direction = Vector3.ZERO   # halt and fight
	if not is_instance_valid(target):
		return
	var to_target := target.global_position - global_position
	to_target.y = 0.0
	if to_target.length_squared() > 0.01:
		var target_angle := atan2(-to_target.x, -to_target.z)
		rotation.y = lerp_angle(rotation.y, target_angle, delta * turn_speed * 1.5)

	_reaction_left -= delta
	_fire_cooldown -= delta
	if not (_target_visible and _reaction_left <= 0.0 and _fire_cooldown <= 0.0 and _is_facing(to_target)):
		return

	# Check fire. A friend in the lane = shuffle sideways instead of shooting.
	var blocker := _friendly_in_line_of_fire(target)
	if blocker:
		var right := to_target.normalized().cross(Vector3.UP)
		var away := -1.0 if (blocker.global_position - global_position).dot(right) > 0.0 else 1.0
		direction = right * away * 0.5
		return

	if anti_tank and target is Vehicle:
		if _rocket_cooldown <= 0.0:
			_fire_rocket(target)
			_rocket_cooldown = rocket_reload * randf_range(0.9, 1.1)
		return   # reloading: don't waste rifle rounds on armour
	_fire_at(target)
	_fire_cooldown = (1.0 / fire_rate) * randf_range(0.85, 1.15)

## First friendly standing within friendly_clearance of the segment from
## our muzzle to the target, or null if the lane is clear
func _friendly_in_line_of_fire(enemy: Node3D) -> Troop:
	var from := eye_position()
	var to: Vector3 = enemy.eye_position()
	var seg := to - from
	var seg_len_sq := seg.length_squared()
	if seg_len_sq < 0.01:
		return null
	for node in get_tree().get_nodes_in_group("Troops"):
		var t := node as Troop
		if t == null or t == self or t.team != team or not t.is_alive() or t.state == States.PASSENGER:
			continue
		var p := t.eye_position()
		var along := (p - from).dot(seg) / seg_len_sq
		if along <= 0.0 or along >= 1.0:
			continue   # behind us or past the target
		if p.distance_to(from + seg * along) < friendly_clearance:
			return t
	return null

func _is_facing(flat_dir: Vector3) -> bool:
	if flat_dir.length_squared() < 0.01:
		return true
	var forward := -global_basis.z
	forward.y = 0.0
	return forward.normalized().angle_to(flat_dir.normalized()) <= deg_to_rad(fire_cone_deg)

func _fire_at(enemy: Node3D) -> void:
	var forward := -global_basis.z
	var muzzle := eye_position() + forward * 0.4
	var aim: Vector3
	if enemy is Troop:
		aim = enemy.global_position + Vector3.UP * randf_range(-0.3, 0.5)
	else:
		# Aircraft: aim for the cabin, anywhere on a big target
		aim = enemy.eye_position() + Vector3(randf_range(-1.5, 1.5), randf_range(-0.8, 0.8), randf_range(-1.5, 1.5))
	var dist := muzzle.distance_to(aim)

	var spread := deg_to_rad(base_spread_deg + spread_per_meter_deg * dist) / skill
	if Vector2(velocity.x, velocity.z).length() > 0.5:
		spread *= moving_spread_multiplier
	var dir := _apply_spread((aim - muzzle).normalized(), spread)

	var end := muzzle + dir * current_sight_range() * 1.25
	var query := PhysicsRayQueryParameters3D.create(muzzle, end)
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var hit_pos := end
	if not hit.is_empty():
		hit_pos = hit.position
		# collider can be null: Terrain3D's collision has no node behind it,
		# and a body can be freed the same frame it's hit
		var hit_body: Object = hit.get("collider")
		if is_instance_valid(hit_body) and hit_body.has_method("take_damage"):
			Damage.apply(hit_body, damage, self, Damage.Type.BULLET)

	var col := Color(0.5, 0.7, 1.0) if team == TEAM_FRIENDLY else Color(1.0, 0.55, 0.3)
	Tracer.spawn(get_tree().current_scene, muzzle, hit_pos, col)

## AT rocket: a slow, visible projectile, lightly led onto moving vehicles
func _fire_rocket(vehicle: Vehicle) -> void:
	var forward := -global_basis.z
	var muzzle := eye_position() + forward * 0.5 + Vector3.UP * 0.2
	var aim := vehicle.global_position + Vector3.UP * (vehicle.aim_height * 0.6)
	var flight_time := muzzle.distance_to(aim) / 90.0
	aim += vehicle.velocity * flight_time
	var dir := _apply_spread((aim - muzzle).normalized(), deg_to_rad(rocket_spread_deg) / skill)
	Projectile.fire(rocket_scene, get_tree().current_scene, muzzle, dir, self, [get_rid()])

# ---------------------------------------------------------------- demolition

## Nearest enemy vehicle we could blow up with a charge that no one else is
## already going for, or null
func _find_charge_target() -> Vehicle:
	var best : Vehicle = null
	var best_d := charge_seek_range
	for node in get_tree().get_nodes_in_group("Vehicles"):
		var v := node as Vehicle
		if v == null or not v.chargeable or not v.is_alive() or v.is_carried() or not is_enemy_of(v):
			continue
		if is_instance_valid(v.sapper) and v.sapper != self and v.sapper.is_alive():
			continue
		var d := global_position.distance_to(v.global_position)
		if d < best_d:
			best_d = d
			best = v
	return best

func _begin_sapping(v: Vehicle) -> void:
	if state == States.COMBAT:
		target = null
		_target_visible = false
	else:
		_resume_state = state
	_charge_target = v
	v.sapper = self
	_plant_left = -1.0
	_stuck_time = 0.0
	nav.target_position = v.global_position
	state = States.SAPPING
	print("[Troop] %s going to plant a charge on %s" % [name, v.name])

func _sap_tick(delta: float) -> void:
	var v := _charge_target
	if not is_instance_valid(v) or not v.is_alive() or v.is_carried():
		_end_sapping()
		return
	var reach := v.hull_radius + 1.5
	if _plant_left < 0.0:
		if _flat_dist(v.global_position, global_position) <= reach:
			_plant_left = charge_plant_time   # in position: start planting
			direction = Vector3.ZERO
			return
		# Walk up to it (it may be moving)
		if nav.target_position.distance_to(v.global_position) > 3.0:
			nav.target_position = v.global_position
		var next := nav.get_next_path_position() if _path_reaches_target() else v.global_position
		var to_next := next - global_position
		to_next.y = 0.0
		direction = to_next.normalized() if to_next.length_squared() > 0.01 else Vector3.ZERO
		if direction != Vector3.ZERO:
			rotation.y = lerp_angle(rotation.y, atan2(-direction.x, -direction.z), delta * turn_speed)
		return
	# Kneeling at the hull, setting the charge
	direction = Vector3.ZERO
	if _flat_dist(v.global_position, global_position) > reach + 2.0:
		_plant_left = -1.0   # it drove off: chase it
		return
	_plant_left -= delta
	if _plant_left <= 0.0:
		print("[Troop] %s detonated a charge on %s" % [name, v.name])
		Damage.apply(v, charge_damage, self, Damage.Type.CHARGE)
		_end_sapping()

func _end_sapping() -> void:
	if is_instance_valid(_charge_target) and _charge_target.sapper == self:
		_charge_target.sapper = null
	_charge_target = null
	_plant_left = -1.0
	state = States.IDLE
	if squad:
		squad.member_rejoin(self)

# ---------------------------------------------------------------- vehicles

## Ride inside a ground vehicle (APC): hidden, no collision, snapped to the seat
func board_vehicle(seat: Node3D) -> void:
	_clear_target_obj()
	target = null
	seat_marker = seat
	state = States.PASSENGER
	collision_layer = 0
	collision_mask = 0
	visible = false

## Random direction inside a cone of half-angle `angle` around `dir`
func _apply_spread(dir: Vector3, angle: float) -> Vector3:
	var u := dir.cross(Vector3.UP)
	if u.length_squared() < 0.0001:
		u = dir.cross(Vector3.RIGHT)
	u = u.normalized()
	var v := dir.cross(u).normalized()
	var r := angle * sqrt(randf())
	var theta := randf() * TAU
	return (dir + (u * cos(theta) + v * sin(theta)) * tan(r)).normalized()

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

func _die(killer: Node = null) -> void:
	if is_instance_valid(_charge_target) and _charge_target.sapper == self:
		_charge_target.sapper = null
	_leave_seat()
	_clear_target_obj()
	target = null
	state = States.DEAD
	collision_layer = 0
	collision_mask  = 0
	print("[Troop] %s (%s) killed by %s" % [
		name, squad.squad_name if squad else "solo", str(killer.name) if killer else "?"])
	died.emit(self)
	queue_free()   # placeholder until there's a death animation / ragdoll

## Re-check whether the navmesh actually connects us to the target this often
const DIRECT_CHECK_INTERVAL := 1.0
## Path ends this close (flat m) to us / the target = navmesh covers the trip
const PATH_REACH_TOLERANCE := 3.0

var _direct_mode : bool = false
var _direct_check_timer : float = 0.0
var _direct_checked_target : Vector3 = Vector3.INF

## Does the navmesh link where we stand to where we're going? False when
## either end is on unbaked ground: then the agent's path would be empty,
## or stop short at the edge of a baked tile.
func _path_reaches_target() -> bool:
	var map := nav.get_navigation_map()
	if NavigationServer3D.map_get_iteration_id(map) == 0:
		return false
	var path := NavigationServer3D.map_get_path(map, global_position, nav.target_position, true)
	if path.is_empty():
		return false
	return _flat_dist(path[0], global_position) <= PATH_REACH_TOLERANCE \
		and _flat_dist(path[path.size() - 1], nav.target_position) <= PATH_REACH_TOLERANCE

func _flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

func _update_navigation_direction() -> void:
	# Pick nav-following or straight-line walking. Decided every second (or
	# right away when the goal moves) instead of every frame, so troops
	# don't flicker between the two at the edge of a baked tile.
	_direct_check_timer -= get_physics_process_delta_time()
	if _direct_check_timer <= 0.0 or nav.target_position.distance_to(_direct_checked_target) > 5.0:
		_direct_check_timer = DIRECT_CHECK_INTERVAL * randf_range(0.8, 1.2)
		_direct_checked_target = nav.target_position
		_direct_mode = not _path_reaches_target()

	var arrived_direct := _direct_mode and _flat_dist(nav.target_position, global_position) <= arrival_distance
	var arrived_nav := not _direct_mode and nav.is_navigation_finished()
	if arrived_nav or arrived_direct or _is_stuck_near_goal():
		direction = Vector3.ZERO
		_stuck_time = 0.0
		_on_arrived()
		return

	var next_point: Vector3 = nav.target_position if _direct_mode else nav.get_next_path_position()
	var to_next: Vector3 = next_point - global_position
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
		"Target": str(target.name) if is_instance_valid(target) else "-",
		"Nav_Target": nav.target_position,
		"Position": global_position,
		"Velocity": velocity,
	}
