extends Control
## Nút cảm ứng tự vẽ (không cần ảnh), chạy được cả bằng ngón tay lẫn chuột.
## Nhấn = giữ action trong Input Map; thả = nhả action. Gửi InputEventAction thật nên cả
## Input.is_action_pressed() lẫn _unhandled_input() / is_action_pressed(event) đều nhận được.
##
## Kích thước và vị trí tính theo CHIỀU CAO viewport để tỉ lệ luôn giống ảnh tham chiếu ở mọi độ phân giải.

const UiStyle := preload("res://scripts/ui/ui_style.gd")

@export var action: StringName = &"run"
@export_enum("fire", "cast", "run") var icon_kind := "run"
@export var size_h := 0.2          # cạnh nút / chiều cao viewport
@export var from_right_h := 0.23   # tâm nút cách mép phải (đơn vị chiều cao viewport)
@export var from_bottom_h := 0.23  # tâm nút cách mép dưới

# Hình dạng / màu nút (nền, viền, bo góc) lấy từ ui_style.gd để mọi nút giống nhau.
const ICON_DARK := Color(0.30, 0.25, 0.22, 0.85)
const FLAME := [Vector2(0.05, -1.0), Vector2(0.35, -0.6), Vector2(0.68, -0.12), Vector2(0.74, 0.38),
	Vector2(0.46, 0.84), Vector2(0.0, 1.0), Vector2(-0.46, 0.84), Vector2(-0.74, 0.38),
	Vector2(-0.66, -0.05), Vector2(-0.36, -0.42), Vector2(-0.24, -0.12), Vector2(-0.16, -0.55)]

var _pointer := -1   # -1 rảnh, -2 chuột, >= 0 chỉ số ngón tay đang giữ nút
var _pressed := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	get_viewport().size_changed.connect(_layout)
	_layout()


func _exit_tree() -> void:
	_set_pressed(false)


func _layout() -> void:
	var vp := get_viewport_rect().size
	var s := vp.y * size_h
	size = Vector2(s, s)
	position = Vector2(vp.x - vp.y * from_right_h - s * 0.5, vp.y - vp.y * from_bottom_h - s * 0.5)
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	var touch := event as InputEventScreenTouch
	var click := event as InputEventMouseButton
	if touch != null:
		if touch.pressed and _pointer == -1:
			_pointer = touch.index
			_set_pressed(true)
			accept_event()
		elif not touch.pressed and touch.index == _pointer:
			_pointer = -1
			_set_pressed(false)
			accept_event()
	elif click != null and click.button_index == MOUSE_BUTTON_LEFT:
		if click.pressed and _pointer == -1:
			_pointer = -2
			_set_pressed(true)
			accept_event()
		elif not click.pressed and _pointer == -2:
			_pointer = -1
			_set_pressed(false)
			accept_event()


func _set_pressed(on: bool) -> void:
	if on == _pressed:
		return
	_pressed = on
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = on
	ev.strength = 1.0 if on else 0.0
	Input.parse_input_event(ev)
	queue_redraw()


func _draw() -> void:
	var s := size.x
	UiStyle.draw_button(self, Rect2(Vector2.ZERO, size), _pressed)
	var k := 0.94 if _pressed else 1.0
	draw_set_transform(size * 0.5, 0.0, Vector2(k, k))
	var u := s * 0.26 # đơn vị kích thước biểu tượng
	match icon_kind:
		"fire":
			_draw_fire(u)
		"cast":
			_draw_cast(u)
		_:
			_draw_run(u)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_fire(u: float) -> void:
	var outer := PackedVector2Array()
	var inner := PackedVector2Array()
	for p in FLAME:
		outer.append(p * u)
		inner.append(p * u * 0.5 + Vector2(0, 0.35 * u))
	draw_colored_polygon(outer, Color(1.0, 0.55, 0.15, 0.92))
	draw_colored_polygon(inner, Color(1.0, 0.86, 0.35, 0.95))


func _draw_cast(u: float) -> void:
	var c := Color(0.45, 0.75, 1.0, 0.92)
	var w := maxf(2.0, u * 0.12)
	draw_arc(Vector2.ZERO, u, 0.0, TAU, 48, c, w, true)
	draw_arc(Vector2.ZERO, u * 0.72, 0.0, TAU, 48, c, w * 0.7, true)
	for start in [-PI * 0.5, PI * 0.5]:  # hai tam giác chồng nhau = sao 6 cánh
		var tri := PackedVector2Array()
		for i in 4:
			tri.append(Vector2.from_angle(start + TAU * i / 3.0) * u * 0.72)
		draw_polyline(tri, c, w * 0.7, true)


func _draw_run(u: float) -> void:
	var w := maxf(3.0, u * 0.22)
	for dx in [-0.42, 0.42]:
		var chevron := PackedVector2Array([
			Vector2(dx * u - 0.3 * u, -0.7 * u), Vector2(dx * u + 0.3 * u, 0.0), Vector2(dx * u - 0.3 * u, 0.7 * u)])
		draw_polyline(chevron, ICON_DARK, w, true)
