class_name Objective
extends StaticBody3D

signal captured(team: int)   # 1 = friendly, -1 = enemy

const CAPTURE_MAX : float = 100.0

@export var capture_rate : float = 1.0   # progress per tick (0.1s) -> 10s to capture

var capture_progress : float = 0.0
var owner_team : int = 0
var friendlies_in_zone : Array[FriendlyTroop] = []

@onready var capture_tick : Timer = $CaptureTick
@onready var flag : MeshInstance3D = $Flag

func _ready() -> void:
	add_to_group("Objectives")  # needed for FriendlyTroop to find it
	capture_tick.wait_time = 0.1
	capture_tick.one_shot = false
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.WHITE
	flag.set_surface_override_material(0, mat)

func _on_capture_area_body_entered(body: Node3D) -> void:
	if body is FriendlyTroop and body not in friendlies_in_zone:
		friendlies_in_zone.append(body)
		if capture_tick.is_stopped():
			capture_tick.start()

func _on_capture_area_body_exited(body: Node3D) -> void:
	if body is FriendlyTroop:
		friendlies_in_zone.erase(body)
		if friendlies_in_zone.is_empty():
			capture_tick.stop()

func _on_capture_tick_timeout() -> void:
	if friendlies_in_zone.size() >= 1:  # later: compare against enemy count
		capture_progress = minf(capture_progress + capture_rate, CAPTURE_MAX)
	if capture_progress >= CAPTURE_MAX and owner_team != 1:
		_captured(1)

func _captured(team: int) -> void:
	owner_team = team
	var mat := flag.get_surface_override_material(0) as StandardMaterial3D
	mat.albedo_color = Color(0, 0, 1) if team == 1 else Color(1, 0, 0)
	captured.emit(team)
	capture_tick.stop()
