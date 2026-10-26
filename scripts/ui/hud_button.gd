extends Control
## Nút cảm ứng tự vẽ (không cần ảnh) dùng cho mọi nút trên màn hình, chạy được cả bằng ngón tay lẫn chuột.
##  - action != "": giữ nút = giữ action trong Input Map (nút chạy, nút tương tác). Gửi InputEventAction thật nên
##    Input.is_action_pressed() lẫn _unhandled_input() đều nhận được.
##  - action == "": chạm nút = phát signal tapped (nút túi).
##  - hide_when_idle: nút ẩn cho tới khi set_prompt(icon, chữ) được gọi với icon khác rỗng (nút tương tác theo ngữ cảnh).
## Kích thước / vị trí tính theo CHIỀU CAO viewport (tâm nút cách mép phải / mép dưới bao nhiêu phần chiều cao);
## tắt auto_layout nếu muốn tự đặt size / position (nút túi).
## Hình dạng nút (nền, viền, bo góc) nằm ở draw_frame() / draw_button() để các UI khác (danh sách nhặt, ô túi) vẽ cùng kiểu.
## Icon: nếu có res://assets/ui/<icon_kind>.png thì dùng ảnh đó, không thì vẽ bằng code: run, pickup, chop, smash, bag.

signal tapped

const ItemDefs := preload("res://scripts/inventory/item_defs.gd")

const FILL := Color(1.0, 0.93, 0.72, 0.34)
const FILL_DOWN := Color(1.0, 0.93, 0.72, 0.55)
const BORDER := Color(0.62, 0.45, 0.30, 0.60)
const BORDER_DOWN := Color(0.62, 0.45, 0.30, 0.85)
const RADIUS := 0.25         # bo góc / cạnh ngắn
const BORDER_WIDTH := 0.055  # độ dày viền / cạnh ngắn
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
@export var auto_layout := true
@export var hide_when_idle := false

var _label := ""
var _pointer := -1   # -1 rảnh, -2 chuột, >= 0 chỉ số ngón tay đang giữ nút
var _down := false


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
	visible = not hide_when_idle
	if auto_layout:
		get_viewport().size_changed.connect(_layout)
		_layout()


func _exit_tree() -> void:
	_set_down(false)


## icon rỗng = ẩn nút (với hide_when_idle). label hiện dưới nút, ví dụ "Chặt cây (2/4)".
func set_prompt(icon: String, label: String) -> void:
	if icon == "":
		_pointer = -1
		_set_down(false)
	icon_kind = icon
	_label = label
	visible = icon != "" or not hide_when_idle
	queue_redraw()


func _layout() -> void:
	var vp := get_viewport_rect().size
	var d := vp.y * size_h
	size = Vector2(d, d)
	position = Vector2(vp.x - vp.y * from_right_h - d * 0.5, vp.y - vp.y * from_bottom_h - d * 0.5)
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
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
	draw_button(self, Rect2(Vector2.ZERO, size), _down)
	var k := 0.94 if _down else 1.0
	draw_set_transform(size * 0.5, 0.0, Vector2(k, k)) # từ đây icon vẽ quanh gốc (0, 0), thu nhỏ nhẹ khi nhấn
	var tex := ItemDefs.ui_icon(icon_kind)
	if tex != null:
		var side := u * 0.62
		draw_texture_rect(tex, Rect2(Vector2(-side, -side) * 0.5, Vector2(side, side)), false)
	else:
		match icon_kind:
			"run": _icon_run(u * 0.26)
			"pickup": _icon_pickup(u * 0.30)
			"chop": _icon_axe(u * 0.30)
			"smash": _icon_pickaxe(u * 0.30)
			"bag": _icon_bag(u * 0.30)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if _label != "":
		var font := get_theme_default_font()
		var fs := maxi(12, roundi(u * 0.17))
		var w := font.get_string_size(_label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var pos := Vector2((size.x - w) * 0.5, size.y + fs * 1.25)
		draw_string_outline(font, pos, _label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 7, OUTLINE)
		draw_string(font, pos, _label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, TEXT)


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
