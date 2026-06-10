extends Node2D
## A cloud that drifts across the map on the wind and runs through a weather
## cycle while it crosses.
##
## Sheet: assets/environment/cloud sprites.png, a 3x5 grid (15 sprites). Sprite
## numbers are 1-based row-major (1 = row0 col0 ... 15 = row2 col4); FRAMES holds
## each sprite's tight content rect, indexed 0-based (sprite N -> FRAMES[N-1]).
##
## Weather cycle (each phase lasts PHASE_MIN..PHASE_MAX seconds, then the cycle
## repeats): dry, light, heavy, light, heavy, thunder, light, dry.
##   dry     - sprite 1, "breathing" (slowly scales up and back); full speed.
##   light   - sprites 2,3,6,7 animated; moves at 75% wind speed.
##   heavy   - sprites 4,5,8,9,10 animated; moves at 25% wind speed.
##   thunder - the last row (11..15) looped in THUNDER_SECONDS; full speed.
##
## Wind direction and speed are owned by main (see main.wind_vector and the UI
## wind controls); by default it blows from the top-right (NE) toward the
## bottom-left, the +y direction on the iso grid. main spawns clouds off the
## upwind edge and removes them once they drift past the downwind edge (see
## main._reap_clouds).

const HALF_W := 16            # iso horizontal half-step (matches main.gd)
const QUARTER_H := 8          # iso vertical step

# Tight content rect (x, y, w, h) of each of the 15 cloud sprites on the sheet.
const FRAMES := [
	Rect2(53, 105, 233, 147),   # 1  dry
	Rect2(323, 105, 234, 169),  # 2  light
	Rect2(614, 102, 232, 206),  # 3  light
	Rect2(889, 104, 239, 232),  # 4  heavy
	Rect2(1190, 104, 242, 224), # 5  heavy
	Rect2(53, 407, 233, 276),   # 6  light
	Rect2(322, 406, 233, 173),  # 7  light
	Rect2(615, 406, 234, 277),  # 8  heavy
	Rect2(890, 406, 238, 277),  # 9  heavy
	Rect2(1190, 406, 241, 277), # 10 heavy
	Rect2(51, 683, 235, 205),   # 11 thunder
	Rect2(321, 683, 232, 217),  # 12 thunder
	Rect2(614, 683, 236, 211),  # 13 thunder
	Rect2(888, 683, 241, 213),  # 14 thunder
	Rect2(1191, 683, 239, 212), # 15 thunder
]

# Frame groups as 0-based indices into FRAMES.
const DRY_FRAMES := [0]                     # sprite 1
const LIGHT_FRAMES := [1, 2, 5, 6]          # sprites 2, 3, 6, 7
const HEAVY_FRAMES := [3, 4, 7, 8, 9]       # sprites 4, 5, 8, 9, 10
const THUNDER_FRAMES := [10, 11, 12, 13, 14] # sprites 11..15

enum Phase { DRY, LIGHT, HEAVY, THUNDER }
# The weather cycle, repeated for the cloud's whole life.
const CYCLE := [
	Phase.DRY, Phase.LIGHT, Phase.HEAVY, Phase.LIGHT,
	Phase.HEAVY, Phase.THUNDER, Phase.LIGHT, Phase.DRY,
]
const PHASE_MIN := 10.0       # each cycle phase lasts this..PHASE_MAX seconds
const PHASE_MAX := 20.0

const RAIN_FPS := 8.0         # light/heavy rain frame animation rate
const THUNDER_SECONDS := 0.5  # time for one full loop of the last row
const BREATHE_MIN := 9.0      # dry "breathing" period range (seconds)
const BREATHE_MAX := 18.0
const BREATHE_AMP := 0.15     # dry cloud grows up to +15% and back

const CLOUD_SCALE := 0.6      # base draw scale of the sprite art
const CLOUD_LIFT := 60.0      # pixels the cloud floats above the ground plane

static var _sheet: Texture2D

var world: Node2D             # the terrain node (scripts/main.gd), owns the wind
var pos := Vector2.ZERO       # continuous grid position (drifts with the wind)
var _cycle_i := 0             # index into CYCLE
var _phase_left := 0.0        # seconds left in the current phase
var _anim_t := 0.0            # animation timer within the current phase
var _breathe_t := 0.0         # breathing timer (dry phase)
var _breathe_period := 4.0


func setup(w: Node2D, start: Vector2) -> void:
	if _sheet == null:
		_sheet = load("res://assets/environment/cloud sprites.png")
	world = w
	pos = start
	_cycle_i = 0
	_phase_left = randf_range(PHASE_MIN, PHASE_MAX)
	_breathe_period = randf_range(BREATHE_MIN, BREATHE_MAX)
	_breathe_t = randf() * _breathe_period   # desync breathing between clouds
	_anim_t = 0.0


func _phase() -> int:
	return CYCLE[_cycle_i]


## Forces the cloud into its thunderstorm phase and holds it there (the
## infinite phase timer never expires) until restart_cycle() is called.
## Used by the UI storm toggle.
func force_thunder() -> void:
	_cycle_i = CYCLE.find(Phase.THUNDER)
	_phase_left = INF
	_anim_t = 0.0


## Restarts the normal weather cycle from its start (a fresh dry phase).
func restart_cycle() -> void:
	_cycle_i = 0
	_phase_left = randf_range(PHASE_MIN, PHASE_MAX)
	_anim_t = 0.0
	_breathe_period = randf_range(BREATHE_MIN, BREATHE_MAX)
	_breathe_t = randf() * _breathe_period


## True while this cloud is dropping heavy rain — the heavy and thunderstorm
## phases both count (used to wet tiles below it).
func is_heavy_rain() -> bool:
	return _phase() == Phase.HEAVY or _phase() == Phase.THUNDER


## Grid cell where the rain column visually meets the ground. The cloud body is
## drawn CLOUD_LIFT px above the ground plane, top-anchored, with the rain
## streaks hanging below it, so the contact point sits down-left (+x, +y) of
## pos. Derived from the current frame's drawn height so it tracks the art.
func rain_cell() -> Vector2i:
	var rc: Rect2 = FRAMES[_frame_index()]
	# Screen y of the bottom edge of the sprite (where the rain ends).
	var bottom := (pos.x + pos.y) * QUARTER_H + QUARTER_H - CLOUD_LIFT \
		+ rc.size.y * CLOUD_SCALE
	var s := bottom / QUARTER_H   # grid diagonal (gx + gy) at that screen y
	var d := pos.x - pos.y        # same screen column as the cloud centre
	return Vector2i(roundi((s + d) * 0.5), roundi((s - d) * 0.5))


## Wind-speed multiplier for the current weather (rain slows the cloud down).
func _speed_mult() -> float:
	match _phase():
		Phase.LIGHT:
			return 0.75
		Phase.HEAVY:
			return 0.25
		_:
			return 1.0   # dry and thunder drift at full speed


func _process(delta: float) -> void:
	_phase_left -= delta
	if _phase_left <= 0.0:
		_cycle_i = (_cycle_i + 1) % CYCLE.size()
		_phase_left = randf_range(PHASE_MIN, PHASE_MAX)
		_anim_t = 0.0
		if _phase() == Phase.DRY:
			_breathe_period = randf_range(BREATHE_MIN, BREATHE_MAX)
			_breathe_t = 0.0
	pos += world.wind_vector() * _speed_mult() * delta
	_anim_t += delta
	_breathe_t += delta


## The 0-based sprite index to show this frame for the current phase/animation.
func _frame_index() -> int:
	match _phase():
		Phase.DRY:
			return DRY_FRAMES[0]
		Phase.LIGHT:
			return LIGHT_FRAMES[int(_anim_t * RAIN_FPS) % LIGHT_FRAMES.size()]
		Phase.HEAVY:
			return HEAVY_FRAMES[int(_anim_t * RAIN_FPS) % HEAVY_FRAMES.size()]
		_:  # THUNDER: loop the whole last row in THUNDER_SECONDS
			var per := THUNDER_SECONDS / float(THUNDER_FRAMES.size())
			return THUNDER_FRAMES[int(_anim_t / per) % THUNDER_FRAMES.size()]


## Sprite draw data for main to composite on top of the scene (see main._draw).
func render() -> Dictionary:
	if _sheet == null:
		return {}
	var rc: Rect2 = FRAMES[_frame_index()]
	var scale := CLOUD_SCALE
	if _phase() == Phase.DRY:
		# Smooth breathing: 1.0 -> 1.0 + BREATHE_AMP -> 1.0 over one period.
		scale *= 1.0 + BREATHE_AMP * (0.5 - 0.5 * cos(TAU * _breathe_t / _breathe_period))
	# Float above the ground plane at the cloud's grid position. Anchored by the
	# top-centre of the art so the cloud body holds steady while rain hangs below.
	var ax := (pos.x - pos.y) * HALF_W + HALF_W
	var ay := (pos.x + pos.y) * QUARTER_H + QUARTER_H - CLOUD_LIFT
	var w := rc.size.x * scale
	var h := rc.size.y * scale
	return {
		d = pos.x + pos.y,
		tex = _sheet,
		src = rc,
		dst = Rect2(ax - w * 0.5, ay, w, h),
		mod = Color.WHITE,
	}
