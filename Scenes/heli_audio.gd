class_name HeliAudio
extends Node3D
## Helicopter sound mixer. The players are child nodes (set up in
## testheli.tscn, under Audio); this only starts/stops them and sets their
## volume and pitch from the aircraft each frame.
##
##   start   - one-shot when the engine is switched on (R). Fades out once the
##             rotor is up to speed and the loops have taken over.
##   idle    - loop, only while landed. Louder the faster the rotor turns.
##   forward - loop, whenever airborne (crossfades with idle at lift-off).
##   cabin   - one-shots, a random one each time a troop climbs aboard.
## Pitch of the loops follows rotor rpm, so spool up / wind down sound right.

@export var aircraft : HeliBase
@export var start : AudioStreamPlayer3D
@export var idle : AudioStreamPlayer3D
@export var forward : AudioStreamPlayer3D
## Played (one at random) when a troop gets on board. Empty = none.
@export var cabin_sounds : Array[AudioStreamPlayer3D] = []

@export_group("Mix")
## Overall loudness of the loops (dB), on top of each player's own volume
@export var loop_volume_db : float = 0.0
## Loops fade in between these rotor fractions (0..1) during start-up, so
## the start sound carries the spool-up
@export var loop_fade_in : Vector2 = Vector2(0.35, 0.9)
## Seconds to fade the start sound out once the rotor reaches full speed
@export var start_fade_out_time : float = 2.5
## Idle plays only while landed, forward while airborne. Seconds to
## crossfade between them at lift-off / touchdown.
@export var liftoff_crossfade_time : float = 1.0

@export_group("Pitch")
## Loop pitch at the lowest audible rpm and at full rpm
@export var pitch_range : Vector2 = Vector2(0.55, 1.0)
## Extra pitch at full collective (blades working harder)
@export var collective_pitch_boost : float = 0.04

var _was_on : bool = false
var _start_gain : float = 1.0
var _air_blend : float = 0.0   # 0 = landed (idle), 1 = airborne (forward)
var _passengers : PassengerHandler
var _last_passenger_count : int = 0

func _ready() -> void:
	if aircraft == null:
		aircraft = get_parent() as HeliBase
	for c in aircraft.get_children():
		if c is PassengerHandler:
			_passengers = c
	for p in [start, idle, forward]:
		if p:
			p.stop()
	if aircraft:
		aircraft.destroyed.connect(_on_destroyed)

func _process(delta: float) -> void:
	if aircraft == null:
		return
	var rpm := aircraft.rotor_fraction()
	var engine_on := aircraft.engine_on and not aircraft.is_destroyed

	# --- Start-up one-shot
	if engine_on and not _was_on and start:
		_start_gain = 1.0
		start.volume_db = 0.0
		start.play()
	_was_on = engine_on
	if start and start.playing:
		if not engine_on or rpm >= 0.98:
			_start_gain = move_toward(_start_gain, 0.0, delta / maxf(start_fade_out_time, 0.01))
			start.volume_db = _db(_start_gain)
			if _start_gain <= 0.0:
				start.stop()

	# --- Loops: on while the rotor is turning, louder and higher as it spins up
	var audible := rpm > 0.02
	var loop_gain := rpm * smoothstep(loop_fade_in.x, loop_fade_in.y, rpm) if engine_on else rpm * rpm
	var collective := clampf(aircraft._collective_current, 0.0, 1.0)
	# Idle on the ground, forward as soon as we're off it (smoothed so
	# lift-off and touchdown crossfade instead of snapping)
	var airborne := 0.0 if aircraft.is_landed() else 1.0
	_air_blend = move_toward(_air_blend, airborne, delta / maxf(liftoff_crossfade_time, 0.01))
	var power := _air_blend
	var pitch := lerpf(pitch_range.x, pitch_range.y, rpm) + collective * collective_pitch_boost

	# Equal-power crossfade so the total loudness stays even
	_drive_loop(idle, audible, loop_gain * cos(power * PI * 0.5), pitch)
	_drive_loop(forward, audible, loop_gain * sin(power * PI * 0.5), pitch)

	# --- Troops climbing aboard
	if _passengers:
		var n := _passengers.passenger_count()
		if n > _last_passenger_count and not cabin_sounds.is_empty():
			var p: AudioStreamPlayer3D = cabin_sounds.pick_random()
			if p:
				p.play()
		_last_passenger_count = n

func _drive_loop(player: AudioStreamPlayer3D, audible: bool, gain: float, pitch: float) -> void:
	if player == null:
		return
	if not audible:
		if player.playing:
			player.stop()
		return
	if not player.playing:
		player.play()
	player.volume_db = loop_volume_db + _db(gain)
	player.pitch_scale = maxf(pitch, 0.05)

func _db(gain: float) -> float:
	return linear_to_db(maxf(gain, 0.0001))

## Shot down: the start-up sound cuts; the loops wind down with the rotor
func _on_destroyed() -> void:
	if start:
		start.stop()
	_was_on = false
