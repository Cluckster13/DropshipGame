extends Control

@export var test_helicopter: HeliBase
@export var friendly_troop: Troop

@onready var heli_text: RichTextLabel = $HeliText
@onready var aitext: RichTextLabel = $AItext

# Called when the node enters the scene tree for the first time.
## Debug readout. F3 toggles it.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		visible = not visible

func _process(_delta: float) -> void:
	if not visible:
		return
	heli_text.text = str(test_helicopter.get_debug_info())
	if not is_instance_valid(friendly_troop) or not friendly_troop.is_alive():
		friendly_troop = _find_replacement()
	aitext.text = str(friendly_troop.ai_debug_info()) if friendly_troop else "(no friendly troops left)"

## Tracked troop died: follow another friendly, same squad first
func _find_replacement() -> Troop:
	var fallback: Troop = null
	for node in get_tree().get_nodes_in_group("Troops"):
		var t := node as Troop
		if t == null or not t.is_alive() or t.team != Troop.TEAM_FRIENDLY:
			continue
		if fallback == null:
			fallback = t
		if t.squad and t.squad.squad_name == "Alpha":
			return t
	return fallback
