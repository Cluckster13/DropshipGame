class_name SlingHook
extends Node3D
## Cargo hook under the helicopter. Put it as a child of the HeliBase where
## the hook hangs (under the belly), with a Rope MeshInstance3D child.
##
## Sling (H): hover low over a friendly sling load (an AA emplacement) and
## press to hook it; press again to release it. The load hangs on a rope as
## a swinging point mass, and its weight pulls the aircraft down and around,
## so you need extra collective to lift it and it swings in turns.
## Set it down gently: a hard drop damages it.

@export var aircraft : HeliBase
@export var action : StringName = &"Sling"
## Rope length (m), hook to load
@export var rope_length : float = 12.0
## The load must be this close sideways (m) to hook it...
@export var pickup_radius : float = 9.0
## ...and the hook no more than this far above it
@export var pickup_max_height : float = 20.0
## ...and the aircraft slower than this (m/s)
@export var pickup_max_speed : float = 6.0
## Air drag on the swinging load (per second)
@export var load_damping : float = 0.25
## Ground friction while the load drags along the ground (per second)
@export var ground_friction : float = 6.0
## Visual rope: a box/cylinder mesh 1 m long along -Z, stretched each frame
@export var rope : MeshInstance3D

## What's on the hook (null = nothing)
var cargo : Vehicle = null
var _pos : Vector3
var _vel : Vector3
var _tension : float = 0.0

func _ready() -> void:
	if aircraft == null:
		aircraft = get_parent() as HeliBase
	if rope:
		rope.top_level = true
		rope.visible = false
	if aircraft:
		aircraft.destroyed.connect(release)

func is_carrying() -> bool:
	return is_instance_valid(cargo)

## A load we could hook right now, or null
func hookable_load() -> Vehicle:
	if aircraft == null or aircraft.is_destroyed or aircraft.linear_velocity.length() > pickup_max_speed:
		return null
	var best : Vehicle = null
	var best_d := pickup_radius
	for node in get_tree().get_nodes_in_group("SlingLoads"):
		var v := node as Vehicle
		if v == null or not v.is_alive() or v.is_carried() or v.team != aircraft.team:
			continue
		var p := v.sling_point_position()
		var flat := Vector2(p.x - global_position.x, p.z - global_position.z).length()
		var above := global_position.y - p.y
		if flat <= best_d and above > 0.5 and above <= pickup_max_height:
			best_d = flat
			best = v
	return best

## Text for the HUD: what H does right now ("" = nothing to show)
func status_text() -> String:
	if is_carrying():
		return "SLING  %s   ·   H  release" % cargo.display_name
	var v := hookable_load()
	if v:
		return "H  hook %s" % v.display_name
	return ""

func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(action) or event.is_echo():
		return
	if is_carrying():
		release()
	else:
		var v := hookable_load()
		if v:
			hook(v)

func hook(v: Vehicle) -> void:
	cargo = v
	v.set_carried(true)
	_pos = v.sling_point_position()
	_vel = Vector3.ZERO
	_tension = 0.0
	if rope:
		rope.visible = true
	print("[Sling] hooked %s" % v.name)

func release() -> void:
	if aircraft:
		aircraft.external_force = Vector3.ZERO
	if rope:
		rope.visible = false
	if not is_instance_valid(cargo):
		cargo = null
		return
	print("[Sling] released %s" % cargo.name)
	cargo.set_carried(false, _vel)
	cargo = null

func _physics_process(delta: float) -> void:
	if not is_carrying():
		return
	if not cargo.is_alive() or aircraft == null or aircraft.is_destroyed:
		release()
		return

	var mass := aircraft.mass * cargo.sling_weight_fraction
	var g := ProjectSettings.get_setting("physics/3d/default_gravity", 9.8) as float
	var hook_pos := global_position
	var hook_vel := aircraft.linear_velocity

	# Free flight of the load: gravity and a little air drag
	_vel += Vector3.DOWN * g * delta
	_vel *= maxf(1.0 - load_damping * delta, 0.0)
	_pos += _vel * delta

	# Rope: can't get further than rope_length from the hook. Whatever
	# outward speed it had is taken out, and that's the rope tension.
	var tension := 0.0
	var n := Vector3.DOWN
	var d := _pos - hook_pos
	var dist := d.length()
	if dist > rope_length and dist > 0.001:
		n = d / dist
		_pos = hook_pos + n * rope_length
		var outward := (_vel - hook_vel).dot(n)
		if outward > 0.0:
			_vel -= n * outward
			tension = mass * outward / delta

	# Ground: the load sits on it instead of sinking in (no tension then)
	var ground := _ground_height(_pos)
	var bottom_offset := cargo.sling_point_position().y - cargo.global_position.y
	if _pos.y - bottom_offset < ground:
		_pos.y = ground + bottom_offset
		if _vel.y < 0.0:
			_vel.y = 0.0
		var k := maxf(1.0 - ground_friction * delta, 0.0)
		_vel.x *= k
		_vel.z *= k

	# Smooth the pull a touch so the aircraft doesn't buzz
	_tension = lerpf(_tension, minf(tension, mass * g * 3.0), clampf(delta * 20.0, 0.0, 1.0))
	aircraft.external_force = n * _tension

	cargo.global_position = cargo.carried_origin_for(_pos)
	_update_rope(hook_pos, _pos)

func _ground_height(p: Vector3) -> float:
	var query := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 5.0, p + Vector3.DOWN * 50.0)
	query.exclude = [aircraft.get_rid(), cargo.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return hit.position.y if not hit.is_empty() else -INF

func _update_rope(from: Vector3, to: Vector3) -> void:
	if rope == null:
		return
	var length := from.distance_to(to)
	if length < 0.05:
		return
	var dir := (to - from) / length
	var up := Vector3.FORWARD if absf(dir.dot(Vector3.UP)) > 0.99 else Vector3.UP
	rope.global_transform = Transform3D(Basis.looking_at(dir, up) * Basis.from_scale(Vector3(1.0, 1.0, length)), (from + to) * 0.5)
