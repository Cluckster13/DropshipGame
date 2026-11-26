extends Node
## Requisition funds for the player's side. Registered as the "Economy"
## autoload, so anything can call Economy.spend(...) / Economy.funds.
##
## Income: a steady trickle every income_interval seconds, plus a bonus each
## time friendlies capture an objective (hooked up automatically to every
## Objective that enters the scene).

signal funds_changed(funds: int)

@export var starting_funds : int = 1000
@export var income_amount : int = 50          ## paid every income_interval
@export var income_interval : float = 30.0    ## seconds
@export var capture_reward : int = 300        ## per objective captured by friendlies

var funds : int = 0
var _income_timer : float = 0.0

func _ready() -> void:
	funds = starting_funds
	get_tree().node_added.connect(_on_node_added)

func _process(delta: float) -> void:
	_income_timer += delta
	if _income_timer >= income_interval:
		_income_timer -= income_interval
		add_funds(income_amount)

func can_afford(amount: int) -> bool:
	return funds >= amount

## Returns false (and spends nothing) if there isn't enough
func spend(amount: int) -> bool:
	if not can_afford(amount):
		return false
	funds -= amount
	funds_changed.emit(funds)
	return true

func add_funds(amount: int) -> void:
	funds += amount
	funds_changed.emit(funds)

## Start a fresh match (e.g. when a level loads)
func reset() -> void:
	funds = starting_funds
	_income_timer = 0.0
	funds_changed.emit(funds)

func _on_node_added(node: Node) -> void:
	if node is Objective:
		node.captured.connect(_on_objective_captured.bind(node))

func _on_objective_captured(team: int, objective: Node) -> void:
	if team == Troop.TEAM_FRIENDLY:
		add_funds(capture_reward)
		print("[Economy] +%d for capturing %s (funds %d)" % [capture_reward, objective.name, funds])
