class_name GunnerController
extends Node
## Lets the pilot jump on a door gun without letting go of the stick.
##
##   GunnerToggle (G)   — man / leave the guns
##   GunnerSwitch (Tab) — swap to the other door
##   GunFire (LMB)      — fire
##
## While manning a gun the view switches to that gun's fixed camera and a
## crosshair follows the mouse (light-gun / on-rails style): the camera never
## moves, the gun pivots to whatever is under the crosshair. Keyboard flight
## controls keep working because HeliBase reads them independently.
## Guns you're not on stay under AI control.

@export var guns : Array[DoorGun] = []
## Camera to go back to when you leave the guns
@export var orbit_camera : Camera3D
@export var crosshair_color : Color = Color(1.0, 1.0, 1.0, 0.9)
## Small marker showing where the barrel actually points (lags when slewing,
## stops at the arc limit)
@export var barrel_marker_color : Color = Color(1.0, 0.6, 0.2, 0.9)

var active_index : int = -1   ## -1 = flying from the orbit camera

var _layer : CanvasLayer
var _crosshair : Control
var _barrel_screen_pos : Vector2
var _barrel_on_screen : bool = false

func _ready() -> void:
	_layer = CanvasLayer.new()
	_layer.visible = false
	add_child(_layer)
	_crosshair = Control.new()
	_crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_crosshair.draw.connect(_draw_crosshair)
	_layer.add_child(_crosshair)

func is_manning() -> bool:
	return active_index >= 0

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("GunnerToggle"):
		if is_manning():
			_leave_gun()
		elif not guns.is_empty():
			_man_gun(0)
	elif event.is_action_pressed("GunnerSwitch") and is_manning() and guns.size() > 1:
		_man_gun((active_index + 1) % guns.size())

func _physics_process(_delta: float) -> void:
	if not is_manning():
		return
	var gun := guns[active_index]
	var cam := gun.camera
	var mouse := get_viewport().get_mouse_position()

	# Whatever is under the crosshair is the aim point; sky = far point on the ray
	var origin := cam.project_ray_origin(mouse)
	var dir := cam.project_ray_normal(mouse)
	var hit := gun._raycast(origin, origin + dir * gun.max_range)
	gun.manual_aim_point = hit.position if not hit.is_empty() else origin + dir * gun.max_range
	gun.trigger_held = Input.is_action_pressed("GunFire")

	var barrel_point := gun.muzzle.global_position + gun.barrel_direction() * 50.0
	_barrel_on_screen = not cam.is_position_behind(barrel_point)
	if _barrel_on_screen:
		_barrel_screen_pos = cam.unproject_position(barrel_point)
	_crosshair.queue_redraw()

func _man_gun(index: int) -> void:
	if is_manning():
		_release(guns[active_index])
	active_index = index
	var gun := guns[index]
	gun.manual_control = true
	gun.camera.make_current()
	_set_orbit_input(false)   # stop orbit-camera freelook grabbing the mouse
	Input.mouse_mode = Input.MOUSE_MODE_CONFINED_HIDDEN
	get_viewport().warp_mouse(get_viewport().get_visible_rect().size * 0.5)
	_layer.visible = true

func _leave_gun() -> void:
	if not is_manning():
		return
	_release(guns[active_index])
	active_index = -1
	if orbit_camera:
		orbit_camera.make_current()
	_set_orbit_input(true)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_layer.visible = false

func _set_orbit_input(enabled: bool) -> void:
	if orbit_camera and "input_enabled" in orbit_camera:
		orbit_camera.input_enabled = enabled

func _release(gun: DoorGun) -> void:
	gun.manual_control = false
	gun.trigger_held = false

func _draw_crosshair() -> void:
	var c := get_viewport().get_mouse_position()
	var gap := 6.0
	var arm := 14.0
	_crosshair.draw_arc(c, 18.0, 0.0, TAU, 32, crosshair_color, 1.5)
	_crosshair.draw_line(c + Vector2(-gap - arm, 0), c + Vector2(-gap, 0), crosshair_color, 2.0)
	_crosshair.draw_line(c + Vector2(gap, 0), c + Vector2(gap + arm, 0), crosshair_color, 2.0)
	_crosshair.draw_line(c + Vector2(0, -gap - arm), c + Vector2(0, -gap), crosshair_color, 2.0)
	_crosshair.draw_line(c + Vector2(0, gap), c + Vector2(0, gap + arm), crosshair_color, 2.0)
	if _barrel_on_screen:
		_crosshair.draw_circle(_barrel_screen_pos, 3.0, barrel_marker_color)
