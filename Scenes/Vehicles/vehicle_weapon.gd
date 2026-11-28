class_name VehicleWeapon
extends Node3D
## One gun on a Vehicle (main gun, machine gun, AA cannon). Put it anywhere
## under the vehicle with its -Z axis pointing down the barrel, and give it a
## Muzzle child. It finds its own targets and fires on its own.
##
## Aiming:
##   turret - optional Node3D it swings left/right toward the target
##            (several weapons can share one turret; only set it on one)
##   barrel - optional Node3D it tilts up/down (rotation.x)
##   Without a turret the weapon only fires at targets inside fire_cone_deg
##   of where its muzzle points (e.g. a coax MG riding on the main turret).
##
## Rounds: hitscan with a tracer, or a Projectile scene (rocket / shell).

@export_group("Targets")
@export var targets_troops : bool = true
@export var targets_vehicles : bool = false
@export var targets_aircraft : bool = false
## Prefer vehicles over troops when both are in sight
@export var prefer_vehicles : bool = false
@export var max_range : float = 150.0
## Seconds between target scans
@export var scan_interval : float = 0.3
## Seconds from first seeing a target to opening fire
@export var reaction_time : float = 0.8

@export_group("Aiming")
@export var turret : Node3D
## Shares the turret with this weapon and lets it aim first (e.g. a coax MG
## yielding to the main gun): only swings the turret while that one is idle
@export var turret_yields_to : VehicleWeapon
@export var barrel : Node3D
@export var muzzle : Node3D
@export var turret_speed_deg : float = 60.0
@export var barrel_speed_deg : float = 40.0
@export var barrel_min_deg : float = -10.0
@export var barrel_max_deg : float = 25.0
## Fires once the barrel is within this angle of the target
@export var fire_cone_deg : float = 4.0

@export_group("Weapon")
@export var damage : float = 20.0
@export var damage_type : Damage.Type = Damage.Type.BULLET
@export var fire_rate : float = 6.0        ## rounds per second
## Seconds of firing, then burst_pause seconds of silence (0 = continuous)
@export var burst_time : float = 0.0
@export var burst_pause : float = 0.0
@export var spread_deg : float = 1.0
## Extra spread per 100 m to the target, so long shots mostly miss
@export var spread_per_100m_deg : float = 0.5
## Empty = hitscan with a tracer
@export var projectile_scene : PackedScene
@export var tracer_color : Color = Color(1.0, 0.8, 0.4)

var target : Node3D = null
## The vehicle this gun belongs to (found by walking up the tree)
var vehicle : Vehicle

var _scan_timer : float = 0.0
var _cooldown : float = 0.0
var _reaction_left : float = 0.0
var _burst_timer : float = 0.0
var _bursting : bool = true

func _ready() -> void:
	var n := get_parent()
	while n and not (n is Vehicle):
		n = n.get_parent()
	vehicle = n as Vehicle
	_scan_timer = randf() * scan_interval
	if muzzle == null:
		muzzle = self

func is_engaging() -> bool:
	return _is_valid_target(target)

func _physics_process(delta: float) -> void:
	_cooldown -= delta
	if vehicle == null or not vehicle.weapons_active():
		target = null
		return

	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = scan_interval
		var best := _find_target()
		if best != target:
			target = best
			_reaction_left = reaction_time
		elif target and not _can_see(target):
			target = null

	if not _is_valid_target(target):
		target = null
		return
	var aim := _aim_point(target)
	_slew_toward(aim, delta)
	if target is HeliBase:
		target.set_meta("aa_warning_until", Time.get_ticks_msec() + 1500)

	_reaction_left -= delta
	if burst_time > 0.0:
		_burst_timer -= delta
		if _burst_timer <= 0.0:
			_bursting = not _bursting
			_burst_timer = burst_time if _bursting else burst_pause * randf_range(0.8, 1.2)
	if _reaction_left > 0.0 or _cooldown > 0.0 or (burst_time > 0.0 and not _bursting):
		return
	var to_aim := (aim - muzzle.global_position).normalized()
	var forward := -muzzle.global_basis.z.normalized()
	if rad_to_deg(forward.angle_to(to_aim)) > fire_cone_deg:
		return
	_fire(aim)

# ---------------------------------------------------------------- targeting

## Untyped: the old target may already be freed
func _is_valid_target(t) -> bool:
	if not is_instance_valid(t) or not t.has_method("is_alive") or not t.is_alive():
		return false
	if t is Troop and t.state == Troop.States.PASSENGER:
		return false
	if t is Vehicle and t.is_carried():
		return false
	var their_team = t.get("team")
	if not (their_team is int) or their_team == 0 or their_team == vehicle.team:
		return false
	return muzzle.global_position.distance_to(t.global_position) <= max_range

func _find_target() -> Node3D:
	var groups: Array[String] = []
	if targets_troops: groups.append("Troops")
	if targets_vehicles: groups.append("Vehicles")
	if targets_aircraft: groups.append("Aircraft")
	var candidates: Array = []
	var from := muzzle.global_position
	for group in groups:
		for node in get_tree().get_nodes_in_group(group):
			if node == vehicle or not _is_valid_target(node):
				continue
			var d := from.distance_to(node.global_position)
			if prefer_vehicles and node is Vehicle:
				d *= 0.25
			if turret == null and not _in_cone(node.global_position, 60.0):
				continue   # fixed gun: only what's roughly in front of it
			candidates.append([d, node])
	candidates.sort_custom(func(a, b): return a[0] < b[0])
	for i in mini(candidates.size(), 4):
		if _can_see(candidates[i][1]):
			return candidates[i][1]
	return null

func _can_see(t: Node3D) -> bool:
	var query := PhysicsRayQueryParameters3D.create(muzzle.global_position, _aim_point(t))
	query.exclude = [vehicle.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return hit.is_empty() or hit.collider == t

func _aim_point(t: Node3D) -> Vector3:
	if t is Troop:
		return t.global_position + Vector3.UP * 0.2
	return t.eye_position()

func _in_cone(point: Vector3, cone_deg: float) -> bool:
	var forward := -muzzle.global_basis.z.normalized()
	return rad_to_deg(forward.angle_to((point - muzzle.global_position).normalized())) <= cone_deg

# ---------------------------------------------------------------- aiming / firing

func _slew_toward(point: Vector3, delta: float) -> void:
	var yielding := turret_yields_to != null and turret_yields_to.is_engaging()
	if turret and not yielding:
		var local: Vector3 = (turret.get_parent() as Node3D).to_local(point) - turret.position
		var want_yaw := atan2(-local.x, -local.z)
		turret.rotation.y = rotate_toward(turret.rotation.y, want_yaw, deg_to_rad(turret_speed_deg) * delta)
	if barrel:
		var local: Vector3 = (barrel.get_parent() as Node3D).to_local(point) - barrel.position
		var want_pitch := atan2(local.y, Vector2(local.x, local.z).length())
		want_pitch = clampf(want_pitch, deg_to_rad(barrel_min_deg), deg_to_rad(barrel_max_deg))
		barrel.rotation.x = move_toward(barrel.rotation.x, want_pitch, deg_to_rad(barrel_speed_deg) * delta)

func _fire(aim: Vector3) -> void:
	_cooldown = (1.0 / fire_rate) * randf_range(0.9, 1.1)
	var from := muzzle.global_position
	var dist := from.distance_to(aim)
	var spread := deg_to_rad(spread_deg + spread_per_100m_deg * dist / 100.0)
	# Fire down the barrel (not straight at the target), so turret lag shows
	var dir := _apply_spread(-muzzle.global_basis.z.normalized(), spread)

	if projectile_scene:
		Projectile.fire(projectile_scene, get_tree().current_scene, from, dir, vehicle, [vehicle.get_rid()])
		return

	var end := from + dir * max_range * 1.2
	var query := PhysicsRayQueryParameters3D.create(from, end)
	query.exclude = [vehicle.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var hit_pos := end
	if not hit.is_empty():
		hit_pos = hit.position
		Damage.apply(hit.collider, damage, vehicle, damage_type)
	Tracer.spawn(get_tree().current_scene, from, hit_pos, tracer_color)

func _apply_spread(dir: Vector3, angle: float) -> Vector3:
	var u := dir.cross(Vector3.UP)
	if u.length_squared() < 0.0001:
		u = dir.cross(Vector3.RIGHT)
	u = u.normalized()
	var v := dir.cross(u).normalized()
	var r := angle * sqrt(randf())
	var theta := randf() * TAU
	return (dir + (u * cos(theta) + v * sin(theta)) * tan(r)).normalized()
