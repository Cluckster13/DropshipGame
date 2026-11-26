class_name NavPatchBaker
extends Node
## Navigation for Terrain3D maps too big to bake in one go.
##
## The world is cut into a grid of square tiles. Tiles are baked on
## background threads, only where they're needed:
##   - around every anchor (and every node in anchor_groups) at startup
##   - around the helicopter whenever it starts unloading troops
##   - anywhere else you call request_area(position)
## Tiles share exact edges (border_size overlap) so neighbours join up into
## one continuous navmesh. Already-baked tiles are never baked twice.
##
## Startup: the tiles requested at startup are the "initial bake". While it
## runs, several tiles bake at once (the loading screen hides the stutter);
## initial_bake_finished fires when they're all in. After that, tiles bake one
## at a time so gameplay stays smooth.
##
## Terrain: uses Terrain3D.generate_nav_mesh_source_geometry(), so with
## require_painted_nav on, only ground painted with Terrain3D's Navigable
## tool ends up walkable.
## Obstacles: static colliders under obstacle_root (e.g. ProtonScatter trees
## and rocks with keep_static_colliders) are cut out of the mesh.

signal tile_baked(tile: Vector2i)
## Every tile requested at startup is baked and registered
signal initial_bake_finished

@export var terrain : Terrain3D
## Static colliders under this node become obstacles (trees, rocks, walls)
@export var obstacle_root : Node
## Only bake ground painted navigable with Terrain3D's Navigation tool
@export var require_painted_nav : bool = true

@export_group("Tiles")
## Edge length of one tile in metres. 128 m at 0.25 cells ≈ 0.26M cells: fast.
@export var tile_size : float = 128.0
## Tiles baked around each requested point: 1 = 3x3 tiles (384 m square)
@export_range(0, 4, 1) var bake_radius_tiles : int = 1
## Overlap baked past each tile edge so neighbours stitch. Multiple of cell_size.
@export var border_size : float = 2.0
## Lowest / highest world Y considered when baking. Keep the span under
## ~2000 m: Recast can't store heights past 8191 cells (2048 m at 0.25).
@export var height_range : Vector2 = Vector2(-200.0, 800.0)

@export_group("When to bake")
## Areas baked at startup (e.g. the base)
@export var anchors : Array[Node3D] = []
## Every node in these groups is baked around at startup
@export var anchor_groups : Array[StringName] = [&"Objectives"]
## Bake around the aircraft as soon as it starts unloading troops
@export var bake_on_unload : bool = true
## Wait this long before the first bake so scatter/terrain finish loading
@export var startup_delay : float = 1.0

@export_group("Performance")
## Tiles baking at the same time during the initial (loading screen) bake
@export_range(1, 16, 1) var initial_parallel_bakes : int = 4
## Tiles baking at the same time during gameplay
@export_range(1, 16, 1) var gameplay_parallel_bakes : int = 1

@export_group("Advanced")
## Agent + cell settings. Empty = defaults that match Troop (0.25 cells,
## 0.5 m radius, 2 m tall, 45° slopes).
@export var template : NavigationMesh
@export var log_timing : bool = false

## True once every tile requested at startup is baked
var initial_ready : bool = false

var _obstacle_geometry : NavigationMeshSourceGeometryData3D
var _regions : Dictionary = {}    # Vector2i -> NavigationRegion3D (or null while queued/baking)
var _queue : Array[Vector2i] = []
var _tasks : Dictionary = {}      # Vector2i -> [WorkerThreadPool task id (-1 = none), start msec]
var _started : bool = false
var _initial_total : int = 0
var _initial_started_ms : int = 0

func _ready() -> void:
	# Keeps baking while the loading screen has the game paused
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("NavPatchBaker")
	if template == null:
		template = _default_template()
	_apply_map_cell_size()
	get_tree().node_added.connect(_on_node_added)
	_hook_existing_passenger_handlers.call_deferred()

	# Timers from create_timer run while paused by default
	await get_tree().create_timer(startup_delay).timeout
	_initial_started_ms = Time.get_ticks_msec()
	_parse_obstacles()
	for a in anchors:
		if is_instance_valid(a):
			request_area(a.global_position)
	for g in anchor_groups:
		for n in get_tree().get_nodes_in_group(g):
			if n is Node3D:
				request_area(n.global_position)
	_initial_total = _queue.size()
	_started = true

func _process(_delta: float) -> void:
	if not _started:
		return
	# One geometry gather per frame (it's main-thread work); the bakes
	# themselves run in parallel on worker threads
	var limit := gameplay_parallel_bakes if initial_ready else initial_parallel_bakes
	if not _queue.is_empty() and _tasks.size() < limit:
		_start_next()
	if not initial_ready and _queue.is_empty() and _tasks.is_empty():
		initial_ready = true
		if log_timing:
			print("[NavPatchBaker] initial bake: %d tiles in %d ms" % [
				_initial_total, Time.get_ticks_msec() - _initial_started_ms])
		initial_bake_finished.emit()

# ---------------------------------------------------------------- public

## Bake the tiles around a world position (no-op for tiles already done)
func request_area(world_pos: Vector3, radius_tiles: int = -1) -> void:
	var r := bake_radius_tiles if radius_tiles < 0 else radius_tiles
	var center := tile_of(world_pos)
	# Nearest tiles first
	var wanted: Array[Vector2i] = []
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			wanted.append(center + Vector2i(dx, dz))
	wanted.sort_custom(func(a, b): return (a - center).length_squared() < (b - center).length_squared())
	for t in wanted:
		if not _regions.has(t):
			_regions[t] = null    # mark as queued
			_queue.append(t)

func tile_of(world_pos: Vector3) -> Vector2i:
	return Vector2i(floori(world_pos.x / tile_size), floori(world_pos.z / tile_size))

func is_tile_baked(t: Vector2i) -> bool:
	return _regions.get(t) != null

func baked_tile_count() -> int:
	var n := 0
	for t in _regions:
		if _regions[t] != null:
			n += 1
	return n

## 0..1 progress of the startup bake (for loading screens)
func initial_progress() -> float:
	if initial_ready:
		return 1.0
	if not _started or _initial_total == 0:
		return 0.0
	var done := _initial_total - _queue.size() - _tasks.size()
	return clampf(float(done) / _initial_total, 0.0, 1.0)

# ---------------------------------------------------------------- baking

func _start_next() -> void:
	var t: Vector2i = _queue.pop_front()
	var started := Time.get_ticks_msec()
	var bounds := AABB(
		Vector3(t.x * tile_size, height_range.x, t.y * tile_size),
		Vector3(tile_size, height_range.y - height_range.x, tile_size))
	var nav_mesh: NavigationMesh = template.duplicate()
	nav_mesh.border_size = border_size
	nav_mesh.filter_baking_aabb = bounds.grow(border_size)

	# Gather geometry here on the main thread: Terrain3D isn't safe to query
	# from a worker, and one tile's worth of faces only takes a few ms.
	var geometry := NavigationMeshSourceGeometryData3D.new()
	if _obstacle_geometry:
		geometry = _obstacle_geometry.duplicate()
	var face_count := 0
	if terrain:
		var faces: PackedVector3Array = terrain.generate_nav_mesh_source_geometry(nav_mesh.filter_baking_aabb, require_painted_nav)
		@warning_ignore("integer_division")
		face_count = faces.size() / 3
		if face_count > 0:
			geometry.add_faces(faces, Transform3D.IDENTITY)
	if log_timing:
		print("[NavPatchBaker] baking tile %s: %d terrain tris, gathered in %d ms (%d queued)" % [
			t, face_count, Time.get_ticks_msec() - started, _queue.size()])
	if not geometry.has_data():
		_tasks[t] = [-1, started]
		_bake_done(t, nav_mesh)   # nothing walkable here: empty tile, don't ask again
		return
	_tasks[t] = [WorkerThreadPool.add_task(_bake_task.bind(t, nav_mesh, geometry), false, "NavPatchBaker"), started]

## Runs on a worker thread: the slow part (voxelising + building polygons)
func _bake_task(t: Vector2i, nav_mesh: NavigationMesh, geometry: NavigationMeshSourceGeometryData3D) -> void:
	NavigationServer3D.bake_from_source_geometry_data(nav_mesh, geometry)
	_bake_done.call_deferred(t, nav_mesh)

func _bake_done(t: Vector2i, nav_mesh: NavigationMesh) -> void:
	var entry: Array = _tasks.get(t, [-1, Time.get_ticks_msec()])
	if entry[0] != -1:
		WorkerThreadPool.wait_for_task_completion(entry[0])
	_tasks.erase(t)
	var region := NavigationRegion3D.new()
	region.name = "NavTile_%d_%d" % [t.x, t.y]
	region.navigation_mesh = nav_mesh
	add_child(region)
	_regions[t] = region
	if log_timing:
		print("[NavPatchBaker] tile %s baked in %d ms (%d polygons)" % [
			t, Time.get_ticks_msec() - entry[1], nav_mesh.get_polygon_count()])
	tile_baked.emit(t)

# ---------------------------------------------------------------- setup

func _default_template() -> NavigationMesh:
	var nm := NavigationMesh.new()
	nm.cell_size = 0.25
	nm.cell_height = 0.25
	nm.agent_radius = 0.5
	nm.agent_height = 2.0
	nm.agent_max_climb = 0.5
	nm.agent_max_slope = 45.0
	nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nm.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	return nm

## Baked meshes must use the same cell size as the navigation map
func _apply_map_cell_size() -> void:
	var map := get_viewport().find_world_3d().navigation_map
	NavigationServer3D.map_set_cell_size(map, template.cell_size)
	NavigationServer3D.map_set_cell_height(map, template.cell_height)

## Parsed once on the main thread, then copied into every tile bake
func _parse_obstacles() -> void:
	if obstacle_root == null:
		return
	var t0 := Time.get_ticks_msec()
	_obstacle_geometry = NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(template, _obstacle_geometry, obstacle_root)
	if log_timing:
		@warning_ignore("integer_division")
		var tris := _obstacle_geometry.get_indices().size() / 3
		print("[NavPatchBaker] parsed obstacles in %d ms: %d tris" % [Time.get_ticks_msec() - t0, tris])

func _on_node_added(node: Node) -> void:
	if node is PassengerHandler:
		_hook_passenger_handler(node)

func _hook_existing_passenger_handlers() -> void:
	for n in get_tree().root.find_children("*", "Node3D", true, false):
		if n is PassengerHandler:
			_hook_passenger_handler(n)

func _hook_passenger_handler(ph: PassengerHandler) -> void:
	if bake_on_unload and ph.has_signal("unloading_started") and not ph.unloading_started.is_connected(_on_unloading_started):
		ph.unloading_started.connect(_on_unloading_started)

func _on_unloading_started(where: Vector3) -> void:
	request_area(where)
