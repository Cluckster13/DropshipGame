class_name LevelButton
extends Button
## A main menu button that starts a level. To add a level, duplicate one of
## these under MainMenu's LevelButtons and point it at the scene.

## The level to load
@export_file("*.tscn") var scene : String = ""
## Shown under the buttons while this one is hovered / focused
@export_multiline var description : String = ""
## On: load in the background behind the loading screen and wait for the
## level to be ready (navigation etc). Off: switch straight to it, for small
## test maps.
@export var use_loading_screen : bool = true
