class_name FlightHUD
extends CanvasLayer
## Pilot HUD. Layout and styling are nodes in FlightHUD.tscn (shared look in
## hud_theme.tres); this script only fills in values and recolours.
##   Top centre   - enemy tickets, objective widgets (ObjectiveWidget.tscn),
##                  defeat countdown
##   Centre       - victory / defeat banner, "aircraft destroyed"
##   Bottom left  - speed, altitude, vertical speed, hull, state
##   Bottom right - funds, troops aboard, boarding, load hint
##
## Instance FlightHUD.tscn as a child of the helicopter: it finds HeliBase and
## PassengerHandler by itself.

@export var aircraft : HeliBase
@export var passenger_handler : PassengerHandler
## One of these is made per objective in %Objectives
@export var objective_widget_scene : PackedScene = preload("res://Scenes/ObjectiveWidget.tscn")
## HUD refreshes per second (UI doesn't need to update every frame)
@export var refresh_rate : float = 10.0
## Altitude above ground is measured with a ray this long; above it, shows sea-level altitude
@export var max_agl_range : float = 1500.0
## Peak opacity of the red %HitFlash overlay when taking damage (its colour
## is set on the node)
@export_range(0.0, 1.0, 0.05) var hit_flash_strength : float = 0.5

@export_group("Status colours")
## Colours the script switches between at runtime (static colours and fonts
## are on the nodes / in hud_theme.tres)
@export var text_color     : Color = Color(0.85, 1.0, 0.85)
@export var dim_color      : Color = Color(0.55, 0.7, 0.55)
@export var warn_color     : Color = Color(1.0, 0.75, 0.25)
@export var friendly_color : Color = Color(0.3, 0.55, 1.0)
@export var enemy_color    : Color = Color(1.0, 0.3, 0.25)
@export var neutral_color  : Color = Color(0.8, 0.8, 0.8)

# Top
@onready var tickets_panel : Control = %TicketsPanel
@onready var tickets_value : Label = %TicketsValue
@onready var wave_label : Label = %WaveLabel
@onready var objectives_box : Container = %Objectives
@onready var warning_label : Label = %Warning
# Centre
@onready var banner : Control = %Banner
@onready var banner_title : Label = %BannerTitle
@onready var banner_sub : Label = %BannerSub
@onready var destroyed_label : Label = %Destroyed
@onready var hit_flash : ColorRect = %HitFlash
# Flight
@onready var speed_value : Label = %Speed
@onready var alt_caption : Label = %AltCaption
@onready var alt_value : Label = %Altitude
@onready var vs_value : Label = %VerticalSpeed
@onready var hull_value : Label = %Hull
@onready var state_label : Label = %State
# Troops
@onready var funds_label : Label = %Funds
@onready var troops_value : Label = %TroopsValue
@onready var boarding_label : Label = %Boarding
@onready var hint_label : Label = %Hint

## Toggles ~1.25 times a second, for blinking warnings
var blink_on : bool = true

var _battle : BattleManager
var _widgets : Dictionary = {}   # Objective -> ObjectiveWidget
var _flash : float = 0.0         # seconds of red flash left after taking damage
var _accum : float = 0.0

func _ready() -> void:
	if aircraft == null:
		aircraft = _find_aircraft()
	if passenger_handler == null and aircraft:
		for c in aircraft.get_children():
			if c is PassengerHandler:
				passenger_handler = c
				break
	if aircraft and aircraft.has_signal("damaged"):
		aircraft.damaged.connect(_on_aircraft_damaged)
	# The editor preview objectives in %Objectives are just for layout
	for c in objectives_box.get_children():
		c.queue_free()
	hit_flash.color.a = 0.0
	_refresh()

func _process(delta: float) -> void:
	# Damage flash runs every frame so it fades smoothly
	_flash = maxf(_flash - delta, 0.0)
	hit_flash.color.a = _flash * hit_flash_strength
	_accum += delta
	if _accum < 1.0 / refresh_rate:
		return
	_accum = 0.0
	_refresh()

func team_color(team: int) -> Color:
	if team == Troop.TEAM_FRIENDLY:
		return friendly_color
	if team == Troop.TEAM_ENEMY:
		return enemy_color
	return neutral_color

# ---------------------------------------------------------------- refresh

func _refresh() -> void:
	blink_on = int(Time.get_ticks_msec() / 400.0) % 2 == 0
	_refresh_battle()
	_refresh_objectives()
	_refresh_flight()
	_refresh_troops()

func _refresh_battle() -> void:
	if not is_instance_valid(_battle):
		_battle = get_tree().get_first_node_in_group("Battle") as BattleManager
	tickets_panel.visible = _battle != null
	if _battle == null:
		warning_label.visible = false
		banner.visible = false
		return

	tickets_value.text = str(_battle.tickets)
	var next := _battle.time_to_next_wave()
	if next >= 0.0:
		@warning_ignore("integer_division")
		wave_label.text = "·  next wave %d:%02d" % [int(next) / 60, int(next) % 60]
	elif not _battle.is_over:
		wave_label.text = "·  %d left" % _battle.enemies_alive()
	else:
		wave_label.text = ""

	# Defeat countdown while the enemy holds everything
	var holding := not _battle.is_over and _battle.enemy_holds_all()
	warning_label.visible = holding
	if holding:
		var left := ceili(_battle.hold_to_lose - _battle.enemy_hold_time)
		warning_label.text = "ENEMY HOLDS ALL OBJECTIVES  —  DEFEAT IN %ds" % left
		warning_label.add_theme_color_override("font_color", enemy_color if blink_on else warn_color)

	banner.visible = _battle.is_over
	if _battle.is_over:
		banner_title.text = "VICTORY" if _battle.player_won else "DEFEAT"
		banner_title.add_theme_color_override("font_color", friendly_color if _battle.player_won else enemy_color)
		banner_sub.text = ("Enemy reinforcements exhausted" if _battle.player_won \
			else "The enemy held every objective") + "\nPress Enter to play again"

func _refresh_objectives() -> void:
	var objectives: Array = get_tree().get_nodes_in_group("Objectives")
	objectives.sort_custom(func(a, b): return str(a.name) < str(b.name))

	# Drop widgets for objectives that no longer exist
	for obj in _widgets.keys():
		if not is_instance_valid(obj) or obj not in objectives:
			_widgets[obj].queue_free()
			_widgets.erase(obj)

	for i in objectives.size():
		var obj := objectives[i] as Objective
		if obj == null:
			continue
		if not _widgets.has(obj):
			var w := objective_widget_scene.instantiate() as ObjectiveWidget
			objectives_box.add_child(w)
			_widgets[obj] = w
		var widget: ObjectiveWidget = _widgets[obj]
		objectives_box.move_child(widget, i)
		widget.show_objective(obj, self)

	objectives_box.visible = not objectives.is_empty()

func _refresh_flight() -> void:
	if aircraft == null:
		return
	var v := aircraft.linear_velocity
	speed_value.text = "%d km/h" % roundi(Vector2(v.x, v.z).length() * 3.6)

	var agl := _altitude_above_ground()
	if agl >= 0.0:
		alt_caption.text = "ALT"
		alt_value.text = "%d m" % roundi(agl)
		alt_value.add_theme_color_override("font_color", warn_color if agl < 10.0 and not aircraft.is_landed() else text_color)
	else:
		alt_caption.text = "MSL"
		alt_value.text = "%d m" % roundi(aircraft.global_position.y)
		alt_value.add_theme_color_override("font_color", text_color)

	vs_value.text = "%+.1f m/s" % v.y

	var hull: float = aircraft.health_fraction()
	hull_value.text = "%d%%" % roundi(hull * 100.0)
	var hull_col := text_color if hull > 0.5 else (warn_color if hull > 0.25 else enemy_color)
	if _flash > 0.0 or (hull <= 0.25 and not blink_on):
		hull_col = enemy_color
	hull_value.add_theme_color_override("font_color", hull_col)

	destroyed_label.visible = aircraft.is_destroyed
	if aircraft.is_destroyed:
		destroyed_label.text = "AIRCRAFT DESTROYED" + (
			"\nNew aircraft at base in %ds" % ceili(aircraft.respawn_time_left) if aircraft.respawn_delay > 0.0 else "")

	if aircraft.is_destroyed:
		_set_state("DESTROYED", enemy_color)
	elif not aircraft.engine_on:
		_set_state("ENGINE OFF  (R)", warn_color)
	elif aircraft.is_landed():
		_set_state("LANDED", friendly_color)
	else:
		_set_state("AIRBORNE", text_color)

func _refresh_troops() -> void:
	var economy := get_node_or_null("/root/Economy")
	funds_label.visible = economy != null
	if economy:
		funds_label.text = "$ %d" % economy.funds
	if passenger_handler == null:
		troops_value.text = "--"
		return
	troops_value.text = "%d / %d" % [passenger_handler.passenger_count(), passenger_handler.seat_count()]
	var boarding := passenger_handler.boarding_count()
	boarding_label.text = "%d boarding" % boarding if boarding > 0 else ""
	boarding_label.visible = boarding > 0
	var landed := aircraft != null and aircraft.is_landed()
	hint_label.text = "F  load    U  unload" if landed else "land to load / unload"
	hint_label.add_theme_color_override("font_color", text_color if landed else dim_color)

# ---------------------------------------------------------------- helpers

func _altitude_above_ground() -> float:
	# Start a metre up: the aircraft origin sits right at skid level and can
	# end up a hair inside the ground, which makes a ray from there miss
	var origin := aircraft.global_position
	var from := origin + Vector3.UP
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * (max_agl_range + 1.0))
	query.exclude = [aircraft.get_rid()]
	var hit := aircraft.get_world_3d().direct_space_state.intersect_ray(query)
	return maxf(origin.y - hit.position.y, 0.0) if not hit.is_empty() else -1.0

func _on_aircraft_damaged(amount: float, _source: Node) -> void:
	# Bigger hits flash longer: a rifle round blinks, a crash lingers
	_flash = clampf(_flash + 0.08 + amount / 400.0, 0.0, 0.6)

func _set_state(text: String, col: Color) -> void:
	state_label.text = text
	state_label.add_theme_color_override("font_color", col)

func _find_aircraft() -> HeliBase:
	var n := get_parent()
	while n:
		if n is HeliBase:
			return n
		n = n.get_parent()
	return null
