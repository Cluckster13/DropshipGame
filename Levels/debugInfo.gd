extends Control

@export var test_helicopter: HeliBase
@export var friendly_troop: FriendlyTroop

@onready var heli_text: RichTextLabel = $HeliText
@onready var aitext: RichTextLabel = $AItext

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	heli_text.text = str(test_helicopter.get_debug_info())
	aitext.text = str(friendly_troop.ai_debug_info())
