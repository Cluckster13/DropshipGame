class_name ObjectiveMarker
extends Sprite3D
## Floating badge over an objective, readable from the cockpit:
##   - a disc with the objective's letter, coloured by who owns it
##   - a ring around it that fills with capture progress (blue/red)
##   - the status underneath (CAPTURING 45%, CONTESTED, SECURED...)
## Always faces the camera, stays the same size on screen at any distance and
## draws through terrain/trees. Put it on a Sprite3D child of an Objective;
## the node's height above the objective is where the badge floats.

## Defaults to the parent
@export var objective : Objective

@export_group("Size")
## On-screen size of everything. Bigger = larger badge.
@export var badge_pixel_size : float = 0.0011
@export var texture_size : int = 128
@export var ring_width : int = 12
@export var letter_font_size : int = 72
@export var status_font_size : int = 34
## Hide when the camera is closer than this (m). 0 = always show.
@export var hide_within : float = 0.0

@export_group("Colours")
@export var friendly_color : Color = Color(0.3, 0.55, 1.0)
@export var enemy_color    : Color = Color(1.0, 0.3, 0.25)
@export var neutral_color  : Color = Color(0.9, 0.9, 0.9)
@export var contested_color : Color = Color(1.0, 0.75, 0.25)
@export var backdrop_color : Color = Color(0.0, 0.0, 0.0, 0.55)
@export var track_color    : Color = Color(1.0, 1.0, 1.0, 0.18)

const REFRESH_INTERVAL := 0.1

var _letter : Label3D
var _status : Label3D
var _image : Image
var _tex : ImageTexture
var _pixels : PackedByteArray
# Per-pixel geometry, worked out once: 0 outside, 1 = backdrop, 2 = ring.
# Coverage is for soft (anti-aliased) edges, angle is 0..1 clockwise from top.
var _zone : PackedByteArray
var _coverage : PackedFloat32Array
var _angle : PackedFloat32Array
var _last_ring_key := ""
var _timer : float = 0.0

func _ready() -> void:
	if objective == null:
		objective = get_parent() as Objective
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	fixed_size = true
	no_depth_test = true
	shaded = false
	double_sided = true
	pixel_size = badge_pixel_size
	texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	render_priority = 1

	_build_geometry()
	_image = Image.create_empty(texture_size, texture_size, false, Image.FORMAT_RGBA8)
	_tex = ImageTexture.create_from_image(_image)
	texture = _tex

	_letter = _make_label(letter_font_size, 4)
	_status = _make_label(status_font_size, 4)
	# Label offsets are in the same pixel units as the texture, so the status
	# line sits just under the disc at every distance
	_status.offset = Vector2(0, -(texture_size * 0.5 + status_font_size * 0.75))
	_refresh()

func _process(delta: float) -> void:
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = REFRESH_INTERVAL
	_refresh()

func _refresh() -> void:
	if not is_instance_valid(objective):
		visible = false
		return
	if hide_within > 0.0:
		var cam := get_viewport().get_camera_3d()
		visible = cam == null or cam.global_position.distance_to(objective.global_position) > hide_within
		if not visible:
			return

	var progress := objective.capture_progress / Objective.CAPTURE_MAX   # -1..1
	var info: Dictionary = objective.status()
	var blink := int(Time.get_ticks_msec() / 400.0) % 2 == 0

	# Letter: owner colour
	_letter.text = objective.get_label()
	_letter.modulate = _team_color(objective.owner_team)

	# Status line
	var text: String = info["text"]
	if info["active"]:
		text += "  %d%%" % roundi(absf(progress) * 100.0)
	_status.text = text
	if info["contested"]:
		_status.modulate = contested_color if blink else contested_color.darkened(0.5)
	else:
		_status.modulate = _team_color(info["team"])

	# Ring: only redraw when it visibly changes
	var ring_col := friendly_color if progress > 0.0 else enemy_color
	var key := "%d_%d" % [roundi(absf(progress) * 200.0), signi(int(progress * 1000.0))]
	if key != _last_ring_key:
		_last_ring_key = key
		_draw_badge(absf(progress), ring_col)

func _team_color(team: int) -> Color:
	if team == Troop.TEAM_FRIENDLY:
		return friendly_color
	if team == Troop.TEAM_ENEMY:
		return enemy_color
	return neutral_color

# ---------------------------------------------------------------- drawing

func _build_geometry() -> void:
	var n := texture_size * texture_size
	_zone.resize(n)
	_coverage.resize(n)
	_angle.resize(n)
	_pixels.resize(n * 4)
	var c := (texture_size - 1) * 0.5
	var outer := texture_size * 0.5 - 1.0
	var inner := outer - ring_width
	for y in texture_size:
		for x in texture_size:
			var i := y * texture_size + x
			var dx := x - c
			var dy := y - c
			var r := sqrt(dx * dx + dy * dy)
			_coverage[i] = clampf(outer - r + 0.5, 0.0, 1.0)
			_zone[i] = 0 if r > outer + 0.5 else (2 if r > inner else 1)
			_angle[i] = fposmod(atan2(dx, -dy), TAU) / TAU

func _draw_badge(fill: float, fill_color: Color) -> void:
	for i in _zone.size():
		var p := i * 4
		var col := Color(0, 0, 0, 0)
		match _zone[i]:
			1:
				col = backdrop_color
			2:
				col = fill_color if _angle[i] <= fill else track_color
		col.a *= _coverage[i]
		_pixels[p] = int(col.r * 255.0)
		_pixels[p + 1] = int(col.g * 255.0)
		_pixels[p + 2] = int(col.b * 255.0)
		_pixels[p + 3] = int(col.a * 255.0)
	_image.set_data(texture_size, texture_size, false, Image.FORMAT_RGBA8, _pixels)
	_tex.update(_image)

func _make_label(size: int, outline: int) -> Label3D:
	var l := Label3D.new()
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.fixed_size = true
	l.no_depth_test = true
	l.shaded = false
	l.double_sided = true
	l.pixel_size = badge_pixel_size
	l.font_size = size
	l.outline_size = outline * 3
	l.outline_modulate = Color(0, 0, 0, 0.85)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# Draw after the badge so text sits on top of it
	l.render_priority = 3
	l.outline_render_priority = 2
	add_child(l)
	return l
