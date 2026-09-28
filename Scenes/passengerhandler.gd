class_name PassengerHandler
extends Node3D

@export var left_door  : NodePath   ## NPCLoadingAreaLeft — safe threshold, already used for boarding
@export var right_door : NodePath   ## NPCLoadingAreaRight
@export var unload_stagger_delay : float = 0.6   ## seconds between each troop disembarking

@onready var left_door_node  : Node3D = get_node(left_door)
@onready var right_door_node : Node3D = get_node(right_door)

var seats: Dictionary = {}
var _is_unloading: bool = false

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

## Called once per press. Guards against overlapping calls while a
## staggered unload is already in progress.
func unload_all() -> void:
	if _is_unloading:
		return
	_is_unloading = true

	for seat_name in seats.keys():
		var data: Dictionary = seats[seat_name]
		if data["occupied"] and data["occupant"] is FriendlyTroop:
			var is_left   : bool   = _seat_number(seat_name) % 2 == 0
			var door_node : Node3D = left_door_node if is_left else right_door_node
			data["occupant"].command_disembark(door_node.global_position)
			await get_tree().create_timer(unload_stagger_delay).timeout

	_is_unloading = false
