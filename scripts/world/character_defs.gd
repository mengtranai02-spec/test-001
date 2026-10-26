extends RefCounted
## Nạp dữ liệu người chơi và mob từ res://data/player.json và res://data/mobs.json.
## Hiện chỉ có collider (elip). Sửa JSON rồi chạy lại game là có hiệu lực, không phải sửa code.

const PLAYER_PATH := "res://data/player.json"
const MOBS_PATH := "res://data/mobs.json"
const ELLIPSE_POINTS := 24
const DEFAULT_COLLIDER := {"shape": "ellipse", "offset": [0, 0], "radius": [12, 6]}

static var _loaded := false
static var _player: Dictionary = {}
static var _mob_default: Dictionary = {}
static var _mobs: Dictionary = {}
static var _shape_cache: Dictionary = {}  # khoá chuỗi -> ConvexPolygonShape2D dùng chung


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var p = _read_json(PLAYER_PATH)
	_player = p if p is Dictionary else {}
	var m = _read_json(MOBS_PATH)
	if m is Dictionary:
		_mob_default = m.get("default", {})
		_mobs = m.get("mobs", {})
	_shape_cache.clear()


## Collider của người chơi: {offset: Vector2, radius: Vector2}.
static func player_collider() -> Dictionary:
	ensure_loaded()
	return _parse_collider(_player.get("collider"))


## Collider của một loại mob (mob_type). Không có thì dùng mục "default" rồi tới giá trị mặc định.
static func mob_collider(mob_type: String) -> Dictionary:
	ensure_loaded()
	var entry: Dictionary = _mobs.get(mob_type, _mob_default)
	return _parse_collider(entry.get("collider"))


## Gắn collider elip vào body: dùng CollisionShape2D có sẵn trong scene (nếu có) hoặc tạo mới.
## Elip được dựng bằng đa giác lồi nên đúng là elip khi va chạm (Godot không có shape elip riêng).
## Elip chỉ dùng cho va chạm player <-> mob; với vật tĩnh chỉ dùng radius.x làm nửa dài đoạn chân.
static func apply_collider(body: CollisionObject2D, collider: Dictionary, cache_key: String) -> void:
	var cs: CollisionShape2D = null
	for child in body.get_children():
		if child is CollisionShape2D:
			cs = child
			break
	if cs == null:
		cs = CollisionShape2D.new()
		cs.name = "CollisionShape2D"
		body.add_child(cs)
	# Va chạm với vật tĩnh dùng đoạn ngang ở chân, nửa dài = radius.x (map.can_walk đọc meta này).
	body.set_meta("foot_half_width", (collider["radius"] as Vector2).x)
	cs.scale = Vector2.ONE
	cs.rotation = 0.0
	cs.position = collider["offset"]
	cs.shape = _ellipse_shape(cache_key, collider["radius"])


static func _ellipse_shape(cache_key: String, radius: Vector2) -> ConvexPolygonShape2D:
	var key := "%s|%s" % [cache_key, radius]
	var shape: ConvexPolygonShape2D = _shape_cache.get(key)
	if shape == null:
		var pts := PackedVector2Array()
		for i in ELLIPSE_POINTS:
			var a := TAU * i / ELLIPSE_POINTS
			pts.append(Vector2(cos(a) * radius.x, sin(a) * radius.y))
		shape = ConvexPolygonShape2D.new()
		shape.points = pts
		_shape_cache[key] = shape
	return shape


static func _parse_collider(c) -> Dictionary:
	if not (c is Dictionary):
		c = DEFAULT_COLLIDER
	var shape_name := str(c.get("shape", "ellipse"))
	if shape_name != "ellipse":
		push_warning("player/mobs json: collider chỉ hỗ trợ ellipse (nhận '%s'), dùng ellipse" % shape_name)
	var off: Array = c.get("offset", [0, 0])
	var rad: Array = c.get("radius", [12, 6])
	return {
		"offset": Vector2(off[0], off[1]),
		"radius": Vector2(maxf(float(rad[0]), 0.5), maxf(float(rad[1]), 0.5)),
	}


static func _read_json(path: String):
	var res = load(path)
	if res is JSON:
		return res.data
	# Dự phòng: đọc thẳng file (khi xuất game nhớ thêm *.json vào Export > Resources > Filters).
	var text := FileAccess.get_file_as_string(path)
	return JSON.parse_string(text) if not text.is_empty() else null
