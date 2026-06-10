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
const UiPanelScript := preload("res://scripts/ui_panel.gd")

# Clouds drift in from the upwind edge and are removed once they pass the
# downwind edge. These are the grid margins, in cells, beyond the edge for
# spawning and despawning.
const CLOUD_SPAWN_MARGIN := 6.0
const CLOUD_EXIT_MARGIN := 20.0
# Wind speed UI step and ceiling (cells/sec); speed can be nudged down to 0.
const WIND_STEP := 0.05
const WIND_MAX := 1.0
# A cloud bank is scattered this many cells across the entry edge and back from
# it, so the clouds read as one large, ragged bank rather than a neat line.
const CLOUD_BANK_SPREAD := 22.0
const CLOUD_BANK_DEPTH := 16.0

enum { GRASS, DIRT, WATER }

# Tile pools as SPRITE NUMBERS (row-major over the 11x11 sheet).
# Grass: the three clean diamond tiles are the default; the thicker/leafier
# variants (row 2 col 7 .. row 3 col 3) appear in grown clumps, not at random.
const GRASS_MAIN := [22, 23, 24]
# The middle GRASS_MAIN tile (row 2, col 1): the "thicker" grass that the other
# two plain grass tiles temporarily become when heavy rain falls on them.
const GRASS_LUSH := 23
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
# While a tile is the leading edge of a RISING water-power wave it is drawn as
# the shoreline tile whose land-abutting sides face the wave's direction of
# travel, lifted by this many pixels, so the front reads as a rushing wave lip.
const RUSH_LIFT := TILE_PX / 6.0
# Splash: when arriving high (power 2) water slaps against land it doesn't
# cover, a one-shot splash animation plays on that tile. The sheet is a 1x8
# strip played start-to-finish in SPLASH_SECONDS.
const SPLASH_FRAMES := 8
const SPLASH_SECONDS := 0.75
const SPLASH_SCALE := 0.03    # source frames are 732x704; ~22px on screen
const SPLASH_SQUASH := 0.5    # extra vertical-only squash (height = scale * this)
# Row 1 (cracked dirt) is shown when a water cell is in the dry phase.
const DRY_TILES := [11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21]
# Water's top face sits ~4px lower than land's, so dry tiles are drawn this many
# pixels lower to keep their surface level with the water they replace.
const DRY_DROP := 4.0
# Water-power cycle phases (advance one per cycle as the wave passes).
const PHASE_HIGH := 0   # dark, row 9; floods the valley shoulder one level up
const PHASE_LOW := 1    # light, row 10
const PHASE_DRY := 2    # no water, row 1 cracked dirt
# When a flooded shoulder tile un-floods, this fraction of the fade window is
# spent quickly turning the dark flood water into the light low-power tile; the
# light tile then drains away over the remainder stretched by FLOOD_DRY_MULT,
# so the bank lingers wet and dries out gradually instead of blinking dry.
const FLOOD_CALM_T := 0.3
const FLOOD_DRY_MULT := 4.0

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
# Trees grow in copses: copse_count seeds each grow into a clustered stand of
# copse_min..copse_max trees (organic blob growth, like thick grass), with
# copse_density controlling how tightly packed the stand is. lone_tree_count
# scattered singles round the woodland out. Each tree cycles through all its
# growth stages.
@export var copse_count := 70
@export var copse_min := 4
@export var copse_max := 14
@export_range(0.1, 1.0) var copse_density := 0.7
@export var lone_tree_count := 60
# Clouds arrive in banks: a bank of cloud_group_min..cloud_group_max clouds
# drifts in when the map loads, then a new bank arrives every
# cloud_spawn_min..cloud_spawn_max seconds. Clouds in a bank are offset within
# CLOUD_BANK_SPREAD across the entry edge and CLOUD_BANK_DEPTH back from it.
# The interval is sized against the slow wind speed so successive banks stay
# clearly separated clumps (gap = interval * wind speed > bank spread).
@export var cloud_group_min := 3
@export var cloud_group_max := 11
@export var cloud_spawn_min := 120.0
@export var cloud_spawn_max := 300.0
# Chance, per river cell, that a fish is left flopping when that cell dries out.
@export_range(0.0, 1.0) var fish_chance := 0.004
# Heavy-rain and thunderstorm clouds raise the water level of the river tiles
# where their rain meets the ground (and one tile around) for this long after
# passing; the boost spreads through connected water up to rain_boost_radius
# tiles, flooding the adjacent shoulder ring, before receding.
@export var rain_boost_seconds := 10.0
@export_range(1, 30) var rain_boost_radius := 5
# Puddles: land tiles in the rain footprint accumulate surface water, reaching
# full depth after rain_pool_seconds of rain and draining away again over
# rain_dry_seconds once the rain has moved on.
@export_range(1, 10) var rain_wet_radius := 2
@export var rain_pool_seconds := 4.0
@export var rain_dry_seconds := 12.0
@export_range(0.0, 1.0) var puddle_max_alpha := 0.65
# Rained-on dirt sprouts grass: the cell turns to a grass tile and reverts to
# its old dirt tile this many seconds after rain last touched it.
@export var rain_grass_seconds := 60.0
# Rained-on plain grass (the two non-lush GRASS_MAIN tiles) thickens to the
# GRASS_LUSH tile, reverting this many seconds after rain last touched it.
@export var rain_lush_seconds := 60.0
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
var _rushtile: Array = []       # _rushtile[x][y]  -> leading-edge wave sprite (water cells)
var _splash_sheet: Texture2D
var _splash_by_dist: Dictionary = {}  # ring distance -> Array[Vector2i] of splash cells
var _dist_high: Dictionary = {}       # ring distance -> bool (ring is in the HIGH phase)
var _splashes: Dictionary = {}        # Vector2i -> start time of a live splash
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
var _wetness: Dictionary = {}   # Vector2i land cell -> 0..1 accumulated puddle water
var _grassed: Dictionary = {}   # Vector2i dirt cell rained into grass -> {until, old sprite}
var _lushed: Dictionary = {}    # Vector2i grass cell rained lush -> {until, old sprite}
var _storm := false             # UI storm toggle: all clouds held at thunderstorm
# Wind, shared by all clouds (UI-controlled). The direction is the grid-space
# drift of the clouds; the default +y means wind FROM the NE (top-right).
var wind_dir := Vector2(0.0, 1.0)
var wind_speed := 0.25          # cells/sec
var _wdist: Array = []          # _wdist[x][y]   -> water rings from map edge (-1 if not water)
var _max_wdist := 0             # largest _wdist value (bounds the fade window)
var _time := 0.0                # seconds since start, drives the water cycle
var _last_tick := -1            # last ring tick that triggered a redraw


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # crisp pixel art
	_sheet = load("res://assets/spritesheet.png")
	_splash_sheet = load("res://assets/environment/splash_sprites.png")
	randomize()
	_generate()
	_center_camera()
	var ui: CanvasLayer = UiPanelScript.new()
	ui.setup(self)
	add_child(ui)


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
	_build_splash_cells()
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
	_wetness = {}
	_grassed = {}
	_lushed = {}
	_boars = _spawn_herd(BoarScript, randi_range(boar_min_count, boar_max_count))
	_stags = _spawn_herd(StagScript, randi_range(stag_min_count, stag_max_count))
	_spawn_trees()
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


## Seeds a few banks already spread across the sky (so clouds are visible right
## away, not a minute's drift away), spaced apart along the wind axis so they
## read as separate clumps, and arms the timer for the next bank.
func _spawn_clouds() -> void:
	_clouds = []
	var perp := Vector2(wind_dir.y, -wind_dir.x)
	for i in 3:
		var base := Vector2(MAP_W * 0.5, MAP_H * 0.5) \
			+ wind_dir * (MAP_H * 0.35 * (i - 1) + randf_range(-4.0, 4.0)) \
			+ perp * randf_range(-0.2, 0.2) * MAP_W
		_add_cloud_bank(true, base)
	_next_cloud = randf_range(cloud_spawn_min, cloud_spawn_max)


## Adds a bank of cloud_group_min..cloud_group_max clouds, scattered around a
## base spot so they read as one large, ragged bank. With over_map the bank is
## centred on base (in grid cells, so load-time banks can be spaced apart);
## otherwise it enters just off the upwind edge and drifts in.
func _add_cloud_bank(over_map := false, base := Vector2.ZERO) -> void:
	var d := wind_dir
	var perp := Vector2(d.y, -d.x)
	if not over_map:
		base = Vector2(MAP_W * 0.5, MAP_H * 0.5) \
			- d * (MAP_W * 0.5 + CLOUD_SPAWN_MARGIN) \
			+ perp * randf_range(-MAP_W * 0.5, MAP_W * 0.5)
	for _i in randi_range(cloud_group_min, cloud_group_max):
		var c: Node2D = CloudScript.new()
		add_child(c)
		var off := perp * randf_range(-CLOUD_BANK_SPREAD, CLOUD_BANK_SPREAD)
		if over_map:
			off += d * randf_range(-CLOUD_BANK_DEPTH, CLOUD_BANK_DEPTH)
		else:
			off -= d * randf_range(0.0, CLOUD_BANK_DEPTH)   # further back upwind
		c.setup(self, base + off)
		if _storm:
			c.force_thunder()
		_clouds.append(c)


## Plants trees in copses: copse_count seeds dropped on random grass cells each
## grow into a clustered stand (the same organic blob growth as lakes and thick
## grass), planting a tree on ~copse_density of the stand's cells until it
## holds copse_min..copse_max trees. Seeds that miss grass are discarded, then
## lone_tree_count scattered singles are added.
func _spawn_trees() -> void:
	_trees = []
	_tree_at = {}
	for _i in copse_count:
		var start := Vector2i(randi() % MAP_W, randi() % MAP_H)
		if not _tree_cell_ok(start):
			continue
		var target := randi_range(copse_min, copse_max)
		_plant_tree(start)
		var planted := 1
		var inblob := {start: true}
		var frontier: Array[Vector2i] = []
		_push_tree_neighbors(start, inblob, frontier)
		while planted < target and not frontier.is_empty():
			var j := randi() % frontier.size()
			var c: Vector2i = frontier[j]
			frontier[j] = frontier[frontier.size() - 1]
			frontier.resize(frontier.size() - 1)
			if inblob.has(c):
				continue
			inblob[c] = true
			if randf() < copse_density:
				_plant_tree(c)
				planted += 1
			_push_tree_neighbors(c, inblob, frontier)
	var placed := 0
	var tries := 0
	while placed < lone_tree_count and tries < 4000:
		tries += 1
		var c := Vector2i(randi() % MAP_W, randi() % MAP_H)
		if _tree_cell_ok(c):
			_plant_tree(c)
			placed += 1


## True for a plain-grass cell (not dirt, water, or stone) with no tree on it.
func _tree_cell_ok(c: Vector2i) -> bool:
	return _is_plain_grass(c.x, c.y) and not _tree_at.has(c)


func _plant_tree(c: Vector2i) -> void:
	var t: Node2D = TreeScript.new()
	add_child(t)
	t.setup(self, c)
	_trees.append(t)
	_tree_at[c] = t


func _push_tree_neighbors(c: Vector2i, inblob: Dictionary, frontier: Array) -> void:
	for nb: Vector2i in [Vector2i(c.x + 1, c.y), Vector2i(c.x - 1, c.y), Vector2i(c.x, c.y + 1), Vector2i(c.x, c.y - 1)]:
		if _tree_cell_ok(nb) and not inblob.has(nb):
			frontier.append(nb)


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


# --- UI panel API (see scripts/ui_panel.gd) ----------------------------------

## Number of live critters of the given kind: "boar", "stag", "bird", "cloud".
func critter_count(kind: String) -> int:
	match kind:
		"boar": return _boars.size()
		"stag": return _stags.size()
		"bird": return _birds.size()
		"cloud": return _clouds.size()
	return 0


## Spawns one critter of the given kind at a random valid spot.
func spawn_critter(kind: String) -> void:
	match kind:
		"boar":
			_boars.append_array(_spawn_herd(BoarScript, 1))
		"stag":
			_stags.append_array(_spawn_herd(StagScript, 1))
		"bird":
			var b: Node2D = BirdScript.new()
			add_child(b)
			b.setup(self, Vector2i(randi() % MAP_W, randi() % MAP_H))
			_birds.append(b)
		"cloud":
			# Spawned somewhere over the upper half of the map (rather than off
			# the entry edge) so the new cloud is visible right away.
			var c: Node2D = CloudScript.new()
			add_child(c)
			c.setup(self, Vector2(randf_range(0.0, MAP_W), randf_range(0.0, MAP_H * 0.5)))
			if _storm:
				c.force_thunder()
			_clouds.append(c)


## Current wind as a grid-space velocity (cells/sec) for clouds to drift by.
func wind_vector() -> Vector2:
	return wind_dir * wind_speed


## Sets where the wind blows FROM ("NE", "SE", "NW", "SW", as the UI shows it);
## clouds drift the opposite way and new banks enter from that edge.
## Iso compass: NE = top-right (-y), SE = bottom-right (+x),
## NW = top-left (-x), SW = bottom-left (+y).
func set_wind_from(dirname: String) -> void:
	match dirname:
		"NE": wind_dir = Vector2(0.0, 1.0)
		"SE": wind_dir = Vector2(-1.0, 0.0)
		"NW": wind_dir = Vector2(1.0, 0.0)
		"SW": wind_dir = Vector2(0.0, -1.0)


## Raises or lowers the wind speed by the given amount, clamped to 0..WIND_MAX.
func nudge_wind(amount: float) -> void:
	wind_speed = clampf(wind_speed + amount, 0.0, WIND_MAX)


## Whether the all-clouds thunderstorm toggle is active.
func is_storm() -> bool:
	return _storm


## Turns every cloud into a held thunderstorm (on), or restarts every cloud's
## normal weather cycle (off). New clouds spawned while the storm is on are
## thunderstorms too.
func set_storm(on: bool) -> void:
	_storm = on
	for c in _clouds:
		if on:
			c.force_thunder()
		else:
			c.restart_cycle()


## Removes one random critter of the given kind (clouds drift off on their own).
func remove_critter(kind: String) -> void:
	var arr: Array
	match kind:
		"boar": arr = _boars
		"stag": arr = _stags
		"bird": arr = _birds
		_: return
	if arr.is_empty():
		return
	var i := randi() % arr.size()
	arr[i].queue_free()
	arr.remove_at(i)


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


## Distance in cells from grid position p to the nearest raining (heavy or
## thunder) cloud's ground contact point; INF when nothing is raining.
func rain_distance(p: Vector2) -> float:
	var best := INF
	for cloud in _clouds:
		if cloud.is_heavy_rain():
			best = minf(best, p.distance_to(Vector2(cloud.rain_cell())))
	return best


## Ground contact point of the nearest raining cloud, or Vector2.INF if none.
func nearest_rain(p: Vector2) -> Vector2:
	var best := Vector2.INF
	var best_d := INF
	for cloud in _clouds:
		if cloud.is_heavy_rain():
			var q := Vector2(cloud.rain_cell())
			var d := p.distance_squared_to(q)
			if d < best_d:
				best_d = d
				best = q
	return best


## True if a living tree stands on cell c.
func has_tree(c: Vector2i) -> bool:
	return _tree_at.has(c)


## Grid position of the nearest living tree to p, or Vector2.INF if none.
func nearest_tree(p: Vector2) -> Vector2:
	var best := Vector2.INF
	var best_d := INF
	for c: Vector2i in _tree_at:
		var d := p.distance_squared_to(Vector2(c))
		if d < best_d:
			best_d = d
			best = Vector2(c)
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
	_update_splashes()
	_update_rain_boost(delta)
	# Entities animate and move continuously, and they're composited into _draw,
	# so the scene must redraw every frame whenever any are present.
	if not _boars.is_empty() or not _stags.is_empty() or not _trees.is_empty() \
			or not _clouds.is_empty() or not _fish_at.is_empty() or not _rain_until.is_empty() \
			or not _birds.is_empty() or not _wetness.is_empty() or not _grassed.is_empty() \
			or not _lushed.is_empty() or not _splashes.is_empty():
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


## Frees clouds that have drifted past the downwind edge of the map.
func _reap_clouds() -> void:
	if _clouds.is_empty():
		return
	var center := Vector2(MAP_W * 0.5, MAP_H * 0.5)
	var limit := MAP_W * 0.5 + CLOUD_EXIT_MARGIN
	var alive: Array = []
	for c in _clouds:
		if (c.pos - center).dot(wind_dir) > limit:
			c.queue_free()
		else:
			alive.append(c)
	if alive.size() != _clouds.size():
		_clouds = alive


## Cells where arriving high water meets land it doesn't cover: water tiles and
## flood-able shoulder tiles whose flood-waterline sprite has a land-facing
## edge (i.e. isn't open water at the flood level), grouped by ring distance so
## the wave watcher can trigger a whole ring's splashes at once.
func _build_splash_cells() -> void:
	_splash_by_dist = {}
	_dist_high = {}
	_splashes = {}
	for x in MAP_W:
		for y in MAP_H:
			var d: int = _wdist[x][y]
			if d < 0:
				continue
			var edge := -1
			if _terrain[x][y] == WATER:
				edge = _hiwtile[x][y]
			elif _height[x][y] == SHORE_H:
				edge = _floodtile[x][y]
			if edge >= 0 and edge != WATER_OPEN:
				if not _splash_by_dist.has(d):
					_splash_by_dist[d] = []
				_splash_by_dist[d].append(Vector2i(x, y))


## Water-power phase of ring distance d at the current time (no fade info).
func _dist_phase(d: int) -> int:
	var since := _time - d * water_ring_seconds
	if since < 0.0:
		return PHASE_LOW
	return floori(since / water_cycle_seconds) % 3


## The moment a ring enters the HIGH phase, every splash cell at that distance
## starts a one-shot splash; finished splashes are dropped.
func _update_splashes() -> void:
	for d in _splash_by_dist:
		var high := _dist_phase(d) == PHASE_HIGH
		if high and not _dist_high.get(d, false):
			for c: Vector2i in _splash_by_dist[d]:
				_splashes[c] = _time
		_dist_high[d] = high
	for c: Vector2i in _splashes.keys():
		if _time - _splashes[c] >= SPLASH_SECONDS:
			_splashes.erase(c)


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
	# The shoulder's slow drying (see _draw_cell_flood) outlasts the normal fade.
	var tail := water_fade_seconds * (FLOOD_CALM_T + (1.0 - FLOOD_CALM_T) * FLOOD_DRY_MULT)
	var span := _max_wdist * water_ring_seconds + maxf(water_fade_seconds, tail)
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
	_rushtile = []
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
		var rushcol := []
		rushcol.resize(MAP_H)
		rushcol.fill(-1)
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
				# Leading-edge wave lip shown while a rising wave passes through.
				rushcol[y] = _rush_sprite(x, y)
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
		_rushtile.append(rushcol)


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
## HIGH -> LOW -> DRY. Returns [prev_phase, cur_phase, t, secs] where t is the
## 0..1 cross-fade progress from prev to cur (1.0 once the fade has finished)
## and secs is the raw seconds since cur began (for effects, like the shoulder
## drying out, that outlast the fade window).
func _water_phase_blend(x: int, y: int) -> Array:
	var d: int = _wdist[x][y]
	if d < 0:
		return [PHASE_LOW, PHASE_LOW, 1.0, INF]
	var since := _time - d * water_ring_seconds
	var k := floori(since / water_cycle_seconds)
	if k < 0:
		return [PHASE_LOW, PHASE_LOW, 1.0, INF]
	var cur := k % 3
	# Before the first wave the tile sits in LOW, so that's what fades out first.
	var prev := (k + 2) % 3 if k > 0 else PHASE_LOW
	var secs := since - k * water_cycle_seconds
	var t := 1.0
	if water_fade_seconds > 0.0:
		t = clampf(secs / water_fade_seconds, 0.0, 1.0)
	return [prev, cur, t, secs]


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


## Leading-edge wave sprite for water cell (x,y): reuses the shoreline tiles,
## but the "land" sides are the DOWNSTREAM sides — water neighbours the wave
## reaches next (greater ring distance) — so the tile's raised lip faces the
## wave's direction of travel. E.g. a wave moving top-right -> bottom-left has
## its downstream side at BL and uses row 10 col 4. Local maxima (nowhere
## further to flow) fall back to open water.
func _rush_sprite(x: int, y: int) -> int:
	var d: int = _wdist[x][y]
	var flags := 0
	if _is_downstream(x - 1, y, d):
		flags |= 1   # TL
	if _is_downstream(x, y - 1, d):
		flags |= 2   # TR
	if _is_downstream(x + 1, y, d):
		flags |= 4   # BR
	if _is_downstream(x, y + 1, d):
		flags |= 8   # BL
	if flags == 0:
		return WATER_OPEN
	return WATER_EDGE.get(flags, 119)


func _is_downstream(x: int, y: int, d: int) -> bool:
	return _in_bounds(x, y) and _terrain[x][y] == WATER and _wdist[x][y] > d


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
				# A RISING wave (more water: smaller phase number) shows a raised
				# leading-edge lip for the first ring tick after it arrives; the
				# old phase is kept underneath so no gap opens below the lip.
				if pb[1] < pb[0] and pb[3] < water_ring_seconds:
					_draw_water_phase(pb[0], x, y, base_x, base_y)
					var lip: int = _rushtile[x][y]
					if pb[1] == PHASE_HIGH:
						lip -= WATER_DARK_OFFSET
					_draw_sprite(lip, base_x, base_y - RUSH_LIFT)
				elif pb[2] >= 1.0 or pb[0] == pb[1]:
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
				# Rain puddle: translucent open water over the surface cube, alpha
				# tracking accumulation. Water's face sits DRY_DROP px lower than
				# land's within the sprite, so it is drawn that much higher.
				var wet: float = _wetness.get(Vector2i(x, y), 0.0)
				if wet > 0.0:
					_draw_sprite(WATER_OPEN, base_x,
						base_y - (ids.size() - 1) * STEP - DRY_DROP, wet * puddle_max_alpha)
				# Flood: the valley shoulder is covered by a dark water tile in the high
				# phase. A tree's cell draws its flood AFTER the tree (see _blit_entity)
				# so the water covers the tree base; skip it here in that case.
				if not _tree_at.has(Vector2i(x, y)):
					_draw_cell_flood(x, y, base_x, base_y)
			# One-shot splash where arriving high water slaps against land it
			# doesn't cover, anchored on the flood waterline.
			var sp: float = _splashes.get(Vector2i(x, y), -1.0)
			if sp >= 0.0:
				_draw_splash(_time - sp, base_x, base_y - float((SHORE_H + 1) * STEP))
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
	elif pb[0] == PHASE_HIGH:
		# Drying out: the dark flood calms quickly into the light low-power tile,
		# which then lingers and drains away over a window FLOOD_DRY_MULT times
		# longer than the rest of the fade, so the bank dries gradually.
		var secs: float = pb[3]
		var calm := FLOOD_CALM_T * water_fade_seconds
		var drain := (1.0 - FLOOD_CALM_T) * water_fade_seconds * FLOOD_DRY_MULT
		if secs < calm:
			_draw_flood(fl, base_x, fy, 1.0)
			_draw_flood(fl - WATER_DARK_OFFSET, base_x, fy, 1.0 - secs / calm)
		elif secs < calm + drain:
			_draw_flood(fl, base_x, fy, 1.0 - (secs - calm) / drain)


## Boost-aware water phase: like _water_phase_blend, but tiles currently wet by a
## heavy-rain cloud are shifted up one level (dry->low, low->high; phase numbers
## run HIGH=0 < LOW=1 < DRY=2, so more water means a smaller number).
func _effective_phase_blend(x: int, y: int) -> Array:
	var pb := _water_phase_blend(x, y)
	if _boosted.has(Vector2i(x, y)):
		return [maxi(0, int(pb[0]) - 1), maxi(0, int(pb[1]) - 1), pb[2], pb[3]]
	return pb


## Heavy-rain and thunderstorm clouds wet the 3x3 of river tiles where their
## rain visually meets the ground; each becomes a +1 water-level source that
## lingers rain_boost_seconds after the cloud passes. The boost spreads through
## connected water up to rain_boost_radius tiles, then recedes, and spills onto
## the adjacent valley-shoulder ring so the buildup is visible as flooding.
## _boosted lists every cell raised a level this frame. Land cells in the rain
## footprint accumulate puddle water (_wetness), which drains once rain stops.
func _update_rain_boost(delta: float) -> void:
	var rained := {}
	for cloud in _clouds:
		if not cloud.is_heavy_rain():
			continue
		var center: Vector2i = cloud.rain_cell()
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var c := center + Vector2i(dx, dy)
				if _in_bounds(c.x, c.y) and _terrain[c.x][c.y] == WATER:
					_rain_until[c] = _time + rain_boost_seconds
		# Land under the rain soaks. The footprint is a disc, not the full square:
		# corners beyond the radius are skipped, and each cell's wetness is capped
		# by a falloff with distance from the centre, so puddles fill deepest in
		# the middle and stay shallow at the rim instead of forming a hard square.
		for dx in range(-rain_wet_radius, rain_wet_radius + 1):
			for dy in range(-rain_wet_radius, rain_wet_radius + 1):
				var dist := Vector2(dx, dy).length()
				if dist > rain_wet_radius + 0.5:
					continue
				var c := center + Vector2i(dx, dy)
				if _in_bounds(c.x, c.y) and _terrain[c.x][c.y] != WATER:
					rained[c] = true
					var cap := clampf((rain_wet_radius + 0.5 - dist) / rain_wet_radius, 0.0, 1.0)
					var w: float = _wetness.get(c, 0.0)
					# Grow toward the local cap; never let rain lower existing water.
					_wetness[c] = maxf(w, minf(cap, w + delta / rain_pool_seconds))
					# Rained-on dirt sprouts grass; fresh rain refreshes the timer.
					if _grassed.has(c):
						_grassed[c].until = _time + rain_grass_seconds
					elif _terrain[c.x][c.y] == DIRT and not _stone[c.x][c.y]:
						var ids: PackedInt32Array = _columns[c.x][c.y]
						var top := ids.size() - 1
						_grassed[c] = {until = _time + rain_grass_seconds, old = ids[top]}
						_columns[c.x][c.y][top] = GRASS_MAIN[randi() % GRASS_MAIN.size()]
						_terrain[c.x][c.y] = GRASS
					# Rained-on plain grass thickens to the lush tile. Cells that
					# are temporary grass themselves (_grassed) are skipped so the
					# two reverts can't fight over the original sprite.
					if _lushed.has(c):
						_lushed[c].until = _time + rain_lush_seconds
					elif not _grassed.has(c) and _terrain[c.x][c.y] == GRASS \
							and not _stone[c.x][c.y]:
						var gids: PackedInt32Array = _columns[c.x][c.y]
						var gtop := gids.size() - 1
						if gids[gtop] != GRASS_LUSH and GRASS_MAIN.has(gids[gtop]):
							_lushed[c] = {until = _time + rain_lush_seconds, old = gids[gtop]}
							_columns[c.x][c.y][gtop] = GRASS_LUSH
	# Cells no longer under rain dry back out and are dropped at zero.
	for c: Vector2i in _wetness.keys():
		if rained.has(c):
			continue
		var w: float = _wetness[c] - delta / rain_dry_seconds
		if w <= 0.0:
			_wetness.erase(c)
		else:
			_wetness[c] = w
	# Temporary grass reverts to its old dirt tile once its timer runs out.
	for c: Vector2i in _grassed.keys():
		if _grassed[c].until <= _time:
			_columns[c.x][c.y][_columns[c.x][c.y].size() - 1] = _grassed[c].old
			_terrain[c.x][c.y] = DIRT
			_grassed.erase(c)
	# Thickened grass reverts to its original plain tile the same way.
	for c: Vector2i in _lushed.keys():
		if _lushed[c].until <= _time:
			_columns[c.x][c.y][_columns[c.x][c.y].size() - 1] = _lushed[c].old
			_lushed.erase(c)
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
	# Spill onto the valley shoulder: shore cells beside boosted water ride the
	# boost too, so _draw_cell_flood shows the high water flooding the banks.
	var shores: Array[Vector2i] = []
	for cell: Vector2i in _boosted:
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var n := Vector2i(cell.x + dx, cell.y + dy)
				if _in_bounds(n.x, n.y) and _terrain[n.x][n.y] != WATER \
						and _height[n.x][n.y] == SHORE_H and not _boosted.has(n):
					shores.append(n)
	for n in shores:
		_boosted[n] = true


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


## Draws one frame of the splash animation, bottom-centred on the tile whose
## (raised, flood-level) cube top-left is at (px, py). The whole 8-frame strip
## plays once over SPLASH_SECONDS.
func _draw_splash(elapsed: float, px: float, py: float) -> void:
	var i := int(elapsed / SPLASH_SECONDS * SPLASH_FRAMES)
	if i < 0 or i >= SPLASH_FRAMES or _splash_sheet == null:
		return
	var fw := _splash_sheet.get_width() / float(SPLASH_FRAMES)
	var fh := float(_splash_sheet.get_height())
	var w := fw * SPLASH_SCALE
	var h := fh * SPLASH_SCALE * SPLASH_SQUASH
	# Feet on the water surface: the face centre sits ~QUARTER_H + DRY_DROP
	# below the cube's top-left corner.
	var foot := py + QUARTER_H + DRY_DROP
	draw_texture_rect_region(_splash_sheet,
		Rect2(px + (TILE_PX - w) * 0.5, foot - h, w, h),
		Rect2(i * fw, 0.0, fw, fh))


func _draw_sprite(n: int, px: float, py: float, alpha := 1.0) -> void:
	var src := Rect2((n % SHEET_COLS) * TILE_PX, (n / SHEET_COLS) * TILE_PX, TILE_PX, TILE_PX)
	draw_texture_rect_region(_sheet, Rect2(px, py, TILE_PX, TILE_PX), src, Color(1, 1, 1, alpha))


func _center_camera() -> void:
	# Cell (64,64): screen ((x-y)*16, (x+y)*8) = (0, 1024).
	camera.position = Vector2(0.0, float((MAP_W + MAP_H) / 2 * QUARTER_H))
