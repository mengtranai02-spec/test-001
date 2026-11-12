extends Control
## Nút cảm ứng tự vẽ (không cần ảnh) dùng cho mọi nút trên màn hình, chạy được cả bằng ngón tay lẫn chuột.
##  - action != "": giữ nút = giữ action trong Input Map (nút chạy, nút tương tác). Gửi InputEventAction thật nên
##    Input.is_action_pressed() lẫn _unhandled_input() đều nhận được.
##  - action == "": chạm nút = phát signal tapped (nút túi).
##  - hide_when_idle: nút ẩn cho tới khi set_prompt(icon, chữ) được gọi với icon khác rỗng (nút tương tác theo ngữ cảnh).
## Kích thước / vị trí tính theo CHIỀU CAO viewport (tâm nút cách mép phải / mép dưới bao nhiêu phần chiều cao);
## tắt auto_layout nếu muốn tự đặt size / position (nút túi).
## Hình dạng nút (nền, viền, bo góc) nằm ở draw_frame() / draw_button() để các UI khác (danh sách nhặt, ô túi) vẽ cùng kiểu.
## Icon: nếu có res://assets/ui/<icon_kind>.png thì dùng ảnh đó, không thì vẽ bằng code: run, pickup, chop, smash, bag, pilball.

signal tapped
signal drag_changed(direction: Vector2)
signal drag_ended(direction: Vector2)

const ItemDefs := preload("res://scripts/inventory/item_defs.gd")

const FILL := Color(0.188, 0.145, 0.110, 0.70) # #30251C, opacity 70%
const FILL_DOWN := Color(0.188, 0.145, 0.110, 0.78)
const BORDER := Color(0.906, 0.773, 0.545, 0.95) # #E7C58B
const BORDER_DOWN := Color(0.98, 0.86, 0.64, 1.0)
const RADIUS := 0.15         # khoảng 24 px với button 160 px
const BORDER_WIDTH := 0.055  # độ dày viền cũ / cạnh ngắn
const TEXT := Color(1.0, 0.95, 0.82)
const OUTLINE := Color(0.12, 0.07, 0.04, 0.95)
const DARK := Color(0.30, 0.16, 0.30, 0.90)
const STEEL := Color(0.78, 0.82, 0.86, 0.95)
const WOOD := Color(0.62, 0.40, 0.22, 0.95)
const STONE := Color(0.64, 0.65, 0.70, 0.95)

@export var action: StringName = &""
@export var icon_kind := "run"
@export var size_h := 0.16
@export var from_right_h := 0.23
@export var from_bottom_h := 0.23
@export var layout_offset_px := Vector2.ZERO
@export var auto_layout := true
@export var hide_when_idle := false
@export var circular := true
@export var drag_mode := false

## Nút ở trạng thái bật (ví dụ chế độ "Ném Pilball"): vẽ đậm như đang nhấn.
var active := false:
	set(value):
		if value != active:
			active = value
			queue_redraw()

var _pointer := -1   # -1 rảnh, -2 chuột, >= 0 chỉ số ngón tay đang giữ nút
var _down := false
var _drag_pointer := -1
var _drag_direction := Vector2.ZERO
var _drag_origin := Vector2.ZERO
var _icon_sprite: Sprite2D
var _warm_icon_material: ShaderMaterial


## Vẽ khung (nền + viền bo góc) vào canvas ci, gọi trong _draw của ci. Dùng chung cho nút, dòng danh sách, ô túi.
## radius_px / border_px < 0 thì tính theo cạnh ngắn của rect (RADIUS, BORDER_WIDTH).
## Nền phủ kín cả khung rồi viền (không nền) vẽ đè lên. Không dùng một StyleBoxFlat vừa nền vừa viền vì khi nền và viền
## đều bán trong suốt + anti_aliasing, hai vùng chỉ phủ một phần điểm ảnh ở ranh giới nên lộ nền phía sau thành vệt sáng.
static func draw_frame(ci: CanvasItem, rect: Rect2, fill: Color = FILL, border: Color = BORDER,
		radius_px: float = -1.0, border_px: float = -1.0) -> void:
	var u: float = minf(rect.size.x, rect.size.y)
	var bg := StyleBoxFlat.new()
	bg.bg_color = fill
	var ring := StyleBoxFlat.new()
	ring.draw_center = false
	ring.border_color = border
	ring.set_border_width_all(roundi(border_px) if border_px >= 0.0 else maxi(2, roundi(u * BORDER_WIDTH)))
	for sb: StyleBoxFlat in [bg, ring]:
		sb.set_corner_radius_all(roundi(radius_px) if radius_px >= 0.0 else roundi(u * RADIUS))
		sb.anti_aliasing = true
		ci.draw_style_box(sb, rect)


## Khung nút bấm: thu nhỏ và đậm hơn khi đang nhấn.
static func draw_button(ci: CanvasItem, rect: Rect2, pressed: bool = false) -> void:
	if pressed:
		var u: float = minf(rect.size.x, rect.size.y)
		draw_frame(ci, rect.grow(-u * 0.03), FILL_DOWN, BORDER_DOWN)
	else:
		draw_frame(ci, rect)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_icon_sprite = Sprite2D.new()
	_icon_sprite.centered = true
	var icon_shader := Shader.new()
	icon_shader.code = """
shader_type canvas_item;
void fragment() {
	vec4 c = texture(TEXTURE, UV) * COLOR;
	float l = dot(c.rgb, vec3(0.299, 0.587, 0.114));
	vec3 warm_dark = vec3(0.92, 0.76, 0.52);
	float amount = 1.0 - smoothstep(0.08, 0.58, l);
	COLOR = vec4(mix(c.rgb, warm_dark, amount * 0.94), c.a);
}
"""
	_warm_icon_material = ShaderMaterial.new()
	_warm_icon_material.shader = icon_shader
	add_child(_icon_sprite)
	resized.connect(_update_icon_sprite)
	_update_icon_sprite()
	visible = not hide_when_idle
	if auto_layout:
		get_viewport().size_changed.connect(_layout)
		_layout()


func _exit_tree() -> void:
	_set_down(false)


## icon rỗng = ẩn nút (với hide_when_idle). label hiện dưới nút, ví dụ "Chặt cây (2/4)".
func set_prompt(icon: String, _label: String) -> void:
	if icon == "":
		_pointer = -1
		_set_down(false)
	icon_kind = icon
	_update_icon_sprite()
	visible = icon != "" or not hide_when_idle
	queue_redraw()


func _has_point(point: Vector2) -> bool:
	if circular:
		return point.distance_to(size * 0.5) <= minf(size.x, size.y) * 0.5
	return Rect2(Vector2.ZERO, size).has_point(point)


func _update_icon_sprite() -> void:
	if _icon_sprite == null:
		return
	var tex := ItemDefs.ui_icon(icon_kind)
	_icon_sprite.texture = tex
	_icon_sprite.visible = tex != null
	_icon_sprite.material = _warm_icon_material if icon_kind in ["attack", "pickup", "run"] else null
	if tex == null or size.x <= 0.0 or size.y <= 0.0:
		return
	var side := minf(size.x, size.y) * 0.62
	var tex_size := tex.get_size()
	var fit := side / maxf(tex_size.x, tex_size.y)
	_icon_sprite.scale = Vector2(fit, fit)
	_icon_sprite.position = size * 0.5


func _layout() -> void:
	var vp := get_viewport_rect().size
	var d := vp.y * size_h
	size = Vector2(d, d)
	position = Vector2(vp.x - vp.y * from_right_h - d * 0.5, vp.y - vp.y * from_bottom_h - d * 0.5) + layout_offset_px
	_update_icon_sprite()
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if drag_mode:
		_handle_drag_input(event)
		return
	var touch := event as InputEventScreenTouch
	var click := event as InputEventMouseButton
	var pointer := -1
	var pressed := false
	if touch != null:
		pointer = touch.index
		pressed = touch.pressed
	elif click != null and click.button_index == MOUSE_BUTTON_LEFT:
		pointer = -2
		pressed = click.pressed
	else:
		return
	if pressed and _pointer == -1:
		_pointer = pointer
		_set_down(true)
	elif not pressed and pointer == _pointer:
		_pointer = -1
		_set_down(false)
	else:
		return
	accept_event()


func _handle_drag_input(event: InputEvent) -> void:
	var touch := event as InputEventScreenTouch
	var click := event as InputEventMouseButton
	if touch != null:
		if touch.pressed and _drag_pointer == -1:
			_drag_pointer = touch.index
			_drag_origin = touch.position
			_drag_direction = Vector2.ZERO
			if _icon_sprite != null:
				_icon_sprite.visible = false
			_set_down(true)
			queue_redraw()
			accept_event()
		elif not touch.pressed and touch.index == _drag_pointer:
			drag_ended.emit(_drag_direction)
			_drag_pointer = -1
			_drag_direction = Vector2.ZERO
			_update_icon_sprite()
			_set_down(false)
			queue_redraw()
			accept_event()
		return
	if click != null and click.button_index == MOUSE_BUTTON_LEFT:
		if click.pressed and _drag_pointer == -1:
			_drag_pointer = -2
			_drag_origin = click.position
			_drag_direction = Vector2.ZERO
			if _icon_sprite != null:
				_icon_sprite.visible = false
			_set_down(true)
			queue_redraw()
			accept_event()
		elif not click.pressed and _drag_pointer == -2:
			drag_ended.emit(_drag_direction)
			_drag_pointer = -1
			_drag_direction = Vector2.ZERO
			_update_icon_sprite()
			_set_down(false)
			queue_redraw()
			accept_event()
		return
	var touch_drag := event as InputEventScreenDrag
	var mouse_motion := event as InputEventMouseMotion
	if touch_drag != null and touch_drag.index == _drag_pointer:
		_update_drag_direction(touch_drag.position)
		accept_event()
	elif mouse_motion != null and _drag_pointer == -2 and (mouse_motion.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		_update_drag_direction(mouse_motion.position)
		accept_event()


func _update_drag_direction(pointer_position: Vector2) -> void:
	var pull := (pointer_position - _drag_origin) / maxf(size.y, 1.0)
	_drag_direction = pull.limit_length(1.0)
	drag_changed.emit(_drag_direction)
	queue_redraw()


func _set_down(on: bool) -> void:
	if on == _down:
		return
	_down = on
	if action != &"":
		var ev := InputEventAction.new()
		ev.action = action
		ev.pressed = on
		ev.strength = 1.0 if on else 0.0
		Input.parse_input_event(ev)
	elif on:
		tapped.emit()
	queue_redraw()


# ---------------------------------------------------------------- vẽ

func _draw() -> void:
	var u := minf(size.x, size.y)
	if circular:
		var center := size * 0.5
		var radius := u * (0.47 if _down or active else 0.5)
		var border_width := maxf(2.0, u * BORDER_WIDTH)
		draw_circle(center, radius, FILL_DOWN if _down or active else FILL)
		draw_arc(center, radius - border_width * 0.5, 0.0, TAU, 48,
			BORDER_DOWN if _down or active else BORDER, border_width, true)
		if drag_mode and _drag_pointer != -1:
			var travel := u * 0.90
			var ring_radius := u * 1.05
			var glow := Color(0.94, 0.78, 0.52, 0.10)
			var edge := Color(0.94, 0.78, 0.52, 0.58)
			var knob := center + _drag_direction * travel
			draw_circle(center, ring_radius, glow)
			draw_arc(center, ring_radius, 0.0, TAU, 64, edge, maxf(2.0, u * 0.035), true)
			if _drag_direction.length() > 0.02:
				draw_line(center, knob, Color(0.94, 0.78, 0.52, 0.45), maxf(2.0, u * 0.035), true)
			draw_circle(knob, u * 0.22, Color(0.94, 0.78, 0.52, 0.42))
			draw_arc(knob, u * 0.22, 0.0, TAU, 48, Color(1.0, 0.90, 0.70, 0.82), maxf(2.0, u * 0.025), true)
	else:
		draw_button(self, Rect2(Vector2.ZERO, size), _down or active)
	var k := 0.94 if _down else 1.0
	draw_set_transform(size * 0.5, 0.0, Vector2(k, k)) # từ đây icon vẽ quanh gốc (0, 0), thu nhỏ nhẹ khi nhấn
	var tex := ItemDefs.ui_icon(icon_kind)
	if tex == null:
		match icon_kind:
			"attack":
				var tip := Vector2(u * 0.24, -u * 0.25)
				var grip := Vector2(-u * 0.22, u * 0.23)
				draw_line(grip, tip, STEEL, u * 0.09, true)
				draw_line(Vector2(-u * 0.23, u * 0.03), Vector2(-u * 0.03, u * 0.23), TEXT, u * 0.055, true)
			"run": _icon_run(u * 0.26)
			"pickup": _icon_pickup(u * 0.30)
			"chop": _icon_axe(u * 0.30)
			"smash": _icon_pickaxe(u * 0.30)
			"bag": _icon_bag(u * 0.30)
			"pilball": _icon_pilball(u * 0.30)
			"build": _icon_hammer(u * 0.30)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _pts(k: float, unit: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in unit:
		out.append((p as Vector2) * k)
	return out


func _stroke(line: PackedVector2Array, k: float, color: Color) -> void: # viền tối nằm dưới nét màu
	draw_polyline(line, DARK, k * 0.34, true)
	draw_polyline(line, color, k * 0.17, true)


func _icon_run(k: float) -> void:
	for dx in [-0.42, 0.42]:
		draw_polyline(_pts(k, [Vector2(dx - 0.3, -0.7), Vector2(dx + 0.3, 0.0), Vector2(dx - 0.3, 0.7)]),
			Color(0.30, 0.25, 0.22, 0.85), maxf(3.0, k * 0.22), true)


func _icon_pickup(k: float) -> void: # ba viên đá nhỏ
	for stone in [[Vector2(-0.45, 0.35), 0.52], [Vector2(0.45, 0.40), 0.58], [Vector2(0.0, -0.30), 0.60]]:
		var centre: Vector2 = (stone[0] as Vector2) * k
		var r: float = float(stone[1]) * k
		draw_circle(centre, r, STONE)
		draw_circle(centre + Vector2(-r * 0.25, -r * 0.30), r * 0.38, STONE.lightened(0.35))
		draw_arc(centre, r, 0.0, TAU, 20, DARK, maxf(2.0, k * 0.12), true)


func _icon_axe(k: float) -> void:
	_stroke(_pts(k, [Vector2(-0.75, 0.85), Vector2(0.45, -0.75)]), k, WOOD)
	var head := _pts(k, [Vector2(0.10, -1.00), Vector2(0.95, -0.72), Vector2(0.92, 0.02), Vector2(0.50, -0.22), Vector2(0.18, -0.48)])
	draw_colored_polygon(head, STEEL)
	head.append(head[0])
	draw_polyline(head, DARK, maxf(2.0, k * 0.14), true)


func _icon_pickaxe(k: float) -> void:
	_stroke(_pts(k, [Vector2(-0.70, 0.90), Vector2(0.55, -0.70)]), k, WOOD)
	var arc := PackedVector2Array()
	for i in 13: # mũi cuốc cong vắt qua đỉnh cán
		var x := lerpf(-0.95, 0.95, i / 12.0)
		arc.append(Vector2(x + 0.18, -0.55 - 0.55 * (1.0 - x * x / 0.9025) + 0.25 - 0.12) * k)
	_stroke(arc, k, STEEL)


func _icon_bag(k: float) -> void: # ba lô
	var body := StyleBoxFlat.new()
	body.bg_color = Color(0.72, 0.48, 0.26, 0.95)
	var flap := StyleBoxFlat.new()
	flap.bg_color = Color(0.58, 0.36, 0.20, 0.95)
	for sb: StyleBoxFlat in [body, flap]:
		sb.border_color = DARK
		sb.set_border_width_all(maxi(2, roundi(k * 0.14)))
		sb.anti_aliasing = true
	body.set_corner_radius_all(roundi(k * 0.45))
	flap.corner_radius_top_left = roundi(k * 0.45)
	flap.corner_radius_top_right = roundi(k * 0.45)
	draw_style_box(body, Rect2(Vector2(-0.85, -0.65) * k, Vector2(1.7, 1.7) * k))
	draw_style_box(flap, Rect2(Vector2(-0.85, -0.65) * k, Vector2(1.7, 0.75) * k))
	var pocket := Rect2(Vector2(-0.30, 0.30) * k, Vector2(0.6, 0.45) * k)
	draw_rect(pocket, Color(0.45, 0.28, 0.16, 0.95))
	draw_rect(pocket, DARK, false, maxf(2.0, k * 0.10))
	draw_arc(Vector2(0.0, -0.70) * k, k * 0.38, PI, TAU, 16, DARK, maxf(2.0, k * 0.16), true)


func _icon_pilball(k: float) -> void: # quả cầu vàng
	var r := k * 0.95
	draw_circle(Vector2.ZERO, r, DARK)
	draw_circle(Vector2.ZERO, r * 0.86, Color(0.93, 0.64, 0.22, 0.98))
	draw_circle(Vector2(0.0, r * 0.2), r * 0.6, Color(0.80, 0.45, 0.16, 0.9))
	draw_line(Vector2(-r * 0.86, 0.0), Vector2(r * 0.86, 0.0), DARK, maxf(2.0, k * 0.14))
	draw_circle(Vector2.ZERO, r * 0.24, Color(1.0, 0.95, 0.8, 0.98))
	draw_arc(Vector2.ZERO, r * 0.24, 0.0, TAU, 14, DARK, maxf(2.0, k * 0.1), true)
	draw_circle(Vector2(-r * 0.36, -r * 0.4), r * 0.2, Color(1.0, 0.93, 0.72, 0.9))


func _icon_hammer(k: float) -> void:
	_stroke(_pts(k, [Vector2(-0.62, 0.88), Vector2(0.38, -0.35)]), k, WOOD)
	var head := _pts(k, [Vector2(-0.55, -0.95), Vector2(0.82, -0.60), Vector2(0.62, 0.18), Vector2(-0.10, -0.12), Vector2(-0.30, 0.10)])
	draw_colored_polygon(head, STEEL)
	head.append(head[0])
	draw_polyline(head, DARK, maxf(2.0, k * 0.14), true)
