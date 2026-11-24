class_name LoadTrigger
extends Area3D

@export var passenger_handler : PassengerHandler
@export var door              : Node3D
## Only troops on this team may board (1 = friendly)
@export_range(-1, 1, 1) var allowed_team : int = Troop.TEAM_FRIENDLY

var _troops_in_range: Array[Troop] = []

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("Load"):
		_command_boarding()
	elif event.is_action_pressed("Unload"):
		passenger_handler.unload_all()

func _on_body_entered(body: Node3D) -> void:
	if body is Troop and body not in _troops_in_range:
		_troops_in_range.append(body)

func _on_body_exited(body: Node3D) -> void:
	if body is Troop:
		_troops_in_range.erase(body)

## Squads board together (whole squad or nobody) so they don't get split
## across aircraft. Troops without a squad board one by one.
func _command_boarding() -> void:
	if not passenger_handler.can_load_or_unload():
		print("[LoadTrigger] Can't load: aircraft must be landed")
		return
	var handled: Array[Troop] = []
	for troop in _troops_in_range:
		if not is_instance_valid(troop) or troop in handled or troop.team != allowed_team:
			continue

		var group: Array[Troop] = []
		if troop.squad:
			group = troop.squad.available_members()
		elif troop.is_available():
			group = [troop]
		handled.append_array(group)
		if troop.squad:
			handled.append_array(troop.squad.alive_members())

		if group.is_empty():
			continue
		if group.size() > passenger_handler.free_seat_count():
			print("Not enough seats for %s (%d needed, %d free)" % [
				troop.squad.squad_name if troop.squad else str(troop.name),
				group.size(), passenger_handler.free_seat_count()])
			continue

		for t in group:
			var seat_name := passenger_handler.get_free_seat()
			if passenger_handler.reserve_seat(seat_name, t):
				t.command_board(passenger_handler, seat_name, door.global_position)
