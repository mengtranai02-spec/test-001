extends RefCounted
## Collider của vật thể tĩnh (cây, đá, khúc gỗ, ...): đăng ký theo chunk, tra cứu theo ô lưới, kiểm tra điểm / đoạn thẳng
## và vẽ viền debug. Không dùng node vật lý của Godot nên chạy được với hàng nghìn vật thể.
##
## Mọi toạ độ trong file này là toạ độ CỤC BỘ của map (cùng hệ với _tile_to_screen của map.gd).
## Mỗi collider là một Array theo chỉ số E_*:
##   [shape, center, half, cells, poly]
##   shape  : 0 elip | 1 chữ nhật | 2 hình bình hành | 3 hình thoi (khớp object_defs.gd)
##   center : Vector2 tâm collider
##   half   : Vector2 nửa kích thước (elip, chữ nhật)
##   cells  : Array[Vector2i] các ô lưới collider phủ tới
##   poly   : PackedVector2Array đỉnh đa giác (chỉ có khi shape >= 2)

const ObjectDefs := preload("res://scripts/world/object_defs.gd")

const E_SHAPE := 0
const E_CENTER := 1
const E_HALF := 2
const E_CELLS := 3
const E_POLY := 4

const SEGMENT_STEP_TILES := 0.5 # khi xét đoạn thẳng: lấy mẫu ô lưới dọc đoạn, bước tối đa nửa ô

var _tile_w: float
var _tile_h: float
var _by_cell: Dictionary = {}  # Vector2i (ô toàn cục) -> Array collider chạm ô đó
var _by_chunk: Dictionary = {} # Vector2i (chunk) -> Array collider do chunk đó sinh ra


## tile_w / tile_h phải bằng TILE_W / TILE_H của map.gd (để đổi toạ độ ô <-> màn hình giống hệt map).
func _init(tile_w: float, tile_h: float) -> void:
	_tile_w = tile_w
	_tile_h = tile_h


## Ghi nhận collider của các vật thể mà một chunk vừa rải. props: [[tên sprite, tx, ty, scale nhóm], ...].
func register_chunk(coord: Vector2i, props: Array) -> void:
	var entries: Array = []
	for p in props:
		var col: Dictionary = ObjectDefs.sprites[p[0]]["collider"]
		if col.is_empty():
			continue
		var sc: float = ObjectDefs.object_scale * float(p[3])
		var center := _tile_to_screen(p[1], p[2]) + (col["offset"] as Vector2) * sc
		var half := (col["radius"] as Vector2) * sc
		var shape: int = col["shape"]
		var poly := PackedVector2Array() # chỉ dùng cho hình bình hành / hình thoi
		var bound_points: Array = []
		if shape >= 2:
			for pt in col["points"]:
				poly.append(center + (pt as Vector2) * sc)
			bound_points = Array(poly)
		else:
			for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
				bound_points.append(center + corner * half)
		# Phép đổi toạ độ là tuyến tính nên hộp bao trong không gian ô của các đỉnh là đủ để biết ô nào bị phủ.
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for bp in bound_points:
			var t := _screen_to_tile(bp)
			lo = lo.min(t)
			hi = hi.max(t)
		var cells: Array[Vector2i] = []
		for cy in range(floori(lo.y), floori(hi.y) + 1):
			for cx in range(floori(lo.x), floori(hi.x) + 1):
				cells.append(Vector2i(cx, cy))
		var entry := [shape, center, half, cells, poly]
		for k in cells:
			if not _by_cell.has(k):
				_by_cell[k] = []
			_by_cell[k].append(entry)
		entries.append(entry)
	_by_chunk[coord] = entries


## Xoá collider do chunk này sinh ra (khi chunk bị giải phóng).
func unregister_chunk(coord: Vector2i) -> void:
	for entry in _by_chunk.get(coord, []):
		for k in entry[E_CELLS]:
			var list: Array = _by_cell.get(k, [])
			list.erase(entry)
			if list.is_empty():
				_by_cell.erase(k)
	_by_chunk.erase(coord)


func clear() -> void:
	_by_cell.clear()
	_by_chunk.clear()


## Điểm local có nằm trong collider nào không.
func is_blocked_at(local: Vector2) -> bool:
	var t := _screen_to_tile(local)
	var list = _by_cell.get(Vector2i(floori(t.x), floori(t.y)))
	if list == null:
		return false
	for e in list:
		if e[E_SHAPE] >= 2:
			if Geometry2D.is_point_in_polygon(local, e[E_POLY]):
				return true
			continue
		var d: Vector2 = local - (e[E_CENTER] as Vector2)
		var h: Vector2 = e[E_HALF]
		if e[E_SHAPE] == 0:
			if (d.x * d.x) / (h.x * h.x) + (d.y * d.y) / (h.y * h.y) <= 1.0:
				return true
		elif absf(d.x) <= h.x and absf(d.y) <= h.y:
			return true
	return false


## Đoạn thẳng a-b (local) có cắt / nằm trong collider nào không.
func is_segment_blocked(a: Vector2, b: Vector2) -> bool:
	var ta := _screen_to_tile(a)
	var tb := _screen_to_tile(b)
	# Các ô lưới mà đoạn đi qua: lấy mẫu dọc đoạn.
	var steps := maxi(1, ceili((tb - ta).length() / SEGMENT_STEP_TILES))
	var seen: Dictionary = {}
	for i in steps + 1:
		var t := ta.lerp(tb, float(i) / steps)
		var key := Vector2i(floori(t.x), floori(t.y))
		if seen.has(key):
			continue
		seen[key] = true
		var list = _by_cell.get(key)
		if list == null:
			continue
		for e in list:
			if _segment_hits_collider(a, b, e):
				return true
	return false


## Vẽ viền đỏ của mọi collider vật thể đang nạp (để canh offset / radius trong props.json).
func draw_debug(overlay: CanvasItem, color: Color) -> void:
	for entries in _by_chunk.values():
		for e in entries:
			var c: Vector2 = e[E_CENTER]
			var h: Vector2 = e[E_HALF]
			if e[E_SHAPE] == 0:
				overlay.draw_set_transform(c, 0.0, Vector2(1.0, h.y / h.x))
				overlay.draw_arc(Vector2.ZERO, h.x, 0.0, TAU, 24, color, 1.5)
			elif e[E_SHAPE] == 1:
				overlay.draw_set_transform(c, 0.0, Vector2.ONE)
				overlay.draw_rect(Rect2(-h, h * 2.0), color, false, 1.5)
			else:
				var outline: PackedVector2Array = (e[E_POLY] as PackedVector2Array).duplicate()
				outline.append(outline[0]) # khép kín viền
				overlay.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
				overlay.draw_polyline(outline, color, 1.5)
	overlay.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## Đoạn a-b có chạm collider e không.
static func _segment_hits_collider(a: Vector2, b: Vector2, e: Array) -> bool:
	var c: Vector2 = e[E_CENTER]
	var h: Vector2 = e[E_HALF]
	match int(e[E_SHAPE]):
		0: # elip: co trục Y cho thành hình tròn bán kính h.x rồi tính khoảng cách tâm -> đoạn
			var k := h.x / h.y
			var pa := Vector2(a.x - c.x, (a.y - c.y) * k)
			var pb := Vector2(b.x - c.x, (b.y - c.y) * k)
			return Geometry2D.get_closest_point_to_segment(Vector2.ZERO, pa, pb).length_squared() <= h.x * h.x
		1:
			return _segment_hits_box(a, b, c, h)
		_: # hình bình hành, hình thoi
			var poly: PackedVector2Array = e[E_POLY]
			if Geometry2D.is_point_in_polygon(a, poly):
				return true # đoạn nằm hẳn bên trong (hoặc đầu mút nằm trong)
			for i in poly.size():
				if Geometry2D.segment_intersects_segment(a, b, poly[i], poly[(i + 1) % poly.size()]) != null:
					return true
			return false


## Đoạn a-b cắt hình chữ nhật tâm c, nửa kích thước h (phương pháp slab).
static func _segment_hits_box(a: Vector2, b: Vector2, c: Vector2, h: Vector2) -> bool:
	var lo := c - h
	var hi := c + h
	var d := b - a
	var t0 := 0.0
	var t1 := 1.0
	for i in 2:
		if absf(d[i]) < 0.00001:
			if a[i] < lo[i] or a[i] > hi[i]:
				return false
		else:
			var s0 := (lo[i] - a[i]) / d[i]
			var s1 := (hi[i] - a[i]) / d[i]
			t0 = maxf(t0, minf(s0, s1))
			t1 = minf(t1, maxf(s0, s1))
			if t0 > t1:
				return false
	return true


func _tile_to_screen(x: float, y: float) -> Vector2:
	return Vector2((x - y) * _tile_w * 0.5, (x + y) * _tile_h * 0.5)


func _screen_to_tile(point: Vector2) -> Vector2:
	var sx := point.x / (_tile_w * 0.5)
	var sy := point.y / (_tile_h * 0.5)
	return Vector2((sx + sy) * 0.5, (sy - sx) * 0.5)
