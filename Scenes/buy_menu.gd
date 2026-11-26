class_name BuyMenu
extends CanvasLayer
## Requisition screen: one row per SquadType with tier, stats, cost and a
## Buy button. Pure UI: emits purchase_requested and lets BuyZone decide.

signal purchase_requested(squad_type: SquadType)
signal close_requested

@export var font_size : int = 18
@export var text_color   : Color = Color(0.85, 1.0, 0.85)
@export var dim_color    : Color = Color(0.55, 0.7, 0.55)
@export var money_color  : Color = Color(1.0, 0.8, 0.3)
@export var bad_color    : Color = Color(1.0, 0.4, 0.35)
@export var panel_color  : Color = Color(0.05, 0.08, 0.05, 0.92)
@export var row_color    : Color = Color(1.0, 1.0, 1.0, 0.05)

var _funds_label : Label
var _seats_label : Label
var _list : VBoxContainer
var _rows : Array = []   # [{type, button, cost_label}]

func _init() -> void:
	layer = 20   # above the flight HUD

func _ready() -> void:
	_build()

## Rebuild the row list for these squad types
func set_squad_types(types: Array) -> void:
	for r in _rows:
		r["panel"].queue_free()
	_rows.clear()
	for t in types:
		_rows.append(_make_row(t))

## Update affordability / seat checks. free_seats < 0 = unknown.
func refresh(funds: int, free_seats: int, total_seats: int) -> void:
	_funds_label.text = "$ %d" % funds
	_seats_label.text = "Seats free  %d / %d" % [free_seats, total_seats] if free_seats >= 0 else ""
	for r in _rows:
		var t: SquadType = r["type"]
		var affordable := funds >= t.cost
		var fits := free_seats < 0 or t.size <= free_seats
		var btn: Button = r["button"]
		btn.disabled = not (affordable and fits)
		if not affordable:
			btn.text = "Need $%d" % (t.cost - funds)
		elif not fits:
			btn.text = "No room"
		else:
			btn.text = "Buy"
		r["cost_label"].add_theme_color_override("font_color", money_color if affordable else bad_color)

# ---------------------------------------------------------------- build

func _build() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)   # also swallows clicks behind the menu

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(680, 0)
	panel.add_theme_stylebox_override("panel", _box(panel_color, 16, 6))
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	# Header: title + funds
	var header := HBoxContainer.new()
	vbox.add_child(header)
	var title := _label("REQUISITION", font_size + 10, text_color)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_funds_label = _label("$ 0", font_size + 10, money_color)
	header.add_child(_funds_label)

	_seats_label = _label("", font_size, dim_color)
	vbox.add_child(_seats_label)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 6)
	vbox.add_child(_list)

	var footer := HBoxContainer.new()
	vbox.add_child(footer)
	var hint := _label("Squads run to the aircraft and board.   B / Esc to close", font_size - 4, dim_color)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(hint)
	var close := Button.new()
	close.text = "Close"
	close.add_theme_font_size_override("font_size", font_size)
	close.pressed.connect(func(): close_requested.emit())
	footer.add_child(close)

func _make_row(t: SquadType) -> Dictionary:
	var row_panel := PanelContainer.new()
	row_panel.add_theme_stylebox_override("panel", _box(row_color, 10, 4))
	_list.add_child(row_panel)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 16)
	row_panel.add_child(hbox)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 2)
	hbox.add_child(info)

	var name_line := HBoxContainer.new()
	info.add_child(name_line)
	name_line.add_child(_label(t.display_name, font_size + 4, text_color))
	name_line.add_child(_label("  " + "★".repeat(t.tier) + "☆".repeat(3 - t.tier), font_size + 2, money_color))

	if t.description != "":
		var desc := _label(t.description, font_size - 4, dim_color)
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.custom_minimum_size = Vector2(440, 0)
		info.add_child(desc)
	info.add_child(_label(t.stats_text(), font_size - 3, text_color))

	var buy_col := VBoxContainer.new()
	buy_col.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_child(buy_col)
	var cost_label := _label("$ %d" % t.cost, font_size + 4, money_color)
	cost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	buy_col.add_child(cost_label)
	var btn := Button.new()
	btn.text = "Buy"
	btn.custom_minimum_size = Vector2(110, 34)
	btn.add_theme_font_size_override("font_size", font_size)
	btn.pressed.connect(func(): purchase_requested.emit(t))
	buy_col.add_child(btn)

	return {"type": t, "panel": row_panel, "button": btn, "cost_label": cost_label}

func _box(col: Color, margin: int, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = margin
	sb.content_margin_right = margin
	sb.content_margin_top = margin * 0.75
	sb.content_margin_bottom = margin * 0.75
	return sb

func _label(text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l
