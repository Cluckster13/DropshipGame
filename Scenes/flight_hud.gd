class_name FlightHUD
extends CanvasLayer
## Pilot HUD.
##   Top centre   — objectives: name, owner colour, capture bar, status
##   Bottom left  — ground speed, altitude above ground, vertical speed, state
##   Bottom right — troops aboard / seats, troops still boarding, load hint
##
## Add as a child of the helicopter: it finds HeliBase and PassengerHandler
## by itself. Builds its own UI in code; tweak colours/sizes in the Style group.

@export var aircraft : HeliBase
@export var passenger_handler : PassengerHandler
## HUD refreshes per second (UI doesn't need to update every frame)
@export var refresh_rate : float = 10.0
## Altitude above ground is measured with a ray this long; above it, shows sea-level altitude
@export var max_agl_range : float = 1500.0

@export_group("Style")
@export var font_size : int = 18
@export var big_font_size : int = 28
@export var text_color    : Color = Color(0.85, 1.0, 0.85)
@export var dim_color     : Color = Color(0.55, 0.7, 0.55)
@export var warn_color    : Color = Color(1.0, 0.75, 0.25)
@export var panel_color   : Color = Color(0.0, 0.0, 0.0, 0.45)
@export var friendly_color : Color = Color(0.3, 0.55, 1.0)
@export var enemy_color    : Color = Color(1.0, 0.3, 0.25)
@export var neutral_color  : Color = Color(0.8, 0.8, 0.8)

var _objective_bar : HBoxContainer
var _objective_widgets : Dictionary = {}   # Objective -> Dictionary of controls

var _hull_value : Label
var _hit_flash : float = 0.0   # seconds of red flash left after taking damage
var _hit_overlay : ColorRect
var _down_label : Label

var _battle : BattleManager
var _tickets_panel : PanelContainer
var _tickets_value : Label
var _wave_label : Label
var _warning_label : Label
var _banner : VBoxContainer
var _banner_title : Label
var _banner_sub : Label

var _speed_value : Label
var _alt_value   : Label
var _alt_caption : Label
var _vs_value    : Label
var _state_label : Label

var _funds_label : Label
var _troops_value : Label
var _boarding_label : Label
var _hint_label : Label

var _accum : float = 0.0
var _blink_on : bool = true

func _ready() -> void:
	if aircraft == null:
		aircraft = _find_aircraft()
	if passenger_handler == null and aircraft:
		for c in aircraft.get_children():
			if c is PassengerHandler:
				passenger_handler = c
				break
	_build()
	if aircraft and aircraft.has_signal("damaged"):
		aircraft.damaged.connect(_on_aircraft_damaged)
	_refresh()

func _process(delta: float) -> void:
	# Damage flash runs every frame so it fades smoothly
	_hit_flash = maxf(_hit_flash - delta, 0.0)
	_hit_overlay.color.a = _hit_flash * 0.5
	_accum += delta
	if _accum < 1.0 / refresh_rate:
		return
	_accum = 0.0
	_refresh()

# ---------------------------------------------------------------- refresh

func _refresh() -> void:
	_blink_on = int(Time.get_ticks_msec() / 400.0) % 2 == 0   # ~1.25 Hz blink
	_refresh_battle()
	_refresh_objectives()
	_refresh_flight()
	_refresh_troops()

func _refresh_battle() -> void:
	if not is_instance_valid(_battle):
		_battle = get_tree().get_first_node_in_group("Battle") as BattleManager
	_tickets_panel.visible = _battle != null
	if _battle == null:
		_warning_label.visible = false
		_banner.visible = false
		return

	_tickets_value.text = str(_battle.tickets)
	var next := _battle.time_to_next_wave()
	if next >= 0.0:
		_wave_label.text = "·  next wave %d:%02d" % [int(next) / 60, int(next) % 60]
	elif not _battle.is_over:
		_wave_label.text = "·  %d left" % _battle.enemies_alive()
	else:
		_wave_label.text = ""

	# Defeat countdown while the enemy holds everything
	var holding := not _battle.is_over and _battle.enemy_holds_all()
	_warning_label.visible = holding
	if holding:
		var left := ceili(_battle.hold_to_lose - _battle.enemy_hold_time)
		_warning_label.text = "ENEMY HOLDS ALL OBJECTIVES  —  DEFEAT IN %ds" % left
		_warning_label.add_theme_color_override("font_color", enemy_color if _blink_on else warn_color)

	_banner.visible = _battle.is_over
	if _battle.is_over:
		_banner_title.text = "VICTORY" if _battle.player_won else "DEFEAT"
		_banner_title.add_theme_color_override("font_color", friendly_color if _battle.player_won else enemy_color)
		_banner_sub.text = ("Enemy reinforcements exhausted" if _battle.player_won \
			else "The enemy held every objective") + "\nPress Enter to play again"

func _refresh_flight() -> void:
	if aircraft == null:
		return
	var v := aircraft.linear_velocity
	_speed_value.text = "%d km/h" % roundi(Vector2(v.x, v.z).length() * 3.6)

	var agl := _altitude_above_ground()
	if agl >= 0.0:
		_alt_caption.text = "ALT"
		_alt_value.text = "%d m" % roundi(agl)
		_alt_value.add_theme_color_override("font_color", warn_color if agl < 10.0 and not aircraft.is_landed() else text_color)
	else:
		_alt_caption.text = "MSL"
		_alt_value.text = "%d m" % roundi(aircraft.global_position.y)
		_alt_value.add_theme_color_override("font_color", text_color)

	_vs_value.text = "%+.1f m/s" % v.y

	var hull: float = aircraft.health_fraction()
	_hull_value.text = "%d%%" % roundi(hull * 100.0)
	var hull_col := text_color if hull > 0.5 else (warn_color if hull > 0.25 else enemy_color)
	if _hit_flash > 0.0 or (hull <= 0.25 and not _blink_on):
		hull_col = enemy_color
	_hull_value.add_theme_color_override("font_color", hull_col)

	_down_label.visible = aircraft.is_destroyed
	if aircraft.is_destroyed:
		_down_label.text = "AIRCRAFT DESTROYED" + (
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
	_funds_label.visible = economy != null
	if economy:
		_funds_label.text = "$ %d" % economy.funds
	if passenger_handler == null:
		_troops_value.text = "--"
		return
	_troops_value.text = "%d / %d" % [passenger_handler.passenger_count(), passenger_handler.seat_count()]
	var boarding := passenger_handler.boarding_count()
	_boarding_label.text = "%d boarding" % boarding if boarding > 0 else ""
	_boarding_label.visible = boarding > 0
	var landed := aircraft != null and aircraft.is_landed()
	_hint_label.text = "F  load    U  unload" if landed else "land to load / unload"
	_hint_label.add_theme_color_override("font_color", text_color if landed else dim_color)

func _refresh_objectives() -> void:
	var objectives: Array = get_tree().get_nodes_in_group("Objectives")
	objectives.sort_custom(func(a, b): return str(a.name) < str(b.name))

	# Drop widgets for objectives that no longer exist
	for obj in _objective_widgets.keys():
		if not is_instance_valid(obj) or obj not in objectives:
			_objective_widgets[obj]["panel"].queue_free()
			_objective_widgets.erase(obj)

	for i in objectives.size():
		var obj := objectives[i] as Objective
		if obj == null:
			continue
		if not _objective_widgets.has(obj):
			_objective_widgets[obj] = _make_objective_widget()
		var w: Dictionary = _objective_widgets[obj]
		_objective_bar.move_child(w["panel"], i)
		_update_objective_widget(obj, w)

	_objective_bar.visible = not objectives.is_empty()

func _update_objective_widget(obj: Objective, w: Dictionary) -> void:
	var progress := obj.capture_progress          # -100 enemy .. +100 friendly
	var owner_col := _team_color(obj.owner_team)

	w["name"].text = _objective_name(obj)
	w["name"].add_theme_color_override("font_color", owner_col)

	w["bar"].value = absf(progress)
	w["fill"].bg_color = friendly_color if progress > 0.0 else (enemy_color if progress < 0.0 else neutral_color)

	var info: Dictionary = obj.status()
	var status: String = info["text"]
	var status_col := dim_color
	if info["contested"]:
		status_col = warn_color if _blink_on else dim_color
	elif info["team"] != 0:
		status_col = _team_color(info["team"])
	w["status"].text = status
	w["status"].add_theme_color_override("font_color", status_col)

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

## Uses the objective's `display_name` if it has one set, else the node name
## minus "Objective_" (Objective_A -> "A")
func _objective_name(obj: Objective) -> String:
	var custom = obj.get("display_name")
	if custom is String and custom != "":
		return custom
	return str(obj.name).trim_prefix("Objective_")

func _on_aircraft_damaged(amount: float, _source: Node) -> void:
	# Bigger hits flash longer: a rifle round blinks, a crash lingers
	_hit_flash = clampf(_hit_flash + 0.08 + amount / 400.0, 0.0, 0.6)

func _set_state(text: String, col: Color) -> void:
	_state_label.text = text
	_state_label.add_theme_color_override("font_color", col)

func _team_color(team: int) -> Color:
	if team == Troop.TEAM_FRIENDLY:
		return friendly_color
	if team == Troop.TEAM_ENEMY:
		return enemy_color
	return neutral_color

func _find_aircraft() -> HeliBase:
	var n := get_parent()
	while n:
		if n is HeliBase:
			return n
		n = n.get_parent()
	return null

# ---------------------------------------------------------------- build UI

func _build() -> void:
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# Red wash over the screen when taking hits
	_hit_overlay = ColorRect.new()
	_hit_overlay.name = "HitFlash"
	_hit_overlay.color = Color(0.8, 0.0, 0.0, 0.0)
	_hit_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hit_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(_hit_overlay)

	_down_label = _label("", 40, enemy_color)
	_down_label.name = "Destroyed"
	_down_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_down_label.visible = false
	root.add_child(_down_label)
	_down_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_KEEP_SIZE)
	_down_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_down_label.grow_vertical = Control.GROW_DIRECTION_BOTH

	# --- Top centre: enemy tickets, objectives, defeat warning
	var top := VBoxContainer.new()
	top.name = "TopCenter"
	top.alignment = BoxContainer.ALIGNMENT_BEGIN
	top.add_theme_constant_override("separation", 6)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(top)
	top.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_KEEP_SIZE, 12)
	top.grow_horizontal = Control.GROW_DIRECTION_BOTH

	_tickets_panel = _make_panel("Tickets")
	_tickets_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var tickets_row := HBoxContainer.new()
	tickets_row.add_theme_constant_override("separation", 10)
	_tickets_panel.add_child(tickets_row)
	tickets_row.add_child(_label("ENEMY TICKETS", font_size - 4, dim_color))
	_tickets_value = _label("0", big_font_size - 6, enemy_color)
	tickets_row.add_child(_tickets_value)
	_wave_label = _label("", font_size - 4, dim_color)
	tickets_row.add_child(_wave_label)
	top.add_child(_tickets_panel)

	_objective_bar = HBoxContainer.new()
	_objective_bar.name = "Objectives"
	_objective_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	_objective_bar.add_theme_constant_override("separation", 10)
	_objective_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(_objective_bar)

	_warning_label = _label("", font_size, enemy_color)
	_warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	top.add_child(_warning_label)

	# --- Victory / defeat banner, centre screen
	_banner = VBoxContainer.new()
	_banner.name = "Banner"
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.visible = false
	root.add_child(_banner)
	_banner_title = _label("", 72, text_color)
	_banner_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.add_child(_banner_title)
	_banner_sub = _label("", font_size + 2, text_color)
	_banner_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.add_child(_banner_sub)
	_banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_KEEP_SIZE)
	_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_banner.grow_vertical = Control.GROW_DIRECTION_BOTH

	# --- Flight data, bottom left
	var flight := _make_panel("Flight")
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 2)
	flight.add_child(grid)
	grid.add_child(_label("SPD", font_size, dim_color))
	_speed_value = _label("0 km/h", big_font_size, text_color)
	grid.add_child(_speed_value)
	_alt_caption = _label("ALT", font_size, dim_color)
	grid.add_child(_alt_caption)
	_alt_value = _label("0 m", big_font_size, text_color)
	grid.add_child(_alt_value)
	grid.add_child(_label("V/S", font_size, dim_color))
	_vs_value = _label("+0.0 m/s", font_size, text_color)
	grid.add_child(_vs_value)
	grid.add_child(_label("HULL", font_size, dim_color))
	_hull_value = _label("100%", font_size + 4, text_color)
	grid.add_child(_hull_value)
	grid.add_child(_label("", font_size, dim_color))
	_state_label = _label("", font_size, text_color)
	grid.add_child(_state_label)
	root.add_child(flight)
	_anchor_corner(flight, Control.PRESET_BOTTOM_LEFT)

	# --- Troops, bottom right
	var troops := _make_panel("Troops")
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)
	troops.add_child(vbox)
	_funds_label = _label("", big_font_size - 4, warn_color)
	_funds_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	vbox.add_child(_funds_label)
	var header := _label("TROOPS", font_size, dim_color)
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	vbox.add_child(header)
	_troops_value = _label("0 / 0", big_font_size, text_color)
	_troops_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	vbox.add_child(_troops_value)
	_boarding_label = _label("", font_size, warn_color)
	_boarding_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	vbox.add_child(_boarding_label)
	_hint_label = _label("", font_size - 2, dim_color)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	vbox.add_child(_hint_label)
	root.add_child(troops)
	_anchor_corner(troops, Control.PRESET_BOTTOM_RIGHT)

func _make_objective_widget() -> Dictionary:
	var panel := _make_panel("Objective")
	panel.custom_minimum_size = Vector2(96, 0)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	panel.add_child(vbox)

	var name_label := _label("?", big_font_size - 4, neutral_color)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(name_label)

	var bar := ProgressBar.new()
	bar.max_value = Objective.CAPTURE_MAX
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 6)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(1, 1, 1, 0.12)
	var fill := StyleBoxFlat.new()
	fill.bg_color = neutral_color
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fill)
	vbox.add_child(bar)

	var status := _label("", font_size - 6, dim_color)
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(status)

	_objective_bar.add_child(panel)
	return {"panel": panel, "name": name_label, "bar": bar, "fill": fill, "status": status}

func _make_panel(node_name: String) -> PanelContainer:
	var p := PanelContainer.new()
	p.name = node_name
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = panel_color
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	p.add_theme_stylebox_override("panel", sb)
	return p

func _label(text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	return l

## Pins a panel to a bottom corner with a margin; grows up/inward as content changes
func _anchor_corner(c: Control, preset: Control.LayoutPreset) -> void:
	c.grow_vertical = Control.GROW_DIRECTION_BEGIN
	c.grow_horizontal = Control.GROW_DIRECTION_BEGIN if preset == Control.PRESET_BOTTOM_RIGHT else Control.GROW_DIRECTION_END
	c.set_anchors_and_offsets_preset(preset, Control.PRESET_MODE_MINSIZE, 16)
