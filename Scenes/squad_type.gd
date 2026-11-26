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

func stats_text() -> String:
	return "%d troops   ·   Skill %.2f   ·   HP %d   ·   Speed %.1f" % [size, skill, roundi(max_health), move_speed]
