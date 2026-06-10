extends Node2D
## A wandering boar critter. Loops between idling and running a few tiles in
## one of the four isometric directions (NW/NE/SE/SW), matching the spritesheet
## orientations. Movement follows the terrain's iso projection and the boar's
## vertical offset tracks the ground height beneath it.
##
## Sheets: boar_<DIR>_idle_sheet.png is a 3x3 grid (9 frames) and
## boar_<DIR>_run_sheet.png is a 2x2 grid (4 frames); frame size is derived
## from the texture so the slightly different sizes per direction all work.

const HALF_W := 16            # iso horizontal half-step (matches main.gd)
const QUARTER_H := 8          # iso vertical step
const STEP := 8               # vertical pixels per elevation level

const IDLE_FPS := 6.0
const RUN_FPS := 10.0
const RUN_SPEED := 3.0        # tiles per second
const IDLE_COLS := 3
const IDLE_ROWS := 3
const IDLE_FRAMES := 7        # last 2 cells of the 3x3 idle sheet are empty
const RUN_COLS := 2
const RUN_ROWS := 2
const RUN_FRAMES := 4
const FOOT := 4.0             # px between frame bottom and the boar's feet

# Grid step -> facing name (matches the spritesheet file names):
# -x is up-left (NW), -y up-right (NE), +x down-right (SE), +y down-left (SW).
const DIR_NAME := {
	Vector2i(-1, 0): "NW",
	Vector2i(0, -1): "NE",
	Vector2i(1, 0): "SE",
	Vector2i(0, 1): "SW",
}

var world: Node2D             # the terrain node (scripts/main.gd)
var cell := Vector2i.ZERO     # origin cell of the current move / resting cell
var move_dir := Vector2i.ZERO
var move_t := 0.0             # 0..1 progress toward the next cell
var running := false
var facing := "SE"
var idle_left := 0.0          # seconds of idling remaining
var run_cells := 0            # cells left to run
var frame := 0.0
var _tex := {}                # "SE_run" -> Texture2D


func setup(w: Node2D, c: Vector2i) -> void:
	world = w
	cell = c
	for d in ["NW", "NE", "SE", "SW"]:
		_tex[d + "_idle"] = load("res://assets/critters/boar/boar_%s_idle_sheet.png" % d)
		_tex[d + "_run"] = load("res://assets/critters/boar/boar_%s_run_sheet.png" % d)
	facing = DIR_NAME.values().pick_random()
	idle_left = randf_range(0.5, 3.0)


## Continuous grid position (cell + movement progress).
func grid_pos() -> Vector2:
	var p := Vector2(cell)
	if running:
		p += Vector2(move_dir) * move_t
	return p


func _process(delta: float) -> void:
	frame += delta * (RUN_FPS if running else IDLE_FPS)
	if running:
		move_t += delta * RUN_SPEED
		while move_t >= 1.0:
			move_t -= 1.0
			cell += move_dir
			run_cells -= 1
			if run_cells <= 0:
				_start_idle()
			elif not world.is_critter_walkable(cell, cell + move_dir):
				# Blocked ahead: turn somewhere else if possible, else rest.
				if not _start_run():
					_start_idle()
	else:
		idle_left -= delta
		if idle_left <= 0.0 and not _start_run():
			idle_left = randf_range(1.0, 3.0)   # boxed in; try again later


func _start_idle() -> void:
	running = false
	move_dir = Vector2i.ZERO
	move_t = 0.0
	frame = 0.0
	idle_left = randf_range(1.0, 4.0)


## Picks a random walkable direction and starts a run. False if fully stuck.
func _start_run() -> bool:
	var dirs := DIR_NAME.keys()
	dirs.shuffle()
	for d: Vector2i in dirs:
		if world.is_critter_walkable(cell, cell + d):
			move_dir = d
			facing = DIR_NAME[d]
			running = true
			move_t = 0.0
			frame = 0.0
			run_cells = randi_range(2, 8)
			return true
	return false


## Sprite draw data for the terrain to composite this frame (see main._draw).
func render() -> Dictionary:
	var tex: Texture2D = _tex.get(facing + ("_run" if running else "_idle"))
	if tex == null:
		return {}
	var cols := RUN_COLS if running else IDLE_COLS
	var rows := RUN_ROWS if running else IDLE_ROWS
	var fw := tex.get_width() / float(cols)
	var fh := tex.get_height() / float(rows)
	var i := int(frame) % (RUN_FRAMES if running else IDLE_FRAMES)
	var src := Rect2(float(i % cols) * fw, float(i / cols) * fh, fw, fh)

	# Continuous grid position and interpolated ground height.
	var gx := float(cell.x)
	var gy := float(cell.y)
	var h := float(world.cell_height(cell))
	if running:
		gx += move_dir.x * move_t
		gy += move_dir.y * move_t
		h = lerpf(h, float(world.cell_height(cell + move_dir)), move_t)
	# Anchor at the centre of the surface diamond of the cell underfoot.
	var ax := (gx - gy) * HALF_W + HALF_W
	var ay := (gx + gy) * QUARTER_H - h * STEP + QUARTER_H
	return {
		d = gx + gy,
		tex = tex,
		src = src,
		dst = Rect2(ax - fw / 2.0, ay - fh + FOOT, fw, fh),
		mod = Color.WHITE,
	}
