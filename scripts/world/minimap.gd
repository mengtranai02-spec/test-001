extends Control

## Minimap tròn, vẽ theo đúng phép chiếu iso của màn hình chính: người chơi đi sang phải
## trên màn hình thì bản đồ trên minimap cũng trượt sang trái (không còn bị xoay chéo 45 độ).
## Mũi tên trỏ đúng hướng người chơi đang đi trên màn hình.

var player: Node2D
var terrain_map: Node2D

const VIEW_RADIUS_PX := 2400.0    # bán kính thế giới (px) mà minimap hiển thị
const REVEAL_RADIUS_PX := 1500.0  # bán kính thế giới (px) tự khám phá quanh người chơi
const BLOCK := 16                 # mỗi khối cache = BLOCK x BLOCK ô
const NONE := Vector2i(1 << 30, 1 << 30) # "chưa có ô tâm nào"
const BG_COLOR := Color(0.015, 0.02, 0.03)
const RING_COLOR := Color(0.8, 0.9, 1.0, 0.85)
const BIG_BG_COLOR := Color(0.015, 0.02, 0.03, 0.96)
const BIG_ZOOM_DEFAULT := 0.1     # px màn hình trên 1 px thế giới của bản đồ lớn
const BIG_ZOOM_MIN := 0.025
const BIG_ZOOM_MAX := 0.4


## Một khối bản đồ = ảnh BLOCK x BLOCK pixel (1 pixel = 1 ô iso).
## Pixel trong suốt (alpha = 0) nghĩa là ô đó chưa được khám phá.
class Block:
	var data := PackedByteArray()
	var texture: ImageTexture
	var dirty := false
	var side := 0

	func _init(n: int) -> void:
		side = n
		data.resize(n * n * 4) # mặc định toàn 0 => trong suốt
		texture = ImageTexture.create_from_image(Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, data))

	func upload() -> void:
		texture.update(Image.create_from_data(side, side, false, Image.FORMAT_RGBA8, data))
		dirty = false


## Node con vẽ nội dung minimap. Nó bị cắt tròn theo hình tròn nền của node cha (clip_children).
class MapView extends Control:
	var host

	func _draw() -> void:
		host.draw_map(self)


## Bản đồ lớn toàn màn hình: kéo chuột / ngón tay để dịch, lăn chuột để thu phóng.
class BigMap extends Control:
	var host
	var _dragging := false

	func _draw() -> void:
		host.draw_big_map(self)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var e := event as InputEventMouseButton
			match e.button_index:
				MOUSE_BUTTON_LEFT:
					_dragging = e.pressed
				MOUSE_BUTTON_WHEEL_UP:
					if e.pressed:
						host.zoom_big(1.15)
				MOUSE_BUTTON_WHEEL_DOWN:
					if e.pressed:
						host.zoom_big(1.0 / 1.15)
			accept_event()
		elif event is InputEventMouseMotion and _dragging:
			host.pan_big((event as InputEventMouseMotion).relative)
			accept_event()


var _view: MapView
var _big: BigMap
var _big_center := Vector2.ZERO   # điểm thế giới (px) đang ở giữa bản đồ lớn
var _big_zoom := BIG_ZOOM_DEFAULT
var _blocks: Dictionary = {}    # Vector2i -> Block
var _dirty: Array[Block] = []   # các khối có pixel mới, chờ đẩy lên GPU
var _last_center := NONE        # ô người chơi đứng ở lần khám phá trước
var _last_pos := Vector2.INF
var _last_facing := Vector2.INF

# Hình dạng vùng khám phá theo từng hàng ô (dy). Vòng tròn trên MÀN HÌNH = hình elip trong không gian ô.
var _row_lo := PackedInt32Array() # dx nhỏ nhất nằm trong vùng khám phá của hàng dy
var _row_hi := PackedInt32Array() # dx lớn nhất (lo > hi nghĩa là hàng rỗng)
var _row_off := 0                 # chỉ số hàng = dy + _row_off
var _ax := Vector2.ZERO           # vector thế giới (px) của 1 ô theo trục x
var _ay := Vector2.ZERO           # vector thế giới (px) của 1 ô theo trục y


func clear_exploration() -> void:
	_blocks.clear()
	_dirty.clear()
	_last_center = NONE
	_last_pos = Vector2.INF
	if is_instance_valid(_view):
		_view.queue_redraw()
	if is_instance_valid(_big):
		_big.queue_redraw()


func _ready() -> void:
	custom_minimum_size = Vector2(220, 220)
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	offset_right = -16
	offset_left = -236
	offset_top = 16
	offset_bottom = 236
	mouse_filter = Control.MOUSE_FILTER_STOP                  # bấm vào minimap để mở bản đồ lớn
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST        # giữ pixel vuông, không bị nhoè
	clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW         # nội dung bị cắt theo hình tròn nền
	_view = MapView.new()
	_view.host = self
	_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_view)
	_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_create_big_map.call_deferred() # cha (CanvasLayer) đang dựng con nên phải thêm trễ 1 nhịp


## Bản đồ lớn là anh em của minimap (không phải con) để không bị cắt tròn.
func _create_big_map() -> void:
	var parent := get_parent()
	if parent == null:
		return
	_big = BigMap.new()
	_big.host = self
	_big.visible = false
	_big.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_big.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(_big)
	_big.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var hint := Label.new()
	hint.text = "Kéo để di chuyển bản đồ  •  Cuộn để thu phóng  •  M / Esc để đóng"
	hint.position = Vector2(16, 12)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_big.add_child(hint)

	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	row.offset_left = -220.0
	row.offset_right = -16.0
	row.offset_top = 10.0
	_big.add_child(row)
	var recenter := Button.new()
	recenter.text = "Về chỗ tôi"
	recenter.pressed.connect(func():
		_big_center = player.global_position
		_big.queue_redraw())
	row.add_child(recenter)
	var close := Button.new()
	close.text = "Đóng"
	close.pressed.connect(func(): _set_big_open(false))
	row.add_child(close)


func _exit_tree() -> void:
	if is_instance_valid(_big):
		_big.queue_free()


func _gui_input(event: InputEvent) -> void:
	var click := event as InputEventMouseButton
	if click != null and click.pressed and click.button_index == MOUSE_BUTTON_LEFT:
		_set_big_open(true)
		accept_event()


## Chỉ nhận chuột trong hình tròn (góc vuông của hộp vẫn cho click xuyên qua).
func _has_point(point: Vector2) -> bool:
	return point.distance_to(size * 0.5) <= minf(size.x, size.y) * 0.5


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.physical_keycode == KEY_M:
		_set_big_open(not (is_instance_valid(_big) and _big.visible))
		get_viewport().set_input_as_handled()
	elif key.physical_keycode == KEY_ESCAPE and is_instance_valid(_big) and _big.visible:
		_set_big_open(false)
		get_viewport().set_input_as_handled()


func _set_big_open(open: bool) -> void:
	if not is_instance_valid(_big) or _big.visible == open:
		return
	_big.visible = open
	if open:
		if is_instance_valid(player):
			_big_center = player.global_position
		_big_zoom = BIG_ZOOM_DEFAULT
		_big.queue_redraw()


func pan_big(screen_delta: Vector2) -> void:
	_big_center -= screen_delta / _big_zoom
	_big.queue_redraw()


func zoom_big(factor: float) -> void:
	_big_zoom = clampf(_big_zoom * factor, BIG_ZOOM_MIN, BIG_ZOOM_MAX)
	_big.queue_redraw()


## Hình tròn nền (đặc, không trong suốt) vừa là nền vừa là mặt nạ cắt cho node con.
func _draw() -> void:
	draw_circle(size * 0.5, minf(size.x, size.y) * 0.5, BG_COLOR)


func _process(_delta: float) -> void:
	if not is_instance_valid(player) or not is_instance_valid(terrain_map) or not is_instance_valid(_view):
		return
	if _row_lo.is_empty():
		_build_reveal_table()

	var t: Vector2 = terrain_map.world_to_tile(player.global_position)
	var center := Vector2i(floori(t.x), floori(t.y))
	if center != _last_center:
		_reveal(center, _last_center)
		_last_center = center
		for block in _dirty:
			block.upload()
		_dirty.clear()

	# Vẽ lại khi người chơi di chuyển hoặc đổi hướng (chỉ ~50 lệnh vẽ nên rất nhẹ).
	var pos := player.global_position
	var facing: Vector2 = player.facing_direction
	if pos != _last_pos or facing != _last_facing:
		_last_pos = pos
		_last_facing = facing
		_view.queue_redraw()
		if is_instance_valid(_big) and _big.visible:
			_big.queue_redraw() # cập nhật mũi tên người chơi + vùng mới khám phá


## Dựng bảng hình dạng vùng khám phá: ô (dx, dy) lệch so với ô người chơi được khám phá khi
## khoảng cách TRÊN MÀN HÌNH của nó tới người chơi <= REVEAL_RADIUS_PX.
func _build_reveal_table() -> void:
	var o: Vector2 = terrain_map.tile_to_world(0.0, 0.0)
	_ax = terrain_map.tile_to_world(1.0, 0.0) - o
	_ay = terrain_map.tile_to_world(0.0, 1.0) - o
	# |dx*ax + dy*ay|^2 <= R^2  <=>  a*dx^2 + b*dy*dx + c*dy^2 - R^2 <= 0
	var a := _ax.length_squared()
	var b := 2.0 * _ax.dot(_ay)
	var c := _ay.length_squared()
	var r2 := REVEAL_RADIUS_PX * REVEAL_RADIUS_PX
	var k := c - b * b / (4.0 * a)
	var dy_max := int(floor(sqrt(r2 / k)))
	_row_off = dy_max
	var rows := dy_max * 2 + 1
	_row_lo.resize(rows)
	_row_hi.resize(rows)
	for i in rows:
		var dy := float(i - dy_max)
		var bb := b * dy
		var cc := c * dy * dy - r2
		var disc := bb * bb - 4.0 * a * cc
		if disc < 0.0:
			_row_lo[i] = 1
			_row_hi[i] = 0
		else:
			var s := sqrt(disc)
			_row_lo[i] = ceili((-bb - s) / (2.0 * a))
			_row_hi[i] = floori((-bb + s) / (2.0 * a))


## Khám phá vùng quanh ô tâm mới. Chỉ xét phần chưa nằm trong vùng của tâm cũ
## (hiệu hai hình theo từng hàng) nên mỗi bước chỉ tốn vài chục ô thay vì cả vùng.
func _reveal(center: Vector2i, old: Vector2i) -> void:
	var rows := _row_lo.size()
	for i in rows:
		var lo := _row_lo[i]
		var hi := _row_hi[i]
		if lo > hi:
			continue
		var y := center.y + (i - _row_off)
		var x0 := center.x + lo
		var x1 := center.x + hi
		var j := y - old.y + _row_off # hàng tương ứng của vùng cũ
		if j >= 0 and j < rows and _row_lo[j] <= _row_hi[j]:
			var ox0 := old.x + _row_lo[j]
			var ox1 := old.x + _row_hi[j]
			_reveal_span(y, x0, mini(x1, ox0 - 1))
			_reveal_span(y, maxi(x0, ox1 + 1), x1)
		else:
			_reveal_span(y, x0, x1)


func _reveal_span(y: int, xa: int, xb: int) -> void:
	if xa > xb:
		return
	var by := floori(float(y) / BLOCK)
	var row := (y - by * BLOCK) * BLOCK
	var x := xa
	while x <= xb:
		var bx := floori(float(x) / BLOCK)
		var base := bx * BLOCK
		var block := _get_block(Vector2i(bx, by))
		var end_x := mini(xb, base + BLOCK - 1)
		for xx in range(x, end_x + 1):
			var idx := (row + xx - base) * 4
			if block.data[idx + 3] != 0:
				continue # ô này đã khám phá, không cần lấy noise lại
			var c: Color = terrain_map.terrain_color_at_tile(float(xx) + 0.5, float(y) + 0.5)
			block.data[idx] = c.r8
			block.data[idx + 1] = c.g8
			block.data[idx + 2] = c.b8
			block.data[idx + 3] = 255
			if not block.dirty:
				block.dirty = true
				_dirty.append(block)
		x = end_x + 1


func _get_block(key: Vector2i) -> Block:
	var block: Block = _blocks.get(key)
	if block == null:
		block = Block.new(BLOCK)
		_blocks[key] = block
	return block


## Được MapView gọi trong _draw của nó.
func draw_map(canvas: Control) -> void:
	var half := canvas.size * 0.5
	var radius := minf(canvas.size.x, canvas.size.y) * 0.5
	if _ready_to_draw():
		var ext := Vector2.ONE * VIEW_RADIUS_PX
		_draw_blocks(canvas, player.global_position, half, radius / VIEW_RADIUS_PX, ext)
	_draw_arrow(canvas, half, player.facing_direction if is_instance_valid(player) else Vector2.RIGHT)
	canvas.draw_arc(half, radius - 1.5, 0.0, TAU, 64, RING_COLOR, 3.0)


## Được BigMap gọi trong _draw của nó.
func draw_big_map(canvas: Control) -> void:
	canvas.draw_rect(Rect2(Vector2.ZERO, canvas.size), BIG_BG_COLOR)
	if not _ready_to_draw():
		return
	var half := canvas.size * 0.5
	_draw_blocks(canvas, _big_center, half, _big_zoom, half / _big_zoom)
	# Người chơi: cùng phép co giãn với bản đồ (thế giới -> màn hình chỉ là tịnh tiến + tỉ lệ).
	var p := half + (player.global_position - _big_center) * _big_zoom
	if Rect2(Vector2.ZERO, canvas.size).has_point(p):
		_draw_arrow(canvas, p, player.facing_direction)


func _ready_to_draw() -> bool:
	return is_instance_valid(player) and is_instance_valid(terrain_map) and not _row_lo.is_empty()


## Vẽ các khối đã khám phá. center_world = điểm thế giới nằm ở screen_center; k = px màn hình / px thế giới;
## half_extent = nửa kích thước vùng nhìn (px thế giới). Mỗi khối vẽ ở toạ độ ô, phép biến đổi iso
## biến nó thành hình bình hành đúng như trên màn hình chính.
func _draw_blocks(canvas: CanvasItem, center_world: Vector2, screen_center: Vector2, k: float, half_extent: Vector2) -> void:
	var t: Vector2 = terrain_map.world_to_tile(center_world)
	var origin := screen_center - k * (t.x * _ax + t.y * _ay)
	canvas.draw_set_transform_matrix(Transform2D(_ax * k, _ay * k, origin))
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		var tc: Vector2 = terrain_map.world_to_tile(center_world + corner * half_extent)
		lo = lo.min(tc)
		hi = hi.max(tc)
	var b0 := Vector2i((lo / BLOCK).floor())
	var b1 := Vector2i((hi / BLOCK).floor())
	for by in range(b0.y, b1.y + 1):
		for bx in range(b0.x, b1.x + 1):
			var block: Block = _blocks.get(Vector2i(bx, by))
			if block == null:
				continue
			# +0.03 ô để hai khối kề nhau không hở khe.
			canvas.draw_texture_rect(block.texture, Rect2(bx * BLOCK, by * BLOCK, BLOCK + 0.03, BLOCK + 0.03), false)
	canvas.draw_set_transform_matrix(Transform2D.IDENTITY)


## Mũi tên người chơi: hướng đi trên màn hình = hướng trên bản đồ (cùng phép chiếu, đồng dạng).
func _draw_arrow(canvas: CanvasItem, pos: Vector2, look: Vector2) -> void:
	if look.is_zero_approx():
		look = Vector2.RIGHT
	look = look.normalized()
	canvas.draw_colored_polygon(PackedVector2Array([
		pos + look * 9.0,
		pos + look.rotated(2.45) * 6.0,
		pos + look.rotated(-2.45) * 6.0,
	]), Color.WHITE)
