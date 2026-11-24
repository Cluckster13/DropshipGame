class_name Tracer
extends MeshInstance3D
## A brief visible streak (tracer) for a hitscan shot, so you can read a firefight.
## Usage: Tracer.spawn(get_tree().current_scene, muzzle, hit_point, color)

const LIFETIME := 0.06

static var _mesh : BoxMesh
static var _materials : Dictionary = {}   # Color -> StandardMaterial3D, shared

static func spawn(parent: Node, from: Vector3, to: Vector3, color: Color) -> void:
	var length := from.distance_to(to)
	if parent == null or length < 0.05:
		return
	if _mesh == null:
		_mesh = BoxMesh.new()
		_mesh.size = Vector3(0.03, 0.03, 1.0)

	var t := Tracer.new()
	t.mesh = _mesh
	t.material_override = _material_for(color)
	t.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(t)

	var dir := (to - from) / length
	var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	t.global_position = (from + to) * 0.5
	t.look_at(to, up)
	t.scale = Vector3(1.0, 1.0, length)
	parent.get_tree().create_timer(LIFETIME).timeout.connect(t.queue_free)

static func _material_for(color: Color) -> StandardMaterial3D:
	if not _materials.has(color):
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = color
		_materials[color] = m
	return _materials[color]
