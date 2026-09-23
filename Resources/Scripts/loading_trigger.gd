# Scenes/loadtrigger.gd
class_name LoadTrigger
extends Area3D

@export var passenger_handler_path: NodePath
@onready var passenger_handler: PassengerHandler = get_node(passenger_handler_path)

var _troops_in_range: Array[FriendlyTroop] = []

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("Load"):
		_command_boarding()

func _on_body_entered(body: Node3D) -> void:
	if body is FriendlyTroop and body not in _troops_in_range:
		_troops_in_range.append(body)

func _on_body_exited(body: Node3D) -> void:
	if body is FriendlyTroop:
		_troops_in_range.erase(body)

func _command_boarding() -> void:
	for troop in _troops_in_range:
		if troop.state == FriendlyTroop.States.IDLE and passenger_handler.get_free_seat() != "":
			troop.command_board(global_position)
