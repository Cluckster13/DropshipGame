class_name BuyMenu
extends CanvasLayer
## Requisition screen. Layout is nodes in BuyMenu.tscn; each squad is a
## SquadRow.tscn added to %Rows. Pure UI: emits purchase_requested and lets
## BuyZone decide what happens.

signal purchase_requested(squad_type: SquadType)
signal close_requested

## Template for each squad's row
@export var row_scene : PackedScene = preload("res://Scenes/SquadRow.tscn")

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

## Rebuild the row list for these squad types
func set_squad_types(types: Array) -> void:
	for r in _rows:
		r.queue_free()
	_rows.clear()
	for t in types:
		var row := row_scene.instantiate() as SquadRow
		rows_box.add_child(row)
		row.setup(t)
		row.buy_pressed.connect(func(st): purchase_requested.emit(st))
		_rows.append(row)

## Update affordability / seat checks. free_seats < 0 = unknown.
func refresh(funds: int, free_seats: int, total_seats: int) -> void:
	funds_label.text = "$ %d" % funds
	seats_label.text = "Seats free  %d / %d" % [free_seats, total_seats] if free_seats >= 0 else ""
	for r in _rows:
		r.refresh(funds, free_seats)
