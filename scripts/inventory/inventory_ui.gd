extends Control
## Giao diện túi đồ: nút túi (dưới minimap), bảng lưới ô, chi tiết vật phẩm, thông báo +N khi nhận đồ.
##  - Chạm một ô = chọn ô đó và xem thông tin (chọn ô khác thì xem ô khác, không đổi chỗ).
##  - Kéo vật phẩm: thả lên ô khác = chuyển / gộp; thả ra ngoài bảng = vứt ra map (signal item_dropped).
##  - Nút "Tách": hiện thanh trượt chọn số lượng rồi tách khỏi chồng sang ô trống đầu tiên.
## Gắn vào một CanvasLayer (để không bị ban đêm nhuộm tối). Gọi setup(inventory) một lần.
## Kích thước tính bằng px: ô 48 chứa icon 32 (ItemDefs.ICON_SIZE).

const ItemDefs := preload("res://scripts/inventory/item_defs.gd")
const ItemIcon := preload("res://scripts/inventory/item_icon.gd")
const HudButton := preload("res://scripts/ui/hud_button.gd")

## Vứt vật phẩm ra map (kéo ra ngoài bảng).
signal item_dropped(id: String, amount: int)

const MINIMAP_BOTTOM := 236.0   # minimap chiếm từ y = 16 tới 236 (px) ở góc trên phải
const BAG_SIZE_H := 0.115       # nút túi / chiều cao viewport
const SLOT := 48.0              # cạnh một ô
const GAP := 4                  # khoảng hở giữa các ô
const BTN_H := 40.0
const FS_TITLE := 26
const FS_NAME := 20
const FS_TEXT := 17
const PANEL_BG := Color(0.20, 0.14, 0.10, 0.95)
const PANEL_BORDER := Color(0.62, 0.45, 0.30, 1.0)
const TEXT := Color(1.0, 0.95, 0.82)
const TEXT_DIM := Color(0.85, 0.78, 0.62)

var inventory

var _bag: Control
var _overlay: Control
var _panel: PanelContainer
var _count_label: Label
var _detail_name: Label
var _detail_desc: Label
var _row_main: HBoxContainer    # hàng nút Tách / Sắp xếp
var _row_split: HBoxContainer   # hàng thanh trượt chọn số lượng tách (thay thế hàng trên khi đang tách)
var _btn_split: Button
var _split_slider: HSlider
var _split_label: Label
var _toasts: VBoxContainer
var _ghost: Control             # icon đi theo ngón tay khi đang kéo
var _ghost_id := ""
var _ghost_pos := Vector2.ZERO
var _views: Array = []
var _selected := -1


# ---------------------------------------------------------------- một ô túi
class SlotView extends Control:
	const ItemDefs := preload("res://scripts/inventory/item_defs.gd")
	const ItemIcon := preload("res://scripts/inventory/item_icon.gd")
	const HudButton := preload("res://scripts/ui/hud_button.gd")
	const BG := Color(1.0, 0.93, 0.72, 0.13)
	const BORDER := Color(0.62, 0.45, 0.30, 0.70)
	const SELECTED := Color(1.0, 0.85, 0.40, 1.0)
	const DRAG_SLOP := 8.0      # kéo quá mức này (px) mới tính là kéo, chưa tới thì là chạm

	signal tapped(index: int)
	signal drag_moved(index: int, global_pos: Vector2)
	signal drag_ended(index: int, global_pos: Vector2)

	var index := 0
	var slot: Dictionary = {}
	var selected := false
	var _pointer := -1          # -1 rảnh, -2 chuột, >= 0 chỉ số ngón tay
	var _press := Vector2.ZERO
	var _dragging := false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

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
		elif click != null and click.button_index == MOUSE_BUTTON_LEFT:
			if click.pressed and _pointer == -1:
				_begin(-2, click.position)
			elif not click.pressed and _pointer == -2:
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
		_press = pos
		_dragging = false

	func _move(pos: Vector2) -> void:
		if not _dragging and not slot.is_empty() and pos.distance_to(_press) > DRAG_SLOP:
			_dragging = true
		if _dragging:
			drag_moved.emit(index, global_position + pos)

	func _end(pos: Vector2) -> void:
		var was_dragging := _dragging
		_pointer = -1
		_dragging = false
		if was_dragging:
			drag_ended.emit(index, global_position + pos)
		else:
			tapped.emit(index)

	func _draw() -> void:
		HudButton.draw_frame(self, Rect2(Vector2.ZERO, size), BG, SELECTED if selected else BORDER, 8.0, 3.0 if selected else 2.0)
		if slot.is_empty():
			return
		var side := ItemDefs.ICON_SIZE
		ItemIcon.draw(self, str(slot["id"]), Rect2((size - Vector2(side, side)) * 0.5, Vector2(side, side)))
		var count := int(slot["count"])
		if count > 1:
			var font := ThemeDB.fallback_font
			var text := str(count)
			var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
			var pos := Vector2(size.x - w - 4.0, size.y - 5.0)
			draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 5, Color(0.1, 0.06, 0.04))
			draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1.0, 0.97, 0.88))


# ---------------------------------------------------------------- dựng giao diện
func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE # đóng bảng thì không chặn chạm ở phần còn lại của màn hình
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST # icon pixel art
	get_viewport().size_changed.connect(_layout)


func setup(inv) -> void:
	inventory = inv
	inventory.changed.connect(_refresh)
	inventory.item_added.connect(_on_item_added)
	_build()
	_layout()
	_refresh()


func bag_button() -> Control:
	return _bag


func is_open() -> bool:
	return _overlay != null and _overlay.visible


func toggle() -> void:
	if is_open():
		close()
	else:
		open()


func open() -> void:
	_selected = -1
	_set_splitting(false)
	_overlay.visible = true
	_layout()
	_refresh()


func close() -> void:
	_overlay.visible = false


## Thông báo nổi ngắn (nhận đồ, túi đầy, thiếu công cụ...).
func toast(text: String, color: Color = TEXT) -> void:
	if _toasts == null:
		return
	var l := _make_label(text, 24, color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
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
	var bag := HudButton.new()
	bag.icon_kind = "bag"
	bag.auto_layout = false # vị trí đặt trong _layout (dưới minimap)
	bag.tapped.connect(toggle)
	_bag = bag
	add_child(_bag)

	_toasts = VBoxContainer.new()
	_toasts.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	var title := _make_label("Túi đồ", FS_TITLE, TEXT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_count_label = _make_label("", FS_TEXT, TEXT_DIM)
	header.add_child(_count_label)
	var close_btn := _make_button("✕", BTN_H)
	close_btn.pressed.connect(close)
	header.add_child(close_btn)

	var grid := GridContainer.new()
	grid.columns = ItemDefs.COLUMNS
	grid.add_theme_constant_override("h_separation", GAP)
	grid.add_theme_constant_override("v_separation", GAP)
	vbox.add_child(grid)
	for i in inventory.slots.size():
		var v := SlotView.new()
		v.index = i
		v.custom_minimum_size = Vector2(SLOT, SLOT)
		v.tapped.connect(_on_slot_tapped)
		v.drag_moved.connect(_on_drag_moved)
		v.drag_ended.connect(_on_drag_ended)
		grid.add_child(v)
		_views.append(v)
	var grid_w := ItemDefs.COLUMNS * SLOT + (ItemDefs.COLUMNS - 1) * GAP

	vbox.add_child(HSeparator.new())
	_detail_name = _make_label("", FS_NAME, SlotView.SELECTED)
	vbox.add_child(_detail_name)
	_detail_desc = _make_label("", FS_TEXT, TEXT)
	_detail_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_desc.custom_minimum_size = Vector2(grid_w, 52.0)
	vbox.add_child(_detail_desc)

	_row_main = HBoxContainer.new()
	_row_main.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(_row_main)
	_btn_split = _make_button("Tách", BTN_H * 2.0)
	_btn_split.pressed.connect(_set_splitting.bind(true))
	_row_main.add_child(_btn_split)
	var btn_sort := _make_button("Sắp xếp", BTN_H * 2.0)
	btn_sort.pressed.connect(_sort)
	_row_main.add_child(btn_sort)

	_row_split = HBoxContainer.new() # cùng chiều cao với _row_main nên bảng không đổi kích thước khi chuyển qua lại
	_row_split.visible = false
	vbox.add_child(_row_split)
	_row_split.add_child(_make_label("Tách", FS_TEXT, TEXT))
	_split_slider = HSlider.new()
	_split_slider.min_value = 1
	_split_slider.step = 1
	_split_slider.focus_mode = Control.FOCUS_NONE
	_split_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_split_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_split_slider.value_changed.connect(_on_split_changed)
	_row_split.add_child(_split_slider)
	_split_label = _make_label("1", FS_NAME, SlotView.SELECTED)
	_split_label.custom_minimum_size.x = 40.0
	_split_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_row_split.add_child(_split_label)
	var btn_ok := _make_button("OK", BTN_H * 1.5)
	btn_ok.pressed.connect(_confirm_split)
	_row_split.add_child(btn_ok)
	var btn_cancel := _make_button("Huỷ", BTN_H * 1.5)
	btn_cancel.pressed.connect(_set_splitting.bind(false))
	_row_split.add_child(btn_cancel)

	_ghost = Control.new() # nằm trên cùng để icon đang kéo không bị bảng che
	_ghost.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ghost.draw.connect(_draw_ghost)
	_overlay.add_child(_ghost)


func _make_label(text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	return l


func _make_button(text: String, min_w: float) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE # không cướp phím của người chơi
	b.custom_minimum_size = Vector2(min_w, BTN_H)
	b.add_theme_font_size_override("font_size", FS_TEXT)
	var fills := {"normal": 0.22, "hover": 0.34, "pressed": 0.50, "disabled": 0.08}
	for state in fills:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(1.0, 0.93, 0.72, float(fills[state]))
		sb.border_color = HudButton.BORDER
		sb.set_border_width_all(maxi(2, roundi(BTN_H * HudButton.BORDER_WIDTH)))
		sb.set_corner_radius_all(roundi(BTN_H * HudButton.RADIUS)) # cùng tỉ lệ bo góc với các nút khác
		sb.set_content_margin_all(8)
		sb.anti_aliasing = true
		b.add_theme_stylebox_override(state, sb)
	for color_name in ["font_color", "font_hover_color", "font_pressed_color"]:
		b.add_theme_color_override(color_name, TEXT)
	b.add_theme_color_override("font_disabled_color", TEXT_DIM)
	return b


func _layout() -> void:
	if _bag == null:
		return
	var vp := get_viewport_rect().size
	var d := vp.y * BAG_SIZE_H
	_bag.size = Vector2(d, d)
	_bag.position = Vector2(vp.x - 16.0 - d, MINIMAP_BOTTOM + 14.0)
	_toasts.custom_minimum_size.x = vp.x * 0.5
	_toasts.position = Vector2(vp.x * 0.25, vp.y * 0.17)
	_panel.reset_size()
	_panel.position = ((vp - _panel.size) * 0.5).floor()


# ---------------------------------------------------------------- cập nhật

func _refresh() -> void:
	if _views.is_empty():
		return
	for i in _views.size():
		var v: SlotView = _views[i]
		v.slot = inventory.slots[i]
		v.selected = (i == _selected)
		v.queue_redraw()
	_count_label.text = "  %d/%d ô" % [inventory.used_slots(), inventory.slots.size()]

	var s: Dictionary = {}
	if _selected >= 0:
		s = inventory.slots[_selected]
	if s.is_empty():
		_detail_name.text = "Chạm vào một ô để xem chi tiết"
		_detail_desc.text = "Kéo vật phẩm sang ô khác để chuyển, kéo ra ngoài bảng để vứt."
	else:
		_detail_name.text = "%s  x%d" % [ItemDefs.item_name(str(s["id"])), int(s["count"])]
		_detail_desc.text = str(ItemDefs.get_item(str(s["id"])).get("desc", ""))
	var can_split := not s.is_empty() and int(s["count"]) >= 2
	_btn_split.disabled = not can_split
	if can_split:
		_split_slider.max_value = int(s["count"]) - 1
	elif _row_split.visible:
		_set_splitting(false)


## Bật / tắt hàng thanh trượt chọn số lượng tách.
func _set_splitting(on: bool) -> void:
	if _row_split == null:
		return
	var enable := false
	if on and _selected >= 0:
		var count := int((inventory.slots[_selected] as Dictionary).get("count", 0))
		if count >= 2:
			enable = true
			_split_slider.max_value = count - 1
			_split_slider.value = maxi(1, int(count * 0.5))
			_split_label.text = str(int(_split_slider.value))
	_row_split.visible = enable
	_row_main.visible = not enable


func _on_split_changed(value: float) -> void:
	_split_label.text = str(int(value))


func _confirm_split() -> void:
	if inventory.split(_selected, int(_split_slider.value)) < 0:
		toast("Không còn ô trống")
	_set_splitting(false)


func _sort() -> void:
	inventory.sort_slots()


func _on_item_added(id: String, amount: int) -> void:
	toast("+%d %s" % [amount, ItemDefs.item_name(id)])


func _on_slot_tapped(index: int) -> void:
	_selected = index
	_set_splitting(false)
	_refresh()


func _on_dim_input(event: InputEvent) -> void:
	if (event is InputEventMouseButton or event is InputEventScreenTouch) and event.pressed:
		close()


# ---------------------------------------------------------------- kéo thả

func _on_drag_moved(index: int, pos: Vector2) -> void:
	_ghost_id = str((inventory.slots[index] as Dictionary).get("id", ""))
	_ghost_pos = pos
	_ghost.queue_redraw()


func _on_drag_ended(index: int, pos: Vector2) -> void:
	_ghost_id = ""
	_ghost.queue_redraw()
	var s: Dictionary = inventory.slots[index]
	if s.is_empty():
		return
	var target := -1
	for v: SlotView in _views:
		if v.get_global_rect().has_point(pos):
			target = v.index
			break
	if target >= 0:
		if target != index:
			inventory.move_slot(index, target)
			_selected = target
	elif not _panel.get_global_rect().has_point(pos): # thả ra ngoài bảng = vứt ra map
		var id := str(s["id"])
		var amount := int(s["count"])
		inventory.remove_at(index, amount)
		item_dropped.emit(id, amount)
	_set_splitting(false)
	_refresh()


func _draw_ghost() -> void:
	if _ghost_id == "":
		return
	var side := ItemDefs.ICON_SIZE
	ItemIcon.draw(_ghost, _ghost_id, Rect2(_ghost_pos - Vector2(side, side) * 0.5, Vector2(side, side)))


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("inventory"):
		toggle()
		get_viewport().set_input_as_handled()
	elif is_open() and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
