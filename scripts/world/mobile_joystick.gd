extends Control
## Joystick cảm ứng (chuột cũng dùng được). Kích thước, vị trí và độ mờ theo ảnh tham chiếu:
## vòng ngoài mờ, núm sáng hơn. Mọi kích thước tính theo CHIỀU CAO viewport nên tỉ lệ giữ nguyên ở mọi độ phân giải.

@export var ring_h := 0.355         # đường kính vòng ngoài / chiều cao viewport
@export var knob_h := 0.14          # đường kính núm
@export var from_left_h := 0.373    # tâm joystick cách mép trái
@export var from_bottom_h := 0.297  # tâm joystick cách mép dưới
@export var deadzone := 0.12

const RING_FILL := Color(1, 1, 1, 0.10)
const RING_LINE := Color(1, 1, 1, 0.30)
const KNOB_FILL := Color(1, 1, 1, 0.28)
const KNOB_LINE := Color(1, 1, 1, 0.45)

var _finger_index := -1
var _knob_offset := Vector2.ZERO
var _knob_radius := 30.0
var _travel := 64.0 # quãng kéo tối đa của tâm núm (px)


func _ready() -> void:
	add_to_group("mobile_joystick")
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 10
	get_viewport().size_changed.connect(_layout)
	_layout()


func _layout() -> void:
	var vp := get_viewport_rect().size
	var d := vp.y * ring_h
	size = Vector2(d, d)
	position = Vector2(vp.y * from_left_h - d * 0.5, vp.y - vp.y * from_bottom_h - d * 0.5)
	_knob_radius = vp.y * knob_h * 0.5
	_travel = d * 0.5 - _knob_radius
	_knob_offset = _knob_offset.limit_length(_travel)
	queue_redraw()


func get_direction() -> Vector2:
	var raw := _knob_offset / _travel
	if raw.length() < deadzone:
		return Vector2.ZERO
	return raw.limit_length(1.0)


func _gui_input(event: InputEvent) -> void:
	var touch := event as InputEventScreenTouch
	var drag := event as InputEventScreenDrag
	var click := event as InputEventMouseButton
	var motion := event as InputEventMouseMotion
	if touch != null:
		if touch.pressed and _finger_index == -1:
			_finger_index = touch.index
			_update_knob(touch.position)
			accept_event()
		elif not touch.pressed and touch.index == _finger_index:
			_release()
			accept_event()
	elif drag != null and drag.index == _finger_index:
		_update_knob(drag.position)
		accept_event()
	elif click != null and click.button_index == MOUSE_BUTTON_LEFT:
		if click.pressed and _finger_index == -1:
			_finger_index = -2
			_update_knob(click.position)
			accept_event()
		elif not click.pressed and _finger_index == -2:
			_release()
			accept_event()
	elif motion != null and _finger_index == -2:
		_update_knob(motion.position)
		accept_event()


func _update_knob(local_position: Vector2) -> void:
	_knob_offset = (local_position - size * 0.5).limit_length(_travel)
	queue_redraw()


func _release() -> void:
	_finger_index = -1
	_knob_offset = Vector2.ZERO
	queue_redraw()


func _draw() -> void:
	var c := size * 0.5
	var line := maxf(2.0, size.x * 0.012)
	var ring_r := size.x * 0.5 - line
	draw_circle(c, ring_r, RING_FILL)
	draw_arc(c, ring_r, 0.0, TAU, 64, RING_LINE, line, true)
	var k := c + _knob_offset
	draw_circle(k, _knob_radius, KNOB_FILL)
	draw_arc(k, _knob_radius, 0.0, TAU, 48, KNOB_LINE, line, true)
