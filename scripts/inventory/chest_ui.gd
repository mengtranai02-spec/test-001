extends Node
## Giao diện rương: bảng lưới ô nằm bên trái bảng túi đồ, cùng kiểu với túi đồ.
##  - Kéo vật phẩm từ rương sang bảng túi (hoặc ngược lại) = chuyển cả chồng.
##  - Chạm một ô rương = chọn; "Lấy" chuyển chồng đó sang túi, "Lấy hết" chuyển mọi thứ nhét được.
##  - Trong túi: chọn một ô rồi bấm "Cất" (nút này do inventory_ui hiện khi rương đang mở).
##  - Kéo trong phạm vi bảng rương để đổi chỗ / gộp chồng.
## Gọi setup(túi, inventory_ui) một lần; building_system gọi open_chest(kho, tên).
## Bảng được tạo bằng code và thêm vào ModalOverlay, không cần sửa ui.tscn.
## Mở rương = mở bảng túi (inventory_ui.open) nên game vẫn khoá điều khiển giống khi mở túi đồ.

const Inventory := preload("res://scripts/inventory/inventory.gd")
const ItemDefs := preload("res://scripts/inventory/item_defs.gd")
const ItemIcon := preload("res://scripts/inventory/item_icon.gd")
const InventoryUI := preload("res://scripts/inventory/inventory_ui.gd")

## Rương đã đóng (do bấm ✕, phím E / Esc hoặc đóng bảng túi).
signal closed

const PANEL_GAP := 16.0   # khoảng cách giữa bảng rương và bảng túi

var _bag: Inventory
var _inventory_ui: Control
var _storage: Inventory
var _panel: PanelContainer
var _title: Label
var _count_label: Label
var _grid: GridContainer
var _detail_name: Label
var _detail_desc: Label
var _status: Label
var _btn_take: Button
var _btn_take_all: Button
var _ghost: Control            # icon đi theo ngón tay khi kéo từ rương
var _ghost_id := ""
var _ghost_pos := Vector2.ZERO
var _views: Array = []
var _selected := -1
var _status_tween: Tween


func setup(bag: Inventory, inventory_ui: Control) -> void:
	_bag = bag
	_inventory_ui = inventory_ui
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	_inventory_ui.closed.connect(_on_inventory_closed)
	get_viewport().size_changed.connect(_layout)


func is_open() -> bool:
	return _storage != null


## Mở bảng rương cho kho storage (một Inventory riêng của từng rương).
func open_chest(storage: Inventory, title: String) -> void:
	if _storage != null:
		return
	_storage = storage
	_storage.changed.connect(_refresh)
	_title.text = title
	_rebuild_grid()
	_selected = -1
	_status.text = " "
	_inventory_ui.set_storage_target(self) # trước open() để nút "Cất" hiện ngay
	if not _inventory_ui.is_open():
		_inventory_ui.open()
	_panel.visible = true
	_layout()
	_refresh()


## Đóng rương (đóng luôn bảng túi; tín hiệu closed của túi sẽ dọn phần còn lại).
func close() -> void:
	if _storage == null:
		return
	if _inventory_ui.is_open():
		_inventory_ui.close()
	else:
		_on_inventory_closed()


# ---- hai hàm inventory_ui gọi (duck typing) ----

func contains_point(global_pos: Vector2) -> bool:
	return _panel != null and _panel.visible and _panel.get_global_rect().has_point(global_pos)


## Cất cả chồng ở ô index của túi vào rương.
func store_from_bag(index: int) -> void:
	if _storage == null:
		return
	if _transfer(_bag, index, _storage) > 0:
		_flash("Rương đã đầy")


# ---------------------------------------------------------------- dựng giao diện

func _build() -> void:
	var overlay: Control = _inventory_ui.modal_overlay()
	_panel = PanelContainer.new()
	_panel.visible = false
	_panel.z_index = 1
	_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var ps := StyleBoxFlat.new()
	ps.bg_color = InventoryUI.PANEL_BG
	ps.border_color = InventoryUI.PANEL_BORDER
	ps.set_border_width_all(4)
	ps.set_corner_radius_all(22)
	ps.set_content_margin_all(18)
	ps.anti_aliasing = true
	_panel.add_theme_stylebox_override("panel", ps)
	overlay.add_child(_panel)

	var vbox := VBoxContainer.new()
	_panel.add_child(vbox)

	var header := HBoxContainer.new()
	vbox.add_child(header)
	_title = InventoryUI.make_label("Rương", InventoryUI.FS_TITLE, InventoryUI.TEXT)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title)
	_count_label = InventoryUI.make_label("", InventoryUI.FS_TEXT, InventoryUI.TEXT_DIM)
	header.add_child(_count_label)
	var close_btn := InventoryUI.make_button("✕", InventoryUI.BTN_H)
	close_btn.pressed.connect(close)
	header.add_child(close_btn)

	_grid = GridContainer.new()
	_grid.columns = ItemDefs.COLUMNS
	_grid.add_theme_constant_override("h_separation", InventoryUI.GAP)
	_grid.add_theme_constant_override("v_separation", InventoryUI.GAP)
	vbox.add_child(_grid)
	var grid_w := ItemDefs.COLUMNS * InventoryUI.SLOT + (ItemDefs.COLUMNS - 1) * InventoryUI.GAP

	vbox.add_child(HSeparator.new())
	_detail_name = InventoryUI.make_label("", InventoryUI.FS_NAME, InventoryUI.SlotView.SELECTED)
	vbox.add_child(_detail_name)
	_detail_desc = InventoryUI.make_label("", InventoryUI.FS_TEXT, InventoryUI.TEXT)
	_detail_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_desc.custom_minimum_size = Vector2(grid_w, 52.0)
	vbox.add_child(_detail_desc)
	_status = InventoryUI.make_label(" ", InventoryUI.FS_TEXT, Color(1.0, 0.55, 0.45))
	vbox.add_child(_status)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(row)
	_btn_take = InventoryUI.make_button("Lấy", InventoryUI.BTN_H * 2.0)
	_btn_take.pressed.connect(_take_selected)
	row.add_child(_btn_take)
	_btn_take_all = InventoryUI.make_button("Lấy hết", InventoryUI.BTN_H * 2.0)
	_btn_take_all.pressed.connect(_take_all)
	row.add_child(_btn_take_all)

	_ghost = Control.new() # nằm trên cùng để icon đang kéo không bị bảng che
	_ghost.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ghost.z_index = 5
	_ghost.draw.connect(_draw_ghost)
	overlay.add_child(_ghost)


## Dựng lại lưới ô khi số ô của kho khác lần trước (mỗi loại rương có thể có số ô riêng).
func _rebuild_grid() -> void:
	if _views.size() == _storage.slots.size():
		return
	for v: Control in _views:
		_grid.remove_child(v)
		v.queue_free()
	_views.clear()
	for i in _storage.slots.size():
		var v := InventoryUI.SlotView.new()
		v.index = i
		v.custom_minimum_size = Vector2(InventoryUI.SLOT, InventoryUI.SLOT)
		v.tapped.connect(_on_slot_tapped)
		v.drag_moved.connect(_on_drag_moved)
		v.drag_ended.connect(_on_drag_ended)
		_grid.add_child(v)
		_views.append(v)


## Đặt bảng rương bên trái bảng túi, cả cụm nằm giữa màn hình.
func _layout() -> void:
	if _panel == null or not _panel.visible:
		return
	_panel.reset_size()
	_inventory_ui.set_side_offset((_panel.size.x + PANEL_GAP) * 0.5)
	var inv_rect: Rect2 = _inventory_ui.panel_global_rect()
	_panel.position = Vector2(
		inv_rect.position.x - PANEL_GAP - _panel.size.x,
		inv_rect.position.y + (inv_rect.size.y - _panel.size.y) * 0.5).floor()


# ---------------------------------------------------------------- cập nhật

func _refresh() -> void:
	if _storage == null or _views.is_empty():
		return
	for i in _views.size():
		var v: InventoryUI.SlotView = _views[i]
		v.slot = _storage.slots[i]
		v.selected = (i == _selected)
		v.queue_redraw()
	_count_label.text = "  %d/%d ô" % [_storage.used_slots(), _storage.slots.size()]

	var s: Dictionary = {}
	if _selected >= 0:
		s = _storage.slots[_selected]
	if s.is_empty():
		_detail_name.text = "Chạm vào một ô để xem chi tiết"
		_detail_desc.text = "Kéo vật phẩm giữa rương và túi đồ để chuyển."
	else:
		_detail_name.text = "%s  x%d" % [ItemDefs.item_name(str(s["id"])), int(s["count"])]
		_detail_desc.text = str(ItemDefs.get_item(str(s["id"])).get("desc", ""))
	_btn_take.disabled = s.is_empty()
	_btn_take_all.disabled = _storage.used_slots() == 0


func _flash(text: String) -> void:
	_status.text = text
	_status.modulate.a = 1.0
	if _status_tween != null and _status_tween.is_valid():
		_status_tween.kill()
	_status_tween = _status.create_tween()
	_status_tween.tween_interval(1.4)
	_status_tween.tween_property(_status, "modulate:a", 0.0, 0.4)


func _on_inventory_closed() -> void:
	if _storage == null:
		return
	_storage.changed.disconnect(_refresh)
	_storage = null
	_panel.visible = false
	_ghost_id = ""
	_ghost.queue_redraw()
	_inventory_ui.set_storage_target(null)
	_inventory_ui.set_side_offset(0.0)
	closed.emit()


# ---------------------------------------------------------------- chuyển đồ

## Chuyển cả chồng ở ô index của from sang to (tự xếp vào chồng cùng loại / ô trống).
## Trả về số lượng KHÔNG chuyển được vì kho đích đã đầy (0 = chuyển hết).
func _transfer(from: Inventory, index: int, to: Inventory) -> int:
	if index < 0 or index >= from.slots.size():
		return 0
	var s: Dictionary = from.slots[index]
	if s.is_empty():
		return 0
	var amount := int(s["count"])
	var leftover := to.add(str(s["id"]), amount)
	var moved := amount - leftover
	if moved > 0:
		from.remove_at(index, moved)
	return leftover


func _take_selected() -> void:
	if _storage == null or _selected < 0:
		return
	if _transfer(_storage, _selected, _bag) > 0:
		_flash("Túi đã đầy")


func _take_all() -> void:
	if _storage == null:
		return
	var failed := false
	for i in _storage.slots.size():
		if _transfer(_storage, i, _bag) > 0:
			failed = true
	if failed:
		_flash("Túi đã đầy, còn đồ chưa lấy hết")


func _on_slot_tapped(index: int) -> void:
	_selected = index
	_refresh()


# ---------------------------------------------------------------- kéo thả

func _on_drag_moved(index: int, pos: Vector2) -> void:
	if _storage == null:
		return
	_ghost_id = str((_storage.slots[index] as Dictionary).get("id", ""))
	_ghost_pos = pos
	_ghost.queue_redraw()


func _on_drag_ended(index: int, pos: Vector2) -> void:
	_ghost_id = ""
	_ghost.queue_redraw()
	if _storage == null or (_storage.slots[index] as Dictionary).is_empty():
		return
	if _inventory_ui.panel_global_rect().has_point(pos): # thả lên bảng túi = lấy ra
		if _transfer(_storage, index, _bag) > 0:
			_flash("Túi đã đầy")
	else:
		var target := -1
		for v: InventoryUI.SlotView in _views:
			if v.get_global_rect().has_point(pos):
				target = v.index
				break
		if target >= 0 and target != index:
			_storage.move_slot(index, target)
			_selected = target
	_refresh()


func _draw_ghost() -> void:
	if _ghost_id == "":
		return
	var side := (InventoryUI.SLOT - 8.0) * 1.2 # đang kéo: to hơn ô một chút cho cảm giác nhấc lên
	ItemIcon.draw(_ghost, _ghost_id, Rect2(_ghost_pos - Vector2(side, side) * 0.5, Vector2(side, side)))
