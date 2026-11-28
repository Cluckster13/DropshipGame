class_name BuyMenu
extends CanvasLayer
## Requisition screen. Layout is nodes in BuyMenu.tscn; each purchasable is
## a SquadRow.tscn added to %Rows, under a SectionHeader.tscn per group
## (Infantry / Vehicles). Pure UI: emits purchase_requested and lets BuyZone
## decide what happens.

## item is a SquadType or a VehicleType
signal purchase_requested(item: Resource)
signal close_requested

## Template for each item's row
@export var row_scene : PackedScene = preload("res://Scenes/SquadRow.tscn")
## Template for the group titles
@export var header_scene : PackedScene = preload("res://Scenes/SectionHeader.tscn")
@export var infantry_title : String = "INFANTRY  ·  boards the helicopter"
@export var vehicles_title : String = "VEHICLES  ·  delivered at base"

@onready var funds_label : Label = %Funds
@onready var seats_label : Label = %Seats
@onready var rows_box : Container = %Rows
@onready var close_button : Button = %CloseButton

var _rows : Array[SquadRow] = []

func _ready() -> void:
	close_button.pressed.connect(func(): close_requested.emit())
	# The preview rows in the scene are just for layout in the editor
	for c in rows_box.get_children():
		c.queue_free()

## Rebuild the list: squads first, then vehicles
func set_items(squads: Array, vehicles: Array = []) -> void:
	for c in rows_box.get_children():
		c.queue_free()
	_rows.clear()
	if not squads.is_empty():
		_add_header(infantry_title)
		for t in squads:
			_add_row(t)
	if not vehicles.is_empty():
		_add_header(vehicles_title)
		for t in vehicles:
			_add_row(t)

## Old name, kept for anything still calling it
func set_squad_types(types: Array) -> void:
	set_items(types)

func _add_header(text: String) -> void:
	var h := header_scene.instantiate() as Label
	h.text = text
	rows_box.add_child(h)

func _add_row(item: Resource) -> void:
	var row := row_scene.instantiate() as SquadRow
	rows_box.add_child(row)
	row.setup(item)
	row.buy_pressed.connect(func(it): purchase_requested.emit(it))
	_rows.append(row)

## Update affordability / seat checks. free_seats < 0 = unknown.
func refresh(funds: int, free_seats: int, total_seats: int) -> void:
	funds_label.text = "$ %d" % funds
	seats_label.text = "Seats free  %d / %d" % [free_seats, total_seats] if free_seats >= 0 else ""
	for r in _rows:
		r.refresh(funds, free_seats)
