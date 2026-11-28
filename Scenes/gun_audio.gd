class_name GunAudio
extends Node3D
## Minigun sounds for one DoorGun. Put it under the gun with the players as
## its children (see testheli.tscn); this only starts and stops them.
##
## A burst: the windup one-shot plays while the barrels spin up (the gun
## doesn't fire until they're at speed), then one of the fire loops (picked
## at random each burst, for variety) starts on the first round. When rounds
## stop coming for stop_delay seconds the loop stops and the shutdown
## (spin-down) one-shot plays. Letting go during the windup also spins down.

@export var gun : DoorGun
## Looping fire sounds; one is picked per burst
@export var fire_loops : Array[AudioStreamPlayer3D] = []
@export var windup : AudioStreamPlayer3D
@export var shutdown : AudioStreamPlayer3D
## No round for this long (s) = the burst is over
@export var stop_delay : float = 0.15
## Random pitch variation per burst, so two guns don't sound identical
@export var pitch_variation : float = 0.04

var _active : AudioStreamPlayer3D = null
var _since_shot : float = INF

func _ready() -> void:
	if gun == null:
		gun = get_parent() as DoorGun
	if gun:
		gun.fired.connect(_on_fired)
		gun.spin_up_started.connect(_on_spin_up_started)
		gun.spin_up_cancelled.connect(_on_spin_up_cancelled)

## Trigger pulled: barrels start winding up (no rounds yet)
func _on_spin_up_started() -> void:
	if shutdown:
		shutdown.stop()
	if windup:
		windup.play()

## Let go before it got up to speed: wind back down
func _on_spin_up_cancelled() -> void:
	if windup:
		windup.stop()
	if shutdown:
		shutdown.play()

func _on_fired() -> void:
	_since_shot = 0.0
	if _active and _active.playing:
		return
	# First round of a burst: the fire loop takes over from the windup
	if fire_loops.is_empty():
		return
	_active = fire_loops.pick_random()
	_active.pitch_scale = 1.0 + randf_range(-pitch_variation, pitch_variation)
	_active.play()
	if shutdown:
		shutdown.stop()

func _process(delta: float) -> void:
	if _active == null:
		return
	_since_shot += delta
	if _since_shot > stop_delay:
		_active.stop()
		_active = null
		if windup:
			windup.stop()
		if shutdown:
			shutdown.play()
