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
		_load_types_from_dir()
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

func enemies_alive() -> int:
	var n := 0
	for node in get_tree().get_nodes_in_group("Troops"):
		var t := node as Troop
		if t and t.team == Troop.TEAM_ENEMY and t.is_alive():
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
	if spawned > 0:
		print("[Battle] Wave %d: %d enemy troops (%d tickets left)" % [wave, spawned, tickets])
		wave_spawned.emit(wave)

## Better squads unlock as waves go on
func _pick_type() -> SquadType:
	@warning_ignore("integer_division")
	var max_tier := 1 + (wave - 1) / waves_per_tier
	var pool := enemy_squad_types.filter(func(t): return t.tier <= max_tier)
	if pool.is_empty():
		pool = [enemy_squad_types[0]]
	return pool.pick_random()

func _spawn_squad(t: SquadType, size: int) -> void:
	_squad_count += 1
	var squad := Squad.new()
	squad.name = "Enemy%s_%d" % [t.display_name.replace(" ", ""), _squad_count]
	squad.squad_name = "Enemy %s %d" % [t.display_name, _squad_count]
	squad.team = Troop.TEAM_ENEMY
	squad.skill = t.skill
	squad.auto_advance = true

	var spawn: Node3D = spawn_points.pick_random()
	var origin := spawn.global_position + Vector3(randf_range(-6, 6), 0, randf_range(-6, 6))
	for i in size:
		var troop := troop_scene.instantiate() as Troop
		troop.name = "%s_%d" % [squad.name, i + 1]
		troop.team = Troop.TEAM_ENEMY
		troop.max_health = t.max_health
		troop.move_speed = t.move_speed
		@warning_ignore("integer_division")
		var offset := Vector3((i % 3 - 1) * spawn_spacing, 0.0, (i / 3) * spawn_spacing)
		troop.position = _ground_point(origin + offset)
		squad.add_child(troop)

	(squad_parent if squad_parent else get_tree().current_scene).add_child(squad)
	_enemy_squads.append(squad)
	squad.wiped_out.connect(_on_squad_wiped_out)
	_set_tickets(tickets - size)

	# Let the nav agents register for a frame before giving orders
	await get_tree().physics_frame
	if is_instance_valid(squad):
		squad.order_capture(_pick_target(squad.centroid()))

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
	if tickets <= 0 and enemies_alive() == 0:
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

func _load_types_from_dir() -> void:
	var dir := DirAccess.open(squad_types_dir)
	if dir == null:
		return
	for file in dir.get_files():
		var path := squad_types_dir.path_join(file.trim_suffix(".remap"))
		if path.ends_with(".tres") or path.ends_with(".res"):
			var t := load(path) as SquadType
			if t:
				enemy_squad_types.append(t)
