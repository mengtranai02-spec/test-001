extends Control
## Danh sách vật phẩm rơi quanh người chơi (icon + tên, món gần nhất ở trên cùng). Chạm vào một dòng để nhặt món đó,
## hoặc nhấn F để nhặt món đầu danh sách. Danh sách dài hơn MAX_ROWS dòng thì kéo (ngón tay / chuột) hoặc lăn chuột để cuộn.
## Chỉ hiện khi có vật phẩm trong tầm. Gắn vào CanvasLayer, gọi setup(loot_system) một lần.
## Mọi kích thước tính theo CHIỀU CAO viewport như các nút khác.

const ItemDefs := preload("res://scripts/inventory/item_defs.gd")
const ItemIcon := preload("res://scripts/inventory/item_icon.gd")
const UiStyle := preload("res://scripts/ui/ui_style.gd")

const MINIMAP_BOTTOM := 236.0   # phải khớp với inventory_ui.gd: danh sách nằm ngay dưới nút túi
const BAG_SIZE_H := 0.115
const WIDTH_H := 0.35           # chiều rộng / chiều cao viewport
const ROW_H := 0.092            # chiều cao một dòng
const GAP_H := 0.010            # khoảng hở giữa các dòng
const MAX_ROWS := 4             # số dòng hiện cùng lúc, nhiều hơn thì cuộn
const TAP_SLOP := 12.0          # ngón di chuyển quá mức này (px) thì coi là kéo cuộn chứ không phải chạm
const SCROLLBAR_W := 5.0

var loot

var _entries: Array = []        # [{"drop", "id", "count", ...}]
var _pending: Array = []        # danh sách mới đến trong lúc đang chạm / kéo: chờ nhả tay mới áp dụng, tránh dòng nhảy dưới ngón tay
var _has_pending := false
var _scroll := 0.0
var _pointer := -1              # -1 rảnh, -2 chuột, >= 0 chỉ số ngón tay
var _press_row := -1
var _press_pos := Vector2.ZERO
var _last_pos := Vector2.ZERO
var _dragged := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	visible = false
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST # icon pixel art
	get_viewport().size_changed.connect(_layout)
	_layout()


func setup(p_loot) -> void:
	loot = p_loot
	loot.nearby_changed.connect(_on_nearby_changed)


func _on_nearby_changed(entries: Array) -> void:
	if _pointer != -1:
		_pending = entries
		_has_pending = true
		return
	_apply(entries)


func _apply(entries: Array) -> void:
	_entries = entries
	visible = not _entries.is_empty()
	_layout()


# ---------------------------------------------------------------- bố cục

func _row_h() -> float:
	return get_viewport_rect().size.y * ROW_H


func _gap() -> float:
	return get_viewport_rect().size.y * GAP_H


func _content_h() -> float:
	var n := _entries.size()
	if n == 0:
		return 0.0
	return n * _row_h() + (n - 1) * _gap()


func _max_scroll() -> float:
	return maxf(0.0, _content_h() - size.y)


func _layout() -> void:
	var vp := get_viewport_rect().size
	var row_h := vp.y * ROW_H
	var gap := vp.y * GAP_H
	var top := MINIMAP_BOTTOM + 14.0 + vp.y * BAG_SIZE_H + 12.0
	var fit := maxi(1, floori((vp.y - top - 12.0 + gap) / (row_h + gap)))
	var rows := clampi(_entries.size(), 1, mini(MAX_ROWS, fit))
	var w := vp.y * WIDTH_H
	size = Vector2(w, rows * row_h + (rows - 1) * gap)
	position = Vector2(vp.x - 16.0 - w, top)
	_scroll = clampf(_scroll, 0.0, _max_scroll())
	queue_redraw()


func _row_at(pos: Vector2) -> int:
	var step := _row_h() + _gap()
	var idx := floori((pos.y + _scroll) / step)
	if idx < 0 or idx >= _entries.size():
		return -1
	return idx if fposmod(pos.y + _scroll, step) <= _row_h() else -1


# ---------------------------------------------------------------- nhập liệu (chạm, kéo cuộn, lăn chuột)

func _gui_input(event: InputEvent) -> void:
	var touch := event as InputEventScreenTouch
	var drag := event as InputEventScreenDrag
	var click := event as InputEventMouseButton
	var motion := event as InputEventMouseMotion
	if touch != null:
		if touch.pressed and _pointer == -1:
			_begin(touch.index, touch.position)
			accept_event()
		elif not touch.pressed and touch.index == _pointer:
			_end(touch.position)
			accept_event()
	elif drag != null:
		if drag.index == _pointer:
			_move(drag.position)
			accept_event()
	elif click != null:
		if click.pressed and click.button_index == MOUSE_BUTTON_WHEEL_UP:
			_scroll_by(-(_row_h() + _gap()))
			accept_event()
		elif click.pressed and click.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_scroll_by(_row_h() + _gap())
			accept_event()
		elif click.button_index == MOUSE_BUTTON_LEFT:
			if click.pressed and _pointer == -1:
				_begin(-2, click.position)
				accept_event()
			elif not click.pressed and _pointer == -2:
				_end(click.position)
				accept_event()
	elif motion != null:
		if _pointer == -2:
			_move(motion.position)
			accept_event()


func _begin(pointer: int, pos: Vector2) -> void:
	_pointer = pointer
	_press_pos = pos
	_last_pos = pos
	_press_row = _row_at(pos)
	_dragged = false
	queue_redraw()


func _move(pos: Vector2) -> void:
	if not _dragged and pos.distance_to(_press_pos) > TAP_SLOP:
		_dragged = true
	if _dragged:
		_scroll_by(-(pos.y - _last_pos.y))
	_last_pos = pos


func _end(pos: Vector2) -> void:
	var row := _row_at(pos)
	var target: Variant = null
	if not _dragged and row >= 0 and row == _press_row and row < _entries.size():
		target = (_entries[row] as Dictionary)["drop"]
	_pointer = -1
	_press_row = -1
	_dragged = false
	if _has_pending:
		_has_pending = false
		_apply(_pending)
	queue_redraw()
	if target != null and loot != null:
		loot.pickup(target)


func _scroll_by(amount: float) -> void:
	_scroll = clampf(_scroll + amount, 0.0, _max_scroll())
	queue_redraw()


# ---------------------------------------------------------------- vẽ

func _draw() -> void:
	if _entries.is_empty():
		return
	var row_h := _row_h()
	var gap := _gap()
	var max_scroll := _max_scroll()
	var row_w := size.x - (SCROLLBAR_W + 4.0 if max_scroll > 0.0 else 0.0)
	var font := ThemeDB.fallback_font
	var fs := maxi(12, roundi(row_h * 0.34))
	var pad := row_h * 0.12
	var icon := row_h - pad * 2.0
	var show_key := not DisplayServer.is_touchscreen_available() # có phím F thì mới hiện nhãn "F"
	for i in _entries.size():
		var y: float = i * (row_h + gap) - _scroll
		if y + row_h < 0.0 or y > size.y:
			continue
		var e: Dictionary = _entries[i]
		var item_id := str(e["id"])
		var held := _pointer != -1 and i == _press_row and not _dragged
		UiStyle.draw_button(self, Rect2(0.0, y, row_w, row_h), held)
		ItemIcon.draw(self, item_id, Rect2(Vector2(pad * 1.2, y + pad), Vector2(icon, icon)))

		var text_x := pad * 1.2 + icon + pad
		var key_slot := row_h * 0.75 if (i == 0 and show_key) else pad
		var label := ItemDefs.item_name(item_id)
		if int(e["count"]) > 1:
			label += " x%d" % int(e["count"])
		label = _fit(font, label, fs, row_w - text_x - key_slot)
		var pos := Vector2(text_x, y + row_h * 0.5 + fs * 0.35)
		draw_string_outline(font, pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 6, UiStyle.TEXT_OUTLINE)
		draw_string(font, pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, UiStyle.TEXT)

		if i == 0 and show_key:
			var bs := row_h * 0.5
			_draw_key_badge(Rect2(row_w - pad - bs, y + (row_h - bs) * 0.5, bs, bs), "F", fs)

	if max_scroll > 0.0:
		var bar_h := maxf(row_h * 0.4, size.y * size.y / _content_h())
		var bar_y := (size.y - bar_h) * (_scroll / max_scroll)
		draw_rect(Rect2(size.x - SCROLLBAR_W, bar_y, SCROLLBAR_W, bar_h), Color(1.0, 0.93, 0.72, 0.55))


func _draw_key_badge(rect: Rect2, text: String, fs: int) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.20, 0.14, 0.10, 0.85)
	sb.border_color = UiStyle.BORDER
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(roundi(rect.size.x * 0.28))
	sb.anti_aliasing = true
	draw_style_box(sb, rect)
	var font := ThemeDB.fallback_font
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(font, Vector2(rect.get_center().x - w * 0.5, rect.get_center().y + fs * 0.35), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, UiStyle.TEXT)


## Cắt tên quá dài và thêm "…" cho vừa chiều rộng max_w.
func _fit(font: Font, text: String, fs: int, max_w: float) -> String:
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= max_w:
		return text
	var t := text
	while t.length() > 1 and font.get_string_size(t + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > max_w:
		t = t.substr(0, t.length() - 1)
	return t + "…"
