extends Node2D
## A wandering stag critter. Walks idly around the map, but runs away from any
## boar that gets too close. Uses the same four facings as the other critters
## (NW/NE/SE/SW); animations are single-row STRIPS of 32x41 frames (idle 24,
## walk 11, run 10 — frame count is derived from the texture width).

const HALF_W := 16            # iso horizontal half-step (matches main.gd)
const QUARTER_H := 8          # iso vertical step
const STEP := 8               # vertical pixels per elevation level

const FRAME_W := 32.0
const IDLE_FPS := 8.0
const WALK_FPS := 8.0
const RUN_FPS := 12.0
const WALK_SPEED := 1.5       # tiles per second
const RUN_SPEED := 5.0        # tiles per second when fleeing
const FLEE_RADIUS := 6.0      # boars closer than this (in tiles) cause a flee
const FOOT := 4.0             # px between frame bottom and the stag's feet

# Grid step -> facing name (matches the asset file names).
const DIR_NAME := {
	Vector2i(-1, 0): "NW",
	Vector2i(0, -1): "NE",
	Vector2i(1, 0): "SE",
	Vector2i(0, 1): "SW",
}

enum { IDLE, WALK, RUN }

var world: Node2D             # the terrain node (scripts/main.gd)
var cell := Vector2i.ZERO     # origin cell of the current move / resting cell
var move_dir := Vector2i.ZERO
var move_t := 0.0             # 0..1 progress toward the next cell
var state := IDLE
var facing := "SE"
var idle_left := 0.0          # seconds of idling remaining
var walk_cells := 0           # cells left to walk
var frame := 0.0
var _tex := {}                # "SE_run" -> Texture2D


func setup(w: Node2D, c: Vector2i) -> void:
	world = w
	cell = c
	for d in ["NW", "NE", "SE", "SW"]:
		for anim in ["idle", "walk", "run"]:
			_tex[d + "_" + anim] = load(
				"res://assets/critters/stag/critter_stag_%s_%s.png" % [d, anim])
	facing = DIR_NAME.values().pick_random()
	idle_left = randf_range(0.5, 3.0)


## Continuous grid position (cell + movement progress).
func grid_pos() -> Vector2:
	var p := Vector2(cell)
	if state != IDLE:
		p += Vector2(move_dir) * move_t
	return p


func _process(delta: float) -> void:
	var fps := RUN_FPS if state == RUN else (WALK_FPS if state == WALK else IDLE_FPS)
	frame += delta * fps
	match state:
		RUN:
			_advance(delta * RUN_SPEED)
		WALK:
			_advance(delta * WALK_SPEED)
		IDLE:
			var threat := _threat()
			if threat != Vector2.INF:
				if not _start_flee(threat):
					idle_left = maxf(idle_left, 0.2)   # cornered; check again soon
			else:
				idle_left -= delta
				if idle_left <= 0.0 and not _start_walk():
					idle_left = randf_range(1.0, 3.0)  # boxed in; try again later


## The nearest boar's grid position if it is within FLEE_RADIUS, else INF.
func _threat() -> Vector2:
	var b: Vector2 = world.nearest_boar(grid_pos())
	if b != Vector2.INF and grid_pos().distance_to(b) < FLEE_RADIUS:
		return b
	return Vector2.INF


## Moves along move_dir, deciding what to do at each cell arrival. A nearby
## boar always wins: walking turns into fleeing, fleeing keeps re-aiming away.
func _advance(dist: float) -> void:
	move_t += dist
	while move_t >= 1.0:
		move_t -= 1.0
		cell += move_dir
		var threat := _threat()
		if threat != Vector2.INF:
			if not _start_flee(threat):
				_start_idle()   # cornered: freeze
			continue
		if state == RUN:
			_start_idle()       # escaped
		else:
			walk_cells -= 1
			if walk_cells <= 0:
				_start_idle()
			elif not world.is_critter_walkable(cell, cell + move_dir):
				if not _start_walk():
					_start_idle()


func _start_idle() -> void:
	state = IDLE
	move_dir = Vector2i.ZERO
	move_t = 0.0
	frame = 0.0
	idle_left = randf_range(1.0, 4.0)


## Picks a random walkable direction and starts walking. False if fully stuck.
func _start_walk() -> bool:
	var dirs := DIR_NAME.keys()
	dirs.shuffle()
	for d: Vector2i in dirs:
		if world.is_critter_walkable(cell, cell + d):
			move_dir = d
			facing = DIR_NAME[d]
			state = WALK
			move_t = 0.0
			frame = 0.0
			walk_cells = randi_range(2, 8)
			return true
	return false


## Starts (or keeps) running in the walkable direction that gets farthest from
## the threat. False if no walkable direction actually moves away.
func _start_flee(threat: Vector2) -> bool:
	var best := Vector2i.ZERO
	var best_d := -INF
	for d: Vector2i in DIR_NAME.keys():
		if world.is_critter_walkable(cell, cell + d):
			var dist := Vector2(cell + d).distance_to(threat)
			if dist > best_d:
				best_d = dist
				best = d
	if best == Vector2i.ZERO or best_d <= Vector2(cell).distance_to(threat):
		return false
	if state != RUN:
		frame = 0.0
		move_t = 0.0
	state = RUN
	move_dir = best
	facing = DIR_NAME[best]
	return true


## Sprite draw data for the terrain to composite this frame (see main._draw).
func render() -> Dictionary:
	var anim := "run" if state == RUN else ("walk" if state == WALK else "idle")
	var tex: Texture2D = _tex.get(facing + "_" + anim)
	if tex == null:
		return {}
	var n := int(tex.get_width() / FRAME_W)
	var fh := float(tex.get_height())
	var i := int(frame) % n
	var src := Rect2(i * FRAME_W, 0.0, FRAME_W, fh)

	# Continuous grid position and interpolated ground height.
	var p := grid_pos()
	var h := float(world.cell_height(cell))
	if state != IDLE:
		h = lerpf(h, float(world.cell_height(cell + move_dir)), move_t)
	# Anchor at the centre of the surface diamond of the cell underfoot.
	var ax := (p.x - p.y) * HALF_W + HALF_W
	var ay := (p.x + p.y) * QUARTER_H - h * STEP + QUARTER_H
	return {
		d = p.x + p.y,
		tex = tex,
		src = src,
		dst = Rect2(ax - FRAME_W / 2.0, ay - fh + FOOT, FRAME_W, fh),
		mod = Color.WHITE,
	}
