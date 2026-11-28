class_name Projectile
extends Node3D
## A visible, travelling round: AT rocket or tank shell. The look is the nodes
## in its scene (Rocket.tscn / Shell.tscn); this flies it in a straight line,
## ray-tests each step, and on impact deals its damage plus optional splash.
##
## Fire one with:  Projectile.fire(scene, parent, from, dir, source, exclude)

@export var speed : float = 90.0
@export var damage : float = 100.0
@export var damage_type : Damage.Type = Damage.Type.AT
## Blast that hurts everything nearby (troops mostly); 0 = none
@export var splash_radius : float = 4.0
@export var splash_damage : float = 60.0
## Seconds before it's removed if it hits nothing
@export var max_lifetime : float = 4.0
## Blast effect on impact (scales with splash_radius)
@export var explosion_scene : PackedScene = preload("res://Scenes/Vehicles/Explosion.tscn")
@export var explosion_size : float = 1.5

## Who fired it (gets the credit; same-team hits are ignored)
var source : Node = null
var exclude : Array[RID] = []
var _velocity : Vector3
var _age : float = 0.0

static func fire(scene: PackedScene, parent: Node, from: Vector3, dir: Vector3, shooter: Node, ignore: Array[RID] = []) -> Projectile:
	if scene == null or parent == null:
		return null
	var p := scene.instantiate() as Projectile
	p.source = shooter
	p.exclude = ignore
	parent.add_child(p)
	p.global_position = from
	p._velocity = dir.normalized() * p.speed
	var up := Vector3.UP if absf(dir.normalized().dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	p.look_at(from + dir, up)
	return p

func _physics_process(delta: float) -> void:
	_age += delta
	if _age >= max_lifetime:
		queue_free()
		return
	var from := global_position
	var to := from + _velocity * delta
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = exclude
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		global_position = to
		return
	_impact(hit.position, hit.collider)

func _impact(pos: Vector3, collider: Object) -> void:
	var shooter := source if is_instance_valid(source) else null
	if collider:
		Damage.apply(collider, damage, shooter, damage_type)
	if splash_radius > 0.0 and splash_damage > 0.0:
		for group in ["Troops", "Vehicles"]:
			for node in get_tree().get_nodes_in_group(group):
				if node == collider or not is_instance_valid(node) or not node.has_method("is_alive") or not node.is_alive():
					continue
				var d: float = (node as Node3D).global_position.distance_to(pos)
				if d < splash_radius:
					var falloff := 1.0 - d / splash_radius
					Damage.apply(node, splash_damage * falloff, shooter, Damage.Type.BULLET if group == "Vehicles" else damage_type)
	Explosion.spawn(explosion_scene, get_tree().current_scene, pos, explosion_size)
	queue_free()
