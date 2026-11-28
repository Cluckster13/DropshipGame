class_name VehicleType
extends Resource
## A purchasable vehicle or emplacement. One .tres per vehicle in
## res://Resources/VehicleTypes/. The buy menu lists them under the squads,
## and the enemy's BattleManager sends them in waves (paying tickets).

@export var display_name : String = "APC"
## 1 = basic, 2 = standard, 3 = heavy. Shown as stars; enemy waves unlock
## higher tiers later, like squads.
@export_range(1, 3, 1) var tier : int = 1
@export_multiline var description : String = ""
## Player price ($)
@export var cost : int = 500
## Enemy price (tickets), on top of any crew squad's troops
@export var tickets : int = 8
## The vehicle scene (APC.tscn, Tank.tscn...)
@export var scene : PackedScene
## Squad that rides inside and is dropped at the objective (APC). Empty = none.
@export var crew_squad : SquadType
## Delivered by the helicopter instead of driving: the player's appears at
## base, packed, for the helicopter to sling-load out; the enemy's appears
## already set up near an objective it holds.
@export var sling_loaded : bool = false
## One line of stats for the buy menu
@export var stats : String = ""

## Vehicles don't take helicopter seats
func seats_needed() -> int:
	return 0

## Make the vehicle (and its crew squad, loaded inside) at `pos`, facing
## along `facing` (flat direction). Used by the buy zone and the enemy waves.
func spawn(parent: Node, team: int, pos: Vector3, facing: Vector3, tag: String,
		troop_scene: PackedScene = null, squad_parent: Node = null) -> Vehicle:
	if scene == null or parent == null:
		return null
	var v := scene.instantiate() as Vehicle
	v.name = tag
	v.team = team
	parent.add_child(v)
	v.global_position = pos
	if facing.length_squared() > 0.01:
		v.rotation.y = atan2(-facing.x, -facing.z)   # vehicles face -Z
	if crew_squad and troop_scene:
		var squad := crew_squad.make_squad(troop_scene, team, tag + "_Crew", "%s crew" % tag.replace("_", " "))
		for troop in squad.get_children():
			(troop as Node3D).position = pos + Vector3.UP * 1.5
		(squad_parent if squad_parent else parent).add_child(squad)
		v.load_squad(squad)
	return v

func stats_text() -> String:
	var text := stats
	if crew_squad:
		text += ("   ·   " if text != "" else "") + "carries a %s (%d)" % [crew_squad.display_name, crew_squad.size]
	if sling_loaded:
		text += ("   ·   " if text != "" else "") + "sling-load it out (H)"
	return text
