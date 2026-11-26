class_name Objective
extends StaticBody3D
## Capture point (contestable). Progress runs from -100 (enemy) to +100 (friendly).
## An owned point must be drained to 0 (neutral) before it can flip.
## Both teams inside = contested, nobody gains. Empty = drifts back
## toward whoever owns it.

signal captured(team: int)      ## 1 = friendly, -1 = enemy
signal neutralized(previous_team: int)

const CAPTURE_MAX : float = 100.0
const TICK_TIME   : float = 0.1

@export var capture_rate   : float = 0.1   ## progress per tick per troop -> 10s solo capture
@export var max_capture_multiplier : int = 3   ## extra troops speed it up, capped here
@export var decay_rate     : float = 0.5   ## drift per tick back toward the owner when empty
## Who holds this point when the level starts (1 friendly, 0 neutral, -1 enemy)
@export_range(-1, 1, 1) var initial_owner : int = 0
## Name shown on the HUD. Empty = node name minus "Objective_" (e.g. "A")
@export var display_name : String = ""

var capture_progress : float = 0.0
var owner_team : int = 0
var occupants : Array[Troop] = []

@onready var capture_tick : Timer = $CaptureTick
@onready var flag : MeshInstance3D = $Flag

var _flag_mat : StandardMaterial3D

func _ready() -> void:
	add_to_group("Objectives")
	capture_tick.wait_time = TICK_TIME
	capture_tick.one_shot = false
	capture_tick.start()   # always runs now: decay needs it even when empty
	owner_team = initial_owner
	capture_progress = initial_owner * CAPTURE_MAX
	_flag_mat = StandardMaterial3D.new()
	flag.set_surface_override_material(0, _flag_mat)
	_update_flag()

## Nearest objective that `team` doesn't already own. Shared by Troop and Squad.
static func nearest_not_owned_by(tree: SceneTree, from: Vector3, team: int) -> Objective:
	var best : Objective = null
	var best_dist := INF
	for node in tree.get_nodes_in_group("Objectives"):
		var obj := node as Objective
		if obj == null or obj.owner_team == team:
			continue
		var d := from.distance_squared_to(obj.global_position)
		if d < best_dist:
			best_dist = d
			best = obj
	return best

## Short name for HUDs and markers: display_name, else the node name minus
## "Objective_" (Objective_A -> "A")
func get_label() -> String:
	return display_name if display_name != "" else str(name).trim_prefix("Objective_")

## What's happening here right now, from the player's side. Shared by the
## HUD and the in-world marker so they always say the same thing.
##   text      - CONTESTED / CAPTURING / UNDER ATTACK / ENEMY CAPTURING /
##               SECURED / ENEMY / NEUTRAL
##   team      - whose colour to show it in (1, -1, or 0 for neutral)
##   active    - someone is changing the bar (worth showing a percentage)
##   contested - both sides inside
func status() -> Dictionary:
	var friendlies := count_team(Troop.TEAM_FRIENDLY)
	var enemies := count_team(Troop.TEAM_ENEMY)
	if friendlies > 0 and enemies > 0:
		return {"text": "CONTESTED", "team": 0, "active": false, "contested": true}
	if friendlies > 0 and capture_progress < CAPTURE_MAX:
		return {"text": "CAPTURING", "team": Troop.TEAM_FRIENDLY, "active": true, "contested": false}
	if enemies > 0 and capture_progress > -CAPTURE_MAX:
		var t := "UNDER ATTACK" if owner_team == Troop.TEAM_FRIENDLY else "ENEMY CAPTURING"
		return {"text": t, "team": Troop.TEAM_ENEMY, "active": true, "contested": false}
	if owner_team == Troop.TEAM_FRIENDLY:
		return {"text": "SECURED", "team": owner_team, "active": false, "contested": false}
	if owner_team == Troop.TEAM_ENEMY:
		return {"text": "ENEMY", "team": owner_team, "active": false, "contested": false}
	return {"text": "NEUTRAL", "team": 0, "active": false, "contested": false}

func count_team(team: int) -> int:
	var n := 0
	for t in occupants:
		if is_instance_valid(t) and t.is_alive() and t.team == team:
			n += 1
	return n

func is_contested() -> bool:
	return count_team(Troop.TEAM_FRIENDLY) > 0 and count_team(Troop.TEAM_ENEMY) > 0

func _on_capture_area_body_entered(body: Node3D) -> void:
	if body is Troop and body not in occupants:
		occupants.append(body)

func _on_capture_area_body_exited(body: Node3D) -> void:
	if body is Troop:
		occupants.erase(body)

func _on_capture_tick_timeout() -> void:
	# Drop anything freed without firing body_exited
	occupants = occupants.filter(func(t): return is_instance_valid(t) and t.is_alive())

	var friendly := count_team(Troop.TEAM_FRIENDLY)
	var enemy    := count_team(Troop.TEAM_ENEMY)
	var before   := capture_progress

	if friendly > 0 and enemy > 0:
		return   # contested: frozen
	elif friendly > 0:
		capture_progress += capture_rate * mini(friendly, max_capture_multiplier)
	elif enemy > 0:
		capture_progress -= capture_rate * mini(enemy, max_capture_multiplier)
	else:
		var rest := owner_team * CAPTURE_MAX
		capture_progress = move_toward(capture_progress, rest, decay_rate)

	capture_progress = clampf(capture_progress, -CAPTURE_MAX, CAPTURE_MAX)
	if capture_progress != before:
		_check_ownership()
		_update_flag()

func _check_ownership() -> void:
	# Lose ownership once the bar crosses back to (or past) neutral
	if owner_team != 0 and signf(capture_progress) != owner_team:
		var prev := owner_team
		owner_team = 0
		print("[Objective] %s neutralized" % name)
		neutralized.emit(prev)

	if owner_team == 0:
		if capture_progress >= CAPTURE_MAX:
			_captured(Troop.TEAM_FRIENDLY)
		elif capture_progress <= -CAPTURE_MAX:
			_captured(Troop.TEAM_ENEMY)

func _captured(team: int) -> void:
	owner_team = team
	print("[Objective] %s captured by %s" % [name, "friendly" if team == 1 else "enemy"])
	captured.emit(team)

func _update_flag() -> void:
	# White when neutral, blending to blue (friendly) or red (enemy) with progress
	var t := absf(capture_progress) / CAPTURE_MAX
	var team_col := Color(0, 0, 1) if capture_progress >= 0.0 else Color(1, 0, 0)
	_flag_mat.albedo_color = Color.WHITE.lerp(team_col, t)
