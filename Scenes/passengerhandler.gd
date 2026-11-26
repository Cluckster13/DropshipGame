class_name PassengerHandler
extends Node3D

@export var left_door  : NodePath   ## NPCLoadingAreaLeft — safe threshold, already used for boarding
@export var right_door : NodePath   ## NPCLoadingAreaRight
@export var unload_stagger_delay : float = 0.6   ## seconds between each troop disembarking
@export var exit_distance : float = 6.0          ## how far out from the door troops walk before regrouping
@export var exit_spacing  : float = 1.5          ## fore/aft gap between troops lining up outside each door

@onready var left_door_node  : Node3D = get_node(left_door)
@onready var right_door_node : Node3D = get_node(right_door)

## Seconds airborne before troops still walking to the door give up
@export var takeoff_cancel_delay : float = 0.5

## Fired when troops start getting out (NavPatchBaker bakes nav around here)
signal unloading_started(where: Vector3)

var seats: Dictionary = {}
var _is_unloading: bool = false
var _airborne_time: float = 0.0

## The helicopter we belong to (our parent). Null = no landing checks.
@onready var aircraft : HeliBase = get_parent() as HeliBase

func can_load_or_unload() -> bool:
	return aircraft == null or aircraft.is_landed()

func _physics_process(delta: float) -> void:
	if can_load_or_unload():
		_airborne_time = 0.0
		return
	_airborne_time += delta
	if _airborne_time < takeoff_cancel_delay:
		return
	# Took off while troops were still walking to the door: they stay behind
	for seat_name in seats:
		var occupant = seats[seat_name]["occupant"]
		if is_instance_valid(occupant) and occupant is Troop and occupant.state == Troop.States.MOVING_TO_BOARD:
			occupant.cancel_board()

func _ready() -> void:
	for spot in get_children():
		seats[spot.name] = {
			"marker"   : spot,
			"occupant" : null,
			"occupied" : false
		}

func get_free_seat() -> String:
	for seat_name in seats:
		if not seats[seat_name]["occupied"]:
			return seat_name
	return ""

func free_seat_count() -> int:
	var n := 0
	for seat_name in seats:
		if not seats[seat_name]["occupied"]:
			n += 1
	return n

func seat_count() -> int:
	return seats.size()

## Troops actually sitting in the aircraft
func passenger_count() -> int:
	return _count_state(Troop.States.PASSENGER)

## Troops with a reserved seat who are still walking to the door
func boarding_count() -> int:
	return _count_state(Troop.States.MOVING_TO_BOARD)

func _count_state(s: Troop.States) -> int:
	var n := 0
	for seat_name in seats:
		var occupant = seats[seat_name]["occupant"]
		if is_instance_valid(occupant) and occupant is Troop and occupant.state == s:
			n += 1
	return n

func reserve_seat(seat_name: String, occupant: Node3D) -> bool:
	if seats.has(seat_name) and not seats[seat_name]["occupied"]:
		seats[seat_name]["occupant"] = occupant
		seats[seat_name]["occupied"] = true
		return true
	return false

func vacate_seat(seat_name: String) -> void:
	if seats.has(seat_name):
		seats[seat_name]["occupant"] = null
		seats[seat_name]["occupied"] = false

func seat_marker(seat_name: String) -> Node3D:
	return seats[seat_name]["marker"] if seats.has(seat_name) else null

func _seat_number(seat_name: String) -> int:
	return seat_name.trim_prefix("ChairNPCSpot").to_int()

## Spot `slot` in a line on the ground outside the given door, pushed out
## sideways from the aircraft. Slots fan out 0, +1, -1, +2, -2... so every
## troop gets its own patch of ground and nobody blocks anyone else.
func _rally_point(door_pos: Vector3, slot: int) -> Vector3:
	var side := global_basis.x
	side.y = 0.0
	side = side.normalized()
	if (door_pos - global_position).dot(side) < 0.0:
		side = -side
	var fore := side.cross(Vector3.UP).normalized()
	@warning_ignore("integer_division")
	var step := (slot + 1) / 2   # 0,1,1,2,2... (intentional int division)
	var fan := 1.0 if slot % 2 == 1 else -1.0
	return door_pos + side * exit_distance + fore * (fan * step * exit_spacing)

## Called once per press. Guards against overlapping calls while a
## staggered unload is already in progress.
func unload_all() -> void:
	if _is_unloading:
		return
	if not can_load_or_unload():
		print("[PassengerHandler] Can't unload: aircraft must be landed")
		return
	_is_unloading = true
	if passenger_count() > 0:
		unloading_started.emit(global_position)
	var left_slot  := 0
	var right_slot := 0

	for seat_name in seats.keys():
		var data: Dictionary = seats[seat_name]
		var occupant = data["occupant"]
		if not can_load_or_unload():
			print("[PassengerHandler] Took off mid-unload, remaining troops stay aboard")
			break
		if data["occupied"] and is_instance_valid(occupant) and occupant is Troop and occupant.state == Troop.States.PASSENGER:
			var is_left   : bool   = _seat_number(seat_name) % 2 == 0
			var door_node : Node3D = left_door_node if is_left else right_door_node
			var door_pos  : Vector3 = door_node.global_position
			var slot := left_slot if is_left else right_slot
			if is_left: left_slot += 1
			else: right_slot += 1
			occupant.command_disembark(door_pos, _rally_point(door_pos, slot))
			await get_tree().create_timer(unload_stagger_delay).timeout

	_is_unloading = false
