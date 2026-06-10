extends CanvasLayer
## Always-visible control panel in the top-left corner of the screen.
##
## One row per controllable critter type (boar, stag, bird): the critter's idle
## sprite on the left with its current map count underneath, then a "+" button
## that spawns one and an "X" button that removes a random one. Clouds get the
## same row but with only a "+" (they drift off the map by themselves).
##
## Lives on a CanvasLayer, so it stays anchored to the screen corner and keeps
## its size no matter how the camera pans or zooms. World interaction goes
## through main.gd's critter_count / spawn_critter / remove_critter API.

const ICON := 40.0            # icon box size, px
const BTN := 28.0             # button size, px

var world: Node2D             # the terrain node (scripts/main.gd)
var _labels := {}             # kind -> count Label


## A button that draws a yellow lightning bolt (the default font has no bolt
## glyph). With `cancel` set it draws a red X over the bolt: clicking then
## cancels the storm instead of starting one.
class BoltButton extends Button:
	var cancel := false

	# Bolt outline in 0..1 coords, scaled into the button when drawn.
	const BOLT := [
		Vector2(0.60, 0.00), Vector2(0.20, 0.55), Vector2(0.45, 0.55),
		Vector2(0.35, 1.00), Vector2(0.80, 0.40), Vector2(0.52, 0.40),
	]

	func _draw() -> void:
		var pad := 6.0
		var box := Rect2(Vector2(pad, pad), size - Vector2(pad, pad) * 2.0)
		var pts := PackedVector2Array()
		for p: Vector2 in BOLT:
			pts.append(box.position + p * box.size)
		draw_colored_polygon(pts, Color(1.0, 0.82, 0.15))
		if cancel:
			var red := Color(0.85, 0.1, 0.1)
			draw_line(box.position, box.end, red, 3.0)
			draw_line(Vector2(box.end.x, box.position.y),
				Vector2(box.position.x, box.end.y), red, 3.0)


func setup(w: Node2D) -> void:
	world = w


func _ready() -> void:
	layer = 10
	var panel := PanelContainer.new()
	panel.position = Vector2(8.0, 8.0)
	add_child(panel)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 6)
	panel.add_child(rows)
	rows.add_child(_make_row("boar", _boar_icon(), true))
	rows.add_child(_make_row("stag", _stag_icon(), true))
	rows.add_child(_make_row("bird", _bird_icon(), true))
	rows.add_child(_make_row("cloud", _cloud_icon(), false))
	rows.add_child(_make_wind_row())


## Counts change as critters spawn, die, or drift away, so refresh every frame.
func _process(_delta: float) -> void:
	if world == null:
		return
	for kind in _labels:
		_labels[kind].text = str(world.critter_count(kind))


## One panel row: [icon over count] [+] [X (if removable)].
func _make_row(kind: String, icon: Texture2D, removable: bool) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var left := VBoxContainer.new()
	var tr := TextureRect.new()
	tr.texture = icon
	tr.custom_minimum_size = Vector2(ICON, ICON)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	left.add_child(tr)
	var lbl := Label.new()
	lbl.text = "0"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	left.add_child(lbl)
	_labels[kind] = lbl
	row.add_child(left)

	var plus := Button.new()
	plus.text = "+"
	plus.custom_minimum_size = Vector2(BTN, BTN)
	plus.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	plus.pressed.connect(func() -> void: world.spawn_critter(kind))
	row.add_child(plus)

	if removable:
		var x := Button.new()
		x.text = "X"
		x.custom_minimum_size = Vector2(BTN, BTN)
		x.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		x.pressed.connect(func() -> void: world.remove_critter(kind))
		row.add_child(x)

	if kind == "cloud":
		# Storm toggle: bolt turns every cloud into a held thunderstorm; it then
		# shows a red X, and clicking again restarts the normal weather cycle.
		var bolt := BoltButton.new()
		bolt.custom_minimum_size = Vector2(BTN, BTN)
		bolt.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		bolt.pressed.connect(func() -> void:
			var on: bool = not world.is_storm()
			world.set_storm(on)
			bolt.cancel = on
			bolt.queue_redraw())
		row.add_child(bolt)
	return row


# The order the wind-direction button cycles through on each click.
const WIND_DIRS := ["NE", "SE", "NW", "SW"]


## Wind row: a button showing where the wind blows FROM (click cycles through
## the four directions), then small +/- buttons that raise/lower wind speed.
func _make_wind_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var dir_btn := Button.new()
	dir_btn.text = WIND_DIRS[0]
	dir_btn.custom_minimum_size = Vector2(ICON, BTN)
	dir_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dir_btn.pressed.connect(func() -> void:
		var i: int = (WIND_DIRS.find(dir_btn.text) + 1) % WIND_DIRS.size()
		dir_btn.text = WIND_DIRS[i]
		world.set_wind_from(dir_btn.text))
	row.add_child(dir_btn)

	var plus := Button.new()
	plus.text = "+"
	plus.custom_minimum_size = Vector2(BTN, BTN)
	plus.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	plus.pressed.connect(func() -> void: world.nudge_wind(world.WIND_STEP))
	row.add_child(plus)

	var minus := Button.new()
	minus.text = "-"
	minus.custom_minimum_size = Vector2(BTN, BTN)
	minus.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	minus.pressed.connect(func() -> void: world.nudge_wind(-world.WIND_STEP))
	row.add_child(minus)
	return row


# --- icons (first idle frame of each critter's art) --------------------------

func _atlas(tex: Texture2D, region: Rect2) -> AtlasTexture:
	var at := AtlasTexture.new()
	at.atlas = tex
	at.region = region
	return at


## Boar idle sheets are a 3x3 grid; the icon is the first frame.
func _boar_icon() -> Texture2D:
	var tex: Texture2D = load("res://assets/critters/boar/boar_SE_idle_sheet.png")
	return _atlas(tex, Rect2(0, 0, tex.get_width() / 3.0, tex.get_height() / 3.0))


## Stag idle is a single-row strip of 32px-wide frames; the icon is the first.
func _stag_icon() -> Texture2D:
	var tex: Texture2D = load("res://assets/critters/stag/critter_stag_SE_idle.png")
	return _atlas(tex, Rect2(0, 0, 32.0, float(tex.get_height())))


## The bird's standing pose (sprite 5 on the sheet; rect from bird.gd FRAMES).
func _bird_icon() -> Texture2D:
	var tex: Texture2D = load("res://assets/critters/bluebird/bird_sprites.png")
	return _atlas(tex, Rect2(713, 46, 102, 68))


## The dry cloud sprite (sprite 1 on the sheet; rect from cloud.gd FRAMES).
func _cloud_icon() -> Texture2D:
	var tex: Texture2D = load("res://assets/environment/cloud sprites.png")
	return _atlas(tex, Rect2(53, 105, 233, 147))
