class_name SquadType
extends Resource
## A purchasable squad. Make one .tres per tier in res://Resources/SquadTypes/
## (right-click > New Resource > SquadType). The buy menu lists every file in
## that folder automatically, sorted by tier then cost.

@export var display_name : String = "Rifle Squad"
## 1 = basic, 2 = standard, 3 = elite. Shown as stars in the buy menu.
@export_range(1, 3, 1) var tier : int = 2
@export_multiline var description : String = ""
@export var cost : int = 250

@export_group("Troops")
@export_range(1, 15, 1) var size : int = 6
## Aim + reaction quality (see Troop.skill). 1 = baseline.
@export_range(0.25, 2.0, 0.05) var skill : float = 1.0
@export var max_health : float = 100.0
@export var move_speed : float = 4.0

@export_group("Role")
## Troops carry rocket launchers (see Troop.anti_tank)
@export var anti_tank : bool = false
## Doesn't go for objectives: guards the spot it's dropped at and hunts
## enemy vehicles around it (see Squad.hunt_vehicles)
@export var hunt_vehicles : bool = false
@export var hunt_radius : float = 400.0

## Seats it needs in the helicopter
func seats_needed() -> int:
	return size

func stats_text() -> String:
	var text := "%d troops   ·   Skill %.2f   ·   HP %d   ·   Speed %.1f" % [size, skill, roundi(max_health), move_speed]
	if anti_tank:
		text += "   ·   AT rockets"
	if hunt_vehicles:
		text += "   ·   hunts vehicles within %dm of drop-off" % roundi(hunt_radius)
	return text

## Build the Squad node and its troops (not yet in the tree). Positions are
## left to the caller.
func make_squad(troop_scene: PackedScene, team: int, node_name: String, label: String) -> Squad:
	var squad := Squad.new()
	squad.name = node_name
	squad.squad_name = label
	squad.team = team
	squad.skill = skill
	squad.auto_advance = not hunt_vehicles
	squad.hunt_vehicles = hunt_vehicles
	squad.hunt_radius = hunt_radius
	for i in size:
		var troop := troop_scene.instantiate() as Troop
		troop.name = "%s_%d" % [node_name, i + 1]
		troop.team = team
		troop.max_health = max_health
		troop.move_speed = move_speed
		troop.anti_tank = anti_tank
		squad.add_child(troop)   # squad picks these up as members in its _ready
	return squad
