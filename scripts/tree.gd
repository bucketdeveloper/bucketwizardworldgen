extends Node2D
## A tree that lives out a one-shot life cycle on tree_sprites.png.
##
## The sheet is a 9-column x 7-row grid read row-major. Columns are a uniform
## 1024/9 px wide, but ROWS HAVE DIFFERENT HEIGHTS (mature trees are taller than
## sprouts or debris), so frame rects come from COL_X / ROW_Y.
##
## Life cycle (the first row of the sheet is unused):
##   GROW  - frames GROW_START..GROW_END on the second row, one per
##           SECONDS_PER_FRAME, then it stops growing.
##   HOLD  - sits fully grown on GROW_END indefinitely; trees no longer fall.
## (FALL and FINAL — the falling rows and debris frame — are retained below but
## unreachable, in case falling is ever brought back.)
##
## Because rows differ and trees aren't centred in their cell, FRAME_BASE holds
## each frame's baseline (bottom opaque row, from the cell top) and FRAME_CX its
## content centre (from the cell left); the tree is anchored by those so it
## neither floats, jumps, nor drifts sideways as it changes stage. The falling
## rows are wider than tall, so each is centred on its own content instead.

const HALF_W := 16            # iso horizontal half-step (matches main.gd)
const QUARTER_H := 8          # iso vertical step
const STEP := 8               # vertical pixels per elevation level

# Lowers every tree's base down the tile by this many screen pixels. The tile
# top face is 2*QUARTER_H tall, so QUARTER_H drops the base half a tile. Tweak
# while testing to slide the trees up (smaller) or down (larger).
const BASE_DROP := QUARTER_H

const COLS := 9
const FRAME_COUNT := 63       # 9 cols x 7 rows
const SCALE := 0.5            # mature tree ~2 tiles tall
# Growth pace (seconds per growth frame) is rolled per tree from this range, so
# a stand of trees grows at varied rates instead of in lockstep.
const GROW_SECONDS_MIN := 2.0
const GROW_SECONDS_MAX := 12.0

# Growth runs along the second row only (the first row is unused).
const GROW_START := 9            # first growth frame (row 2, col 0)
const GROW_END := 14            # last growth frame; the tree holds here

# After growing, each tree waits a random spell before it falls, so a forest
# doesn't topple in sync.
const HOLD_MIN := 5.0
const HOLD_MAX := 500.0

# The last two rows (frames 45-62) are the tree falling. They play quickly:
# the whole fall runs through both rows in FALL_SECONDS.
const FALL_START := 45
const FALL_SECONDS := 2.0
const FALL_SECONDS_PER_FRAME := FALL_SECONDS / float(FRAME_COUNT - FALL_START)
const FINAL_FRAME := FRAME_COUNT - 1   # last debris frame (62)
const FINAL_HOLD_SECONDS := 10.0       # show the final frame this long, then vanish

enum Phase { GROW, HOLD, FALL, FINAL }

# Column left edges (10 values) and row top edges (8 values) on the sheet.
const COL_X := [0, 114, 228, 341, 455, 569, 683, 796, 910, 1024]
const ROW_Y := [0, 131, 253, 394, 568, 739, 887, 1024]

# Per-frame baseline: bottom-most opaque row measured from the cell's top.
const FRAME_BASE := [
	119, 119, 119, 115, 119, 117, 119, 118, 117,
	116, 115, 116, 115, 116, 116, 116, 116, 116,
	131, 130, 133, 135, 131, 130, 135, 140, 138,
	165, 165, 165, 165, 165, 165, 165, 165, 166,
	159, 159, 159, 159, 159, 159, 159, 159, 159,
	119, 125, 122, 124, 123, 124, 124, 124, 124,
	91, 89, 94, 94, 94, 92, 96, 96, 96,
]
# Per-frame content centre, measured from the cell's left edge.
const FRAME_CX := [
	77, 69, 63, 58, 52, 44, 43, 37, 34,
	77, 72, 65, 59, 52, 48, 43, 40, 32,
	76, 71, 66, 60, 54, 48, 44, 61, 35,
	80, 55, 69, 61, 51, 47, 56, 56, 37,
	79, 55, 69, 65, 54, 47, 58, 38, 34,
	# Rows 6-7 are the fall: these poses are wider than tall, so each is centred
	# on its own content (median x of the opaque pixels), not the cell centre.
	78, 72, 71, 72, 60, 41, 47, 41, 28,
	83, 33, 57, 67, 75, 89, 90, 22, 28,
]

static var _sheet: Texture2D

var cell := Vector2i.ZERO     # grid cell the tree stands on
var _anchor := Vector2.ZERO   # precomputed screen position of the tile surface
var frame := 0
var finished := false         # main removes the tree once this is true

var _phase := Phase.GROW
var _elapsed := 0.0           # time spent in the current phase / on the current frame
var _hold_for := 0.0          # this tree's random HOLD duration
var _grow_pace := 5.0         # this tree's random seconds-per-growth-frame


func setup(world: Node2D, c: Vector2i) -> void:
	if _sheet == null:
		_sheet = load("res://assets/trees/tree_sprites.png")
	cell = c
	var h := float(world.cell_height(c))
	_anchor = Vector2(
		(c.x - c.y) * HALF_W + HALF_W,
		(c.x + c.y) * QUARTER_H - h * STEP + QUARTER_H + BASE_DROP)
	frame = GROW_START
	_phase = Phase.GROW
	_elapsed = 0.0
	_hold_for = randf_range(HOLD_MIN, HOLD_MAX)
	_grow_pace = randf_range(GROW_SECONDS_MIN, GROW_SECONDS_MAX)


func _process(delta: float) -> void:
	if finished:
		return
	_elapsed += delta
	match _phase:
		Phase.GROW:
			# Advance one growth frame per SECONDS_PER_FRAME until GROW_END, then hold.
			if _elapsed >= _grow_pace:
				_elapsed -= _grow_pace
				frame += 1
				if frame >= GROW_END:
					frame = GROW_END
					_phase = Phase.HOLD
					_elapsed = 0.0
		Phase.HOLD:
			# Fully grown trees stay standing indefinitely. (The FALL/FINAL
			# phases and their frames are kept below should falling ever come
			# back, but nothing transitions into them any more.)
			pass
		Phase.FALL:
			# Play the two falling rows quickly; the whole fall takes FALL_SECONDS.
			if _elapsed >= FALL_SECONDS_PER_FRAME:
				_elapsed -= FALL_SECONDS_PER_FRAME
				frame += 1
				if frame >= FINAL_FRAME:
					frame = FINAL_FRAME
					_phase = Phase.FINAL
					_elapsed = 0.0
		Phase.FINAL:
			# Hold on the last debris frame, then ask to be removed.
			if _elapsed >= FINAL_HOLD_SECONDS:
				finished = true


## Sprite draw data for the terrain to composite this frame (see main._draw).
func render() -> Dictionary:
	if _sheet == null or finished:
		return {}
	var r := frame / COLS
	var c := frame % COLS
	var x0: int = COL_X[c]
	var y0: int = ROW_Y[r]
	var w := float(COL_X[c + 1] - x0)
	var h := float(ROW_Y[r + 1] - y0)
	var src := Rect2(x0, y0, w, h)
	# Place the frame's content centre over the tile and its baseline on it.
	var pos := Vector2(
		_anchor.x - FRAME_CX[frame] * SCALE,
		_anchor.y - (FRAME_BASE[frame] + 1) * SCALE)
	return {
		d = float(cell.x + cell.y),
		cell = cell,   # lets main draw this cell's flood water over the tree
		tex = _sheet,
		src = src,
		dst = Rect2(pos, Vector2(w, h) * SCALE),
		mod = Color.WHITE,
	}
