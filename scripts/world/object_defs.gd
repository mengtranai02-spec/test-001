extends RefCounted
## Nạp dữ liệu vật thể từ res://data/props.json (sprite, nhóm, collider, luật rải).
## Sửa file JSON rồi chạy lại game là có hiệu lực, không phải sửa code.

const DATA_PATH := "res://data/props.json"

static var _loaded := false
static var sheet: Texture2D
static var shadow_sheet: Texture2D  # sheet chỉ chứa bóng; rect bóng = rect sprite chính. null = không vẽ bóng
static var object_scale := 1.0
## Mỗi nhóm: {id, ground: Array[int], base, forest, spacing, scale, spawn: Array[String]}
static var groups: Array = []
## Tên sprite -> {rect: Rect2, group: int (chỉ số trong groups), collider: Dictionary, occludes: bool, shadow: bool}
## collider rỗng {} = không chắn; ngược lại {shape: 0 elip | 1 chữ nhật | 2 hình bình hành | 3 hình thoi, offset: Vector2, radius: Vector2, points: PackedVector2Array}.
## points chỉ có khi shape = 2 hoặc 3: 4 đỉnh (px sprite gốc) tính từ tâm collider (hình bình hành đã áp skew + rotation).
static var sprites: Dictionary = {}


## Gọi 1 lần ở luồng chính trước khi sinh chunk (thread nền chỉ đọc dữ liệu đã nạp).
static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var root = _read_json()
	if not (root is Dictionary):
		push_error("Không đọc được %s" % DATA_PATH)
		return
	sheet = load(root["sheet"]) as Texture2D
	shadow_sheet = load(root["shadow_sheet"]) as Texture2D if root.has("shadow_sheet") and ResourceLoader.exists(root["shadow_sheet"]) else null
	object_scale = float(root.get("object_scale", 1.0))
	groups.clear()
	sprites.clear()
	for gi in root["groups"].size():
		var g: Dictionary = root["groups"][gi]
		var ground: Array[int] = []
		for v in g.get("ground", []):
			ground.append(int(v))
		var spawn: Array[String] = []
		for v in g.get("spawn", []):
			spawn.append(str(v))
		groups.append({
			"id": str(g.get("id", gi)),
			"occludes": bool(g.get("occludes", true)),
			"shadow": bool(g.get("shadow", false)),
			"ground": ground,
			"base": float(g.get("base", 0.0)),
			"forest": float(g.get("forest", 0.0)),
			"spacing": int(g.get("spacing", 0)),
			"scale": float(g.get("scale", 1.0)),
			"spawn": spawn,
		})
		var table: Dictionary = g["sprites"]
		for sprite_name in table:
			var s: Dictionary = table[sprite_name]
			var r: Array = s["rect"]
			sprites[sprite_name] = {
				"rect": Rect2(r[0], r[1], r[2], r[3]),
				"group": gi,
				"collider": _parse_collider(s.get("collider")),
				# Sprite ghi đè nhóm nếu có khoá riêng.
				"occludes": bool(s.get("occludes", g.get("occludes", true))),
				"shadow": bool(s.get("shadow", g.get("shadow", false))) and shadow_sheet != null,
			}


static func _parse_collider(c) -> Dictionary:
	if not (c is Dictionary):
		return {}
	var off: Array = c.get("offset", [0, 0])
	var rad: Array = c.get("radius", [8, 4])
	var shape_name := str(c.get("shape", "ellipse"))
	var shape := 0
	match shape_name:
		"rect": shape = 1
		"parallelogram": shape = 2
		"diamond": shape = 3
		"ellipse": shape = 0
		_: push_warning("props.json: shape '%s' không hợp lệ (ellipse | rect | parallelogram | diamond), dùng ellipse" % shape_name)
	var radius := Vector2(maxf(float(rad[0]), 0.5), maxf(float(rad[1]), 0.5))
	var result := {
		"shape": shape,
		"offset": Vector2(off[0], off[1]),
		"radius": radius,
	}
	if shape == 2:
		result["points"] = _parallelogram_points(radius, float(c.get("skew", 0.0)), float(c.get("rotation", 0.0)))
	elif shape == 3: # hình thoi: 4 đỉnh trái, trên, phải, dưới
		result["points"] = PackedVector2Array([Vector2(-radius.x, 0.0), Vector2(0.0, -radius.y), Vector2(radius.x, 0.0), Vector2(0.0, radius.y)])
	return result


## Hình bình hành: lấy hình chữ nhật nửa rộng/nửa cao = radius, kéo xiên cạnh trên/dưới theo trục X
## (skew = số px lệch của mỗi cạnh ngắn; skew > 0: cạnh trên lệch sang phải, cạnh dưới sang trái)
## rồi xoay cả hình đi rotation độ (dương = theo chiều kim đồng hồ trên màn hình, trục Y hướng xuống).
## Trả về 4 đỉnh theo thứ tự trên-trái, trên-phải, dưới-phải, dưới-trái, tính từ tâm collider.
const PARALLELOGRAM_SKEW_SIGN := -1.0  # đổi thành 1.0 nếu chiều xiên bị ngược so với hình bạn canh trong tool chỉnh collider

static func _parallelogram_points(radius: Vector2, skew: float, rotation_deg: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var rot := deg_to_rad(rotation_deg)
	for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		var p: Vector2 = corner * radius
		p.x += PARALLELOGRAM_SKEW_SIGN * skew * corner.y
		pts.append(p.rotated(rot))
	return pts


static func _read_json():
	var res = load(DATA_PATH)
	if res is JSON:
		return res.data
	# Dự phòng: đọc thẳng file (khi xuất game nhớ thêm *.json vào Export > Resources > Filters).
	var text := FileAccess.get_file_as_string(DATA_PATH)
	return JSON.parse_string(text) if not text.is_empty() else null


## Chọn vật thể cho một ô. r1 quyết định có mọc không / nhóm nào, r2 chọn biến thể. {} nếu không có gì.
static func pick(ground: int, forest: float, r1: float, r2: float) -> Dictionary:
	var acc := 0.0
	var f2 := forest * forest
	for g in groups:
		var spawn: Array = g["spawn"]
		if spawn.is_empty() or not (ground in g["ground"]):
			continue
		acc += g["base"] + g["forest"] * f2
		if r1 < acc:
			return {"name": spawn[int(r2 * spawn.size()) % spawn.size()], "group": g}
	return {}
