class_name Explosion
extends Node3D
## Short-lived blast effect. The look is the nodes in Explosion.tscn
## (a glowing sphere and a light); this just grows and fades it, then frees it.
## Spawn with Explosion.spawn(scene, parent, position, size).

@export var lifetime : float = 0.45
## Sphere grows from this fraction of `size` to full size
@export var start_scale : float = 0.3
@export var light : OmniLight3D
@export var mesh : MeshInstance3D

var size : float = 1.0
var _age : float = 0.0
var _mat : StandardMaterial3D
var _light_energy : float = 1.0

static func spawn(scene: PackedScene, parent: Node, pos: Vector3, blast_size: float = 1.0) -> void:
	if scene == null or parent == null:
		return
	var e := scene.instantiate() as Explosion
	e.size = blast_size
	parent.add_child(e)
	e.global_position = pos

func _ready() -> void:
	if mesh and mesh.get_surface_override_material(0):
		_mat = mesh.get_surface_override_material(0).duplicate()
		mesh.set_surface_override_material(0, _mat)
	if light:
		_light_energy = light.light_energy
		light.omni_range *= size
	scale = Vector3.ONE * size * start_scale

func _process(delta: float) -> void:
	_age += delta
	var t := clampf(_age / lifetime, 0.0, 1.0)
	scale = Vector3.ONE * size * lerpf(start_scale, 1.0, sqrt(t))
	if _mat:
		_mat.albedo_color.a = 1.0 - t
	if light:
		light.light_energy = _light_energy * (1.0 - t)
	if t >= 1.0:
		queue_free()
