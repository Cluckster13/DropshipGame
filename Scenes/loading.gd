extends CanvasLayer
## Loading screen. Registered as the "Loading" autoload.
##
##   Loading.change_scene("res://Levels/Valley.tscn")
##       Loads the scene on a background thread with a progress bar, switches
##       to it, then keeps the screen up (game paused) until the level is
##       ready: right now that means the NavPatchBaker's startup bake.
##   Loading.reload()
##       Restart the current level the same way.
##
## A level started directly (F6 in the editor) is covered too: if it has a
## NavPatchBaker that hasn't finished its first bake, the screen comes up and
## the game stays paused until it has.

signal finished

## Share of the bar used by loading the scene file (the rest is navigation)
@export_range(0.0, 1.0, 0.05) var file_load_share : float = 0.6
## Frames to wait after navigation is baked so the navigation map syncs
@export var settle_frames : int = 3
@export var fade_time : float = 0.4
@export var title_text : String = "DROPSHIP"

var is_loading : bool = false

enum Phase {IDLE, FILE, LEVEL}
var _phase : Phase = Phase.IDLE
var _path : String = ""
var _base : float = 0.0           # bar value when the level phase started
var _shown : float = 0.0          # displayed (smoothed) progress
var _target : float = 0.0
var _settle_left : int = 0
var _baker : NavPatchBaker
var _dots_time : float = 0.0

var _root : Control
var _status : Label
var _bar : ProgressBar
var _detail : Label

func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_root.visible = false
	_check_current_scene.call_deferred()

# ---------------------------------------------------------------- public

func change_scene(path: String) -> void:
	if is_loading:
		return
	_path = path
	_open(0.0)
	_set_status("Loading map", "")
	var err := ResourceLoader.load_threaded_request(path, "", true)
	if err != OK:
		push_error("Loading: can't load %s (error %d)" % [path, err])
		_close()
		return
	_phase = Phase.FILE

func reload() -> void:
	var scene := get_tree().current_scene
	if scene and scene.scene_file_path != "":
		change_scene(scene.scene_file_path)
	else:
		get_tree().reload_current_scene()

# ---------------------------------------------------------------- flow

func _process(delta: float) -> void:
	if not is_loading:
		return
	_dots_time += delta
	match _phase:
		Phase.FILE:
			_tick_file()
		Phase.LEVEL:
			_tick_level()
	_shown = move_toward(_shown, _target, delta * 1.5)
	_shown = lerpf(_shown, _target, minf(delta * 6.0, 1.0))
	_bar.value = _shown * 100.0
	_status.text = _status.get_meta("base", "") + ".".repeat(int(_dots_time * 3.0) % 4)

func _tick_file() -> void:
	var progress := []
	var status := ResourceLoader.load_threaded_get_status(_path, progress)
	match status:
		ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			_target = progress[0] * file_load_share
		ResourceLoader.THREAD_LOAD_LOADED:
			_phase = Phase.IDLE
			_target = file_load_share
			_switch_to(ResourceLoader.load_threaded_get(_path))
		_:
			push_error("Loading: failed to load %s" % _path)
			_close()

func _switch_to(packed: PackedScene) -> void:
	_set_status("Building world", "")
	# Let the screen draw before instancing (which can block for a while)
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().paused = true
	get_tree().change_scene_to_packed(packed)
	await get_tree().process_frame
	await get_tree().process_frame
	_begin_level(file_load_share)

## Startup: a level run directly still needs its navigation before play
func _check_current_scene() -> void:
	var baker := get_tree().get_first_node_in_group("NavPatchBaker") as NavPatchBaker
	if baker and not baker.initial_ready and not is_loading:
		_open(0.0)
		_begin_level(0.0)

func _begin_level(base: float) -> void:
	get_tree().paused = true
	_base = base
	_target = base
	_baker = get_tree().get_first_node_in_group("NavPatchBaker") as NavPatchBaker
	_settle_left = settle_frames
	_phase = Phase.LEVEL

func _tick_level() -> void:
	if is_instance_valid(_baker) and not _baker.initial_ready:
		var p := _baker.initial_progress()
		_target = _base + (1.0 - _base) * p
		_set_status("Baking navigation", "%d%%  ·  %d tiles ready" % [roundi(p * 100.0), _baker.baked_tile_count()])
		return
	_target = 1.0
	_set_status("Ready", "")
	# Give the navigation server a few frames to merge the new tiles
	_settle_left -= 1
	if _settle_left > 0:
		return
	_phase = Phase.IDLE
	get_tree().paused = false
	_close()

# ---------------------------------------------------------------- show / hide

func _open(start: float) -> void:
	is_loading = true
	_shown = start
	_target = start
	_bar.value = start * 100.0
	_root.modulate.a = 1.0
	_root.visible = true

func _close() -> void:
	_phase = Phase.IDLE
	var tween := create_tween()
	tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tween.tween_property(_root, "modulate:a", 0.0, fade_time)
	await tween.finished
	_root.visible = false
	is_loading = false
	finished.emit()

func _set_status(text: String, detail: String) -> void:
	_status.set_meta("base", text)
	_detail.text = detail

# ---------------------------------------------------------------- UI

func _build_ui() -> void:
	_root = Control.new()
	_root.name = "LoadingScreen"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP   # swallow clicks while loading
	add_child(_root)

	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.06)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.custom_minimum_size = Vector2(440, 0)
	center.add_child(box)

	var title := _label(title_text, 54, Color(0.85, 1.0, 0.85))
	box.add_child(title)

	_status = _label("", 20, Color(0.85, 1.0, 0.85))
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	box.add_child(_status)

	_bar = ProgressBar.new()
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(440, 8)
	var track := StyleBoxFlat.new()
	track.bg_color = Color(1, 1, 1, 0.1)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.55, 0.85, 0.55)
	_bar.add_theme_stylebox_override("background", track)
	_bar.add_theme_stylebox_override("fill", fill)
	box.add_child(_bar)

	_detail = _label("", 15, Color(0.55, 0.7, 0.55))
	_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	box.add_child(_detail)

func _label(text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l
