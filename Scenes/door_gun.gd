class_name DoorGun
extends Node3D
## A pintle-mounted door gun. Put this node where the gun mounts, as a child
## of the helicopter, with its -Z axis pointing OUT of the door. On _ready it
## builds a two-part rig, muzzle and gunner camera:
##
##   DoorGun (mount) -> YawPivot [axle mesh] -> PitchPivot [minigun + barrels] -> Muzzle
##                   -> GunCamera (fixed to the mount, never swings)
##
## AI mode (default): picks the nearest visible enemy inside its arc and
##   hoses it with wide, inaccurate bursts. Suppressive, not surgical.
## Manual mode: GunnerController feeds it an aim point (from the mouse
##   crosshair) and the trigger state. The camera stays fixed to the mount;
##   only the gun pivots, light-gun style.

@export_group("Arc")
## Max swing left/right of straight out the door (degrees)
@export var yaw_limit_deg : float = 75.0
@export var pitch_min_deg : float = -70.0   ## down
@export var pitch_max_deg : float = 20.0    ## up
@export var ai_slew_speed_deg     : float = 90.0
@export var manual_slew_speed_deg : float = 400.0

@export_group("Weapon")
@export var fire_rate : float = 12.0        ## rounds per second
@export var damage    : float = 34.0        ## 3 hits kills a 100hp troop
@export var max_range : float = 200.0
@export var manual_spread_deg : float = 0.6
@export_range(-1, 1, 1) var team : int = Troop.TEAM_FRIENDLY

@export_group("AI gunner")
@export var ai_enabled : bool = true
@export var ai_spread_deg : float = 3.0       ## much worse than a human on the gun
@export var ai_burst_time : float = 1.2
@export var ai_pause_time : float = 0.9
@export var ai_scan_interval : float = 0.3
## Only fires once the barrel is roughly on target (degrees)
@export var ai_max_aim_error_deg : float = 6.0
## Holds fire if a friendly is this close (m) to the line of fire
@export var ai_friendly_clearance : float = 2.5

@export_group("Model")
## Scale applied to all three meshes (e.g. 0.015 if they import in cm like the Blackhawk)
@export var model_scale : float = 1.0
## Where the minigun hinges, relative to the axle's turning point (axle space)
@export var pitch_pivot_offset : Vector3 = Vector3(0.0, 0.25, 0.0)
## Barrel tip relative to the hinge (minigun space). Shots/tracers start here.
@export var muzzle_offset : Vector3 = Vector3(0.0, 0.0, -1.05)

@export_subgroup("Axle")
## Turns left/right. Leave empty for the placeholder post.
@export var axle_mesh : Mesh
## Nudge the mesh so the turning axis lines up (relative to the turning point)
@export var axle_mesh_offset : Vector3 = Vector3.ZERO
@export var axle_mesh_rotation_deg : Vector3 = Vector3.ZERO

@export_subgroup("Minigun")
## Tilts up/down on the hinge. Barrels should end up along -Z.
## Leave empty for the placeholder gun.
@export var minigun_mesh : Mesh
## Nudge the mesh so the hinge lines up (relative to the hinge)
@export var minigun_mesh_offset : Vector3 = Vector3.ZERO
@export var minigun_mesh_rotation_deg : Vector3 = Vector3.ZERO

@export_subgroup("Barrels")
## Optional separate barrel cluster that spins while firing. Its origin
## should be on the spin axis (the centre of the barrel cluster).
@export var barrels_mesh : Mesh
## Where the spin axis sits relative to the hinge
@export var barrels_mesh_offset : Vector3 = Vector3.ZERO
@export var barrels_mesh_rotation_deg : Vector3 = Vector3.ZERO
@export var barrel_spin_speed : float = 40.0   ## rad/s at full spin
@export var barrel_spin_down_time : float = 1.5 ## seconds to wind down after firing

@export_group("Gunner camera")
## Camera position in mount space (+Z = back into the cabin)
@export var camera_offset : Vector3 = Vector3(0.0, 0.6, 0.9)
@export var camera_pitch_deg : float = -14.0
@export var camera_fov : float = 70.0

var manual_control : bool = false
var manual_aim_point : Vector3
var trigger_held : bool = false
var target : Troop = null

var yaw_pivot   : Node3D   ## left/right: holds the axle
var pitch_pivot : Node3D   ## up/down: holds the minigun, child of yaw_pivot
var muzzle : Marker3D
var camera : Camera3D
var aircraft : CollisionObject3D   ## excluded from our raycasts

var _yaw := 0.0
var _pitch := 0.0
var _cooldown := 0.0
var _scan_timer := 0.0
var _burst_timer := 0.0
var _bursting := true
var _barrels : Node3D = null
var _spin : float = 0.0   ## 0..1 barrel spin-up

func _ready() -> void:
	aircraft = _find_aircraft()
	_build()
	_scan_timer = randf() * ai_scan_interval

func _physics_process(delta: float) -> void:
	_cooldown -= delta
	if aircraft and aircraft.has_method("is_alive") and not aircraft.is_alive():
		return   # shot down: guns are silent
	if manual_control:
		_slew_toward(manual_aim_point, manual_slew_speed_deg, delta)
		if trigger_held and _cooldown <= 0.0:
			_fire(manual_spread_deg)
	elif ai_enabled:
		_ai_tick(delta)
	yaw_pivot.rotation.y = _yaw
	pitch_pivot.rotation.x = _pitch

	if _barrels:
		_spin = maxf(_spin - delta / barrel_spin_down_time, 0.0)
		_barrels.rotate_object_local(Vector3.FORWARD, barrel_spin_speed * _spin * delta)

## Direction the barrel is actually pointing (world space)
func barrel_direction() -> Vector3:
	return -muzzle.global_basis.z.normalized()

# ---------------------------------------------------------------- AI

func _ai_tick(delta: float) -> void:
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = ai_scan_interval
		if not _is_valid_target(target):
			target = _find_target()

	if not _is_valid_target(target):
		target = null
		return

	var aim_point := target.global_position + Vector3.UP * 0.3
	var error_deg := _slew_toward(aim_point, ai_slew_speed_deg, delta)

	_burst_timer -= delta
	if _burst_timer <= 0.0:
		_bursting = not _bursting
		_burst_timer = ai_burst_time if _bursting else ai_pause_time * randf_range(0.7, 1.3)

	if _bursting and _cooldown <= 0.0 and error_deg <= ai_max_aim_error_deg \
			and not _friendly_near_line(muzzle.global_position, aim_point):
		_fire(ai_spread_deg)

## Untyped on purpose: the old target may already be freed, and a freed
## object can't be passed into a `Troop`-typed parameter
func _is_valid_target(t) -> bool:
	return is_instance_valid(t) and t is Troop and t.is_alive() and t.state != Troop.States.PASSENGER \
		and t.team != team and t.team != 0 \
		and muzzle.global_position.distance_to(t.global_position) <= max_range \
		and _in_arc(t.global_position)

func _find_target() -> Troop:
	var candidates: Array = []
	var from := muzzle.global_position
	for node in get_tree().get_nodes_in_group("Troops"):
		var t := node as Troop
		if t == null or not _is_valid_target(t):
			continue
		candidates.append([from.distance_squared_to(t.global_position), t])
	candidates.sort_custom(func(a, b): return a[0] < b[0])
	for i in mini(candidates.size(), 5):
		if _has_line_of_sight(candidates[i][1]):
			return candidates[i][1]
	return null

func _has_line_of_sight(t: Troop) -> bool:
	var hit := _raycast(muzzle.global_position, t.eye_position())
	return hit.is_empty() or hit.collider == t

func _friendly_near_line(from: Vector3, to: Vector3) -> bool:
	var seg := to - from
	var seg_len_sq := seg.length_squared()
	if seg_len_sq < 0.01:
		return false
	for node in get_tree().get_nodes_in_group("Troops"):
		var t := node as Troop
		if t == null or t.team != team or not t.is_alive() or t.state == Troop.States.PASSENGER:
			continue
		var p := t.global_position
		var along := (p - from).dot(seg) / seg_len_sq
		if along > 0.0 and along < 1.15 and p.distance_to(from + seg * clampf(along, 0.0, 1.0)) < ai_friendly_clearance:
			return true
	return false

# ---------------------------------------------------------------- aiming / firing

func _in_arc(world_point: Vector3) -> bool:
	var angles := _angles_to(world_point)
	return absf(angles.x) <= deg_to_rad(yaw_limit_deg) \
		and angles.y >= deg_to_rad(pitch_min_deg) and angles.y <= deg_to_rad(pitch_max_deg)

## (yaw, pitch) in radians needed to point the barrel at world_point
func _angles_to(world_point: Vector3) -> Vector2:
	# Measured from the hinge (axle position + hinge offset), close enough
	# for a hinge that sits roughly on the turning axis
	var local := to_local(world_point) - (yaw_pivot.position + pitch_pivot_offset)
	var yaw := atan2(-local.x, -local.z)
	var pitch := atan2(local.y, Vector2(local.x, local.z).length())
	return Vector2(yaw, pitch)

## Turns toward the point (clamped to the arc). Returns remaining error in degrees.
func _slew_toward(world_point: Vector3, speed_deg: float, delta: float) -> float:
	var want := _angles_to(world_point)
	var want_yaw   := clampf(want.x, -deg_to_rad(yaw_limit_deg), deg_to_rad(yaw_limit_deg))
	var want_pitch := clampf(want.y, deg_to_rad(pitch_min_deg), deg_to_rad(pitch_max_deg))
	var step := deg_to_rad(speed_deg) * delta
	_yaw   = move_toward(_yaw, want_yaw, step)
	_pitch = move_toward(_pitch, want_pitch, step)
	return rad_to_deg(absf(want_yaw - _yaw) + absf(want_pitch - _pitch))

func _fire(spread_deg: float) -> void:
	_cooldown = 1.0 / fire_rate
	_spin = 1.0
	var from := muzzle.global_position
	var dir := _apply_spread(barrel_direction(), deg_to_rad(spread_deg))
	var end := from + dir * max_range
	var hit := _raycast(from, end)
	var hit_pos := end
	if not hit.is_empty():
		hit_pos = hit.position
		if hit.collider is Troop or hit.collider is Vehicle:
			# Credit the aircraft, so whoever survives knows to shoot back at it.
			# Vehicles shrug most of it off (their bullet armour).
			Damage.apply(hit.collider, damage, aircraft if aircraft else self, Damage.Type.BULLET)
	Tracer.spawn(get_tree().current_scene, from, hit_pos, Color(1.0, 0.85, 0.3))

func _raycast(from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to)
	if aircraft:
		query.exclude = [aircraft.get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(query)

func _apply_spread(dir: Vector3, angle: float) -> Vector3:
	var u := dir.cross(Vector3.UP)
	if u.length_squared() < 0.0001:
		u = dir.cross(Vector3.RIGHT)
	u = u.normalized()
	var v := dir.cross(u).normalized()
	var r := angle * sqrt(randf())
	var theta := randf() * TAU
	return (dir + (u * cos(theta) + v * sin(theta)) * tan(r)).normalized()

# ---------------------------------------------------------------- setup

func _find_aircraft() -> CollisionObject3D:
	var n := get_parent()
	while n:
		if n is CollisionObject3D:
			return n
		n = n.get_parent()
	return null

## Builds the rig. Uses the mesh slots if set, otherwise placeholder meshes.
func _build() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.15, 0.15, 0.15)

	# --- Yaw: axle
	yaw_pivot = Node3D.new()
	yaw_pivot.name = "YawPivot"
	add_child(yaw_pivot)
	if axle_mesh:
		_add_mesh(axle_mesh, yaw_pivot, axle_mesh_offset, axle_mesh_rotation_deg, "AxleMesh")
	else:
		# Placeholder: short post from the mount up to the hinge
		var post := MeshInstance3D.new()
		var post_mesh := CylinderMesh.new()
		post_mesh.top_radius = 0.03
		post_mesh.bottom_radius = 0.04
		post_mesh.height = maxf(pitch_pivot_offset.y, 0.05)
		post.mesh = post_mesh
		post.material_override = mat
		post.position = Vector3(0.0, post_mesh.height * 0.5, 0.0)
		yaw_pivot.add_child(post)

	# --- Pitch: minigun (+ optional spinning barrels)
	pitch_pivot = Node3D.new()
	pitch_pivot.name = "PitchPivot"
	pitch_pivot.position = pitch_pivot_offset
	yaw_pivot.add_child(pitch_pivot)
	if barrels_mesh:
		_barrels = _add_mesh(barrels_mesh, pitch_pivot, barrels_mesh_offset, barrels_mesh_rotation_deg, "BarrelsMesh")
	if minigun_mesh:
		_add_mesh(minigun_mesh, pitch_pivot, minigun_mesh_offset, minigun_mesh_rotation_deg, "MinigunMesh")
	else:
		var body := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.12, 0.14, 0.35)
		body.mesh = box
		body.material_override = mat
		body.position = Vector3(0.0, 0.0, 0.05)
		pitch_pivot.add_child(body)

		var barrel := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.035
		cyl.bottom_radius = 0.05
		cyl.height = 0.9
		barrel.mesh = cyl
		barrel.material_override = mat
		barrel.rotation_degrees = Vector3(90.0, 0.0, 0.0)   # cylinder's Y axis -> along Z
		barrel.position = Vector3(0.0, 0.0, -0.6)
		pitch_pivot.add_child(barrel)

	muzzle = Marker3D.new()
	muzzle.name = "Muzzle"
	muzzle.position = muzzle_offset
	pitch_pivot.add_child(muzzle)

	# --- Camera: child of the mount, NOT the pivots, so it never swings with the gun
	camera = Camera3D.new()
	camera.name = "GunCamera"
	camera.position = camera_offset
	camera.rotation_degrees = Vector3(camera_pitch_deg, 0.0, 0.0)
	camera.fov = camera_fov
	add_child(camera)

## Adds a MeshInstance3D for `mesh` under `parent`, offset/rotated/scaled.
## Materials come from the mesh itself (as imported).
func _add_mesh(mesh: Mesh, parent: Node3D, offset: Vector3, rotation_deg: Vector3, node_name: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.position = offset
	mi.rotation_degrees = rotation_deg
	mi.scale = Vector3.ONE * model_scale
	parent.add_child(mi)
	return mi
