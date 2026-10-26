extends Control
## Nút tương tác theo ngữ cảnh: chỉ hiện khi có vật thể thu thập được trong tầm (Nhặt / Chặt / Đập).
## Gửi InputEventAction "interact" như phím E. Vị trí / kích thước tính theo chiều cao màn hình
## (cùng quy ước với các nút hành động: tâm nút cách mép phải / mép dưới bao nhiêu phần chiều cao).

const ItemDefs := preload("res://scripts/inventory/item_defs.gd")
const UiStyle := preload("res://scripts/ui/ui_style.gd")

@export var size_h := 0.16
@export var from_right_h := 0.462
@export var from_bottom_h := 0.50

const DARK := Color(0.30, 0.16, 0.30, 0.90)
const STEEL := Color(0.78, 0.82, 0.86, 0.95)
const WOOD := Color(0.62, 0.40, 0.22, 0.95)
const STONE := Color(0.64, 0.65, 0.70, 0.95)

var _icon_kind := ""
var _label := ""
var _finger := -1
var _down := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	if not InputMap.has_action(&"interact"):
		InputMap.add_action(&"interact")
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_E
	if not InputMap.action_has_event(&"interact", ev):
		InputMap.action_add_event(&"interact", ev)
	get_viewport().size_changed.connect(_layout)
	_layout()


func _exit_tree() -> void:
	if _down:
		_send(false)


## icon_kind rỗng = ẩn nút. label hiện dưới nút (vd "Chặt cây (2/4)").
func set_prompt(icon_kind: String, label: String) -> void:
	if icon_kind == "" and _down:
		_down = false
		_finger = -1
		_send(false)
	_icon_kind = icon_kind
	_label = label
	visible = icon_kind != ""
	queue_redraw()


func _layout() -> void:
	var vp := get_viewport_rect().size
	var d := vp.y * size_h
	size = Vector2(d, d)
	position = Vector2(vp.x - vp.y * from_right_h - d * 0.5, vp.y - vp.y * from_bottom_h - d * 0.5)
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed and _finger == -1:
			_finger = event.index
			_set_down(true)
			accept_event()
		elif not event.pressed and event.index == _finger:
			_finger = -1
			_set_down(false)
			accept_event()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and _finger == -1:
			_finger = -2
			_set_down(true)
			accept_event()
		elif not event.pressed and _finger == -2:
			_finger = -1
			_set_down(false)
			accept_event()


func _set_down(on: bool) -> void:
	_down = on
	_send(on)
	queue_redraw()


func _send(pressed: bool) -> void:
	var ev := InputEventAction.new()
	ev.action = &"interact"
	ev.pressed = pressed
	Input.parse_input_event(ev)


func _draw() -> void:
	var u := minf(size.x, size.y)
	var rect := Rect2(Vector2.ZERO, size)
	UiStyle.draw_button(self, rect, _down) # hình dạng nút dùng chung, xem ui_style.gd
	var c := rect.get_center()
	var k := u * 0.30
	var tex := ItemDefs.ui_icon(_icon_kind) # sprite tuỳ chọn: res://assets/ui/pickup.png, chop.png, smash.png
	if tex != null:
		var side := u * 0.62
		draw_texture_rect(tex, Rect2(c - Vector2(side, side) * 0.5, Vector2(side, side)), false)
	else:
		match _icon_kind:
			"pickup":
				_icon_pickup(c, k)
			"chop":
				_icon_axe(c, k)
			"smash":
				_icon_pickaxe(c, k)
	if _label != "":
		var font := get_theme_default_font()
		var fs := maxi(12, roundi(u * 0.17))
		var w := font.get_string_size(_label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var pos := Vector2((size.x - w) * 0.5, size.y + fs * 1.25)
		draw_string_outline(font, pos, _label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 7, Color(0.12, 0.07, 0.04, 0.95))
		draw_string(font, pos, _label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1.0, 0.95, 0.82))


func _pts(c: Vector2, k: float, unit: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in unit:
		out.append(c + (p as Vector2) * k)
	return out


func _icon_pickup(c: Vector2, k: float) -> void: # ba viên đá nhỏ
	for stone in [[Vector2(-0.45, 0.35), 0.52], [Vector2(0.45, 0.40), 0.58], [Vector2(0.0, -0.30), 0.60]]:
		var centre: Vector2 = c + (stone[0] as Vector2) * k
		var r: float = float(stone[1]) * k
		draw_circle(centre, r, STONE)
		draw_circle(centre + Vector2(-r * 0.25, -r * 0.30), r * 0.38, STONE.lightened(0.35))
		draw_arc(centre, r, 0.0, TAU, 20, DARK, maxf(2.0, k * 0.12), true)


func _icon_axe(c: Vector2, k: float) -> void:
	var handle_a := c + Vector2(-0.75, 0.85) * k
	var handle_b := c + Vector2(0.45, -0.75) * k
	draw_line(handle_a, handle_b, DARK, k * 0.34, true)
	draw_line(handle_a, handle_b, WOOD, k * 0.18, true)
	var head := _pts(c, k, [Vector2(0.10, -1.00), Vector2(0.95, -0.72), Vector2(0.92, 0.02), Vector2(0.50, -0.22), Vector2(0.18, -0.48)])
	var loop := head.duplicate()
	loop.append(head[0])
	draw_colored_polygon(head, STEEL)
	draw_polyline(loop, DARK, maxf(2.0, k * 0.14), true)


func _icon_pickaxe(c: Vector2, k: float) -> void:
	var handle_a := c + Vector2(-0.70, 0.90) * k
	var handle_b := c + Vector2(0.55, -0.70) * k
	draw_line(handle_a, handle_b, DARK, k * 0.34, true)
	draw_line(handle_a, handle_b, WOOD, k * 0.18, true)
	var arc := PackedVector2Array()
	for i in 13: # mũi cuốc cong vắt qua đỉnh cán
		var t := float(i) / 12.0
		var x := lerpf(-0.95, 0.95, t)
		arc.append(c + Vector2(x, -0.55 - 0.55 * (1.0 - x * x / 0.9025) + 0.25) * k + Vector2(0.18, -0.12) * k)
	draw_polyline(arc, DARK, k * 0.34, true)
	draw_polyline(arc, STEEL, k * 0.17, true)
