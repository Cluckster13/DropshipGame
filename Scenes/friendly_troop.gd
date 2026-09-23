class_name FriendlyTroop
extends RigidBody3D

enum States {IDLE, PASSENGER, MOVING}
var state : States = States.IDLE
var target_nav : Vector3

@onready var nav: NavigationAgent3D = $NavigationAgent3D


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	if state == States.IDLE:
		return
	elif state == States.PASSENGER:
		target_nav = Vector3(0,0,0)
	elif state == States.MOVING:
		if target_nav != null or target_nav == Vector3(0,0,0):
			pass
