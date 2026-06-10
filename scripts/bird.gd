extends Node2D
## A bluebird that wanders the sky, lands on grass to peck, then takes off again.
##
## Sheet: assets/critters/bluebird/bird_sprites.png, a 2x6 grid (12 sprites).
## FRAMES holds each sprite's tight content rect, 0-based (sprite N -> N-1).
## Sprites face LEFT; the bird is mirrored when it heads right.
##
## Life cycle:
##   FLY     - cruise BIRD_HEIGHT tiles above the ground, wandering. Flap loop
##             1,2,3,2 over one second. After a while it looks for grass.
##   DESCEND - drop to ground level over the chosen grass tile (still flapping).
##   LAND    - sprites 4,5,6 over one second, settling into a stand.
##   PECK    - peck the ground (sprites 5/6), twice facing each way.
##   TAKEOFF - sprites 10,11,12, then it flies again, climbing back up.

const HALF_W := 16            # iso horizontal half-step (matches main.gd)
const QUARTER_H := 8          # iso vertical step
const STEP := 8               # vertical pixels per elevation level

# Tight content rect (x, y, w, h) of sprites 1..12 on the sheet.
const FRAMES := [
	Rect2(37, 6, 86, 99),     # 1 flap (wings up)
	Rect2(180, 28, 124, 73),  # 2 flap (wings out)
	Rect2(369, 41, 108, 63),  # 3 flap (wings back)
	Rect2(530, 19, 103, 93),  # 4 landing
	Rect2(713, 46, 102, 68),  # 5 stand / head up
	Rect2(902, 39, 88, 73),   # 6 peck / head down
	Rect2(36, 161, 86, 73),   # 7 (unused)
	Rect2(204, 161, 86, 73),  # 8 (unused)
	Rect2(381, 159, 86, 75),  # 9 (unused)
	Rect2(545, 134, 93, 107), # 10 takeoff (wings up)
	Rect2(720, 138, 99, 93),  # 11 takeoff (wings spread)
	Rect2(893, 141, 100, 79), # 12 takeoff (glide)
]
const FLY_FRAMES := [0, 1, 2, 1]      # sprites 1,2,3,2
const LAND_FRAMES := [3, 4, 5]        # sprites 4,5,6
const TAKEOFF_FRAMES := [9, 10, 11]   # sprites 10,11,12
const STAND_FRAME := 4                # sprite 5 (head up)
const PECK_DOWN := 5                  # sprite 6 (head down)
const PECK_UP := 4                    # sprite 5 (head up)

const BIRD_HEIGHT := 1.5      # tiles (elevation levels) above ground while flying
const BIRD_SCALE := 0.15      # draw scale of the sprite art
const FOOT := 3.0             # px between frame bottom and the bird's feet
const FLY_SPEED := 2.0        # cells/sec while cruising
const HEIGHT_RAMP := 4.0      # levels/sec climb or descent (quick)
const FLY_LOOP := 1.0         # flap cycle length
const LAND_SECONDS := 1.0     # 4,5,6 settle time
const TAKEOFF_SECONDS := 0.75 # 10,11,12 launch time
const FLY_MIN := 4.0          # seconds of cruising before it tries to land
const FLY_MAX := 10.0
const TURN_MIN := 0.6         # how often the heading jitters while cruising
const TURN_MAX := 1.8
const PECK_DIRS := 2          # peck facing this many ways...
const PECKS_PER_DIR := 2      # ...this many times each
const PECK_DOWN_T := 0.16     # head-down hold per peck
const PECK_UP_T := 0.16       # head-up hold per peck

enum State { FLY, DESCEND, LAND, PECK, TAKEOFF }

static var _sheet: Texture2D

var world: Node2D
var pos := Vector2.ZERO       # continuous grid position
var vel := Vector2.ZERO       # heading * FLY_SPEED
var height := 0.0             # current extra height in levels (0..BIRD_HEIGHT)
var facing_right := false
var _state := State.FLY
var _state_t := 0.0
var _anim_t := 0.0
var _fly_left := 0.0
var _want_land := false
var _turn_t := 0.0
var _target := Vector2.ZERO
var _peck_done := 0
var _peck_phase_down := true
var _peck_t := 0.0


func setup(w: Node2D, c: Vector2i) -> void:
	world = w
	if _sheet == null:
		_sheet = load("res://assets/critters/bluebird/bird_sprites.png")
	pos = Vector2(c)
	height = BIRD_HEIGHT
	_enter_fly()


func _enter_fly() -> void:
	_state = State.FLY
	_state_t = 0.0
	_anim_t = 0.0
	_fly_left = randf_range(FLY_MIN, FLY_MAX)
	_want_land = false
	_turn_t = randf_range(TURN_MIN, TURN_MAX)
	_new_heading()


func _new_heading() -> void:
	var ang := randf() * TAU
	vel = Vector2(cos(ang), sin(ang)) * FLY_SPEED
	facing_right = vel.x > 0.0


func _process(delta: float) -> void:
	_state_t += delta
	_anim_t += delta
	match _state:
		State.FLY:
			_fly(delta)
		State.DESCEND:
			_descend(delta)
		State.LAND:
			if _state_t >= LAND_SECONDS:
				_start_peck()
		State.PECK:
			_peck(delta)
		State.TAKEOFF:
			if _state_t >= TAKEOFF_SECONDS:
				_enter_fly()


func _fly(delta: float) -> void:
	height = move_toward(height, BIRD_HEIGHT, HEIGHT_RAMP * delta)
	pos += vel * delta
	_steer_in_bounds()
	facing_right = vel.x > 0.0
	_turn_t -= delta
	if _turn_t <= 0.0:
		var ang := vel.angle() + randf_range(-0.8, 0.8)
		vel = Vector2(cos(ang), sin(ang)) * FLY_SPEED
		_turn_t = randf_range(TURN_MIN, TURN_MAX)
	_fly_left -= delta
	if _fly_left <= 0.0:
		_want_land = true
	# Once it wants to land, drop onto the first grass tile it drifts over.
	if _want_land:
		var cell := Vector2i(roundi(pos.x), roundi(pos.y))
		if world.is_grass(cell):
			_target = Vector2(cell)
			_state = State.DESCEND
			_state_t = 0.0
			_anim_t = 0.0


func _descend(delta: float) -> void:
	height = move_toward(height, 0.0, HEIGHT_RAMP * delta)
	pos = pos.move_toward(_target, FLY_SPEED * delta)
	if absf(pos.x - _target.x) > 0.001:
		facing_right = pos.x < _target.x
	if height <= 0.0 and pos.distance_to(_target) < 0.05:
		pos = _target
		_state = State.LAND
		_state_t = 0.0
		_anim_t = 0.0


func _start_peck() -> void:
	_state = State.PECK
	_state_t = 0.0
	_anim_t = 0.0
	_peck_done = 0
	_peck_phase_down = true
	_peck_t = 0.0
	facing_right = false


func _peck(delta: float) -> void:
	_peck_t += delta
	if _peck_phase_down:
		if _peck_t >= PECK_DOWN_T:
			_peck_t -= PECK_DOWN_T
			_peck_phase_down = false
	else:
		if _peck_t >= PECK_UP_T:
			_peck_t -= PECK_UP_T
			_peck_phase_down = true
			_peck_done += 1
			if _peck_done % PECKS_PER_DIR == 0:
				facing_right = not facing_right   # turn and peck the other way
			if _peck_done >= PECK_DIRS * PECKS_PER_DIR:
				_state = State.TAKEOFF
				_state_t = 0.0
				_anim_t = 0.0


## Nudges the heading back toward the map if the bird nears an edge.
func _steer_in_bounds() -> void:
	var m := 3.0
	if pos.x < m and vel.x < 0.0:
		vel.x = absf(vel.x)
	elif pos.x > world.MAP_W - m and vel.x > 0.0:
		vel.x = -absf(vel.x)
	if pos.y < m and vel.y < 0.0:
		vel.y = absf(vel.y)
	elif pos.y > world.MAP_H - m and vel.y > 0.0:
		vel.y = -absf(vel.y)


func _frame_index() -> int:
	match _state:
		State.FLY, State.DESCEND:
			return FLY_FRAMES[int(_anim_t / (FLY_LOOP / FLY_FRAMES.size())) % FLY_FRAMES.size()]
		State.LAND:
			var n := LAND_FRAMES.size()
			return LAND_FRAMES[clampi(int(_state_t / (LAND_SECONDS / n)), 0, n - 1)]
		State.TAKEOFF:
			var n := TAKEOFF_FRAMES.size()
			return TAKEOFF_FRAMES[clampi(int(_state_t / (TAKEOFF_SECONDS / n)), 0, n - 1)]
		State.PECK:
			return PECK_DOWN if _peck_phase_down else PECK_UP
		_:
			return STAND_FRAME


## Sprite draw data for main to composite (see main._draw). Anchored at the feet;
## flying height lifts it off the ground beneath. Mirrored when heading right.
func render() -> Dictionary:
	if _sheet == null:
		return {}
	var rc: Rect2 = FRAMES[_frame_index()]
	var cx := clampi(roundi(pos.x), 0, world.MAP_W - 1)
	var cy := clampi(roundi(pos.y), 0, world.MAP_H - 1)
	var gh := float(world.cell_height(Vector2i(cx, cy)))
	var ax := (pos.x - pos.y) * HALF_W + HALF_W
	var ay := (pos.x + pos.y) * QUARTER_H - (gh + height) * STEP + QUARTER_H
	var w := rc.size.x * BIRD_SCALE
	var h := rc.size.y * BIRD_SCALE
	# Sprites face right by default; mirror (negative width) when heading left.
	var dst := Rect2(ax + w * 0.5, ay - h + FOOT, -w, h) if not facing_right \
		else Rect2(ax - w * 0.5, ay - h + FOOT, w, h)
	return {
		d = pos.x + pos.y,
		tex = _sheet,
		src = rc,
		dst = dst,
		mod = Color.WHITE,
	}
