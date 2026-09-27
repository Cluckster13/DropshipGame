class_name PassengerHandler
extends Node3D

@export var left_door  : Area3D
@export var right_door : Area3D

var seats: Dictionary = {}

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

## Even seat number -> left door, odd -> right. Flip the comparison to swap sides.
func exit_door_for_seat(seat_name: String) -> Node3D:
	return left_door if _seat_number(seat_name) % 2 == 0 else right_door

func _seat_number(seat_name: String) -> int:
	return seat_name.trim_prefix("ChairNPCSpot").to_int()

func unload_all() -> void:
	for seat_name in seats.keys():
		var data: Dictionary = seats[seat_name]
		if data["occupied"] and data["occupant"] is FriendlyTroop:
			var door: Node3D = exit_door_for_seat(seat_name)
			data["occupant"].command_disembark(door.global_position)
