extends Control
## Main menu. The project's main scene.
##
## Everything is laid out as nodes in MainMenu.tscn; this script only wires
## it up. Styling lives in menu_theme.tres (set as this node's Theme).
##   - Levels: every LevelButton under %LevelButtons is a level. Duplicate one
##     to add a level, then set its scene / description in the inspector.
##   - %Description shows the hovered level's description.
##   - %QuitButton quits.

@onready var level_buttons : Container = %LevelButtons
@onready var description_label : Label = %Description
@onready var quit_button : Button = %QuitButton

var _busy : bool = false

func _ready() -> void:
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	var first : Button = null
	for child in level_buttons.get_children():
		var b := child as LevelButton
		if b == null:
			continue
		b.pressed.connect(play.bind(b))
		b.mouse_entered.connect(_show_description.bind(b))
		b.focus_entered.connect(_show_description.bind(b))
		if first == null:
			first = b

	quit_button.pressed.connect(get_tree().quit)
	quit_button.mouse_entered.connect(_show_description.bind(null))
	quit_button.focus_entered.connect(_show_description.bind(null))

	description_label.text = ""
	if first:
		first.grab_focus.call_deferred()   # keyboard / controller can navigate right away

func play(button: LevelButton) -> void:
	if _busy:
		return
	if button.scene == "" or not ResourceLoader.exists(button.scene):
		push_error("MainMenu: '%s' has no valid scene set (%s)" % [button.name, button.scene])
		return
	_busy = true
	var loading := get_node_or_null("/root/Loading")
	if button.use_loading_screen and loading:
		loading.change_scene(button.scene)
	else:
		get_tree().change_scene_to_file(button.scene)

func _show_description(button: LevelButton) -> void:
	description_label.text = button.description if button else ""
