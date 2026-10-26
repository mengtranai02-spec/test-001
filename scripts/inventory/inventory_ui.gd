extends Control
## Giao diện túi đồ: nút túi (dưới minimap), bảng lưới ô, chi tiết vật phẩm, thông báo +N khi nhận đồ.
## Gắn vào một CanvasLayer (để không bị ban đêm nhuộm tối). Gọi setup(inventory) một lần.
## Mọi kích thước tính theo CHIỀU CAO viewport nên giữ nguyên tỉ lệ ở mọi độ phân giải.

const ItemDefs := preload("res://scripts/inventory/item_defs.gd")
const ItemIcon := preload("res://scripts/inventory/item_icon.gd")
const UiStyle := preload("res://scripts/ui/ui_style.gd")

const MINIMAP_BOTTOM := 236.0     # minimap chiếm từ y = 16 tới 236 (px) ở góc trên phải
const BAG_SIZE_H := 0.115         # kích thước nút túi / chiều cao viewport
const SLOT_H := 0.118             # kích thước một ô / chiều cao viewport
const TAP_DEBOUNCE_MS := 90       # chạm cảm ứng vừa sinh sự kiện chạm vừa sinh sự kiện chuột: bỏ cái đến sau

const FILL := Color(1.0, 0.93, 0.72, 0.34)
const BORDER := Color(0.62, 0.45, 0.30, 0.55)
const PANEL_BG := Color(0.20, 0.14, 0.10, 0.95)
const PANEL_BORDER := Color(0.62, 0.45, 0.30, 1.0)
const SLOT_BG := Color(1.0, 0.93, 0.72, 0.13)
const SLOT_BORDER := Color(0.62, 0.45, 0.30, 0.70)
const SLOT_SELECTED := Color(1.0, 0.85, 0.40, 1.0)
const TEXT := Color(1.0, 0.95, 0.82)
const TEXT_DIM := Color(0.85, 0.78, 0.62)
const DARK := Color(0.30, 0.16, 0.30, 0.90)

var inventory

var _bag: Control
var _overlay: Control
var _panel: PanelContainer
var _grid: GridContainer
var _title: Label
var _count_label: Label
var _detail_name: Label
var _detail_desc: Label
var _btn_drop1: Button
var _btn_drop_all: Button
var _btn_sort: Button
var _btn_close: Button
var _toasts: VBoxContainer
var _views: Array = []
var _selected := -1


# ---------------------------------------------------------------- nút túi
class BagButton extends Control:
	const UiStyle := preload("res://scripts/ui/ui_style.gd")
	signal pressed
	var last_ms := 0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _gui_input(event: InputEvent) -> void:
		var tap: bool = (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT) \
			or (event is InputEventScreenTouch and event.pressed)
		if tap:
			accept_event()
			var now := Time.get_ticks_msec()
			if now - last_ms > 90:
				last_ms = now
				pressed.emit()

	func _draw() -> void:
		var u := minf(size.x, size.y)
		UiStyle.draw_button(self, Rect2(Vector2.ZERO, size)) # hình dạng nút dùng chung, xem ui_style.gd
		var tex := preload("res://scripts/inventory/item_defs.gd").ui_icon("bag")
		if tex != null:
			var side := u * 0.62
			draw_texture_rect(tex, Rect2((size - Vector2(side, side)) * 0.5, Vector2(side, side)), false)
			return
		_draw_backpack(size * 0.5, u * 0.30)

	# Ba lô vẽ bằng code (thay bằng res://assets/ui/bag.png khi có sprite).
	func _draw_backpack(c: Vector2, k: float) -> void:
		var dark := Color(0.30, 0.16, 0.30, 0.90)
		var body := StyleBoxFlat.new()
		body.bg_color = Color(0.72, 0.48, 0.26, 0.95)
		body.border_color = dark
		body.set_border_width_all(maxi(2, roundi(k * 0.14)))
		body.set_corner_radius_all(roundi(k * 0.45))
		body.anti_aliasing = true
		draw_style_box(body, Rect2(c + Vector2(-0.85, -0.65) * k, Vector2(1.7, 1.7) * k))
		var flap := StyleBoxFlat.new()
		flap.bg_color = Color(0.58, 0.36, 0.20, 0.95)
		flap.border_color = dark
		flap.set_border_width_all(maxi(2, roundi(k * 0.14)))
		flap.corner_radius_top_left = roundi(k * 0.45)
		flap.corner_radius_top_right = roundi(k * 0.45)
		flap.anti_aliasing = true
		draw_style_box(flap, Rect2(c + Vector2(-0.85, -0.65) * k, Vector2(1.7, 0.75) * k))
		draw_rect(Rect2(c + Vector2(-0.30, 0.30) * k, Vector2(0.6, 0.45) * k), Color(0.45, 0.28, 0.16, 0.95))
		draw_rect(Rect2(c + Vector2(-0.30, 0.30) * k, Vector2(0.6, 0.45) * k), dark, false, maxf(2.0, k * 0.10))
		draw_arc(c + Vector2(0, -0.70) * k, k * 0.38, PI, TAU, 16, dark, maxf(2.0, k * 0.16), true)


# ---------------------------------------------------------------- một ô túi
class SlotView extends Control:
	signal tapped(index: int)
	const ItemIcon := preload("res://scripts/inventory/item_icon.gd")
	var index := 0
	var slot: Dictionary = {}
	var selected := false
	var last_ms := 0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST # icon pixel art

	func _gui_input(event: InputEvent) -> void:
		var tap: bool = (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT) \
			or (event is InputEventScreenTouch and event.pressed)
		if tap:
			accept_event()
			var now := Time.get_ticks_msec()
			if now - last_ms > 90:
				last_ms = now
				tapped.emit(index)

	func _draw() -> void:
		var u := minf(size.x, size.y)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(1.0, 0.93, 0.72, 0.13)
		sb.border_color = Color(1.0, 0.85, 0.40, 1.0) if selected else Color(0.62, 0.45, 0.30, 0.70)
		sb.set_border_width_all(roundi(u * (0.06 if selected else 0.035)))
		sb.set_corner_radius_all(roundi(u * 0.14))
		sb.anti_aliasing = true
		draw_style_box(sb, Rect2(Vector2.ZERO, size))
		if slot.is_empty():
			return
		var pad := u * 0.14
		ItemIcon.draw(self, slot["id"], Rect2(Vector2(pad, pad), size - Vector2(pad, pad) * 2.0))
		var count := int(slot["count"])
		if count > 1:
			var font := ThemeDB.fallback_font
			var fs := roundi(u * 0.26)
			var text := str(count)
			var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var pos := Vector2(size.x - w - u * 0.09, size.y - u * 0.10)
			draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 6, Color(0.1, 0.06, 0.04))
			draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1.0, 0.97, 0.88))


# ---------------------------------------------------------------- dựng giao diện
func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE # đóng bảng thì không chặn chạm ở phần còn lại của màn hình
	_ensure_action("inventory", KEY_I)
	get_viewport().size_changed.connect(_layout)


func setup(inv) -> void:
	inventory = inv
	inventory.changed.connect(_refresh)
	inventory.item_added.connect(_on_item_added)
	_build()
	_layout()
	_refresh()


func is_open() -> bool:
	return _overlay != null and _overlay.visible


func toggle() -> void:
	if is_open():
		close()
	else:
		open()


func open() -> void:
	_selected = -1
	_overlay.visible = true
	_layout()
	_refresh()


func close() -> void:
	_overlay.visible = false


## Thông báo nổi ngắn (nhận đồ, túi đầy, thiếu công cụ...).
func toast(text: String, color: Color = TEXT) -> void:
	if _toasts == null:
		return
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", _font(0.036))
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0.12, 0.07, 0.04, 0.95))
	l.add_theme_constant_override("outline_size", 7)
	_toasts.add_child(l)
	while _toasts.get_child_count() > 5:
		var old := _toasts.get_child(0)
		_toasts.remove_child(old)
		old.queue_free()
	var tw := l.create_tween()
	tw.tween_interval(1.4)
	tw.tween_property(l, "modulate:a", 0.0, 0.5)
	tw.tween_callback(l.queue_free)


func _build() -> void:
	_bag = BagButton.new()
	_bag.pressed.connect(toggle)
	add_child(_bag)

	_toasts = VBoxContainer.new()
	_toasts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toasts.alignment = BoxContainer.ALIGNMENT_BEGIN
	add_child(_toasts)

	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.visible = false
	add_child(_overlay)
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.55)
	dim.gui_input.connect(_on_dim_input) # chạm ra ngoài bảng để đóng
	_overlay.add_child(dim)

	_panel = PanelContainer.new()
	var ps := StyleBoxFlat.new()
	ps.bg_color = PANEL_BG
	ps.border_color = PANEL_BORDER
	ps.set_border_width_all(4)
	ps.set_corner_radius_all(22)
	ps.set_content_margin_all(18)
	ps.anti_aliasing = true
	_panel.add_theme_stylebox_override("panel", ps)
	_overlay.add_child(_panel)

	var vbox := VBoxContainer.new()
	_panel.add_child(vbox)

	var header := HBoxContainer.new()
	vbox.add_child(header)
	_title = Label.new()
	_title.text = "Túi đồ"
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title)
	_count_label = Label.new()
	header.add_child(_count_label)
	_btn_close = _make_button("✕")
	_btn_close.pressed.connect(close)
	header.add_child(_btn_close)

	_grid = GridContainer.new()
	_grid.columns = ItemDefs.columns
	vbox.add_child(_grid)
	for i in inventory.slots.size():
		var v := SlotView.new()
		v.index = i
		v.tapped.connect(_on_slot_tapped)
		_grid.add_child(v)
		_views.append(v)

	var sep := HSeparator.new()
	vbox.add_child(sep)
	_detail_name = Label.new()
	vbox.add_child(_detail_name)
	_detail_desc = Label.new()
	_detail_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_desc.custom_minimum_size.y = 1.0
	vbox.add_child(_detail_desc)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(row)
	_btn_drop1 = _make_button("Vứt 1")
	_btn_drop1.pressed.connect(func(): _drop(1))
	row.add_child(_btn_drop1)
	_btn_drop_all = _make_button("Vứt hết")
	_btn_drop_all.pressed.connect(func(): _drop(-1))
	row.add_child(_btn_drop_all)
	_btn_sort = _make_button("Sắp xếp")
	_btn_sort.pressed.connect(func(): inventory.sort_slots())
	row.add_child(_btn_sort)


func _make_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE # không cướp phím của người chơi
	var states := {"normal": Color(1.0, 0.93, 0.72, 0.22), "hover": Color(1.0, 0.93, 0.72, 0.34),
		"pressed": Color(1.0, 0.93, 0.72, 0.50), "disabled": Color(1.0, 0.93, 0.72, 0.08)}
	for state in states:
		var sb := StyleBoxFlat.new()
		sb.bg_color = states[state]
		sb.border_color = BORDER
		sb.set_border_width_all(3)
		sb.set_corner_radius_all(14)
		sb.set_content_margin_all(10)
		sb.anti_aliasing = true
		b.add_theme_stylebox_override(state, sb)
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", TEXT)
	b.add_theme_color_override("font_pressed_color", TEXT)
	b.add_theme_color_override("font_disabled_color", TEXT_DIM)
	return b


func _font(h_ratio: float) -> int:
	return maxi(10, roundi(get_viewport_rect().size.y * h_ratio))


func _layout() -> void:
	if _bag == null:
		return
	var vp := get_viewport_rect().size
	var d := vp.y * BAG_SIZE_H
	_bag.size = Vector2(d, d)
	_bag.position = Vector2(vp.x - 16.0 - d, MINIMAP_BOTTOM + 14.0)
	_toasts.custom_minimum_size.x = vp.x * 0.5
	_toasts.position = Vector2(vp.x * 0.25, vp.y * 0.17)

	var slot := roundi(vp.y * SLOT_H)
	var gap := maxi(4, roundi(vp.y * 0.012))
	_grid.add_theme_constant_override("h_separation", gap)
	_grid.add_theme_constant_override("v_separation", gap)
	for v: Control in _views:
		v.custom_minimum_size = Vector2(slot, slot)
	var fs_title := _font(0.046)
	var fs_text := _font(0.032)
	var btn_h := vp.y * 0.075
	for l: Label in [_title, _count_label]:
		l.add_theme_font_size_override("font_size", fs_title)
		l.add_theme_color_override("font_color", TEXT)
	_count_label.add_theme_font_size_override("font_size", fs_text)
	_count_label.add_theme_color_override("font_color", TEXT_DIM)
	_detail_name.add_theme_font_size_override("font_size", _font(0.038))
	_detail_name.add_theme_color_override("font_color", SLOT_SELECTED)
	_detail_desc.add_theme_font_size_override("font_size", fs_text)
	_detail_desc.add_theme_color_override("font_color", TEXT)
	_detail_desc.custom_minimum_size = Vector2(slot * ItemDefs.columns + gap * (ItemDefs.columns - 1), vp.y * 0.085)
	for b: Button in [_btn_close, _btn_drop1, _btn_drop_all, _btn_sort]:
		b.add_theme_font_size_override("font_size", fs_text)
		b.custom_minimum_size = Vector2(btn_h * (1.0 if b == _btn_close else 2.0), btn_h)
		for state in ["normal", "hover", "pressed", "disabled"]: # cùng tỉ lệ bo góc / viền với các nút trên màn hình
			var sb := b.get_theme_stylebox(state) as StyleBoxFlat
			if sb != null:
				sb.set_corner_radius_all(roundi(btn_h * UiStyle.RADIUS))
				sb.set_border_width_all(maxi(2, roundi(btn_h * UiStyle.BORDER_WIDTH)))
	_panel.reset_size()
	_panel.position = ((vp - _panel.size) * 0.5).floor()


func _refresh() -> void:
	if _views.is_empty():
		return
	for i in _views.size():
		var v: SlotView = _views[i]
		v.slot = inventory.slots[i]
		v.selected = (i == _selected)
		v.queue_redraw()
	_count_label.text = "  %d/%d ô" % [inventory.used_slots(), inventory.slots.size()]
	var has_sel: bool = _selected >= 0 and not (inventory.slots[_selected] as Dictionary).is_empty()
	if has_sel:
		var s: Dictionary = inventory.slots[_selected]
		_detail_name.text = "%s  x%d" % [ItemDefs.item_name(s["id"]), int(s["count"])]
		_detail_desc.text = str(ItemDefs.get_item(s["id"]).get("desc", ""))
	else:
		_detail_name.text = "Chạm vào một ô để xem chi tiết"
		_detail_desc.text = "Chạm tiếp một ô khác để chuyển / gộp vật phẩm."
	_btn_drop1.disabled = not has_sel
	_btn_drop_all.disabled = not has_sel


func _on_slot_tapped(index: int) -> void:
	var from_sel: bool = _selected >= 0 and _selected != index and not (inventory.slots[_selected] as Dictionary).is_empty()
	if from_sel:
		inventory.move_slot(_selected, index)
	_selected = index
	_refresh()


func _drop(amount: int) -> void:
	if _selected < 0 or (inventory.slots[_selected] as Dictionary).is_empty():
		return
	var n: int = int(inventory.slots[_selected]["count"]) if amount < 0 else amount
	inventory.remove_at(_selected, n)


func _on_item_added(id: String, amount: int) -> void:
	toast("+%d %s" % [amount, ItemDefs.item_name(id)])


func _on_dim_input(event: InputEvent) -> void:
	if (event is InputEventMouseButton and event.pressed) or (event is InputEventScreenTouch and event.pressed):
		close()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("inventory"):
		toggle()
		get_viewport().set_input_as_handled()
	elif is_open() and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func _ensure_action(action: StringName, keycode: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode
	if not InputMap.action_has_event(action, ev):
		InputMap.action_add_event(action, ev)
