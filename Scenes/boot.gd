extends Node
## Main scene. Shows the loading screen straight away, then loads the first
## level in the background (Terrain3D maps take a while to load, and without
## this the window would sit frozen on a grey screen).

@export_file("*.tscn") var first_scene : String = "res://Levels/Valley.tscn"

func _ready() -> void:
	Loading.change_scene.call_deferred(first_scene)
