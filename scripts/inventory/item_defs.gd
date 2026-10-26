extends RefCounted
## Dữ liệu vật phẩm: res://data/items.json (tên, mô tả, số lượng tối đa mỗi ô, icon, cấu hình túi đồ).
## Icon vật phẩm: nếu file ảnh có thì dùng, chưa có thì item_icon.gd tự vẽ hình tạm.
## Icon giao diện tuỳ chọn: res://assets/ui/<tên>.png (bag, pickup, chop, smash); thiếu file thì dùng hình vẽ bằng code.

const DATA_PATH := "res://data/items.json"
const UI_ICON_DIR := "res://assets/ui/"

static var slots := 20
static var columns := 5
static var items: Dictionary = {}  # id -> {name, desc, stack, icon_path, shape, color}
static var _loaded := false
static var _texture_cache: Dictionary = {}


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var raw = _read_json(DATA_PATH)
	if not (raw is Dictionary):
		push_warning("Không đọc được %s" % DATA_PATH)
		return
	var inv: Dictionary = raw.get("inventory", {})
	slots = maxi(1, int(inv.get("slots", slots)))
	columns = clampi(int(inv.get("columns", columns)), 1, slots)
	var defs: Dictionary = raw.get("items", {})
	for id in defs:
		var d: Dictionary = defs[id]
		var ph: Dictionary = d.get("placeholder", {})
		var c: Array = ph.get("color", [0.7, 0.7, 0.7])
		items[str(id)] = {
			"name": str(d.get("name", id)),
			"desc": str(d.get("desc", "")),
			"stack": maxi(1, int(d.get("stack", 99))),
			"icon_path": str(d.get("icon", "")),
			"shape": str(ph.get("shape", "")),
			"color": Color(float(c[0]), float(c[1]), float(c[2])),
		}


static func has_item(id: String) -> bool:
	ensure_loaded()
	return items.has(id)


static func get_item(id: String) -> Dictionary:
	ensure_loaded()
	return items.get(id, {})


static func item_name(id: String) -> String:
	return str(get_item(id).get("name", id))


static func max_stack(id: String) -> int:
	return int(get_item(id).get("stack", 99))


static func icon_texture(id: String) -> Texture2D:
	return _load_texture(str(get_item(id).get("icon_path", "")))


## Icon giao diện tuỳ chọn (bag, pickup, chop, smash); trả về null nếu chưa có file.
static func ui_icon(icon_name: String) -> Texture2D:
	return _load_texture(UI_ICON_DIR + icon_name + ".png")


static func _load_texture(path: String) -> Texture2D:
	if path == "":
		return null
	if _texture_cache.has(path):
		return _texture_cache[path]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path) as Texture2D
	_texture_cache[path] = tex
	return tex


static func _read_json(path: String):
	var res = load(path)
	if res is JSON:
		return res.data
	var text := FileAccess.get_file_as_string(path) # dự phòng; khi xuất game nhớ thêm *.json vào Export > Resources > Filters
	return JSON.parse_string(text) if not text.is_empty() else null
