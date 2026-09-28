class_name PassengerHandler
extends Node3D

var seats: Dictionary = {}

@onready var loading_area_left: Area3D = get_parent().get_node("NPCLoadingAreaLeft")

func _ready() -> void:
	for spot in get_children():
		seats[spot.name] = {
			"marker": spot,
			"occupant": null,
			"occupied": false
		}

func get_free_seat() -> String:
	for seat_name in seats:
		if not seats[seat_name]["occupied"]:
			return seat_name
	return ""  # no seats free

func seat_marker(seat_name: String) -> Node3D:
	if seats.has(seat_name):
		return seats[seat_name]["marker"]
	return null

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

func unload_all() -> void:
	for seat_name in seats:
		if seats[seat_name]["occupied"]:
			var occupant: Node3D = seats[seat_name]["occupant"]
			occupant.command_disembark(loading_area_left.global_position)
			vacate_seat(seat_name)
