class_name LoadTrigger
extends Area3D

@export var passenger_handler : PassengerHandler
@export var door              : Node3D

var _troops_in_range: Array[FriendlyTroop] = []

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("Load"):
		_command_boarding()
	elif event.is_action_pressed("Unload"):
		passenger_handler.unload_all()

func _on_body_entered(body: Node3D) -> void:
	if body is FriendlyTroop and body not in _troops_in_range:
		_troops_in_range.append(body)

func _on_body_exited(body: Node3D) -> void:
	if body is FriendlyTroop:
		_troops_in_range.erase(body)

func _command_boarding() -> void:
	for troop in _troops_in_range:
		if troop.state != FriendlyTroop.States.IDLE:
			print("troop found: ", troop)
			continue
		var seat_name: String = passenger_handler.get_free_seat()
		if seat_name == "":
			print("vehicle full")
			break  ## vehicle full
		if passenger_handler.reserve_seat(seat_name, troop):
			troop.command_board(passenger_handler, seat_name, door.global_position)
