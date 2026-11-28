class_name Squad
extends Node
## Groups Troops under one set of orders (a fireteam / squad). Put Troop
## instances as children (they're picked up in _ready) or call add_member().
##
## Plain Node on purpose: it has no transform, so troops underneath keep
## their own world positions instead of being dragged around by the parent.
##
## Movement: the leader (first available member) navigates to the goal at a
## slightly reduced pace; everyone else continuously re-targets their slot
## in a vee behind the leader, speeding up when they fall behind. On arrival
## a MOVE order settles into the vee, a CAPTURE order fans out into a ring
## inside the capture zone.
##
## Semi-autonomous: with auto_advance on, the squad picks its own next
## objective once everyone is off the helicopter and again after each
## capture. The player or a battle director can override at any time with
## order_move / order_capture / order_hold.

signal order_completed(squad: Squad)
signal wiped_out(squad: Squad)

enum Orders {NONE, HOLD, MOVE, CAPTURE}

@export var squad_name : String = "Alpha"
## 1 = friendly, -1 = enemy. Pushed onto every member.
@export_range(-1, 1, 1) var team : int = Troop.TEAM_FRIENDLY
## Choose the next objective by itself after landing / capturing
@export var auto_advance : bool = true
## Soldier quality pushed onto every member (see Troop.skill).
## 1 = baseline, <1 = green/sloppy, >1 = veteran.
@export_range(0.25, 2.0, 0.05) var skill : float = 1.0

@export_group("Vee formation")
## Distance between neighbours along each arm of the vee (metres)
@export var vee_spacing : float = 2.5
## Angle of each arm away from straight-behind. 45 = classic vee,
## lower = narrow / deep, higher = wide / shallow.
@export_range(10.0, 80.0, 1.0) var vee_angle_deg : float = 45.0
## Leader walks at this fraction of full speed so followers can keep up
@export_range(0.5, 1.0, 0.05) var leader_pace : float = 0.8
## Followers this far (m) from their slot run at max catch-up speed
@export var catch_up_distance : float = 6.0
## Max follower speed multiplier when catching up
@export var catch_up_speed : float = 1.25
## Followers aim this many seconds ahead of the leader's motion (smooths stop-start)
@export var slot_lookahead : float = 1.0
## How often follower slots are recomputed (s)
@export var formation_update_interval : float = 0.2

@export_group("Capture")
## Start fanning out into the capture ring when the leader is this close
@export var deploy_distance : float = 12.0
## Gap between troops in the capture ring (metres)
@export var formation_spacing : float = 2.0

@export_group("Vehicle hunting")
## Anti-tank team: once dropped off, stays around where it landed (its home)
## and goes after any enemy vehicle within hunt_radius of it. Ignores
## objectives.
@export var hunt_vehicles : bool = false
@export var hunt_radius : float = 400.0
## Closes to about this distance (m) from a vehicle, then lets rockets fly
@export var hunt_standoff : float = 140.0
## Seconds between looking for prey
@export var hunt_interval : float = 2.0

@export_group("Combat")
## Seconds with nobody engaged before the squad resumes its order
@export var contact_clear_delay : float = 3.0
## A known enemy that nobody has seen for this long is forgotten, so the
## squad can't stay pinned forever by someone it can't reach
@export var enemy_memory_time : float = 15.0

var members    : Array[Troop] = []
## True from first shot until contact_clear_delay after the last one
var in_contact : bool = false
var last_contact_position : Vector3
## Enemies this squad has engaged and is still worried about: Troop -> last seen time (s)
var known_enemies : Dictionary = {}
var _contact_clear_timer : float = 0.0
var order      : Orders = Orders.NONE
var order_position : Vector3
var target_obj : Objective = null

var _travelling : bool = false
var _formation_timer : float = 0.0

## Hunting: where the team was deployed, and what it's after
var hunt_home : Vector3
var has_hunt_home : bool = false
var hunt_target : Vehicle = null
var _hunt_timer : float = 0.0

func _ready() -> void:
	for child in get_children():
		if child is Troop:
			add_member(child)

func _physics_process(delta: float) -> void:
	if hunt_vehicles and has_hunt_home:
		_hunt_timer -= delta
		if _hunt_timer <= 0.0:
			_hunt_timer = hunt_interval
			_update_hunt()
	if in_contact:
		_update_contact(delta)
		return   # formation movement is paused while fighting
	if not _travelling:
		return
	var lead := leader()
	if lead == null:
		return

	_formation_timer -= delta
	if _formation_timer <= 0.0:
		_formation_timer = formation_update_interval
		_update_formation(lead)

	var to_goal := order_position - lead.global_position
	to_goal.y = 0.0
	if order == Orders.CAPTURE and to_goal.length() <= deploy_distance:
		_deploy_ring()
	elif order == Orders.MOVE and lead.state == Troop.States.IDLE:
		_settle_vee(lead)

# ---------------------------------------------------------------- membership

func add_member(troop: Troop) -> void:
	if troop in members:
		return
	if troop.squad and troop.squad != self:
		troop.squad.remove_member(troop)
	members.append(troop)
	troop.squad = self
	troop.team  = team
	troop.skill = skill
	troop.died.connect(_on_member_died)
	troop.arrived.connect(_on_member_arrived)
	troop.disembarked.connect(_on_member_disembarked)
	troop.contact.connect(_on_member_contact)

func remove_member(troop: Troop) -> void:
	members.erase(troop)
	if not is_instance_valid(troop):
		return
	if troop.squad == self:
		troop.squad = null
	troop.speed_scale = 1.0
	for pair in [[troop.died, _on_member_died], [troop.arrived, _on_member_arrived], [troop.disembarked, _on_member_disembarked], [troop.contact, _on_member_contact]]:
		if pair[0].is_connected(pair[1]):
			pair[0].disconnect(pair[1])

func alive_members() -> Array[Troop]:
	var out: Array[Troop] = []
	for t in members:
		if is_instance_valid(t) and t.is_alive():
			out.append(t)
	return out

## Members on the ground and able to take a move order
func available_members() -> Array[Troop]:
	var out: Array[Troop] = []
	for t in alive_members():
		if t.is_available():
			out.append(t)
	return out

## Point man: first member on the ground. Changes automatically if he dies.
func leader() -> Troop:
	var units := available_members()
	return units[0] if not units.is_empty() else null

func centroid() -> Vector3:
	var units := alive_members()
	if units.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for t in units:
		sum += t.global_position
	return sum / units.size()

# ---------------------------------------------------------------- orders

## Travel in a vee; leader ends on `pos`, squad settles in the vee around him
func order_move(pos: Vector3) -> void:
	_clear_target_obj()
	order = Orders.MOVE
	_start_travel(pos)

## Travel in a vee, then fan out into a ring inside the capture zone and
## hold until it flips
func order_capture(obj: Objective) -> void:
	_clear_target_obj()
	if obj == null:
		order_hold()
		return
	target_obj = obj
	target_obj.captured.connect(_on_objective_captured)
	order = Orders.CAPTURE
	_start_travel(obj.global_position)

func order_hold() -> void:
	_clear_target_obj()
	_travelling = false
	order = Orders.HOLD
	for t in available_members():
		t.speed_scale = 1.0
		t.stop()

## Anti-tank teams: guard the area around `home` and hunt vehicles in it
func order_hunt(home: Vector3) -> void:
	hunt_vehicles = true
	auto_advance = false
	hunt_home = home
	has_hunt_home = true
	_hunt_timer = 0.0
	order_move(home)

## A member that went off on its own (planting a charge) wants back in
func member_rejoin(troop: Troop) -> void:
	if not troop.is_available() or _travelling:
		return   # the formation update picks him up on its own
	match order:
		Orders.MOVE, Orders.CAPTURE:
			var offset := Vector3(randf_range(-4.0, 4.0), 0.0, randf_range(-4.0, 4.0))
			troop.move_to(order_position + offset)

func _update_hunt() -> void:
	var units := alive_members()
	if units.is_empty():
		return
	var here := centroid()
	# Keep the current prey while it lives and stays in our patch
	if not _is_prey(hunt_target):
		hunt_target = null
		var best_d := INF
		for node in get_tree().get_nodes_in_group("Vehicles"):
			if _is_prey(node):
				var d := here.distance_to(node.global_position)
				if d < best_d:
					best_d = d
					hunt_target = node
	if hunt_target:
		var to_us := here - hunt_target.global_position
		to_us.y = 0.0
		if to_us.length() > hunt_standoff:
			var spot := hunt_target.global_position + to_us.normalized() * hunt_standoff * 0.8
			if order != Orders.MOVE or order_position.distance_to(spot) > 25.0 or not _travelling:
				order_move(spot)
	elif _flat(here - hunt_home).length() > 30.0 and not (order == Orders.MOVE and _travelling):
		order_move(hunt_home)   # nothing to hunt: go back home

## Untyped: may be a freed vehicle
func _is_prey(v) -> bool:
	return is_instance_valid(v) and v is Vehicle and v.is_alive() and not v.is_carried() \
		and v.team != team and v.team != 0 \
		and _flat(v.global_position - hunt_home).length() <= hunt_radius

func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)

func advance_to_nearest_objective() -> void:
	var obj := Objective.nearest_not_owned_by(get_tree(), centroid(), team)
	print("[Squad %s] advancing to %s" % [squad_name, str(obj.name) if obj else "nothing (holding)"])
	order_capture(obj)

# ---------------------------------------------------------------- formation movement

func _start_travel(dest: Vector3) -> void:
	order_position = dest
	_travelling = true
	_formation_timer = 0.0   # update on the very next physics frame

func _update_formation(lead: Troop) -> void:
	# Leader heads for the goal at a steady pace (re-issued in case the
	# leader changed because the previous one died or got on an aircraft)
	lead.speed_scale = leader_pace
	if lead.state != Troop.States.MOVING or not lead.nav.target_position.is_equal_approx(order_position):
		lead.move_to(order_position)

	var facing := _leader_facing(lead)
	var forward := -facing.z
	# Aim followers where their slot is *about to be*, so they keep walking
	# alongside the leader instead of reaching a stale point and stopping
	var lead_vel := Vector3(lead.velocity.x, 0.0, lead.velocity.z)
	var gain := (catch_up_speed - leader_pace) / catch_up_distance

	var units := available_members()
	for i in range(1, units.size()):
		var t := units[i]
		var slot := lead.global_position + facing * _vee_offset(i)
		var err := slot - t.global_position
		err.y = 0.0
		# Behind the slot -> speed up, ahead of it -> ease off.
		# Sideways error also adds a little speed so they can cut across.
		var behind := err.dot(forward)
		var sideways := absf(err.dot(facing.x))
		t.speed_scale = clampf(leader_pace + (behind + sideways * 0.5) * gain, 0.5, catch_up_speed)
		t.move_to(slot + lead_vel * slot_lookahead)

func _settle_vee(lead: Troop) -> void:
	_travelling = false
	var facing := _leader_facing(lead)
	var units := available_members()
	for i in units.size():
		units[i].speed_scale = 1.0
		if i > 0:
			units[i].move_to(lead.global_position + facing * _vee_offset(i))

func _deploy_ring() -> void:
	_travelling = false
	var units := available_members()
	for i in units.size():
		units[i].speed_scale = 1.0
		units[i].move_to(order_position + _ring_offset(i, units.size()))

## Which way "forward" is for the formation. Uses the leader's body yaw,
## which is already smoothed by Troop.turn_speed, so slots don't jitter.
func _leader_facing(lead: Troop) -> Basis:
	if lead.state != Troop.States.MOVING:
		var to_goal := order_position - lead.global_position
		to_goal.y = 0.0
		if to_goal.length_squared() > 0.01:
			return Basis.looking_at(to_goal.normalized())
	return Basis(Vector3.UP, lead.global_rotation.y)   # troop forward is -Z

## Slot i in the vee, in leader space (-Z forward, +Z behind).
## 0 = leader at the point; then alternating right/left arm, one step back each pair.
func _vee_offset(i: int) -> Vector3:
	if i == 0:
		return Vector3.ZERO
	@warning_ignore("integer_division")
	var step := (i + 1) / 2   # 1,1,2,2,3,3... (intentional int division)
	var side := 1.0 if i % 2 == 1 else -1.0
	var angle := deg_to_rad(vee_angle_deg)
	var along := step * vee_spacing
	return Vector3(side * along * sin(angle), 0.0, along * cos(angle))

func _ring_offset(i: int, count: int) -> Vector3:
	if count <= 1:
		return Vector3.ZERO
	var radius := maxf(formation_spacing, count * formation_spacing / TAU) * 2
	var angle  := TAU * i / count
	return Vector3(cos(angle), 0.0, sin(angle)) * radius

# ---------------------------------------------------------------- contact

## Halt and fight: the whole squad stops where it is. Whoever can see an
## enemy shoots; the rest hold position. Order is kept and resumed later.
func _on_member_contact(_troop: Troop, enemy: Node3D) -> void:
	last_contact_position = enemy.global_position
	known_enemies[enemy] = _now()
	_contact_clear_timer = 0.0
	if in_contact:
		return
	in_contact = true
	_travelling = false
	print("[Squad %s] contact!" % squad_name)
	for t in available_members():
		t.speed_scale = 1.0
		if t.state != Troop.States.COMBAT:
			t.stop()

## Contact only ends when nobody is fighting AND every enemy we know about
## is dead or hasn't been seen for enemy_memory_time. Stops the squad from
## strolling back into the fire after killing the nearest enemy.
func _update_contact(delta: float) -> void:
	var now := _now()
	var fighting := false
	for t in alive_members():
		if t.state == Troop.States.COMBAT:
			fighting = true
			if is_instance_valid(t.target):
				known_enemies[t.target] = now   # still in sight: refresh
				last_contact_position = t.target.global_position

	for e in known_enemies.keys():
		if not is_instance_valid(e) or not e.is_alive() or now - known_enemies[e] > enemy_memory_time:
			known_enemies.erase(e)

	if fighting or not known_enemies.is_empty():
		_contact_clear_timer = 0.0
		return
	_contact_clear_timer += delta
	if _contact_clear_timer >= contact_clear_delay:
		in_contact = false
		print("[Squad %s] contact clear, resuming %s" % [squad_name, Orders.keys()[order]])
		_resume_order()

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _resume_order() -> void:
	match order:
		Orders.CAPTURE:
			if target_obj and is_instance_valid(target_obj):
				order_capture(target_obj)
			elif auto_advance:
				advance_to_nearest_objective()
		Orders.MOVE:
			order_move(order_position)
		_:
			pass   # NONE / HOLD: stay put

# ---------------------------------------------------------------- member events

func _on_member_disembarked(_troop: Troop) -> void:
	if not auto_advance and not hunt_vehicles:
		return
	# Wait until the whole squad is clear of the aircraft before moving off
	for t in alive_members():
		if t.state == Troop.States.PASSENGER or t.state == Troop.States.MOVING_TO_EXIT:
			return
	if hunt_vehicles:
		# Where we were dropped off is the patch we guard
		if not has_hunt_home:
			print("[Squad %s] deployed, hunting vehicles within %dm" % [squad_name, roundi(hunt_radius)])
			order_hunt(centroid())
		return
	advance_to_nearest_objective()

func _on_member_arrived(_troop: Troop) -> void:
	# Followers reach their slot constantly while travelling; only care once settled
	if order != Orders.MOVE or _travelling:
		return
	for t in available_members():
		if t.state == Troop.States.MOVING:
			return
	order_completed.emit(self)

func _on_member_died(troop: Troop) -> void:
	remove_member(troop)
	if alive_members().is_empty():
		print("[Squad %s] wiped out" % squad_name)
		_travelling = false
		in_contact = false
		known_enemies.clear()
		_clear_target_obj()
		wiped_out.emit(self)

func _on_objective_captured(by_team: int) -> void:
	if by_team != team:
		return   # the other side took it; it's still a valid target for us
	order_completed.emit(self)
	if auto_advance:
		advance_to_nearest_objective()
	else:
		order_hold()

func _clear_target_obj() -> void:
	if target_obj and is_instance_valid(target_obj) and target_obj.captured.is_connected(_on_objective_captured):
		target_obj.captured.disconnect(_on_objective_captured)
	target_obj = null

func debug_info() -> Dictionary:
	return {
		"Squad": squad_name,
		"Team": team,
		"Order": Orders.keys()[order],
		"Travelling": _travelling,
		"In_Contact": in_contact,
		"Known_Enemies": known_enemies.size(),
		"Alive": alive_members().size(),
		"Leader": str(leader().name) if leader() else "-",
		"Target": str(target_obj.name) if target_obj else "-",
	}
