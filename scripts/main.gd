extends Node2D
## Procedural 128x128 isometric terrain with elevation.
##
## Terrain types: grass, dirt, water (water is always at the lowest level).
## Water sits at the bottom of a valley: the ring of land touching it is one
## level up (SHORE_H) and normal ground is one level above that (GROUND_H).
## Grass and dirt can additionally rise in raised clumps (plateaus / mesas) up
## to MAX_H levels above ground. Each cell is drawn as a vertical stack of
## "cube" sprites: the lower cubes form the cliff faces, the top cube is the
## surface.
##
## Rendering is a custom _draw() (rather than TileMapLayer) because elevation
## requires a per-cell vertical pixel offset and height-aware depth sorting,
## which TileMapLayer does not provide.
##
## Sprite numbering follows the project convention: sprite N is row N/11,
## column N%11 of the 11x11 spritesheet (sprite 0 = row0/col0, 11 = row1/col0).

const MAP_W := 128
const MAP_H := 128

const SHEET_COLS := 11
const TILE_PX := 32           # source sprite size
const HALF_W := 16            # iso horizontal half-step  (tile width / 2)
const QUARTER_H := 8          # iso vertical step          (tile height / 4)
const STEP := 8               # vertical pixels per elevation level (block height)
const MAX_H := 3              # maximum raised height above normal ground
const SHORE_H := 1            # valley shoulder: land ring touching water
const GROUND_H := 2           # normal surface level (water valley floor is 0)

const RIVER_COUNT := 3
const MIN_RIVER_LEN := 20

const BoarScript := preload("res://scripts/boar.gd")
const StagScript := preload("res://scripts/stag.gd")
const TreeScript := preload("res://scripts/tree.gd")
const CloudScript := preload("res://scripts/cloud.gd")
const FishScript := preload("res://scripts/fish.gd")
const BirdScript := preload("res://scripts/bird.gd")

# Clouds drift in from the top-right edge (grid y just above 0) and are removed
# once they pass the bottom-left edge (grid y past MAP_H). These are the grid
# margins, in cells, beyond the edge for spawning and despawning.
const CLOUD_SPAWN_MARGIN := 6.0
const CLOUD_EXIT_MARGIN := 20.0
# A cloud bank is scattered this many cells across the entry edge and back from
# it, so the clouds read as one large, ragged bank rather than a neat line.
const CLOUD_BANK_SPREAD := 22.0
const CLOUD_BANK_DEPTH := 16.0

enum { GRASS, DIRT, WATER }

# Tile pools as SPRITE NUMBERS (row-major over the 11x11 sheet).
# Grass: the three clean diamond tiles are the default; the thicker/leafier
# variants (row 2 col 7 .. row 3 col 3) appear in grown clumps, not at random.
const GRASS_MAIN := [22, 23, 24]
const THICK_GRASS := [29, 30, 31, 32, 33, 34, 35, 36]
# row 0 dry dirt cols 0-4  +  row 1 cracked dirt cols 0-2
const DIRT_TILES := [0, 1, 2, 3, 4, 11, 12, 13]
# Stone cliff material (row 5, col 6). Whole raised clumps occasionally turn to
# stone, forming rocky cliffs/mesas.
const STONE_TILE := 61
# Row 4 decorations (flowers, logs, stumps, small rocks) placed on some grass.
const DECOR_TILES := [44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54]
# Row 7 rocks, placed in a small fraction of water tiles.
const ROCK_TILES := [77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87]
# Water shoreline tiles (row 10). Sprite N = 110 + column.
# Column meaning (which diamond SIDES touch land):
#   0 open water | 1 TR | 2 TL | 3 BR | 4 BL | 5 TL+TR | 6 BL+BR
#   7 TL+BL | 8 TR+BR | 9 all four | 10 rough open water (unused)
const WATER_OPEN := 110
# Maps a land-side bitmask -> water sprite (row 10, the calm/low-power tiles).
# Bits: TL=1, TR=2, BR=4, BL=8.
const WATER_EDGE := {
	0: 110, 2: 111, 1: 112, 4: 113, 8: 114,
	3: 115, 12: 116, 9: 117, 6: 118, 15: 119,
}
# Row 9 is an identical-but-darker copy of row 10 used for high "water power".
# The darker variant of any water sprite is sprite - 11.
const WATER_DARK_OFFSET := 11
# Row 1 (cracked dirt) is shown when a water cell is in the dry phase.
const DRY_TILES := [11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21]
# Water's top face sits ~4px lower than land's, so dry tiles are drawn this many
# pixels lower to keep their surface level with the water they replace.
const DRY_DROP := 4.0
# Water-power cycle phases (advance one per cycle as the wave passes).
const PHASE_HIGH := 0   # dark, row 9; floods the valley shoulder one level up
const PHASE_LOW := 1    # light, row 10
const PHASE_DRY := 2    # no water, row 1 cracked dirt
# When a flooded shoulder tile un-floods, this fraction of the fade is spent
# quickly turning the dark flood water into the light low-power tile; the
# remainder fades that light tile away.
const FLOOD_CALM_T := 0.3

# Tunable from the inspector so terrain can be tweaked without code edits.
@export var terrain_frequency := 0.025
@export var elevation_frequency := 0.05
@export var elev_threshold_1 := 0.20   # >= this -> height 1
@export var elev_threshold_2 := 0.40   # >= this -> height 2
@export var elev_threshold_3 := 0.55   # >= this -> height 3
@export var stone_clump_chance := 0.15 # fraction of raised clumps made of stone
@export var decor_chance := 0.05       # fraction of grass cells with a row-4 object
@export var rock_chance := 0.03        # fraction of water cells with a row-7 rock
# Thick-grass clumps: this many seeds are dropped on the map; each that lands on
# grass grows into a connected patch of thick-grass tiles.
@export var thick_clump_count := 80
@export var thick_clump_min := 2
@export var thick_clump_max := 25
# Water-power cycle: the high/low (dark/light) state toggles every cycle and the
# change spreads inward from the map edge through connected water, one ring per
# water_ring_seconds, so it appears to "flow" downstream.
@export var water_cycle_seconds := 10.0
@export var water_ring_seconds := 0.25
# When the wave changes a tile's phase, the new tile cross-fades in over the
# old one for this many seconds instead of swapping instantly.
@export var water_fade_seconds := 0.5
# The water sprites are partly translucent, so a single pass lets submerged
# land show through too clearly. Flood tiles get a second pass at this fraction
# of the flood alpha, hiding the shoulder substantially but not completely.
@export_range(0.0, 1.0) var flood_density := 0.85
# Wandering critters spawned per map.
@export var boar_min_count := 2
@export var boar_max_count := 8
@export var stag_min_count := 2
@export var stag_max_count := 8
# Bluebirds that wander the sky, landing on grass to peck before flying off.
@export var bird_min_count := 3
@export var bird_max_count := 6
# Trees placed on random grass cells; each cycles through all growth stages.
@export var tree_count := 180
# Clouds arrive in banks: a bank of cloud_group_min..cloud_group_max clouds
# drifts in when the map loads, then a new bank arrives every
# cloud_spawn_min..cloud_spawn_max seconds. Clouds in a bank are offset within
# CLOUD_BANK_SPREAD across the entry edge and CLOUD_BANK_DEPTH back from it.
@export var cloud_group_min := 3
@export var cloud_group_max := 11
@export var cloud_spawn_min := 10.0
@export var cloud_spawn_max := 60.0
# Chance, per river cell, that a fish is left flopping when that cell dries out.
@export_range(0.0, 1.0) var fish_chance := 0.004
# Heavy-rain clouds raise the water level of the river tiles under them (and one
# tile around) for this long after passing; the boost spreads through connected
# water up to rain_boost_radius tiles before receding.
@export var rain_boost_seconds := 10.0
@export_range(1, 30) var rain_boost_radius := 5
# Lakes grown out from the rivers they attach to.
@export var lake_min_count := 1
@export var lake_max_count := 3
@export var lake_large_chance := 0.4   # chance a lake is "large" (gets islands)
@export var island_threshold := 0.1    # noise cutoff for island land inside large lakes

@onready var camera: Camera2D = $Camera

var _sheet: Texture2D
var _terrain: Array = []        # _terrain[x][y] -> GRASS/DIRT/WATER
var _height: Array = []         # _height[x][y]  -> 0..MAX_H
var _stone: Array = []          # _stone[x][y]   -> bool (raised clump turned to stone)
var _thick: Array = []          # _thick[x][y]   -> bool (part of a thick-grass clump)
var _columns: Array = []        # _columns[x][y] -> PackedInt32Array of sprite ids (level 0..h)
var _decor: Array = []          # _decor[x][y]   -> row-4 sprite id on top, or -1
var _drytile: Array = []        # _drytile[x][y] -> row-1 sprite for the dry phase (water cells)
var _hiwtile: Array = []        # _hiwtile[x][y] -> high-phase sprite for water cells (light row-10 id)
var _floodtile: Array = []      # _floodtile[x][y] -> flood sprite over shore cells in high phase, or -1
var _rocktile: Array = []       # _rocktile[x][y]  -> row-7 rock sprite on a water cell, or -1
var _boars: Array = []          # live boar critter nodes
var _stags: Array = []          # live stag critter nodes
var _trees: Array = []          # live tree nodes
var _tree_at: Dictionary = {}   # Vector2i cell -> tree node, for flood-over-tree lookup
var _clouds: Array = []         # live cloud nodes (drawn on top of everything)
var _next_cloud := 0.0          # seconds until the next cloud drifts in
var _birds: Array = []          # wandering bluebird nodes
var _fish_at: Dictionary = {}   # Vector2i cell -> flopping fish node
var _wcells_by_dist: Dictionary = {}  # ring distance -> Array[Vector2i] of water cells
var _dist_dry: Dictionary = {}  # ring distance -> bool (its cells are currently fully dry)
var _rain_until: Dictionary = {}  # Vector2i source cell -> rain-boost expiry time
var _boosted: Dictionary = {}   # Vector2i -> true, cells raised one water level this frame
var _wdist: Array = []          # _wdist[x][y]   -> water rings from map edge (-1 if not water)
var _max_wdist := 0             # largest _wdist value (bounds the fade window)
var _time := 0.0                # seconds since start, drives the water cycle
var _last_tick := -1            # last ring tick that triggered a redraw


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # crisp pixel art
	_sheet = load("res://assets/spritesheet.png")
	randomize()
	_generate()
	_center_camera()


func _input(event: InputEvent) -> void:
	# Press R to roll a fresh map.
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		randomize()
		_generate()


# --- generation -------------------------------------------------------------

func _generate() -> void:
	_make_terrain()
	_make_heightmap()
	_mark_stone_clumps()
	_mark_thick_clumps()
	_build_water_distance()
	_build_columns()
	_spawn_critters()
	queue_redraw()


## Replaces any existing critters and trees with fresh random ones.
func _spawn_critters() -> void:
	for b in _boars:
		b.queue_free()
	for s in _stags:
		s.queue_free()
	for t in _trees:
		t.queue_free()
	for c in _clouds:
		c.queue_free()
	for f in _fish_at.values():
		f.queue_free()
	for b in _birds:
		b.queue_free()
	_fish_at = {}
	_dist_dry = {}
	_rain_until = {}
	_boosted = {}
	_boars = _spawn_herd(BoarScript, randi_range(boar_min_count, boar_max_count))
	_stags = _spawn_herd(StagScript, randi_range(stag_min_count, stag_max_count))
	_spawn_trees(tree_count)
	_spawn_clouds()
	_spawn_birds()


## Spawns the wandering bluebirds. They start aloft anywhere on the map and
## roam, so (unlike ground critters) their start cell needn't be walkable.
func _spawn_birds() -> void:
	_birds = []
	for _i in randi_range(bird_min_count, bird_max_count):
		var b: Node2D = BirdScript.new()
		add_child(b)
		b.setup(self, Vector2i(randi() % MAP_W, randi() % MAP_H))
		_birds.append(b)


## True for plain grass a bird may land on (not dirt, water, or a stone clump).
func is_grass(c: Vector2i) -> bool:
	return _in_bounds(c.x, c.y) and _terrain[c.x][c.y] == GRASS and not _stone[c.x][c.y]


## Seeds a couple of banks already spread across the sky (so clouds are visible
## right away, not a minute's drift away) and arms the timer for the next bank.
func _spawn_clouds() -> void:
	_clouds = []
	for _i in 3:
		_add_cloud_bank(true)
	_next_cloud = randf_range(cloud_spawn_min, cloud_spawn_max)


## Adds a bank of cloud_group_min..cloud_group_max clouds, scattered around a
## base spot so they read as one large, ragged bank. With over_map the bank is
## placed somewhere across the map (used at load); otherwise it enters just off
## the top-right edge and drifts in.
func _add_cloud_bank(over_map := false) -> void:
	# Load-time banks are centred on the camera's start view (the map middle) so
	# clouds are visible immediately; later banks enter off the top-right edge.
	var base_x := MAP_W * 0.5 if over_map else randf_range(0.0, MAP_W)
	var base_y := MAP_H * 0.5 if over_map else -CLOUD_SPAWN_MARGIN
	for _i in randi_range(cloud_group_min, cloud_group_max):
		var c: Node2D = CloudScript.new()
		add_child(c)
		var gx := base_x + randf_range(-CLOUD_BANK_SPREAD, CLOUD_BANK_SPREAD)
		var gy: float
		if over_map:
			gy = base_y + randf_range(-CLOUD_BANK_DEPTH, CLOUD_BANK_DEPTH)
		else:
			gy = base_y - randf_range(0.0, CLOUD_BANK_DEPTH)
		c.setup(Vector2(gx, gy))
		_clouds.append(c)


## Places trees on random grass cells (not dirt, water, or stone clumps).
func _spawn_trees(count: int) -> void:
	_trees = []
	_tree_at = {}
	var tries := 0
	while _trees.size() < count and tries < 8000:
		tries += 1
		var c := Vector2i(randi() % MAP_W, randi() % MAP_H)
		if _terrain[c.x][c.y] == GRASS and not _stone[c.x][c.y] and not _tree_at.has(c):
			var t: Node2D = TreeScript.new()
			add_child(t)
			t.setup(self, c)
			_trees.append(t)
			_tree_at[c] = t


func _spawn_herd(script: GDScript, count: int) -> Array:
	var herd: Array = []
	var tries := 0
	while herd.size() < count and tries < 1000:
		tries += 1
		var c := Vector2i(randi() % MAP_W, randi() % MAP_H)
		if _terrain[c.x][c.y] != WATER and _height[c.x][c.y] >= GROUND_H:
			var n: Node2D = script.new()
			add_child(n)
			n.setup(self, c)
			herd.append(n)
	return herd


## Ground height a critter at cell c stands on.
func cell_height(c: Vector2i) -> int:
	return _height[c.x][c.y]


## Critters may move onto land at normal ground level or above, stepping at
## most one elevation level per tile (no swimming, no flooded shoulders).
func is_critter_walkable(from: Vector2i, to: Vector2i) -> bool:
	if not _in_bounds(to.x, to.y):
		return false
	if _terrain[to.x][to.y] == WATER or _height[to.x][to.y] < GROUND_H:
		return false
	return absi(_height[to.x][to.y] - _height[from.x][from.y]) <= 1


## Continuous grid position of the boar nearest to grid position p, or
## Vector2.INF if there are no boars. Lets prey critters know what to flee.
func nearest_boar(p: Vector2) -> Vector2:
	var best := Vector2.INF
	var best_d := INF
	for b in _boars:
		var q: Vector2 = b.grid_pos()
		var d := p.distance_squared_to(q)
		if d < best_d:
			best_d = d
			best = q
	return best


func _process(delta: float) -> void:
	_time += delta
	_reap_trees()
	_reap_clouds()
	# A fresh cloud drifts in on its own timer, on top of the load-time batch.
	_next_cloud -= delta
	if _next_cloud <= 0.0:
		_add_cloud_bank()
		_next_cloud = randf_range(cloud_spawn_min, cloud_spawn_max)
	_update_fish()
	_update_rain_boost()
	# Entities animate and move continuously, and they're composited into _draw,
	# so the scene must redraw every frame whenever any are present.
	if not _boars.is_empty() or not _stags.is_empty() or not _trees.is_empty() \
			or not _clouds.is_empty() or not _fish_at.is_empty() or not _rain_until.is_empty() \
			or not _birds.is_empty():
		queue_redraw()
		return
	# Otherwise redraw every frame while any tile may be cross-fading, else only
	# when the wave advances a ring (at most 1/water_ring_seconds Hz).
	if _fade_active():
		queue_redraw()
		return
	var tick := floori(_time / water_ring_seconds)
	if tick != _last_tick:
		_last_tick = tick
		queue_redraw()


## A tree that has lived out its life cycle (grown, held, fallen, and shown its
## final debris frame) sets `finished`; here we free those nodes and drop them
## from the live list so they stop being composited.
func _reap_trees() -> void:
	if _trees.is_empty():
		return
	var alive: Array = []
	for t in _trees:
		if t.finished:
			_tree_at.erase(t.cell)
			t.queue_free()
		else:
			alive.append(t)
	if alive.size() != _trees.size():
		_trees = alive


## Frees clouds that have drifted past the bottom-left edge of the map.
func _reap_clouds() -> void:
	if _clouds.is_empty():
		return
	var alive: Array = []
	for c in _clouds:
		if c.pos.y > MAP_H + CLOUD_EXIT_MARGIN:
			c.queue_free()
		else:
			alive.append(c)
	if alive.size() != _clouds.size():
		_clouds = alive


## True once cell-distance d's water has fully faded into the dry phase (the
## cracked-dirt riverbed is completely shown), false while wet or mid-fade.
func _dist_fully_dry(d: int) -> bool:
	var since := _time - d * water_ring_seconds
	if since < 0.0:
		return false
	var k := floori(since / water_cycle_seconds)
	if k < 0 or k % 3 != PHASE_DRY:
		return false
	if water_fade_seconds <= 0.0:
		return true
	return (since - k * water_cycle_seconds) / water_fade_seconds >= 1.0


## Watches each ring-distance group of river cells: when it dries out, each cell
## has a fish_chance of stranding a flopping fish; when it goes wet again, those
## fish are removed. Cheap because every cell at a distance shares one phase.
func _update_fish() -> void:
	for d in _wcells_by_dist:
		var dry := _dist_fully_dry(d)
		var was: bool = _dist_dry.get(d, false)
		if dry and not was:
			_dist_dry[d] = true
			for c: Vector2i in _wcells_by_dist[d]:
				if not _fish_at.has(c) and randf() < fish_chance:
					var f: Node2D = FishScript.new()
					add_child(f)
					f.setup(self, c)
					_fish_at[c] = f
		elif not dry and was:
			_dist_dry[d] = false
			for c: Vector2i in _wcells_by_dist[d]:
				if _fish_at.has(c):
					_fish_at[c].queue_free()
					_fish_at.erase(c)


## True if some water tile could currently be mid-fade. The wave front for a
## cycle sweeps the map over _max_wdist rings, and each tile fades for
## water_fade_seconds after the front passes, so fades only happen inside the
## first (_max_wdist * ring + fade) seconds of each cycle.
func _fade_active() -> bool:
	if water_fade_seconds <= 0.0:
		return false
	var span := _max_wdist * water_ring_seconds + water_fade_seconds
	if span >= water_cycle_seconds:
		return true
	return fmod(_time, water_cycle_seconds) < span


func _make_terrain() -> void:
	var noise := FastNoiseLite.new()
	noise.seed = randi()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = terrain_frequency

	_terrain = []
	for x in MAP_W:
		var col := []
		col.resize(MAP_H)
		for y in MAP_H:
			col[y] = DIRT if noise.get_noise_2d(float(x), float(y)) < -0.08 else GRASS
		_terrain.append(col)

	for _i in RIVER_COUNT:
		_carve_river()
	_carve_lakes()


func _make_heightmap() -> void:
	var noise := FastNoiseLite.new()
	noise.seed = randi()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = elevation_frequency

	_height = []
	for x in MAP_W:
		var col := []
		col.resize(MAP_H)
		for y in MAP_H:
			var h := 0                            # water: valley floor
			if _terrain[x][y] != WATER:
				if _touches_water(x, y):
					h = SHORE_H                   # valley shoulder ring
				else:
					h = GROUND_H                  # normal surface level
					var e := noise.get_noise_2d(float(x), float(y))
					if e >= elev_threshold_3:
						h += 3
					elif e >= elev_threshold_2:
						h += 2
					elif e >= elev_threshold_1:
						h += 1
			col[y] = mini(h, GROUND_H + MAX_H)
		_height.append(col)


## True if any of the 8 surrounding in-bounds cells is water. Out-of-bounds does
## NOT count as water here, so the map border doesn't get a false valley rim.
func _touches_water(x: int, y: int) -> bool:
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var nx := x + dx
			var ny := y + dy
			if _in_bounds(nx, ny) and _terrain[nx][ny] == WATER:
				return true
	return false


## Finds connected raised regions (height above normal ground, 4-connected) and
## turns a random ~stone_clump_chance fraction of whole clumps into stone.
func _mark_stone_clumps() -> void:
	_stone = []
	for x in MAP_W:
		var col := []
		col.resize(MAP_H)
		col.fill(false)
		_stone.append(col)

	var visited := {}
	for sx in MAP_W:
		for sy in MAP_H:
			if _height[sx][sy] <= GROUND_H or visited.has(Vector2i(sx, sy)):
				continue
			# Flood fill this clump of raised cells.
			var clump: Array = []
			var stack: Array = [Vector2i(sx, sy)]
			visited[Vector2i(sx, sy)] = true
			while not stack.is_empty():
				var c: Vector2i = stack.pop_back()
				clump.append(c)
				for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var nx: int = c.x + d.x
					var ny: int = c.y + d.y
					var nk := Vector2i(nx, ny)
					if _in_bounds(nx, ny) and _height[nx][ny] > GROUND_H and not visited.has(nk):
						visited[nk] = true
						stack.append(nk)
			if randf() < stone_clump_chance:
				for c in clump:
					_stone[c.x][c.y] = true


## Drops thick_clump_count random seeds; each seed that lands on plain grass
## grows into a 4-connected clump of thick_clump_min..thick_clump_max cells of
## thick grass (same organic growth as lakes). Clumps that cannot reach the
## minimum size (isolated grass) are discarded.
func _mark_thick_clumps() -> void:
	_thick = []
	for x in MAP_W:
		var col := []
		col.resize(MAP_H)
		col.fill(false)
		_thick.append(col)

	for _i in thick_clump_count:
		var start := Vector2i(randi() % MAP_W, randi() % MAP_H)
		if not _is_plain_grass(start.x, start.y) or _thick[start.x][start.y]:
			continue
		var target := randi_range(thick_clump_min, thick_clump_max)
		var blob: Array[Vector2i] = [start]
		var inblob := {start: true}
		var frontier: Array[Vector2i] = []
		_push_grass_neighbors(start, inblob, frontier)
		while blob.size() < target and not frontier.is_empty():
			var j := randi() % frontier.size()
			var c: Vector2i = frontier[j]
			frontier[j] = frontier[frontier.size() - 1]
			frontier.resize(frontier.size() - 1)
			if inblob.has(c):
				continue
			inblob[c] = true
			blob.append(c)
			_push_grass_neighbors(c, inblob, frontier)
		if blob.size() >= thick_clump_min:
			for c in blob:
				_thick[c.x][c.y] = true


## Grass that isn't stone (stone clumps render entirely as stone sprites).
func _is_plain_grass(x: int, y: int) -> bool:
	return _in_bounds(x, y) and _terrain[x][y] == GRASS and not _stone[x][y]


func _push_grass_neighbors(c: Vector2i, inblob: Dictionary, frontier: Array) -> void:
	for nb: Vector2i in [Vector2i(c.x + 1, c.y), Vector2i(c.x - 1, c.y), Vector2i(c.x, c.y + 1), Vector2i(c.x, c.y - 1)]:
		if _is_plain_grass(nb.x, nb.y) and not inblob.has(nb) and not _thick[nb.x][nb.y]:
			frontier.append(nb)


## Pre-pick the sprite for every cube of every column once, so the map is stable
## across redraws (and _draw stays cheap).
func _build_columns() -> void:
	_columns = []
	_decor = []
	_drytile = []
	_hiwtile = []
	_floodtile = []
	_rocktile = []
	for x in MAP_W:
		var col := []
		col.resize(MAP_H)
		var dcol := []
		dcol.resize(MAP_H)
		dcol.fill(-1)
		var drycol := []
		drycol.resize(MAP_H)
		drycol.fill(-1)
		var hcol := []
		hcol.resize(MAP_H)
		hcol.fill(-1)
		var fcol := []
		fcol.resize(MAP_H)
		fcol.fill(-1)
		var rcol := []
		rcol.resize(MAP_H)
		rcol.fill(-1)
		for y in MAP_H:
			var ids := PackedInt32Array()
			if _terrain[x][y] == WATER:
				# Water is always a single cube at the lowest level; pick the
				# shoreline-aware sprite based on neighbouring land.
				ids.append(_water_sprite(x, y))
				# High phase floods the shoulder, so the shoreline edges are
				# recomputed against land that stays above the flood waterline.
				hcol[y] = _water_sprite(x, y, GROUND_H)
				# Stable cracked-dirt tile used when this cell is in the dry phase.
				drycol[y] = DRY_TILES[randi() % DRY_TILES.size()]
				# A few water cells get a rock poking out of the water.
				if randf() < rock_chance:
					rcol[y] = ROCK_TILES[randi() % ROCK_TILES.size()]
			elif _stone[x][y]:
				# Stone clump: every cube (top + walls) is the stone sprite.
				for _lvl in _height[x][y] + 1:
					ids.append(STONE_TILE)
			else:
				for _lvl in _height[x][y] + 1:
					ids.append(_pick_land_tile(_terrain[x][y]))
				if _terrain[x][y] == GRASS:
					if _thick[x][y]:
						# Thick-grass clump: the surface cube uses a thick variant.
						ids[ids.size() - 1] = THICK_GRASS[randi() % THICK_GRASS.size()]
					elif randf() < decor_chance:
						# Plain grass may get a decorative row-4 object on top.
						dcol[y] = DECOR_TILES[randi() % DECOR_TILES.size()]
				if _height[x][y] == SHORE_H:
					# Valley shoulder: pre-pick the water tile that covers this
					# cell while the river runs high.
					fcol[y] = _water_sprite(x, y, GROUND_H)
			col[y] = ids
		_columns.append(col)
		_decor.append(dcol)
		_drytile.append(drycol)
		_hiwtile.append(hcol)
		_floodtile.append(fcol)
		_rocktile.append(rcol)


## BFS distance (in water rings) of every water tile from the nearest map-edge
## water tile, travelling only through 4-connected water. Drives the wave timing.
func _build_water_distance() -> void:
	_wdist = []
	for x in MAP_W:
		var col := []
		col.resize(MAP_H)
		col.fill(-1)
		_wdist.append(col)

	var q: Array[Vector2i] = []
	var head := 0
	for x in MAP_W:
		for y in MAP_H:
			if _terrain[x][y] == WATER and (x == 0 or x == MAP_W - 1 or y == 0 or y == MAP_H - 1):
				_wdist[x][y] = 0
				q.append(Vector2i(x, y))
	while head < q.size():
		var c: Vector2i = q[head]
		head += 1
		var nd: int = _wdist[c.x][c.y] + 1
		for nb: Vector2i in [Vector2i(c.x + 1, c.y), Vector2i(c.x - 1, c.y), Vector2i(c.x, c.y + 1), Vector2i(c.x, c.y - 1)]:
			if _in_bounds(nb.x, nb.y) and _terrain[nb.x][nb.y] == WATER and _wdist[nb.x][nb.y] == -1:
				_wdist[nb.x][nb.y] = nd
				q.append(nb)

	# Water not connected to the edge still cycles, using geometric edge distance.
	for x in MAP_W:
		for y in MAP_H:
			if _terrain[x][y] == WATER and _wdist[x][y] == -1:
				_wdist[x][y] = mini(mini(x, MAP_W - 1 - x), mini(y, MAP_H - 1 - y))

	# Valley-shoulder cells (flooded during the high phase) ride the wave one
	# ring behind the nearest water tile, so the flood spreads with the flow.
	_max_wdist = 0
	for x in MAP_W:
		for y in MAP_H:
			if _terrain[x][y] != WATER and _height[x][y] == SHORE_H:
				var best := -1
				for dx in range(-1, 2):
					for dy in range(-1, 2):
						var nx := x + dx
						var ny := y + dy
						if _in_bounds(nx, ny) and _terrain[nx][ny] == WATER:
							var wd: int = _wdist[nx][ny]
							if best < 0 or wd < best:
								best = wd
				if best >= 0:
					_wdist[x][y] = best + 1
			_max_wdist = maxi(_max_wdist, _wdist[x][y])

	# Group water cells by ring distance. Every cell at a given distance shares
	# the same water phase at any moment, so the fish-on-dry-riverbed check can
	# test one phase per distance instead of one per cell.
	_wcells_by_dist = {}
	for x in MAP_W:
		for y in MAP_H:
			if _terrain[x][y] == WATER and _wdist[x][y] >= 0:
				var d: int = _wdist[x][y]
				if not _wcells_by_dist.has(d):
					_wcells_by_dist[d] = []
				_wcells_by_dist[d].append(Vector2i(x, y))
	_dist_dry = {}


## Water-power phase (HIGH/LOW/DRY) for a water or valley-shoulder tile, with
## fade progress.
## The wave front for cycle k reaches a tile at time k*cycle + dist*ring; the
## tile takes the state of the most recent wave that has reached it, cycling
## HIGH -> LOW -> DRY. Returns [prev_phase, cur_phase, t] where t is the 0..1
## cross-fade progress from prev to cur (1.0 once the fade has finished).
func _water_phase_blend(x: int, y: int) -> Array:
	var d: int = _wdist[x][y]
	if d < 0:
		return [PHASE_LOW, PHASE_LOW, 1.0]
	var since := _time - d * water_ring_seconds
	var k := floori(since / water_cycle_seconds)
	if k < 0:
		return [PHASE_LOW, PHASE_LOW, 1.0]
	var cur := k % 3
	# Before the first wave the tile sits in LOW, so that's what fades out first.
	var prev := (k + 2) % 3 if k > 0 else PHASE_LOW
	var t := 1.0
	if water_fade_seconds > 0.0:
		t = clampf((since - k * water_cycle_seconds) / water_fade_seconds, 0.0, 1.0)
	return [prev, cur, t]


## Sprite for a water cell in the given phase.
func _phase_sprite(phase: int, x: int, y: int) -> int:
	match phase:
		PHASE_HIGH:
			# Dark high-power variant, edges matched to the flood waterline.
			return _hiwtile[x][y] - WATER_DARK_OFFSET   # dark, row 9
		PHASE_DRY:
			return _drytile[x][y]                       # cracked dirt, row 1
		_:
			return _columns[x][y][0]                    # light, row 10


## Picks a single land sprite (water is handled separately by _water_sprite).
## Grass uses the clean diamond tiles; thick variants are applied per-clump in
## _build_columns.
func _pick_land_tile(t: int) -> int:
	if t == DIRT:
		return DIRT_TILES[randi() % DIRT_TILES.size()]
	return GRASS_MAIN[randi() % GRASS_MAIN.size()]


func _in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < MAP_W and y >= 0 and y < MAP_H


## A neighbour counts as "land" if it is in bounds and not water. Out-of-bounds
## is treated as water so the map border stays open (no false shoreline).
func _is_land(x: int, y: int) -> bool:
	return _in_bounds(x, y) and _terrain[x][y] != WATER


func _is_land_above(x: int, y: int, minh: int) -> bool:
	return _is_land(x, y) and _height[x][y] >= minh


## Chooses the shoreline water sprite based on which of the cell's four diamond
## sides touch land at height >= min_land_h. Side -> grid neighbour:
##   TL = (x-1, y)   TR = (x, y-1)   BR = (x+1, y)   BL = (x, y+1)
## min_land_h = 0 gives the normal waterline; GROUND_H gives the flood
## waterline, where the submerged shoulder ring counts as open water.
func _water_sprite(x: int, y: int, min_land_h := 0) -> int:
	var flags := 0
	if _is_land_above(x - 1, y, min_land_h):
		flags |= 1   # TL
	if _is_land_above(x, y - 1, min_land_h):
		flags |= 2   # TR
	if _is_land_above(x + 1, y, min_land_h):
		flags |= 4   # BR
	if _is_land_above(x, y + 1, min_land_h):
		flags |= 8   # BL
	# Returns the LOW-power (light, row 10) base tile. The dynamic water-power
	# cycle darkens it to the row-9 variant at draw time.
	if flags == 0:
		return WATER_OPEN
	# Adjacent/single sides have exact tiles; opposite pairs and triples fall
	# back to the "shore on all sides" tile, which reads cleanly for channels.
	return WATER_EDGE.get(flags, 119)


## One long, contiguous, meandering 2-wide river (>= MIN_RIVER_LEN water tiles).
func _carve_river() -> void:
	var flow_h := randf() < 0.5
	var x := 0
	var y := 0
	var dx := 0
	var dy := 0
	if flow_h:
		var l2r := randf() < 0.5
		x = 0 if l2r else MAP_W - 1
		y = randi() % MAP_H
		dx = 1 if l2r else -1
	else:
		var t2b := randf() < 0.5
		x = randi() % MAP_W
		y = 0 if t2b else MAP_H - 1
		dy = 1 if t2b else -1

	var placed := 0
	var steps := 0
	while steps < 4000 and placed < 500:
		steps += 1
		if _in_bounds(x, y):
			_terrain[x][y] = WATER
			placed += 1
			var wx := x
			var wy := y
			if flow_h:
				wy += 1
			else:
				wx += 1
			if _in_bounds(wx, wy):
				_terrain[wx][wy] = WATER
		var r := randf()
		if flow_h:
			x += dx
			if r < 0.25:
				y += 1
			elif r < 0.5:
				y -= 1
		else:
			y += dy
			if r < 0.25:
				x += 1
			elif r < 0.5:
				x -= 1
		if not _in_bounds(x, y):
			if placed >= maxi(MIN_RIVER_LEN, 40):
				break
			x = clampi(x, 0, MAP_W - 1)
			y = clampi(y, 0, MAP_H - 1)


## Grows a few lakes outward from existing river water, so each lake is connected
## to the river network. Large lakes get islands.
func _carve_lakes() -> void:
	var seeds: Array[Vector2i] = []
	for x in MAP_W:
		for y in MAP_H:
			if _terrain[x][y] == WATER:
				seeds.append(Vector2i(x, y))
	if seeds.is_empty():
		return

	var count := randi_range(lake_min_count, lake_max_count)
	var quarter := MAP_W * MAP_H / 4
	for _i in count:
		var start: Vector2i = seeds.pick_random()
		var large := randf() < lake_large_chance
		var target := randi_range(800, quarter) if large else randi_range(4, 40)
		var blob := _grow_water_blob(start, target)
		if large:
			_add_islands(blob)


## Organic blob growth: repeatedly turns a random frontier cell to water, seeded
## from an existing water cell. Returns the cells added (and already present seed).
func _grow_water_blob(start: Vector2i, target: int) -> Array:
	var blob: Array[Vector2i] = [start]
	var inblob := {start: true}
	var frontier: Array[Vector2i] = []
	_push_neighbors(start, inblob, frontier)
	while blob.size() < target and not frontier.is_empty():
		var j := randi() % frontier.size()
		var c: Vector2i = frontier[j]
		frontier[j] = frontier[frontier.size() - 1]
		frontier.resize(frontier.size() - 1)
		if inblob.has(c):
			continue
		inblob[c] = true
		blob.append(c)
		_terrain[c.x][c.y] = WATER
		_push_neighbors(c, inblob, frontier)
	return blob


func _push_neighbors(c: Vector2i, inblob: Dictionary, frontier: Array) -> void:
	for nb: Vector2i in [Vector2i(c.x + 1, c.y), Vector2i(c.x - 1, c.y), Vector2i(c.x, c.y + 1), Vector2i(c.x, c.y - 1)]:
		if _in_bounds(nb.x, nb.y) and not inblob.has(nb):
			frontier.append(nb)


## Punches islands into a large lake using low-frequency noise, but only on water
## that is at least 2 tiles from any shore, so islands stay surrounded by water.
func _add_islands(blob: Array) -> void:
	var noise := FastNoiseLite.new()
	noise.seed = randi()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = 0.09
	var to_land: Array[Vector2i] = []
	for c: Vector2i in blob:
		if _deep_water(c.x, c.y) and noise.get_noise_2d(float(c.x), float(c.y)) > island_threshold:
			to_land.append(c)
	for c: Vector2i in to_land:
		_terrain[c.x][c.y] = GRASS


## True if every tile within Chebyshev distance 2 is water (deep interior).
func _deep_water(x: int, y: int) -> bool:
	for dx in range(-2, 3):
		for dy in range(-2, 3):
			var nx := x + dx
			var ny := y + dy
			if not _in_bounds(nx, ny) or _terrain[nx][ny] != WATER:
				return false
	return true


# --- rendering --------------------------------------------------------------

func _draw() -> void:
	if _columns.is_empty():
		return
	# Gather entity (tree/boar/stag) sprites, sorted by their iso diagonal so they
	# can be interleaved with the terrain rows below. Each render() returns a dict
	# {d, tex, src, dst, mod} (or {} for nothing to draw); d = grid x + y.
	var ents: Array = []
	for group in [_trees, _boars, _stags, _fish_at.values(), _birds]:
		for e in group:
			var info: Dictionary = e.render()
			if not info.is_empty():
				ents.append(info)
	ents.sort_custom(func(a, b): return a.d < b.d)
	var ei := 0

	# Painter's order: increasing diagonal (x + y), then bottom-to-top per column.
	for s in range(MAP_W + MAP_H - 1):
		var x_start := maxi(0, s - (MAP_H - 1))
		var x_end := mini(MAP_W - 1, s)
		for x in range(x_start, x_end + 1):
			var y := s - x
			var ids: PackedInt32Array = _columns[x][y]
			var base_x := float((x - y) * HALF_W)
			var base_y := float((x + y) * QUARTER_H)
			if _terrain[x][y] == WATER:
				# Look depends on the current water-power phase. While a phase
				# change is fresh, the old state is drawn underneath and the new
				# state fades in on top of it.
				var pb := _effective_phase_blend(x, y)
				var rock: int = _rocktile[x][y]
				# While the river runs high the surface rises above the rocks,
				# so they are drawn first (submerged) instead of on top.
				var submerged: bool = pb[0] == PHASE_HIGH or pb[1] == PHASE_HIGH
				if rock >= 0 and submerged:
					_draw_sprite(rock, base_x, base_y)
				if pb[2] >= 1.0 or pb[0] == pb[1]:
					_draw_water_phase(pb[1], x, y, base_x, base_y)
				else:
					_draw_water_phase(pb[0], x, y, base_x, base_y)
					_draw_water_phase(pb[1], x, y, base_x, base_y, pb[2])
				# Rocks poke out of the water (and sit on the dry riverbed).
				if rock >= 0 and not submerged:
					_draw_sprite(rock, base_x, base_y)
			else:
				for lvl in ids.size():
					_draw_sprite(ids[lvl], base_x, base_y - lvl * STEP)
				# Decoration sits on the surface (top) cube.
				var deco: int = _decor[x][y]
				if deco >= 0:
					_draw_sprite(deco, base_x, base_y - (ids.size() - 1) * STEP)
				# Flood: the valley shoulder is covered by a dark water tile in the high
				# phase. A tree's cell draws its flood AFTER the tree (see _blit_entity)
				# so the water covers the tree base; skip it here in that case.
				if not _tree_at.has(Vector2i(x, y)):
					_draw_cell_flood(x, y, base_x, base_y)
		# Draw entities standing on this diagonal (or just behind it). Tiles on
		# later diagonals are drawn afterwards and so correctly occlude them.
		while ei < ents.size() and ents[ei].d < s + 1.0:
			_blit_entity(ents[ei])
			ei += 1
	# Any entities past the last terrain diagonal.
	while ei < ents.size():
		_blit_entity(ents[ei])
		ei += 1

	# Clouds float in the sky, so they draw last, on top of all terrain and
	# entities, sorted among themselves so nearer clouds overlap farther ones.
	var sky: Array = []
	for cloud in _clouds:
		var ci: Dictionary = cloud.render()
		if not ci.is_empty():
			sky.append(ci)
	sky.sort_custom(func(a, b): return a.d < b.d)
	for ci in sky:
		_blit(ci)


## Blits an entity, then (for trees on a flooding cell) draws that cell's flood
## water over the tree so a tree on a freshly-wet tile looks submerged.
func _blit_entity(info: Dictionary) -> void:
	_blit(info)
	if info.has("cell"):
		var c: Vector2i = info.cell
		_draw_cell_flood(c.x, c.y, float((c.x - c.y) * HALF_W), float((c.x + c.y) * QUARTER_H))


## Blits one entity sprite dict {tex, src, dst, mod} produced by render().
## An optional "label"/"label_pos" draws a small debug tag over the sprite.
func _blit(info: Dictionary) -> void:
	draw_texture_rect_region(info.tex, info.dst, info.src, info.mod)
	if info.has("label"):
		_draw_label(info.label, info.label_pos)


## Draws a small orange box with white text, bottom-centred on anchor.
func _draw_label(text: String, anchor: Vector2) -> void:
	var font := ThemeDB.fallback_font
	var fs := 8
	var pad := Vector2(2.0, 1.0)
	var sz := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var box := Rect2(anchor - Vector2(sz.x * 0.5 + pad.x, sz.y + pad.y * 2.0), sz + pad * 2.0)
	draw_rect(box, Color(1.0, 0.5, 0.0))
	draw_string(font, Vector2(box.position.x + pad.x, box.position.y + pad.y + font.get_ascent(fs)),
		text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)


## Draws the valley-shoulder flood water over cell (x,y), cross-fading with the
## wave. Does nothing if the cell has no flood tile or the wave isn't high here.
func _draw_cell_flood(x: int, y: int, base_x: float, base_y: float) -> void:
	var fl: int = _floodtile[x][y]
	if fl < 0:
		return
	var pb := _effective_phase_blend(x, y)
	var fy := base_y - float((SHORE_H + 1) * STEP)
	if pb[1] == PHASE_HIGH:
		var a: float = pb[2] if pb[0] != PHASE_HIGH else 1.0
		_draw_flood(fl - WATER_DARK_OFFSET, base_x, fy, a)
	elif pb[0] == PHASE_HIGH and pb[2] < 1.0:
		var t: float = pb[2]
		if t < FLOOD_CALM_T:
			_draw_flood(fl, base_x, fy, 1.0)
			_draw_flood(fl - WATER_DARK_OFFSET, base_x, fy, 1.0 - t / FLOOD_CALM_T)
		else:
			_draw_flood(fl, base_x, fy, 1.0 - (t - FLOOD_CALM_T) / (1.0 - FLOOD_CALM_T))


## Boost-aware water phase: like _water_phase_blend, but tiles currently wet by a
## heavy-rain cloud are shifted up one level (dry->low, low->high; phase numbers
## run HIGH=0 < LOW=1 < DRY=2, so more water means a smaller number).
func _effective_phase_blend(x: int, y: int) -> Array:
	var pb := _water_phase_blend(x, y)
	if _boosted.has(Vector2i(x, y)):
		return [maxi(0, int(pb[0]) - 1), maxi(0, int(pb[1]) - 1), pb[2]]
	return pb


## Heavy-rain clouds wet the 3x3 of river tiles under them; each becomes a +1
## water-level source that lingers rain_boost_seconds after the cloud passes.
## The boost spreads through connected water up to rain_boost_radius tiles, then
## recedes. _boosted lists every cell raised a level this frame.
func _update_rain_boost() -> void:
	for cloud in _clouds:
		if not cloud.is_heavy_rain():
			continue
		var center := Vector2i(roundi(cloud.pos.x), roundi(cloud.pos.y))
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var c := center + Vector2i(dx, dy)
				if _in_bounds(c.x, c.y) and _terrain[c.x][c.y] == WATER:
					_rain_until[c] = _time + rain_boost_seconds
	for c: Vector2i in _rain_until.keys():
		if _rain_until[c] <= _time:
			_rain_until.erase(c)
	# Spread outward from live sources through connected water, capped by radius.
	_boosted = {}
	var frontier: Array = []
	for c: Vector2i in _rain_until:
		_boosted[c] = true
		frontier.append([c, 0])
	var head := 0
	while head < frontier.size():
		var item: Array = frontier[head]
		head += 1
		var cell: Vector2i = item[0]
		var dist: int = item[1]
		if dist >= rain_boost_radius:
			continue
		for nb: Vector2i in [Vector2i(cell.x + 1, cell.y), Vector2i(cell.x - 1, cell.y), Vector2i(cell.x, cell.y + 1), Vector2i(cell.x, cell.y - 1)]:
			if _in_bounds(nb.x, nb.y) and _terrain[nb.x][nb.y] == WATER and not _boosted.has(nb):
				_boosted[nb] = true
				frontier.append([nb, dist + 1])


## Draws a water cell in the given phase at fade alpha a. During the high phase
## the surface rises to the flood waterline (SHORE_H + 1 levels up); a second
## cube is kept at the base level so no gap opens beneath the raised surface.
func _draw_water_phase(phase: int, x: int, y: int, px: float, py: float, a := 1.0) -> void:
	var n := _phase_sprite(phase, x, y)
	match phase:
		PHASE_HIGH:
			_draw_sprite(n, px, py, a)
			_draw_sprite(n, px, py - float((SHORE_H + 1) * STEP), a)
		PHASE_DRY:
			_draw_sprite(n, px, py + DRY_DROP, a)
		_:
			_draw_sprite(n, px, py, a)


## Draws flood water sprite n at flood strength a (0..1). The sprite is drawn
## twice — the second pass at a * flood_density — so the submerged land
## underneath is substantially (but not completely) hidden.
func _draw_flood(n: int, px: float, py: float, a: float) -> void:
	_draw_sprite(n, px, py, a)
	if flood_density > 0.0:
		_draw_sprite(n, px, py, a * flood_density)


func _draw_sprite(n: int, px: float, py: float, alpha := 1.0) -> void:
	var src := Rect2((n % SHEET_COLS) * TILE_PX, (n / SHEET_COLS) * TILE_PX, TILE_PX, TILE_PX)
	draw_texture_rect_region(_sheet, Rect2(px, py, TILE_PX, TILE_PX), src, Color(1, 1, 1, alpha))


func _center_camera() -> void:
	# Cell (64,64): screen ((x-y)*16, (x+y)*8) = (0, 1024).
	camera.position = Vector2(0.0, float((MAP_W + MAP_H) / 2 * QUARTER_H))
