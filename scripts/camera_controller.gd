extends Camera2D
## WASD pans the camera; the mouse wheel zooms in and out (clamped).

@export var pan_speed := 600.0   # pixels / second at zoom = 1
@export var zoom_step := 0.1     # 10% per wheel notch
@export var min_zoom := 0.2
@export var max_zoom := 4.0


func _ready() -> void:
	make_current()


func _process(delta: float) -> void:
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_W):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_S):
		dir.y += 1.0
	if Input.is_key_pressed(KEY_A):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		dir.x += 1.0
	if dir != Vector2.ZERO:
		# Divide by zoom so panning feels the same speed at every zoom level.
		position += dir.normalized() * pan_speed * delta / zoom.x


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_apply_zoom(1.0 + zoom_step)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_apply_zoom(1.0 - zoom_step)


func _apply_zoom(factor: float) -> void:
	var z := clampf(zoom.x * factor, min_zoom, max_zoom)
	zoom = Vector2(z, z)
