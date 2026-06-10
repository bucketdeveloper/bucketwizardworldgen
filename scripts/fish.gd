extends Node2D
## A fish stranded and flopping on a river tile that has dried out. It sits in
## the middle of the tile and runs a flopping routine, then lies still until
## main removes it once the tile is wet again (see main._update_fish).
##
## Sheet: assets/critters/fish/flopping_fish.png. The flop uses row 0, sprites
## 1..5 (1 = resting, 2..5 = a flop flurry). FRAMES holds their tight content
## rects, 0-based (sprite N -> FRAMES[N-1]).
##
## Routine: show sprite 1, then a "double flop" (flurry 2->5 over FLOP_SECONDS,
## pause WAIT_SECONDS, flurry again). This repeats three times; the sprite-1
## rest before each repeat grows 1s, then 2s, then 3s. After the third it rests
## on sprite 1 indefinitely.

const HALF_W := 16            # iso horizontal half-step (matches main.gd)
const QUARTER_H := 8          # iso vertical step
const STEP := 8               # vertical pixels per elevation level
const DRY_DROP := 4.0         # dry riverbed sits this far below the water surface (matches main)

const FISH_SCALE := 0.08      # draw scale of the sprite art (~half a tile wide)

# Tight content rect (x, y, w, h) of sprites 1..5 on the sheet.
const FRAMES := [
	Rect2(71, 176, 204, 76),    # 1 resting
	Rect2(329, 163, 223, 91),   # 2 flop
	Rect2(614, 122, 221, 131),  # 3 flop
	Rect2(917, 142, 213, 117),  # 4 flop
	Rect2(1206, 167, 225, 93),  # 5 flop
]
const FLOP := [1, 2, 3, 4]    # sprites 2,3,4,5 (0-based) — one flop flurry
const FLOP_SECONDS := 0.25    # time for one 2->5 flurry
const WAIT_SECONDS := 0.5     # pause between the two flurries of a flop
const HOLDS := [1.0, 2.0, 3.0] # sprite-1 rest before each iteration's flopping

enum Step { HOLD, FLOP_ANIM }

static var _sheet: Texture2D

var world: Node2D
var cell := Vector2i.ZERO
var _anchor := Vector2.ZERO   # screen point at the middle of the tile
var _schedule: Array = []     # [[Step, duration], ...]
var _seg := 0                 # current schedule segment
var _seg_t := 0.0             # time into the current segment


func setup(w: Node2D, c: Vector2i) -> void:
	world = w
	cell = c
	if _sheet == null:
		_sheet = load("res://assets/critters/fish/flopping_fish.png")
	var h := float(world.cell_height(c))
	_anchor = Vector2(
		(c.x - c.y) * HALF_W + HALF_W,
		(c.x + c.y) * QUARTER_H - h * STEP + QUARTER_H + DRY_DROP)
	_schedule = []
	for hold in HOLDS:
		_schedule.append([Step.HOLD, hold])      # rest on sprite 1
		_schedule.append([Step.FLOP_ANIM, FLOP_SECONDS])
		_schedule.append([Step.HOLD, WAIT_SECONDS])
		_schedule.append([Step.FLOP_ANIM, FLOP_SECONDS])
	_seg = 0
	_seg_t = 0.0


func _process(delta: float) -> void:
	if _seg >= _schedule.size():
		return   # routine finished: lie still on sprite 1
	_seg_t += delta
	while _seg < _schedule.size() and _seg_t >= _schedule[_seg][1]:
		_seg_t -= _schedule[_seg][1]
		_seg += 1


## The 0-based sprite index to show this frame.
func _frame_index() -> int:
	if _seg >= _schedule.size():
		return 0
	var seg: Array = _schedule[_seg]
	if seg[0] == Step.HOLD:
		return 0
	var n := FLOP.size()
	var i := int(_seg_t / (float(seg[1]) / n))
	return FLOP[clampi(i, 0, n - 1)]


## Sprite draw data for main to composite (see main._draw). Anchored bottom-
## centred so the fish lies on the middle of the tile and its tail flips up.
func render() -> Dictionary:
	if _sheet == null:
		return {}
	var rc: Rect2 = FRAMES[_frame_index()]
	var w := rc.size.x * FISH_SCALE
	var h := rc.size.y * FISH_SCALE
	return {
		d = float(cell.x + cell.y),
		tex = _sheet,
		src = rc,
		dst = Rect2(_anchor.x - w * 0.5, _anchor.y - h, w, h),
		mod = Color.WHITE,
	}
