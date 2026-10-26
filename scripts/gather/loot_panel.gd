extends Control
## Danh sách vật phẩm rơi quanh người chơi (icon 32px + tên, món gần nhất ở trên cùng), nằm ngay dưới nút túi.
## Chạm vào một dòng để nhặt món đó, hoặc nhấn F để nhặt món đầu danh sách. Nhiều hơn MAX_ROWS dòng thì kéo
## (ngón tay / chuột) hoặc lăn chuột để cuộn. Chỉ hiện khi có vật phẩm trong tầm.
## Gắn vào CanvasLayer, gọi setup(loot_system, nút_túi) một lần.

const ItemDefs := preload("res://scripts/inventory/item_defs.gd")
const ItemIcon := preload("res://scripts/inventory/item_icon.gd")
const HudButton := preload("res://scripts/ui/hud_button.gd")

const ROW_H := 44.0       # dòng cao 44: icon 32 + viền
const GAP := 4.0
const WIDTH := 220.0
const MAX_ROWS := 5       # số dòng hiện cùng lúc, nhiều hơn thì cuộn
const FONT_SIZE := 16
const TAP_SLOP := 12.0    # ngón di chuyển quá mức này (px) thì coi là kéo cuộn chứ không phải chạm
const BAR_W := 5.0

var loot

var _anchor: Control            # nút túi: danh sách nằm dưới nó
var _entries: Array = []        # [{"drop", "id", "count", ...}]
var _pending: Array = []        # danh sách mới đến lúc đang chạm / kéo: chờ nhả tay mới áp dụng, tránh dòng nhảy dưới ngón tay
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


func setup(p_loot, anchor: Control) -> void:
	loot = p_loot
	_anchor = anchor
	loot.nearby_changed.connect(_on_nearby_changed)
	_layout()


func _on_nearby_changed(entries: Array) -> void:
	if _pointer != -1:
		_pending = entries
		_has_pending = true
	else:
		_apply(entries)


func _apply(entries: Array) -> void:
	_entries = entries
	visible = not _entries.is_empty()
	_layout()


# ---------------------------------------------------------------- bố cục

func _content_h() -> float:
	return maxf(0.0, _entries.size() * (ROW_H + GAP) - GAP)


func _max_scroll() -> float:
	return maxf(0.0, _content_h() - size.y)


func _layout() -> void:
	var vp := get_viewport_rect().size
	var top := 12.0
	if _anchor != null:
		top += _anchor.position.y + _anchor.size.y
	var fit := maxi(1, floori((vp.y - top - 12.0 + GAP) / (ROW_H + GAP)))
	var rows := clampi(_entries.size(), 1, mini(MAX_ROWS, fit))
	size = Vector2(WIDTH, rows * (ROW_H + GAP) - GAP)
	position = Vector2(vp.x - 16.0 - WIDTH, top)
	_scroll = clampf(_scroll, 0.0, _max_scroll())
	queue_redraw()


func _row_at(pos: Vector2) -> int:
	var y := pos.y + _scroll
	var idx := floori(y / (ROW_H + GAP))
	if idx < 0 or idx >= _entries.size() or fposmod(y, ROW_H + GAP) > ROW_H:
		return -1
	return idx


# ---------------------------------------------------------------- nhập liệu (chạm, kéo cuộn, lăn chuột)

func _gui_input(event: InputEvent) -> void:
	var touch := event as InputEventScreenTouch
	var drag := event as InputEventScreenDrag
	var click := event as InputEventMouseButton
	var motion := event as InputEventMouseMotion
	if touch != null:
		if touch.pressed and _pointer == -1:
			_begin(touch.index, touch.position)
		elif not touch.pressed and touch.index == _pointer:
			_end(touch.position)
		else:
			return
	elif drag != null:
		if drag.index != _pointer:
			return
		_move(drag.position)
	elif click != null:
		if click.pressed and click.button_index == MOUSE_BUTTON_WHEEL_UP:
			_scroll_by(-(ROW_H + GAP))
		elif click.pressed and click.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_scroll_by(ROW_H + GAP)
		elif click.button_index == MOUSE_BUTTON_LEFT and click.pressed and _pointer == -1:
			_begin(-2, click.position)
		elif click.button_index == MOUSE_BUTTON_LEFT and not click.pressed and _pointer == -2:
			_end(click.position)
		else:
			return
	elif motion != null and _pointer == -2:
		_move(motion.position)
	else:
		return
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
		_scroll_by(_last_pos.y - pos.y)
	_last_pos = pos


func _end(pos: Vector2) -> void:
	var row := _row_at(pos)
	var target: Variant = null # món được chạm (nếu là chạm chứ không phải kéo cuộn)
	if not _dragged and row >= 0 and row == _press_row:
		target = (_entries[row] as Dictionary)["drop"]
	_pointer = -1
	_press_row = -1
	_dragged = false
	if _has_pending:
		_has_pending = false
		_apply(_pending)
	queue_redraw()
	if target != null:
		loot.pickup(target)


func _scroll_by(amount: float) -> void:
	_scroll = clampf(_scroll + amount, 0.0, _max_scroll())
	queue_redraw()


# ---------------------------------------------------------------- vẽ

func _draw() -> void:
	var font := ThemeDB.fallback_font
	var max_scroll := _max_scroll()
	var row_w := size.x - (BAR_W + 4.0 if max_scroll > 0.0 else 0.0)
	var icon := ItemDefs.ICON_SIZE
	var show_key := not DisplayServer.is_touchscreen_available() # có bàn phím thì hiện nhãn "F" ở món đầu tiên
	for i in _entries.size():
		var y: float = i * (ROW_H + GAP) - _scroll
		if y + ROW_H < 0.0 or y > size.y:
			continue
		var e: Dictionary = _entries[i]
		var item_id := str(e["id"])
		HudButton.draw_button(self, Rect2(0.0, y, row_w, ROW_H), _pointer != -1 and i == _press_row and not _dragged)
		ItemIcon.draw(self, item_id, Rect2(Vector2(6.0, y + (ROW_H - icon) * 0.5), Vector2(icon, icon)))

		var label := ItemDefs.item_name(item_id)
		if int(e["count"]) > 1:
			label += " x%d" % int(e["count"])
		var badge := i == 0 and show_key
		var text_x := 6.0 + icon + 8.0
		label = _fit(font, label, row_w - text_x - (ROW_H if badge else 8.0))
		var pos := Vector2(text_x, y + ROW_H * 0.5 + FONT_SIZE * 0.35)
		draw_string_outline(font, pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, 6, HudButton.OUTLINE)
		draw_string(font, pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, HudButton.TEXT)
		if badge:
			_draw_key_badge(Rect2(row_w - 30.0, y + (ROW_H - 24.0) * 0.5, 24.0, 24.0), "F", font)

	if max_scroll > 0.0:
		var bar_h := maxf(16.0, size.y * size.y / _content_h())
		var bar_y := (size.y - bar_h) * (_scroll / max_scroll)
		draw_rect(Rect2(size.x - BAR_W, bar_y, BAR_W, bar_h), Color(1.0, 0.93, 0.72, 0.55))


func _draw_key_badge(rect: Rect2, text: String, font: Font) -> void:
	HudButton.draw_frame(self, rect, Color(0.20, 0.14, 0.10, 0.85), HudButton.BORDER, 7.0, 2.0)
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
	draw_string(font, Vector2(rect.get_center().x - w * 0.5, rect.get_center().y + FONT_SIZE * 0.35), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, HudButton.TEXT)


## Cắt tên quá dài và thêm "…" cho vừa chiều rộng max_w.
func _fit(font: Font, text: String, max_w: float) -> String:
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x <= max_w:
		return text
	var t := text
	while t.length() > 1 and font.get_string_size(t + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x > max_w:
		t = t.substr(0, t.length() - 1)
	return t + "…"
