class_name BattleManager
extends Node
## Runs the match: enemy reinforcement waves paid for with tickets, and the
## win / lose conditions. One per level.
##
##   Tickets - every enemy troop spawned costs 1 ticket. When the enemy is
##             out of tickets and its last troop dies, the player wins.
##   Defeat  - the enemy owns every objective for hold_to_lose seconds.
##
## Waves: every wave_interval seconds (first one after first_wave_delay) the
## enemy sends squads_per_wave squads from a spawn point, as long as it has
## tickets and isn't over max_enemies_alive. Later waves bring better troops.
## Each enemy squad is sent at an objective it doesn't own, nearer ones more
## often; once the enemy owns everything, new squads reinforce held points.
## Idle enemy squads get a new target every director_interval seconds.
##
## The HUD finds this node through the "Battle" group.

signal tickets_changed(tickets: int)
signal wave_spawned(wave: int)
signal game_over(player_won: bool)

@export_group("Enemy")
@export var starting_tickets : int = 150
## Where enemy squads appear (picked at random per squad)
@export var spawn_points : Array[Node3D] = []
## Squads to choose from. Empty = every SquadType in squad_types_dir.
@export var enemy_squad_types : Array[SquadType] = []
@export_dir var squad_types_dir : String = "res://Resources/SquadTypes"
@export var troop_scene : PackedScene = preload("res://Scenes/Troop.tscn")
## Where enemy Squad nodes are added. Empty = the current scene root.
@export var squad_parent : Node

@export_group("Waves")
@export var first_wave_delay : float = 20.0
@export var wave_interval : float = 60.0
@export_range(1, 10, 1) var squads_per_wave : int = 2
## Don't spawn more while this many enemy troops are already alive
@export var max_enemies_alive : int = 36
## Tier 2 squads join from this wave on, tier 3 from twice this
@export_range(1, 20, 1) var waves_per_tier : int = 3
## Spacing between troops when a squad spawns (m)
@export var spawn_spacing : float = 1.6

@export_group("Vehicles")
## Vehicles the enemy can send. Empty = every VehicleType in vehicle_types_dir.
@export var enemy_vehicle_types : Array[VehicleType] = []
@export_dir var vehicle_types_dir : String = "res://Resources/VehicleTypes"
## First wave that brings a vehicle, then one every vehicle_wave_every waves
@export var first_vehicle_wave : int = 2
@export_range(1, 10, 1) var vehicle_wave_every : int = 2
@export var max_enemy_vehicles : int = 4
## Where enemy vehicles are added. Empty = the current scene root.
@export var vehicle_parent : Node
## Enemy AA emplacements are set up this far (m) from an objective it holds
@export var emplacement_distance : Vector2 = Vector2(25.0, 45.0)

@export_group("Rules")
## Enemy must hold every objective this long (s) for the player to lose
@export var hold_to_lose : float = 30.0
## How often idle enemy squads are given something to do (s)
@export var director_interval : float = 8.0

var tickets : int = 0
var wave : int = 0
var is_over : bool = false
var player_won : bool = false
## Seconds the enemy has held every objective (0 when it doesn't)
var enemy_hold_time : float = 0.0

var _wave_timer : float = 0.0
var _director_timer : float = 0.0
var _enemy_squads : Array[Squad] = []
var _squad_count : int = 0

func _ready() -> void:
	add_to_group("Battle")
	tickets = starting_tickets
	_wave_timer = first_wave_delay
	if enemy_squad_types.is_empty():
		for r in _load_dir(squad_types_dir):
			if r is SquadType:
				enemy_squad_types.append(r)
	if enemy_vehicle_types.is_empty():
		for r in _load_dir(vehicle_types_dir):
			if r is VehicleType:
				enemy_vehicle_types.append(r)
	enemy_squad_types.sort_custom(func(a, b): return a.tier < b.tier)
	var economy := get_node_or_null("/root/Economy")
	if economy:
		economy.reset()   # autoloads survive a restart; start the match fresh

func _process(delta: float) -> void:
	if is_over:
		return
	_tick_waves(delta)
	_tick_director(delta)
	_check_defeat(delta)
	_check_victory()

func _unhandled_input(event: InputEvent) -> void:
	if is_over and event.is_action_pressed("ui_accept"):
		var loading := get_node_or_null("/root/Loading")
		if loading:
			loading.reload()   # back through the loading screen so nav is ready again
		else:
			get_tree().reload_current_scene()

# ---------------------------------------------------------------- queries (HUD)

## Seconds until the next wave, or -1 if no more waves are coming
func time_to_next_wave() -> float:
	return _wave_timer if tickets > 0 and not is_over else -1.0

## Enemy troops still alive (vehicles not included)
func enemies_alive() -> int:
	var n := 0
	for node in get_tree().get_nodes_in_group("Troops"):
		var t := node as Troop
		if t and t.team == Troop.TEAM_ENEMY and t.is_alive():
			n += 1
	return n

func enemy_vehicles_alive() -> int:
	return _vehicles_alive(Troop.TEAM_ENEMY)

func _vehicles_alive(team: int) -> int:
	var n := 0
	for node in get_tree().get_nodes_in_group("Vehicles"):
		var v := node as Vehicle
		if v and v.team == team and v.is_alive():
			n += 1
	return n

## True while the enemy owns every objective (the defeat clock is running)
func enemy_holds_all() -> bool:
	var objectives := get_tree().get_nodes_in_group("Objectives")
	if objectives.is_empty():
		return false
	for o in objectives:
		if (o as Objective).owner_team != Troop.TEAM_ENEMY:
			return false
	return true

# ---------------------------------------------------------------- waves

func _tick_waves(delta: float) -> void:
	if tickets <= 0:
		return
	_wave_timer -= delta
	if _wave_timer > 0.0:
		return
	_wave_timer = wave_interval
	_spawn_wave()

func _spawn_wave() -> void:
	if spawn_points.is_empty() or enemy_squad_types.is_empty():
		push_warning("BattleManager: no spawn points or squad types, can't spawn")
		return
	wave += 1
	var spawned := 0
	for i in squads_per_wave:
		var t := _pick_type()
		var room := max_enemies_alive - enemies_alive()
		var size := mini(mini(t.size, tickets), room)
		if size <= 0:
			break
		_spawn_squad(t, size)
		spawned += size
	if wave >= first_vehicle_wave and (wave - first_vehicle_wave) % vehicle_wave_every == 0:
		if _spawn_vehicle():
			spawned += 1
	if spawned > 0:
		print("[Battle] Wave %d: %d enemy troops/vehicles (%d tickets left)" % [wave, spawned, tickets])
		wave_spawned.emit(wave)

func _max_tier() -> int:
	@warning_ignore("integer_division")
	return 1 + (wave - 1) / waves_per_tier

## Better squads unlock as waves go on. Anti-tank teams only come out once
## the player has vehicles to hunt.
func _pick_type() -> SquadType:
	var max_tier := _max_tier()
	var player_has_vehicles := _vehicles_alive(Troop.TEAM_FRIENDLY) > 0
	var pool := enemy_squad_types.filter(func(t): return t.tier <= max_tier and (player_has_vehicles or not t.hunt_vehicles))
	if pool.is_empty():
		pool = [enemy_squad_types[0]]
	return pool.pick_random()

func _spawn_squad(t: SquadType, size: int) -> void:
	_squad_count += 1
	var squad := t.make_squad(troop_scene, Troop.TEAM_ENEMY,
		"Enemy%s_%d" % [t.display_name.replace(" ", ""), _squad_count], "Enemy %s %d" % [t.display_name, _squad_count])
	# Short-handed squad (out of tickets / room): drop the extras
	var troops := squad.get_children()
	for i in range(size, troops.size()):
		squad.remove_child(troops[i])
		troops[i].free()

	var spawn: Node3D = spawn_points.pick_random()
	var origin := spawn.global_position + Vector3(randf_range(-6, 6), 0, randf_range(-6, 6))
	var i := 0
	for troop in squad.get_children():
		@warning_ignore("integer_division")
		var offset := Vector3((i % 3 - 1) * spawn_spacing, 0.0, (i / 3) * spawn_spacing)
		(troop as Troop).position = _ground_point(origin + offset)
		i += 1

	_add_enemy_squad(squad)
	_set_tickets(tickets - size)

	# Let the nav agents register for a frame before giving orders
	await get_tree().physics_frame
	if not is_instance_valid(squad):
		return
	var target := _pick_target(squad.centroid())
	if t.hunt_vehicles:
		# Anti-tank team: set up near the objective it's sent to and hunt there
		squad.order_hunt(target.global_position if target else squad.centroid())
	else:
		squad.order_capture(target)

func _add_enemy_squad(squad: Squad) -> void:
	(squad_parent if squad_parent else get_tree().current_scene).add_child(squad)
	_enemy_squads.append(squad)
	squad.wiped_out.connect(_on_squad_wiped_out)

## One enemy vehicle, if there are tickets and room. Ground vehicles drive
## from the spawn; AA emplacements are set up beside an objective the enemy
## holds (it flew them in), or at the spawn if it holds none.
func _spawn_vehicle() -> bool:
	if spawn_points.is_empty() or enemy_vehicle_types.is_empty():
		return false
	if enemy_vehicle_types.size() > 0 and enemy_vehicle_alive_limit_reached():
		return false
	var max_tier := _max_tier()
	var pool := enemy_vehicle_types.filter(func(vt): return vt.tier <= max_tier \
		and vt.tickets + (vt.crew_squad.size if vt.crew_squad else 0) <= tickets)
	if pool.is_empty():
		return false
	var t: VehicleType = pool.pick_random()
	_squad_count += 1
	var tag := "Enemy%s_%d" % [t.display_name.replace(" ", ""), _squad_count]

	var spawn: Node3D = spawn_points.pick_random()
	# Away from where the squads appear
	var ring := randf() * TAU
	var pos := spawn.global_position + Vector3(cos(ring), 0.0, sin(ring)) * randf_range(20.0, 35.0)
	if t.sling_loaded:
		var held := get_tree().get_nodes_in_group("Objectives").filter(func(o): return o.owner_team == Troop.TEAM_ENEMY)
		if not held.is_empty():
			var obj: Node3D = held.pick_random()
			var angle := randf() * TAU
			pos = obj.global_position + Vector3(cos(angle), 0.0, sin(angle)) * randf_range(emplacement_distance.x, emplacement_distance.y)
	pos = _ground_point(pos) - Vector3.UP * 0.8

	var facing := Vector3.FORWARD
	var first := _pick_target(pos)
	if first:
		facing = first.global_position - pos
		facing.y = 0.0
	var parent := vehicle_parent if vehicle_parent else get_tree().current_scene
	var v := t.spawn(parent, Troop.TEAM_ENEMY, pos, facing, tag, troop_scene,
		squad_parent if squad_parent else get_tree().current_scene)
	if v == null:
		return false
	var cost := t.tickets
	if is_instance_valid(v.squad):
		cost += v.squad.members.size()
		_enemy_squads.append(v.squad)
		v.squad.wiped_out.connect(_on_squad_wiped_out)
	_set_tickets(tickets - cost)
	print("[Battle] Enemy %s deployed (%d tickets)" % [t.display_name, cost])
	return true

func enemy_vehicle_alive_limit_reached() -> bool:
	return enemy_vehicles_alive() >= max_enemy_vehicles

func _set_tickets(value: int) -> void:
	tickets = maxi(value, 0)
	tickets_changed.emit(tickets)

func _on_squad_wiped_out(squad: Squad) -> void:
	_enemy_squads.erase(squad)
	squad.queue_free.call_deferred()   # troops free themselves; drop the empty squad node too

# ---------------------------------------------------------------- director

## Objective an enemy squad should go for: one the enemy doesn't own, nearer
## ones more likely. If it owns them all, reinforce a random one.
func _pick_target(from: Vector3) -> Objective:
	var targets: Array[Objective] = []
	var weights: Array[float] = []
	var all_objectives := get_tree().get_nodes_in_group("Objectives")
	for node in all_objectives:
		var o := node as Objective
		if o and o.owner_team != Troop.TEAM_ENEMY:
			targets.append(o)
			weights.append(1.0 / maxf(from.distance_to(o.global_position), 50.0))
	if targets.is_empty():
		return all_objectives.pick_random() if not all_objectives.is_empty() else null
	var total := 0.0
	for w in weights:
		total += w
	var roll := randf() * total
	for i in targets.size():
		roll -= weights[i]
		if roll <= 0.0:
			return targets[i]
	return targets.back()

## Squads that finished their job (holding, or sitting on an objective the
## enemy already owns) go after something else once there's something to take
func _tick_director(delta: float) -> void:
	_director_timer -= delta
	if _director_timer > 0.0:
		return
	_director_timer = director_interval
	var anything_to_take := not enemy_holds_all()
	for squad in _enemy_squads:
		if not is_instance_valid(squad) or squad.in_contact or squad.alive_members().is_empty():
			continue
		var idle := squad.order == Squad.Orders.HOLD or squad.order == Squad.Orders.NONE
		var guarding: bool = squad.order == Squad.Orders.CAPTURE and squad.target_obj != null \
			and squad.target_obj.owner_team == Troop.TEAM_ENEMY
		if anything_to_take and (idle or guarding):
			squad.order_capture(_pick_target(squad.centroid()))

# ---------------------------------------------------------------- win / lose

func _check_defeat(delta: float) -> void:
	if enemy_holds_all():
		enemy_hold_time += delta
		if enemy_hold_time >= hold_to_lose:
			_end(false)
	else:
		enemy_hold_time = 0.0

func _check_victory() -> void:
	if tickets <= 0 and enemies_alive() == 0 and enemy_vehicles_alive() == 0:
		_end(true)

func _end(won: bool) -> void:
	if is_over:
		return
	is_over = true
	player_won = won
	print("[Battle] %s" % ("VICTORY: enemy out of tickets" if won else "DEFEAT: enemy held every objective"))
	game_over.emit(won)

# ---------------------------------------------------------------- helpers

var _warned_no_ground : bool = false

func _ground_point(p: Vector3) -> Vector3:
	var query := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 500.0, p + Vector3.DOWN * 1000.0)
	var hit := get_viewport().find_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		if not _warned_no_ground:
			_warned_no_ground = true
			push_warning("BattleManager: no ground under spawn point at %s. Outside a Terrain3D region? Troops will fall." % p)
		return p
	return hit.position + Vector3.UP * 1.1

## Every resource in a folder (SquadTypes, VehicleTypes)
func _load_dir(path: String) -> Array[Resource]:
	var out: Array[Resource] = []
	var dir := DirAccess.open(path)
	if dir == null:
		return out
	for file in dir.get_files():
		var res_path := path.path_join(file.trim_suffix(".remap"))
		if res_path.ends_with(".tres") or res_path.ends_with(".res"):
			var r := load(res_path)
			if r:
				out.append(r)
	return out
