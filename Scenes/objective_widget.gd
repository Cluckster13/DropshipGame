class_name ObjectiveWidget
extends PanelContainer
## One objective's box on the FlightHUD: name, capture bar, status.
## Layout/styling is in ObjectiveWidget.tscn; FlightHUD makes one per
## objective and calls show_objective() on each refresh.

@onready var name_label : Label = %Name
@onready var bar : ProgressBar = %Bar
@onready var status_label : Label = %Status

var _fill : StyleBoxFlat

func _ready() -> void:
	bar.max_value = Objective.CAPTURE_MAX
	# Every widget recolours its own bar, so give it its own copy of the
	# fill style instead of sharing (and recolouring) the scene's one
	_fill = (bar.get_theme_stylebox("fill") as StyleBoxFlat).duplicate()
	bar.add_theme_stylebox_override("fill", _fill)

func show_objective(obj: Objective, hud: FlightHUD) -> void:
	var progress := obj.capture_progress          # -100 enemy .. +100 friendly
	name_label.text = obj.get_label()
	name_label.add_theme_color_override("font_color", hud.team_color(obj.owner_team))

	bar.value = absf(progress)
	_fill.bg_color = hud.friendly_color if progress > 0.0 else (hud.enemy_color if progress < 0.0 else hud.neutral_color)

	var info: Dictionary = obj.status()
	var col := hud.dim_color
	if info["contested"]:
		col = hud.warn_color if hud.blink_on else hud.dim_color
	elif info["team"] != 0:
		col = hud.team_color(info["team"])
	status_label.text = info["text"]
	status_label.add_theme_color_override("font_color", col)
