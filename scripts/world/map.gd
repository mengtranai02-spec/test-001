extends Node2D

## Đổi seed: mọi thay đổi vật thể (cây đã chặt, đá đã nhặt...) bị xoá cùng thế giới cũ.
signal world_reset
signal map_expanded                      # vùng nhìn thấy thay đổi (giữ lại để tương thích)
signal chunk_built(coord: Vector2i)      # một chunk vừa được dựng xong (kể cả chunk load lại)

## Infinite, deterministic isometric terrain - chunk streaming + shader blend.
##
## Ý tưởng:
## - Texture được chiếu theo toạ độ THẾ GIỚI (không còn dán lại từng tile), nên
##   cùng loại đất liền nhau sẽ thành một mảng liền mạch, phẳng như mặt sàn.
## - Mỗi chunk có một "weight map" nhỏ (RGBA = nước/cát/đất/cỏ) lấy mẫu liên tục
##   từ noise (độ phân giải WEIGHT_RES texel / tile). Shader nội suy + trộn theo
##   kiểu height-blend có nhiễu => ranh giới giữa các loại cong, mềm, tự nhiên.
## - Mỗi chunk chỉ là 1 polygon / 1 draw call, vẽ một lần rồi được Godot cache.
## - Dữ liệu chunk sinh ở thread nền, build mỗi frame có giới hạn => không giật.

# Ô iso đơn vị: 128 x 64 px (mỗi cạnh gấp 2 => diện tích gấp 4 so với ô cũ 64 x 32).
# Toạ độ ô (x, y): đi qua 1 ô thì x hoặc y tăng/giảm đúng 1.
const TILE_W := 128.0
const TILE_H := 64.0

# --- streaming ---
const CHUNK_SIZE := 16            # số ô mỗi cạnh chunk (16 ô x 128px = 2048px)
const VIEW_MARGIN_CHUNKS := 1     # chunk dựng sẵn ngoài màn hình
const UNLOAD_MARGIN_CHUNKS := 2   # chunk xa hơn mức này mới bị xoá
const MAX_TASKS_IN_FLIGHT := 4    # số chunk sinh song song ở thread nền
const MAX_BUILDS_PER_FRAME := 2   # số chunk build tối đa mỗi frame
const VIEW_UNSET := 1 << 30       # giá trị đánh dấu "chưa có view"

# --- weight map / giao diện ---
const WEIGHT_RES := 8             # texel trên mỗi tile (8 = ranh giới chính xác 1/8 ô, độ phân giải ảnh giữ nguyên)
const WEIGHT_PAD := 1             # viền 1 texel để nội suy liền mạch giữa các chunk
const WEIGHT_TEXELS := CHUNK_SIZE * WEIGHT_RES + 2 * WEIGHT_PAD
const CHUNK_OVERLAP := 0.02       # lấn nhẹ (đơn vị tile) để không hở khe giữa chunk
const TEX_PERIOD_TILES := 3.0     # 1 texture phủ bao nhiêu tile (lớn hơn = ít lặp, mờ hơn)
const EDGE_PERIOD_TILES := 8.0   # chu kỳ lặp của noise làm cong ranh giới
const EDGE_JITTER := 0.22         # độ uốn lượn ranh giới
const EDGE_SOFTNESS := 0.14       # độ mềm ranh giới (nhỏ = sắc hơn)
const E_LAND := 0.02              # độ rộng chuyển tiếp theo noise địa hình
# Tần số noise nhân theo kích thước ô: ô 128x64 có cạnh gấp 2 ô cũ nên nhân 2 để địa hình giữ nguyên
# kích thước thật trên màn hình (đặt 1.0 nếu muốn địa hình to gấp đôi).
const NOISE_PER_TILE := 2.0
const ObjectDefs := preload("res://scripts/world/object_defs.gd")
const NightGlow := preload("res://scripts/world/night_glow.gd")
const PropColliders := preload("res://scripts/world/prop_colliders.gd")
# Lớp vẽ (z_index). Người chơi / mob / vật có che lấp nằm ở z = 0 và sắp xếp theo y.
const Z_TERRAIN := -4             # mặt đất
const Z_SHADOW := -3              # bóng: luôn dưới mọi sprite khác
const Z_GROUND_FX := -2           # hiệu ứng trải trên đất (vòng phép): chỉ đè lên mặt đất và bóng, dưới mọi vật thể kể cả khúc gỗ, đá nhỏ
const Z_FLAT_PROP := -1           # vật không che lấp (hoa, cỏ...) và khúc gỗ (hình bình hành): luôn bị người chơi / mob / vật khác đè lên
const PROPS_PER_FRAME := 60       # số sprite vật thể tạo tối đa mỗi frame (rải đều để không giật khi sang chunk mới)
const E_DETAIL := 0.05            # độ rộng chuyển tiếp theo noise chi tiết (đất)

# Ngưỡng noise địa hình: dưới LAND_MIN chắc chắn là nước, trên LAND_MAX chắc chắn là đất liền.
const LAND_MIN := -0.16 - E_LAND
const LAND_MAX := -0.16 + E_LAND

enum Tile { WATER, SAND, DIRT, GRASS } # thứ tự = kênh R,G,B,A của weight map

const GRASS := preload("res://assets/texture/grass.jpg")
const DIRT := preload("res://assets/texture/dirt.jpg")
const SAND := preload("res://assets/texture/sand.jpg")
const WATER := preload("res://assets/texture/water.jpg")


const TERRAIN_SHADER_PATH := "res://shaders/terrain.gdshader" # nạp bằng load() trong _ready (cần biến toàn cục day_tint có trước)
const SWAY_SHADER := preload("res://shaders/sway.gdshader")    # đung đưa cây / bụi / hoa / cỏ

## Nhóm vật thể đung đưa: id nhóm trong props.json -> kiểu đung đưa. Bỏ một nhóm khỏi đây để nhóm đó đứng yên.
const SWAY_GROUPS := {"tree": "tall", "bush": "low", "flower": "low", "tuft": "low"}
## Kiểu đung đưa -> {strength: px lệch ở ngọn, height: độ cao (px) đạt lệch tối đa}
const SWAY_PROFILES := {
	"tall": {"strength": 4.0, "height": 170.0},
	"low": {"strength": 3.0, "height": 60.0},
}

@export var world_seed: int = 7
## Giữ lại để tương thích code cũ; việc render giờ dựa vào camera/viewport.
var target: Node2D

var _land_noise := FastNoiseLite.new()
var _detail_noise := FastNoiseLite.new()
var _shore_noise := FastNoiseLite.new()

var _shader: Shader
var _edge_noise_tex: ImageTexture

var _chunks: Dictionary = {}     # Vector2i -> Chunk
var _inflight: Dictionary = {}   # Vector2i -> task id
var _queued: Dictionary = {}     # Vector2i -> true (chống trùng hàng đợi)
var _queue: Array[Vector2i] = []
var _ready_results: Array = []   # kết quả đã sinh, chờ build
var _results: Array = []         # thread nền ghi vào (có mutex)
var _result_mutex := Mutex.new()

var _view_min := Vector2i(VIEW_UNSET, VIEW_UNSET)
var _view_max := Vector2i(-VIEW_UNSET, -VIEW_UNSET)
var _keep_min := Vector2i.ZERO   # vùng giữ chunk = view + UNLOAD_MARGIN_CHUNKS
var _keep_max := Vector2i.ZERO
var show_iso_grid := false
var show_chunk_grid := false
var show_colliders := false          # vẽ collider vật thể để chỉnh dữ liệu trong props.json

## Node chứa sprite vật thể. PHẢI là node bật y_sort_enabled chung với người chơi / mob (world.gd gán).
var object_root: Node2D
var _forest_noise := FastNoiseLite.new()
var _prop_colliders := PropColliders.new(TILE_W, TILE_H) # collider vật thể tĩnh (xem prop_colliders.gd)
var _chunk_props: Dictionary = {}    # Vector2i (chunk) -> Array[Node2D] sprite đã tạo
var _chunk_pending: Dictionary = {}  # Vector2i (chunk) -> Array vật thể chờ tạo sprite
var _prop_textures: Dictionary = {}  # tên -> AtlasTexture dùng chung
var _sway_materials: Dictionary = {} # kiểu đung đưa -> ShaderMaterial dùng chung
var _prop_overrides: Dictionary = {}  # Vector2i (khoá vị trí vật thể) -> tên sprite thay thế ("" = đã biến mất): cây đã chặt, đá đã nhặt...
var _chunk_prop_data: Dictionary = {} # Vector2i (chunk) -> Array vật thể đang sống [tên, tx, ty, scale] (đã áp _prop_overrides)
var _prop_nodes: Dictionary = {}      # Vector2i (khoá vị trí) -> Sprite2D đã tạo
static var _day_tint_declared := false # biến toàn cục day_tint chỉ được tạo một lần mỗi lần chạy game

## Node vẽ 1 chunk: 1 polygon + ShaderMaterial. Lệnh vẽ được cache, không redraw mỗi frame.
class Chunk extends Node2D:
	var points := PackedVector2Array()
	var uvs := PackedVector2Array()

	func _draw() -> void:
		draw_colored_polygon(points, Color.WHITE, uvs)


func _ready() -> void:
	var grid := Node2D.new()
	grid.set_script(preload("res://scripts/world/grid_overlay.gd"))
	grid.z_index = 10
	add_child(grid)
	ObjectDefs.ensure_loaded()
	# Shader mặt đất khai báo "global uniform day_tint" nên biến này phải tồn tại TRƯỚC khi nạp shader (world.gd đặt giá trị mỗi frame).
	# Nếu bạn đã khai báo day_tint (Color) trong Project Settings > Globals > Shader Globals thì bỏ qua bước tạo.
	# (global_shader_parameter_get_list() chỉ dùng được trong editor nên dùng cờ static để không tạo trùng.)
	if not _day_tint_declared and not ProjectSettings.has_setting("shader_globals/day_tint"):
		RenderingServer.global_shader_parameter_add("day_tint", RenderingServer.GLOBAL_VAR_TYPE_COLOR, Color.WHITE)
	_day_tint_declared = true
	NightGlow.declare_globals() # fx_light0..3 / fx_color0..3: nguồn sáng (lửa, ma pháp) chiếu lên mặt đất, phải có trước khi nạp shader
	_shader = load(TERRAIN_SHADER_PATH)
	_make_sway_materials()
	_edge_noise_tex = _make_edge_noise()
	_apply_seed()


## Mỗi kiểu đung đưa chỉ một material cho mọi vật thể => ít vỡ batching, không tốn thêm node.
func _make_sway_materials() -> void:
	for kind in SWAY_PROFILES:
		var m := ShaderMaterial.new()
		m.shader = SWAY_SHADER
		m.set_shader_parameter("strength", SWAY_PROFILES[kind]["strength"])
		m.set_shader_parameter("height", SWAY_PROFILES[kind]["height"])
		_sway_materials[kind] = m


func _exit_tree() -> void:
	_wait_all_tasks()


func set_world_seed(value: int) -> void:
	_wait_all_tasks()
	world_seed = value
	_prop_overrides.clear() # thế giới mới: bỏ mọi thay đổi vật thể của thế giới cũ
	_clear_all()
	_apply_seed()
	world_reset.emit()


func _apply_seed() -> void:
	_land_noise.seed = world_seed
	_land_noise.frequency = 0.004 * NOISE_PER_TILE
	_land_noise.fractal_octaves = 4
	_land_noise.fractal_gain = 0.48
	_detail_noise.seed = world_seed ^ 0x51A7
	_detail_noise.frequency = 0.025 * NOISE_PER_TILE
	_detail_noise.fractal_octaves = 3
	_shore_noise.seed = world_seed ^ 0x2D31
	_shore_noise.frequency = 0.009 * NOISE_PER_TILE
	_shore_noise.fractal_octaves = 2
	_forest_noise.seed = world_seed ^ 0x7F3A
	_forest_noise.frequency = 0.03   # đơn vị: ô. Mảng rừng rộng cỡ vài chục ô
	_forest_noise.fractal_octaves = 2


func _process(_delta: float) -> void:
	_update_view_range()
	_dispatch_tasks()
	_collect_results()
	_build_ready_chunks()
	_spawn_pending_props()
	if show_iso_grid or show_chunk_grid:
		queue_redraw()

func world_to_tile(world_pos: Vector2) -> Vector2:
	return _screen_to_tile(to_local(world_pos))

## Toạ độ thế giới (global) của điểm (tx, ty) trong không gian ô (ngược lại với world_to_tile).
func tile_to_world(tx: float, ty: float) -> Vector2:
	return to_global(_tile_to_screen(tx, ty))

const COLOR_WATER := Color("2879b5")
const COLOR_SAND := Color("d8c477")
const COLOR_DIRT := Color("896044")
const COLOR_GRASS := Color("5f9b55")

func terrain_color_at_tile(tx: float, ty: float) -> Color:
	var s := _height_at(tx, ty)
	if s <= LAND_MIN:
		return COLOR_WATER # chắc chắn là nước, bỏ qua noise chi tiết
	match _dominant_tile(_weights_from_height(tx, ty, s)):
		Tile.WATER: return COLOR_WATER
		Tile.SAND: return COLOR_SAND
		Tile.DIRT: return COLOR_DIRT
		_: return COLOR_GRASS

func _draw() -> void:
	return

func draw_grid(overlay: CanvasItem) -> void:
	if show_colliders:
		_draw_colliders(overlay)
	if not show_iso_grid and not show_chunk_grid:
		return
	var inv := get_viewport().get_canvas_transform().affine_inverse()
	var rect := get_viewport_rect()
	var corners := [inv * rect.position, inv * Vector2(rect.end.x, rect.position.y), inv * rect.end, inv * Vector2(rect.position.x, rect.end.y)]
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in corners:
		var t := _screen_to_tile(to_local(p))
		lo = lo.min(t); hi = hi.max(t)
	var step := 1 if show_iso_grid else CHUNK_SIZE
	var first_x := floori(lo.x / step) * step
	var first_y := floori(lo.y / step) * step
	for x in range(first_x, ceili(hi.x) + step, step):
		var strong := x % CHUNK_SIZE == 0
		if show_iso_grid or (show_chunk_grid and strong):
			var a := to_global(_tile_to_screen(x, lo.y - 2))
			var b := to_global(_tile_to_screen(x, hi.y + 2))
			overlay.draw_line(to_local(a), to_local(b), Color(1, 1, 1, 0.25 if strong else 0.10), 1.0)
	for y in range(first_y, ceili(hi.y) + step, step):
		var strong := y % CHUNK_SIZE == 0
		if show_iso_grid or (show_chunk_grid and strong):
			var a := to_global(_tile_to_screen(lo.x - 2, y))
			var b := to_global(_tile_to_screen(hi.x + 2, y))
			overlay.draw_line(to_local(a), to_local(b), Color(1, 1, 1, 0.25 if strong else 0.10), 1.0)


## Vẽ viền collider (đỏ) để canh chỉnh offset / radius trong props.json.
func _draw_colliders(overlay: CanvasItem) -> void:
	_prop_colliders.draw_debug(overlay, Color(1.0, 0.2, 0.2, 0.9))
	_draw_body_colliders(overlay)
	overlay.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## Collider của người chơi và mob (node thuộc nhóm "collider_debug"), màu xanh.
## Chữ thập vàng = điểm chân (kiểm tra đất); đoạn vàng ngang = đoạn chân (nửa dài = radius.x của elip), dùng để kiểm tra va chạm với collider vật thể.
func _draw_body_colliders(overlay: CanvasItem) -> void:
	var green := Color(0.2, 1.0, 0.3, 0.95)
	var yellow := Color(1.0, 0.9, 0.2, 1.0)
	var inv := overlay.get_global_transform().affine_inverse()
	for node in get_tree().get_nodes_in_group("collider_debug"):
		var body := node as Node2D
		if body == null or not body.is_visible_in_tree():
			continue
		for child in body.get_children():
			var cs := child as CollisionShape2D
			if cs == null or cs.shape == null or cs.disabled:
				continue
			overlay.draw_set_transform_matrix(inv * cs.get_global_transform())
			var circle := cs.shape as CircleShape2D
			var rect := cs.shape as RectangleShape2D
			var capsule := cs.shape as CapsuleShape2D
			var poly := cs.shape as ConvexPolygonShape2D
			if poly != null: # elip của player / mob được dựng từ đa giác lồi
				var outline := poly.points.duplicate()
				if not outline.is_empty():
					outline.append(outline[0])
					overlay.draw_polyline(outline, green, 1.5)
			elif circle != null:
				overlay.draw_arc(Vector2.ZERO, circle.radius, 0.0, TAU, 24, green, 1.5)
			elif rect != null:
				overlay.draw_rect(Rect2(-rect.size * 0.5, rect.size), green, false, 1.5)
			elif capsule != null:
				var half := maxf(capsule.height * 0.5 - capsule.radius, 0.0)
				var r := capsule.radius
				overlay.draw_arc(Vector2(0, -half), r, PI, TAU, 12, green, 1.5)
				overlay.draw_arc(Vector2(0, half), r, 0.0, PI, 12, green, 1.5)
				overlay.draw_line(Vector2(-r, -half), Vector2(-r, half), green, 1.5)
				overlay.draw_line(Vector2(r, -half), Vector2(r, half), green, 1.5)
		overlay.draw_set_transform_matrix(inv * body.get_global_transform())
		overlay.draw_line(Vector2(-6, 0), Vector2(6, 0), yellow, 2.0)
		var foot_hw := float(body.get_meta("foot_half_width", 0.0)) # đoạn chân dùng để chắn bởi vật tĩnh
		if foot_hw > 0.0:
			overlay.draw_line(Vector2(-foot_hw, 0), Vector2(foot_hw, 0), yellow, 3.0)
		overlay.draw_line(Vector2(0, -6), Vector2(0, 6), yellow, 2.0)
	overlay.draw_set_transform_matrix(Transform2D.IDENTITY)


# ---------------------------------------------------------------- streaming

func _update_view_range() -> void:
	var canvas_to_world := get_viewport().get_canvas_transform().affine_inverse()
	var size := get_viewport_rect().size
	var corners := PackedVector2Array([
		Vector2.ZERO, Vector2(size.x, 0), size, Vector2(0, size.y)
	])
	var min_tile := Vector2(INF, INF)
	var max_tile := Vector2(-INF, -INF)
	for corner in corners:
		var t := _screen_to_tile(to_local(canvas_to_world * corner))
		min_tile.x = minf(min_tile.x, t.x)
		min_tile.y = minf(min_tile.y, t.y)
		max_tile.x = maxf(max_tile.x, t.x)
		max_tile.y = maxf(max_tile.y, t.y)

	var new_min := Vector2i(
		floori(min_tile.x / CHUNK_SIZE) - VIEW_MARGIN_CHUNKS,
		floori(min_tile.y / CHUNK_SIZE) - VIEW_MARGIN_CHUNKS)
	var new_max := Vector2i(
		floori(max_tile.x / CHUNK_SIZE) + VIEW_MARGIN_CHUNKS,
		floori(max_tile.y / CHUNK_SIZE) + VIEW_MARGIN_CHUNKS)
	if new_min == _view_min and new_max == _view_max:
		return
	var is_first_view := _view_min.x == VIEW_UNSET
	_view_min = new_min
	_view_max = new_max
	_keep_min = _view_min - Vector2i.ONE * UNLOAD_MARGIN_CHUNKS
	_keep_max = _view_max + Vector2i.ONE * UNLOAD_MARGIN_CHUNKS
	if not is_first_view:
		map_expanded.emit()

	# Xếp chunk còn thiếu vào hàng đợi, gần tâm màn hình được sinh trước.
	for cy in range(_view_min.y, _view_max.y + 1):
		for cx in range(_view_min.x, _view_max.x + 1):
			var c := Vector2i(cx, cy)
			if _chunks.has(c) or _inflight.has(c) or _queued.has(c):
				continue
			_queued[c] = true
			_queue.append(c)
	var mid := Vector2i((Vector2(_view_min + _view_max) * 0.5).floor()) # tâm vùng nhìn (chia số thực, không còn cảnh báo chia nguyên)
	_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.distance_squared_to(mid) < b.distance_squared_to(mid))

	# Giải phóng chunk đã ra xa.
	for c: Vector2i in _chunks.keys():
		if not _in_range(c, _keep_min, _keep_max):
			_free_chunk(c)


func _dispatch_tasks() -> void:
	while not _queue.is_empty() and _inflight.size() < MAX_TASKS_IN_FLIGHT:
		var c: Vector2i = _queue.pop_front()
		_queued.erase(c)
		if _chunks.has(c) or _inflight.has(c) or not _in_range(c, _view_min, _view_max):
			continue
		_inflight[c] = WorkerThreadPool.add_task(_generate_chunk_task.bind(c))


## Chạy ở thread nền: chỉ ĐỌC noise, không đụng tới scene tree.
## Sinh weight map RGBA8 (WEIGHT_TEXELS^2) cho chunk, có viền PAD để liền mạch.
func _generate_chunk_task(coord: Vector2i) -> void:
	var data := PackedByteArray()
	data.resize(WEIGHT_TEXELS * WEIGHT_TEXELS * 4)
	var ox := float(coord.x * CHUNK_SIZE)
	var oy := float(coord.y * CHUNK_SIZE)
	var idx := 0
	for j in WEIGHT_TEXELS:
		var py := oy + (j + 0.5 - WEIGHT_PAD) / WEIGHT_RES
		for i in WEIGHT_TEXELS:
			var px := ox + (i + 0.5 - WEIGHT_PAD) / WEIGHT_RES
			var w := _weights_at(px, py)
			data[idx] = roundi(w.r * 255.0)
			data[idx + 1] = roundi(w.g * 255.0)
			data[idx + 2] = roundi(w.b * 255.0)
			data[idx + 3] = roundi(w.a * 255.0)
			idx += 4
	var props := _scatter_props(coord, data)
	_result_mutex.lock()
	_results.append({"coord": coord, "data": data, "props": props})
	_result_mutex.unlock()


func _collect_results() -> void:
	_result_mutex.lock()
	var got := _results
	_results = []
	_result_mutex.unlock()
	for r in got:
		var c: Vector2i = r["coord"]
		if _inflight.has(c):
			WorkerThreadPool.wait_for_task_completion(_inflight[c])
			_inflight.erase(c)
		_ready_results.append(r)


func _build_ready_chunks() -> void:
	var built := 0
	while not _ready_results.is_empty() and built < MAX_BUILDS_PER_FRAME:
		var r: Dictionary = _ready_results.pop_front()
		var c: Vector2i = r["coord"]
		if _chunks.has(c) or not _in_range(c, _keep_min, _keep_max):
			continue
		_chunks[c] = _build_chunk(c, r["data"])
		_register_props(c, r["props"])
		built += 1
		chunk_built.emit(c)


# ---------------------------------------------------------------- build

func _build_chunk(coord: Vector2i, data: PackedByteArray) -> Chunk:
	var img := Image.create_from_data(WEIGHT_TEXELS, WEIGHT_TEXELS, false, Image.FORMAT_RGBA8, data)
	var weight_tex := ImageTexture.create_from_image(img)

	var s := float(CHUNK_SIZE)
	var e := CHUNK_OVERLAP
	var tile_corners := PackedVector2Array([
		Vector2(-e, -e), Vector2(s + e, -e), Vector2(s + e, s + e), Vector2(-e, s + e)
	])
	var chunk := Chunk.new()
	chunk.position = _tile_to_screen(coord.x * CHUNK_SIZE, coord.y * CHUNK_SIZE)
	for tc in tile_corners:
		chunk.points.append(_tile_to_screen(tc.x, tc.y))
	chunk.uvs = tile_corners # UV = toạ độ tile cục bộ
	chunk.material = _make_material(weight_tex, coord)
	add_child(chunk)
	return chunk


func _make_material(weight_tex: Texture2D, coord: Vector2i) -> ShaderMaterial:
	var ox := float(coord.x * CHUNK_SIZE)
	var oy := float(coord.y * CHUNK_SIZE)
	var m := ShaderMaterial.new()
	m.shader = _shader
	m.set_shader_parameter("weight_map", weight_tex)
	m.set_shader_parameter("edge_noise", _edge_noise_tex)
	m.set_shader_parameter("tex_water", WATER)
	m.set_shader_parameter("tex_sand", SAND)
	m.set_shader_parameter("tex_dirt", DIRT)
	m.set_shader_parameter("tex_grass", GRASS)
	# Wrap gốc chunk theo chu kỳ để giữ độ chính xác float ở toạ độ rất xa.
	m.set_shader_parameter("tex_origin", Vector2(fposmod(ox, TEX_PERIOD_TILES), fposmod(oy, TEX_PERIOD_TILES)))
	m.set_shader_parameter("edge_origin", Vector2(fposmod(ox, EDGE_PERIOD_TILES), fposmod(oy, EDGE_PERIOD_TILES)))
	m.set_shader_parameter("tex_period", TEX_PERIOD_TILES)
	m.set_shader_parameter("edge_period", EDGE_PERIOD_TILES)
	m.set_shader_parameter("weight_scale", float(WEIGHT_RES) / WEIGHT_TEXELS)
	m.set_shader_parameter("weight_bias", float(WEIGHT_PAD) / WEIGHT_TEXELS)
	m.set_shader_parameter("edge_jitter", EDGE_JITTER)
	m.set_shader_parameter("edge_softness", EDGE_SOFTNESS)
	return m


## Texture nhiễu 4 kênh độc lập, tileable, dùng để uốn cong ranh giới trong shader.
func _make_edge_noise() -> ImageTexture:
	var size := 128
	var data := PackedByteArray()
	data.resize(size * size * 4)
	for c in 4:
		var n := FastNoiseLite.new()
		n.seed = 1000 + c * 77
		n.frequency = 0.05
		n.fractal_octaves = 3
		var img := n.get_seamless_image(size, size)
		if img.get_format() != Image.FORMAT_L8:
			img.convert(Image.FORMAT_L8)
		var bytes := img.get_data()
		for i in size * size:
			data[i * 4 + c] = bytes[i]
	var out := Image.create_from_data(size, size, false, Image.FORMAT_RGBA8, data)
	return ImageTexture.create_from_image(out)


# ---------------------------------------------------------------- terrain

## Noise địa hình tổng hợp (quyết định nước / đất liền).
func _height_at(px: float, py: float) -> float:
	return _land_noise.get_noise_2d(px, py) + _shore_noise.get_noise_2d(px, py) * 0.08


## Trọng số 4 loại đất tại điểm liên tục (px, py) trong không gian tile.
func _weights_at(px: float, py: float) -> Color:
	return _weights_from_height(px, py, _height_at(px, py))


## Tổng = 1. Dùng smoothstep nên ranh giới là đường đồng mức của noise
## => cong mượt, không bị gấp khúc theo lưới tile.
func _weights_from_height(px: float, py: float, s: float) -> Color:
	var d := _detail_noise.get_noise_2d(px, py)
	var land := smoothstep(LAND_MIN, LAND_MAX, s)
	var inland := smoothstep(-0.04 - E_LAND, -0.04 + E_LAND, s)
	var dirt := smoothstep(0.30 - E_DETAIL, 0.30 + E_DETAIL, d)
	var sand_in := (1.0 - smoothstep(0.10 - E_LAND, 0.10 + E_LAND, s)) \
		* smoothstep(-0.18 - E_DETAIL, -0.18 + E_DETAIL, d)
	return Color(
		1.0 - land,
		land * (1.0 - inland) + inland * (1.0 - dirt) * sand_in,
		inland * dirt,
		inland * (1.0 - dirt) * (1.0 - sand_in))


func _dominant_tile(w: Color) -> int:
	var best := Tile.WATER
	var best_w := w.r
	if w.g > best_w:
		best = Tile.SAND
		best_w = w.g
	if w.b > best_w:
		best = Tile.DIRT
		best_w = w.b
	if w.a > best_w:
		best = Tile.GRASS
	return best


## Đất hay nước tại toạ độ tile. Kết quả giống hệt _dominant_tile(_weights_at) != WATER,
## nhưng bỏ qua noise chi tiết khi chắc chắn là nước (land = 0) hoặc đất liền (land = 1).
func _is_land_tile(tx: float, ty: float) -> bool:
	var s := _height_at(tx, ty)
	if s <= LAND_MIN:
		return false
	if s >= LAND_MAX:
		return true
	return _dominant_tile(_weights_from_height(tx, ty, s)) != Tile.WATER


## Loại đất (enum Tile) tại một vị trí thế giới - dùng cho gameplay (nước, spawn...).
func get_terrain_at(world_pos: Vector2) -> int:
	var t := _screen_to_tile(to_local(world_pos))
	return _dominant_tile(_weights_at(t.x, t.y))


func is_land_at(world_pos: Vector2) -> bool:
	var t := _screen_to_tile(to_local(world_pos))
	return _is_land_tile(t.x, t.y)


## Vị trí này có nằm trong collider của vật thể (cây, đá...) không.
func is_blocked_at(world_pos: Vector2) -> bool:
	return _prop_colliders.is_blocked_at(to_local(world_pos))


## Chân nhân vật là đoạn thẳng nằm ngang tại world_pos, nửa dài half_width (px): có cắt / nằm trong
## collider vật thể nào không. half_width <= 0 thì quay về kiểm tra một điểm.
func is_segment_blocked_at(world_pos: Vector2, half_width: float) -> bool:
	if half_width <= 0.0:
		return is_blocked_at(world_pos)
	return _prop_colliders.is_segment_blocked(
		to_local(world_pos + Vector2(-half_width, 0.0)),
		to_local(world_pos + Vector2(half_width, 0.0)))


## Đi từ from_pos tới to_pos có được không: điểm chân phải là đất và đoạn chân (nửa dài half_width)
## không chạm collider. Nếu đang đứng sẵn trong collider (vd mob sinh ra sát cây) thì vẫn cho đi ra.
func can_walk(from_pos: Vector2, to_pos: Vector2, half_width: float = 0.0) -> bool:
	return is_land_at(to_pos) and (not is_segment_blocked_at(to_pos, half_width) or is_segment_blocked_at(from_pos, half_width))


func find_nearest_land(world_pos: Vector2, max_radius: float = 1200.0, step: float = 24.0) -> Vector2:
	if is_land_at(world_pos):
		return world_pos
	var radius := step
	while radius <= max_radius:
		var samples := maxi(8, ceili(TAU * radius / step))
		for i in samples:
			var angle := TAU * float(i) / float(samples)
			var candidate := world_pos + Vector2(cos(angle), sin(angle)) * radius
			if is_land_at(candidate):
				return candidate
		radius += step
	return world_pos


# ---------------------------------------------------------------- vật thể (cây, đá, hoa...)

## Chạy ở thread nền. Kết quả chỉ phụ thuộc seed + toạ độ chunk => chunk nạp lại vẫn y hệt.
## Mỗi phần tử: [tên, tx, ty, hệ số scale của nhóm].
func _scatter_props(coord: Vector2i, data: PackedByteArray) -> Array:
	var out: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(world_seed, coord.x, coord.y))
	var occupied := {}
	var ox := float(coord.x * CHUNK_SIZE)
	var oy := float(coord.y * CHUNK_SIZE)
	for ly in CHUNK_SIZE:
		for lx in CHUNK_SIZE:
			# Luôn bốc đủ 4 số ngẫu nhiên mỗi ô để kết quả ổn định dù ô bị bỏ qua.
			var r1 := rng.randf()
			var r2 := rng.randf()
			var u := lx + 0.15 + 0.7 * rng.randf()
			var v := ly + 0.15 + 0.7 * rng.randf()
			if occupied.has(Vector2i(lx, ly)):
				continue
			var tx := ox + u
			var ty := oy + v
			if absf(tx) < 2.0 and absf(ty) < 2.0:
				continue # chừa chỗ xuất phát của người chơi
			var texel := ((WEIGHT_PAD + int(v * WEIGHT_RES)) * WEIGHT_TEXELS + WEIGHT_PAD + int(u * WEIGHT_RES)) * 4
			if data[texel] > 60:
				continue # sát mép nước
			var ground := _dominant_tile(Color8(data[texel], data[texel + 1], data[texel + 2], data[texel + 3]))
			var forest := smoothstep(0.05, 0.45, _forest_noise.get_noise_2d(tx, ty))
			var pick := ObjectDefs.pick(ground, forest, r1, r2)
			if pick.is_empty():
				continue
			var g: Dictionary = pick["group"]
			var spacing: int = g["spacing"]
			for dy in range(-spacing, spacing + 1):
				for dx in range(-spacing, spacing + 1):
					occupied[Vector2i(lx + dx, ly + dy)] = true
			out.append([pick["name"], tx, ty, g["scale"]])
	return out


## Ghi nhận collider ngay (để gameplay đúng), còn sprite thì tạo dần qua nhiều frame.
func _register_props(coord: Vector2i, props: Array) -> void:
	# Áp các thay đổi người chơi đã làm (cây đã chặt -> gốc cây, đá đã nhặt -> biến mất) lên vật thể sinh theo seed.
	var live: Array = []
	for p in props:
		var key := prop_key(p[1], p[2])
		if not _prop_overrides.has(key):
			live.append(p)
			continue
		var replacement: String = _prop_overrides[key]
		if replacement != "":
			live.append([replacement, p[1], p[2], _group_scale(replacement)])
	_chunk_prop_data[coord] = live
	_prop_colliders.register_chunk(coord, live)
	_chunk_props[coord] = []
	_chunk_pending[coord] = live.duplicate()


func _spawn_pending_props() -> void:
	if _chunk_pending.is_empty():
		return
	var budget := PROPS_PER_FRAME
	for c: Vector2i in _chunk_pending.keys():
		var list: Array = _chunk_pending[c]
		var nodes: Array = _chunk_props[c]
		while budget > 0 and not list.is_empty():
			var p: Array = list.pop_back()
			var node := _make_prop(p)
			nodes.append(node)
			_prop_nodes[prop_key(p[1], p[2])] = node
			budget -= 1
		if list.is_empty():
			_chunk_pending.erase(c)
		if budget <= 0:
			break


func _make_prop(p: Array) -> Sprite2D:
	var def: Dictionary = ObjectDefs.sprites[p[0]]
	var tex := _prop_texture(p[0])
	var size := tex.get_size()
	var sc: float = ObjectDefs.object_scale * float(p[3])
	var col: Dictionary = def["collider"]
	var foot := _tile_to_screen(p[1], p[2]) # giữa cạnh đáy sprite (toạ độ cục bộ của map)
	# Gốc node = điểm xét y-sort = tâm collider (elip, hình thoi, chữ nhật, hình bình hành); không có collider thì giữa đáy.
	# Vật nằm thấp hơn trên màn hình thì vẽ đè lên. Sprite dịch ngược lại để giữa đáy ảnh vẫn nằm đúng tại foot.
	var anchor: Vector2 = col["offset"] if not col.is_empty() else Vector2.ZERO
	var s := Sprite2D.new()
	s.texture = tex
	s.centered = false
	s.offset = Vector2(-size.x * 0.5, -size.y) - anchor
	s.scale = Vector2.ONE * sc
	s.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var sway_kind: String = SWAY_GROUPS.get(ObjectDefs.groups[def["group"]]["id"], "")
	if sway_kind != "":
		s.material = _sway_materials[sway_kind] # bóng (con) không dùng material này nên đứng yên
	# Không che lấp (hoa, cỏ...) hoặc collider hình bình hành (khúc gỗ): nằm dưới lớp z = 0 nơi player / mob / vật khác đứng
	# => luôn bị đè lên. Các vật cùng lớp này vẫn xếp trước/sau với nhau theo y.
	if not def["occludes"] or (not col.is_empty() and int(col["shape"]) == 2):
		s.z_index = Z_FLAT_PROP
	if def["shadow"]:
		# Bóng là con của sprite (cùng vị trí, scale, offset) nhưng ở lớp z riêng nên luôn bị sprite khác đè lên.
		var sh := Sprite2D.new()
		sh.texture = _prop_texture(p[0], true)
		sh.centered = false
		sh.offset = s.offset
		sh.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		sh.z_as_relative = false
		sh.z_index = Z_SHADOW
		s.add_child(sh)
	var root: Node2D = object_root if is_instance_valid(object_root) else self
	s.position = root.to_local(to_global(foot + anchor * sc))
	root.add_child(s)
	return s


func _prop_texture(prop_name: String, shadow := false) -> AtlasTexture:
	var key := ("s:" + prop_name) if shadow else prop_name
	var t: AtlasTexture = _prop_textures.get(key)
	if t == null:
		t = AtlasTexture.new()
		# Mọi vật thể chung 1 ảnh => gộp draw call. Bóng dùng đúng rect của sprite chính trong sheet bóng.
		t.atlas = ObjectDefs.shadow_sheet if shadow else ObjectDefs.sheet
		t.region = ObjectDefs.sprites[prop_name]["rect"]
		t.filter_clip = true       # không lẫn viền vật thể bên cạnh trong sheet
		_prop_textures[key] = t
	return t


## Xoá chunk cùng toàn bộ vật thể và ô chắn của nó.
func _free_chunk(c: Vector2i) -> void:
	var chunk = _chunks.get(c)
	if chunk != null:
		chunk.queue_free()
	_chunks.erase(c)
	for n in _chunk_props.get(c, []):
		if is_instance_valid(n):
			n.queue_free()
	_chunk_props.erase(c)
	_chunk_pending.erase(c)
	for p in _chunk_prop_data.get(c, []):
		_prop_nodes.erase(prop_key(p[1], p[2]))
	_chunk_prop_data.erase(c)
	_prop_colliders.unregister_chunk(c)


# ---------------------------------------------------------------- vật thể tương tác (chặt cây, nhặt đá...)

## Khoá nhận dạng một vật thể: vị trí ô (số thực) làm tròn. Ổn định theo seed nên dùng được cho thay đổi lâu dài.
func prop_key(tx: float, ty: float) -> Vector2i:
	return Vector2i(roundi(tx * 64.0), roundi(ty * 64.0))


## Các vật thể (đã có sprite) trong bán kính radius_tiles ô quanh world_pos, mỗi phần tử:
## {key, name, group (id nhóm trong props.json), world (vị trí chân, toạ độ thế giới), dist (đơn vị ô)}.
func find_gatherables(world_pos: Vector2, radius_tiles: float) -> Array:
	var out: Array = []
	var t := world_to_tile(world_pos)
	var c := Vector2i(floori(t.x / CHUNK_SIZE), floori(t.y / CHUNK_SIZE))
	var r2 := radius_tiles * radius_tiles
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var data = _chunk_prop_data.get(Vector2i(c.x + dx, c.y + dy))
			if data == null:
				continue
			for p in data:
				var d := Vector2(p[1], p[2]) - t
				if d.length_squared() > r2:
					continue
				var key := prop_key(p[1], p[2])
				if not _prop_nodes.has(key):
					continue # sprite chưa tạo xong (chunk mới dựng)
				var group_id: String = ObjectDefs.groups[ObjectDefs.sprites[p[0]]["group"]]["id"]
				out.append({"key": key, "name": p[0], "group": group_id, "world": tile_to_world(p[1], p[2]), "dist": d.length()})
	return out


func get_prop_node(key: Vector2i) -> Sprite2D:
	var n = _prop_nodes.get(key)
	return n if is_instance_valid(n) else null


## Đổi vật thể tại key sang sprite new_name ("" = xoá hẳn): cập nhật sprite, collider và nhớ lại để chunk dựng lại vẫn đúng.
func replace_prop(key: Vector2i, new_name: String) -> void:
	var c := Vector2i(floori(key.x / 64.0 / CHUNK_SIZE), floori(key.y / 64.0 / CHUNK_SIZE))
	var data: Array = _chunk_prop_data.get(c, [])
	var found := -1
	for i in data.size():
		if prop_key(data[i][1], data[i][2]) == key:
			found = i
			break
	if found < 0:
		return
	var old: Array = data[found]
	_prop_overrides[key] = new_name
	var old_node = _prop_nodes.get(key)
	if old_node != null:
		_chunk_props[c].erase(old_node)
		if is_instance_valid(old_node):
			old_node.queue_free()
		_prop_nodes.erase(key)
	if new_name == "":
		data.remove_at(found)
	else:
		var replacement := [new_name, old[1], old[2], _group_scale(new_name)]
		data[found] = replacement
		var node := _make_prop(replacement)
		_chunk_props[c].append(node)
		_prop_nodes[key] = node
	_prop_colliders.unregister_chunk(c)
	_prop_colliders.register_chunk(c, data)


func _group_scale(sprite_name: String) -> float:
	return float(ObjectDefs.groups[ObjectDefs.sprites[sprite_name]["group"]]["scale"])


## Danh sách thay đổi vật thể để lưu game: [[x, y, "tên sprite" hoặc ""], ...]. Khôi phục bằng import_prop_overrides
## (gọi SAU set_world_seed, trước khi chunk dựng xong, vì đổi seed sẽ xoá các thay đổi).
func export_prop_overrides() -> Array:
	var out: Array = []
	for key: Vector2i in _prop_overrides:
		out.append([key.x, key.y, _prop_overrides[key]])
	return out


func import_prop_overrides(list: Array) -> void:
	_prop_overrides.clear()
	for e in list:
		_prop_overrides[Vector2i(int(e[0]), int(e[1]))] = str(e[2])


# ---------------------------------------------------------------- chunk API (cho mob / gameplay)

## Chunk chứa một vị trí thế giới.
func world_to_chunk(world_pos: Vector2) -> Vector2i:
	var t := _screen_to_tile(to_local(world_pos))
	return Vector2i(floori(t.x / CHUNK_SIZE), floori(t.y / CHUNK_SIZE))


## true nếu chunk nằm trong vùng nhìn thấy + margin (đơn vị chunk).
func is_chunk_near_view(c: Vector2i, margin: int = 1) -> bool:
	return _in_range(c, _view_min - Vector2i.ONE * margin, _view_max + Vector2i.ONE * margin)


## Khoảng chunk đang nhìn thấy + margin (Rect2i theo đơn vị chunk). Rect rỗng nếu chưa có view.
func get_chunk_range(margin: int = 0) -> Rect2i:
	if _view_min.x == VIEW_UNSET:
		return Rect2i()
	var lo := _view_min - Vector2i.ONE * margin
	var hi := _view_max + Vector2i.ONE * margin
	return Rect2i(lo, hi - lo + Vector2i.ONE)


## true nếu điểm thế giới nằm trong khung nhìn camera (mở rộng thêm margin pixel).
func is_world_pos_on_screen(world_pos: Vector2, margin: float = 0.0) -> bool:
	var screen_pos := get_viewport().get_canvas_transform() * world_pos
	return get_viewport_rect().grow(margin).has_point(screen_pos)


## Điểm đất ngẫu nhiên trong chunk (toạ độ thế giới). Trả về Vector2.INF nếu không tìm được.
func random_land_in_chunk(c: Vector2i, rng: RandomNumberGenerator, tries: int = 10) -> Vector2:
	for i in tries:
		var tx := (c.x + rng.randf()) * CHUNK_SIZE
		var ty := (c.y + rng.randf()) * CHUNK_SIZE
		if _is_land_tile(tx, ty):
			var gp := to_global(_tile_to_screen(tx, ty))
			if not is_blocked_at(gp):
				return gp
	return Vector2.INF


# ---------------------------------------------------------------- helpers

func _in_range(c: Vector2i, lo: Vector2i, hi: Vector2i) -> bool:
	return c.x >= lo.x and c.x <= hi.x and c.y >= lo.y and c.y <= hi.y


func _wait_all_tasks() -> void:
	for id in _inflight.values():
		WorkerThreadPool.wait_for_task_completion(id)
	_inflight.clear()
	_result_mutex.lock()
	_results.clear()
	_result_mutex.unlock()


func _clear_all() -> void:
	for c: Vector2i in _chunks.keys():
		_free_chunk(c)
	_prop_colliders.clear()
	_chunk_prop_data.clear()
	_prop_nodes.clear()
	_queue.clear()
	_queued.clear()
	_ready_results.clear()
	_view_min = Vector2i(VIEW_UNSET, VIEW_UNSET)
	_view_max = Vector2i(-VIEW_UNSET, -VIEW_UNSET)


func _tile_to_screen(x: float, y: float) -> Vector2:
	return Vector2((x - y) * TILE_W * 0.5, (x + y) * TILE_H * 0.5)


func _screen_to_tile(point: Vector2) -> Vector2:
	var sx := point.x / (TILE_W * 0.5)
	var sy := point.y / (TILE_H * 0.5)
	return Vector2((sx + sy) * 0.5, (sy - sx) * 0.5)
