extends Node2D

const ObjectDefs := preload("res://scripts/world/object_defs.gd")
const ChestOpener := preload("chest_opener.gd")
const Inventory := preload("res://scripts/inventory/inventory.gd")
const InventoryUI := preload("res://scripts/inventory/inventory_ui.gd")
const BUILDING_FILES := [
	"res://data/buildings/spirit_tower.json",
	"res://data/buildings/wooden_chest.json",
	"res://data/buildings/campfire.json",
]
const TILE_W := 128.0
const TILE_H := 64.0
const SAMPLE_STEP_TILES := 0.15
const CHEST_REACH := 170.0      # người chơi cách rương tối đa (px, đã bù độ dẹt iso) thì hiện nút "Mở rương"
const OPEN_UI_DELAY := 0.4      # chờ hiệu ứng mở nắp chạy xong rồi mới hiện bảng (bảng có lớp phủ tối)
const PROMPT_INTERVAL := 0.12   # giây giữa các lần tìm rương gần nhất

var terrain_map: Node2D
var hud_controls: Control
var _panel: PanelContainer
var _buildings: Array[Dictionary] = []
var _selected := -1
var _preview: Sprite2D
var _preview_pos := Vector2.ZERO
var _preview_valid := false
var _placed: Array[Dictionary] = []

# --- rương: kho chứa riêng từng cái, nút "Mở rương" khi đứng gần ---
var _chest_ui: Node
var _game_ui: Node              # UI (CanvasLayer): hỏi gameplay_input_blocked()
var _player: Node2D
var _prompt: Button
var _prompt_index := -1         # rương gần nhất đang hiện nút, -1 = không có
var _prompt_timer := 0.0
var _open_index := -1           # rương đang mở bảng
var _busy := false              # đang chạy hiệu ứng mở nắp, chưa hiện bảng


func setup(map: Node2D, controls: Control) -> void:
	terrain_map = map
	hud_controls = controls
	_load_definitions()
	_build_menu()
	_preview = Sprite2D.new()
	_preview.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_preview.modulate = Color(0.5, 1.0, 0.55, 0.62)
	_preview.z_index = 20
	_preview.visible = false
	add_child(_preview)


## Nối với bảng rương. Gọi một lần sau khi túi đồ đã dựng (xem world.gd).
func setup_storage(chest_ui: Node, game_ui: Node) -> void:
	_chest_ui = chest_ui
	_game_ui = game_ui
	_chest_ui.connect("closed", _on_chest_closed)
	_prompt = InventoryUI.make_button("Mở rương", 150.0)
	_prompt.visible = false
	_prompt.pressed.connect(_on_prompt_pressed)
	hud_controls.add_child(_prompt)


func _load_definitions() -> void:
	_buildings.clear()
	for path in BUILDING_FILES:
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not parsed is Dictionary:
			push_error("Không đọc được dữ liệu công trình: %s" % path)
			continue
		var def: Dictionary = parsed
		var tile_size := Vector2(float(def.get("grid_size", [1, 1])[0]), float(def.get("grid_size", [1, 1])[1]))
		var trigger_size: Array = def.get("trigger_size", [0.8, 0.8])
		# Trigger là hình thoi có tâm tại điểm y-sort: trục ngang/dọc theo màn hình iso.
		def["grid_size"] = tile_size
		def["trigger_half"] = Vector2(TILE_W * float(trigger_size[0]) * 0.5, TILE_H * float(trigger_size[1]) * 0.5)
		def["texture_resource"] = load(str(def.get("texture", ""))) as Texture2D
		# Công trình có "texture_open" trong JSON (vd: rương) thì mở được.
		var open_path := str(def.get("texture_open", ""))
		if open_path != "":
			def["texture_open_resource"] = load(open_path) as Texture2D
		_buildings.append(def)


func _build_menu() -> void:
	_panel = hud_controls.get_node("BuildMenu") as PanelContainer
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	_panel.add_child(column)
	var title := Label.new()
	title.text = "Công trình"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)
	for i in _buildings.size():
		var def: Dictionary = _buildings[i]
		var row := HBoxContainer.new()
		column.add_child(row)
		var button := Button.new()
		button.text = str(def.get("name", def.get("id", "Building")))
		button.custom_minimum_size = Vector2(210, 54)
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(_select_building.bind(i))
		row.add_child(button)
		var image := TextureRect.new()
		image.texture = def.get("texture_resource") as Texture2D
		image.custom_minimum_size = Vector2(48, 48)
		image.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(image)
	var close := Button.new()
	close.text = "Đóng"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(_close_menu)
	column.add_child(close)


func toggle_menu() -> void:
	_panel.visible = not _panel.visible
	if _panel.visible:
		_selected = -1
		_preview.visible = false


func close_menu() -> void:
	_close_menu()


func _select_building(index: int) -> void:
	_selected = index
	_panel.visible = false
	_preview.texture = _buildings[index].get("texture_resource") as Texture2D
	_preview.offset = Vector2(0.0, -_preview.texture.get_size().y * 0.25)
	_preview.visible = true


func _close_menu() -> void:
	_panel.visible = false
	_selected = -1
	_preview.visible = false
	queue_redraw() # xoá viền footprint của bản xem trước


func _unhandled_input(event: InputEvent) -> void:
	if _selected < 0:
		# Phím tương tác (Q) mở rương đang hiện nút.
		if _prompt != null and _prompt.visible and _prompt_index >= 0 and event.is_action_pressed("interact"):
			_open_chest(_prompt_index)
			get_viewport().set_input_as_handled()
		return
	var screen_pos := Vector2.ZERO
	var click := event as InputEventMouseButton
	var touch := event as InputEventScreenTouch
	if click != null and click.button_index == MOUSE_BUTTON_LEFT and click.pressed:
		screen_pos = click.position
	elif touch != null and touch.pressed:
		screen_pos = touch.position
	else:
		return
	var world_pos := get_viewport().get_canvas_transform().affine_inverse() * screen_pos
	_preview_pos = _snap_to_tile(world_pos)
	if _can_place(_preview_pos, _selected):
		_place(_preview_pos, _selected)
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_update_chest_prompt(delta)
	if _selected < 0 or not _preview.visible:
		return
	_preview_pos = _snap_to_tile(get_global_mouse_position())
	_preview.position = to_local(_preview_pos)
	_preview_valid = _can_place(_preview_pos, _selected)
	_preview.modulate = Color(0.5, 1.0, 0.55, 0.62) if _preview_valid else Color(1.0, 0.35, 0.3, 0.62)
	queue_redraw()


func _draw() -> void:
	if _selected < 0 or not _preview.visible:
		return
	var poly := _trigger_polygon(_preview_pos, _buildings[_selected])
	var local_poly := PackedVector2Array()
	for point in poly:
		local_poly.append(to_local(point))
	var color := Color(0.25, 0.95, 0.35, 0.9) if _preview_valid else Color(1.0, 0.2, 0.15, 0.9)
	local_poly.append(local_poly[0])
	draw_polyline(local_poly, color, 3.0, true)


func _snap_to_tile(world_pos: Vector2) -> Vector2:
	var tile: Vector2 = terrain_map.world_to_tile(world_pos)
	# Tâm ô 1x1 nằm giữa các giao điểm lưới (n + 0.5); footprint 2x2
	# có tâm tại giao điểm nguyên. Canh theo tâm footprint để trigger nằm trong ô.
	var grid_size: Vector2 = _buildings[_selected]["grid_size"]
	var center_x := roundf(tile.x - grid_size.x * 0.5) + grid_size.x * 0.5
	var center_y := roundf(tile.y - grid_size.y * 0.5) + grid_size.y * 0.5
	return terrain_map.tile_to_world(center_x, center_y)


func _trigger_polygon(center: Vector2, def: Dictionary) -> PackedVector2Array:
	var half: Vector2 = def["trigger_half"]
	return PackedVector2Array([
		center + Vector2(-half.x, 0.0), center + Vector2(0.0, -half.y),
		center + Vector2(half.x, 0.0), center + Vector2(0.0, half.y),
	])


func _can_place(world_pos: Vector2, index: int) -> bool:
	var def := _buildings[index]
	var poly := _trigger_polygon(world_pos, def)
	# Quét toàn footprint trong hệ toạ độ ô iso, gồm cả biên để không lọt collider hẹp.
	var tile_center: Vector2 = terrain_map.world_to_tile(world_pos)
	var half: Vector2 = def["trigger_half"]
	var min_x := -half.x / (TILE_W * 0.5)
	var max_x := half.x / (TILE_W * 0.5)
	var min_y := -half.y / (TILE_H * 0.5)
	var max_y := half.y / (TILE_H * 0.5)
	var x := min_x
	while x <= max_x + 0.001:
		var y := min_y
		while y <= max_y + 0.001:
			var sample: Vector2 = terrain_map.tile_to_world(tile_center.x + x, tile_center.y + y)
			if Geometry2D.is_point_in_polygon(sample, poly):
				if not terrain_map.is_land_at(sample) or terrain_map.is_blocked_at(sample):
					return false
			y += SAMPLE_STEP_TILES
		x += SAMPLE_STEP_TILES
	var player := get_tree().get_first_node_in_group("collider_debug")
	if player is Node2D and Geometry2D.is_point_in_polygon(player.global_position, poly):
		return false
	for existing in _placed:
		if not Geometry2D.intersect_polygons(poly, existing["polygon"]).is_empty():
			return false
	return true


func _place(world_pos: Vector2, index: int) -> void:
	var def := _buildings[index]
	var sprite := Sprite2D.new()
	sprite.texture = def.get("texture_resource") as Texture2D
	sprite.centered = true
	sprite.position = get_parent().to_local(world_pos)
	sprite.offset = Vector2(0.0, -sprite.texture.get_size().y * 0.25)
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	get_parent().add_child(sprite)
	var polygon: PackedVector2Array = _trigger_polygon(world_pos, def)
	var collider_enabled := bool(def.get("collider_enabled", true))
	if collider_enabled:
		terrain_map.register_building_collider(_placed.size(), polygon)
		var body := StaticBody2D.new()
		body.name = "%s_Collider" % str(def.get("id", "Building"))
		body.position = get_parent().to_local(world_pos)
		var collision := CollisionPolygon2D.new()
		collision.polygon = PackedVector2Array([Vector2(-float(def["trigger_half"].x), 0), Vector2(0, -float(def["trigger_half"].y)), Vector2(float(def["trigger_half"].x), 0), Vector2(0, float(def["trigger_half"].y))])
		body.add_child(collision)
		get_parent().add_child(body)
	# Công trình có "storage_slots" trong JSON (vd: rương) có kho chứa riêng, dùng lại Inventory của túi đồ.
	var storage_slots := int(def.get("storage_slots", 0))
	_placed.append({
		"position": world_pos,
		"polygon": polygon,
		"node": sprite,
		"collider_enabled": collider_enabled,
		"name": str(def.get("name", def.get("id", "Rương"))),
		"closed_texture": def.get("texture_resource", null),
		"open_texture": def.get("texture_open_resource", null),
		"storage": Inventory.new(storage_slots) if storage_slots > 0 else null,
		"opened_once": false,   # đã phát hiệu ứng mở lần đầu chưa
	})
	_remove_nonblocking_props(world_pos, polygon)
	_selected = -1
	_preview.visible = false
	queue_redraw() # xoá viền footprint của bản xem trước


# ---------------------------------------------------------------- rương

## Rương có kho chứa gần người chơi nhất (trong CHEST_REACH), -1 nếu không có.
func _nearest_chest() -> int:
	var player := _get_player()
	if player == null:
		return -1
	var best := -1
	var best_d := CHEST_REACH * CHEST_REACH
	for i in _placed.size():
		if _placed[i]["storage"] == null:
			continue
		var delta: Vector2 = (_placed[i]["position"] as Vector2) - player.global_position
		delta.y *= 2.0  # bù độ dẹt của hệ iso 2:1
		var d := delta.length_squared()
		if d < best_d:
			best_d = d
			best = i
	return best


func _get_player() -> Node2D:
	if not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("collider_debug") as Node2D
	return _player


## Hiện nút "Mở rương" phía trên rương gần nhất. Tìm rương mỗi PROMPT_INTERVAL giây, chỉ cập nhật vị trí nút mỗi khung hình.
func _update_chest_prompt(delta: float) -> void:
	if _prompt == null:
		return
	var allowed := _selected < 0 and not _busy and _open_index < 0 and not _panel.visible \
		and not bool(_game_ui.call("gameplay_input_blocked"))
	if not allowed:
		_prompt.visible = false
		_prompt_index = -1
		return
	_prompt_timer -= delta
	if _prompt_timer <= 0.0:
		_prompt_timer = PROMPT_INTERVAL
		_prompt_index = _nearest_chest()
	if _prompt_index < 0:
		_prompt.visible = false
		return
	var sprite := _placed[_prompt_index]["node"] as Sprite2D
	if not is_instance_valid(sprite):
		_prompt_index = -1
		_prompt.visible = false
		return
	# Đặt nút ngay trên đỉnh sprite rương, đi theo camera.
	var top: Vector2 = sprite.global_transform * Vector2(0.0, sprite.get_rect().position.y)
	var screen: Vector2 = get_viewport().get_canvas_transform() * top
	_prompt.position = (screen - Vector2(_prompt.size.x * 0.5, _prompt.size.y + 6.0)).floor()
	_prompt.visible = true


func _on_prompt_pressed() -> void:
	if _prompt_index >= 0:
		_open_chest(_prompt_index)


## Mở nắp (hiệu ứng ánh sáng chỉ ở lần mở đầu tiên), chờ một chút cho hiệu ứng kịp thấy rồi hiện bảng rương.
func _open_chest(index: int) -> void:
	if _chest_ui == null or _busy or _open_index >= 0 or index < 0 or index >= _placed.size():
		return
	var entry: Dictionary = _placed[index]
	var storage := entry["storage"] as Inventory
	var sprite := entry["node"] as Sprite2D
	if storage == null or not is_instance_valid(sprite):
		return
	_busy = true
	_prompt.visible = false
	var open_texture := entry["open_texture"] as Texture2D
	if open_texture != null:
		ChestOpener.open(sprite, open_texture, not bool(entry["opened_once"]))
		entry["opened_once"] = true
		await get_tree().create_timer(OPEN_UI_DELAY).timeout
	_busy = false
	_open_index = index
	_chest_ui.call("open_chest", storage, str(entry["name"]))


## Bảng rương đã đóng: đóng nắp lại.
func _on_chest_closed() -> void:
	if _open_index < 0:
		return
	var entry: Dictionary = _placed[_open_index]
	_open_index = -1
	ChestOpener.close(entry["node"] as Sprite2D, entry["closed_texture"] as Texture2D)


func _remove_nonblocking_props(world_pos: Vector2, footprint: PackedVector2Array) -> void:
	for prop in terrain_map.find_gatherables(world_pos, 3.0):
		var point: Vector2 = prop.world
		if not Geometry2D.is_point_in_polygon(point, footprint):
			continue
		var prop_def: Dictionary = ObjectDefs.sprites.get(str(prop.name), {})
		if not (prop_def.get("collider", {}) as Dictionary).is_empty():
			continue
		terrain_map.replace_prop(prop.key, "")
