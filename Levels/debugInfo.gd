extends RichTextLabel

@onready var test_helicopter: HeliBase = $"../.."

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	self.text = str(test_helicopter.get_debug_info())
