class_name SquadRow
extends PanelContainer
## One purchasable squad in the BuyMenu. Layout is in SquadRow.tscn;
## BuyMenu makes one of these per SquadType.

signal buy_pressed(squad_type: SquadType)

@export var money_color : Color = Color(1.0, 0.8, 0.3)
@export var cant_afford_color : Color = Color(1.0, 0.4, 0.35)

@onready var name_label : Label = %Name
@onready var stars_label : Label = %Stars
@onready var description_label : Label = %Description
@onready var stats_label : Label = %Stats
@onready var cost_label : Label = %Cost
@onready var buy_button : Button = %BuyButton

var squad_type : SquadType

func _ready() -> void:
	buy_button.pressed.connect(func(): buy_pressed.emit(squad_type))

func setup(t: SquadType) -> void:
	squad_type = t
	name_label.text = t.display_name
	stars_label.text = "★".repeat(t.tier) + "☆".repeat(3 - t.tier)
	description_label.text = t.description
	description_label.visible = t.description != ""
	stats_label.text = t.stats_text()
	cost_label.text = "$ %d" % t.cost

## Enable/disable the Buy button for the current funds and free seats
## (free_seats < 0 = unknown, don't check)
func refresh(funds: int, free_seats: int) -> void:
	var affordable := funds >= squad_type.cost
	var fits := free_seats < 0 or squad_type.size <= free_seats
	buy_button.disabled = not (affordable and fits)
	if not affordable:
		buy_button.text = "Need $%d" % (squad_type.cost - funds)
	elif not fits:
		buy_button.text = "No room"
	else:
		buy_button.text = "Buy"
	cost_label.add_theme_color_override("font_color", money_color if affordable else cant_afford_color)
