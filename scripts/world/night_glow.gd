extends PointLight2D
## Nguồn sáng ban đêm cho lửa / ma pháp: ánh sáng NHÂN với màu vật bị chiếu (kết quả = màu vật x (màu ngày đêm + ánh sáng)),
## nên chi tiết cỏ, đất, lá vẫn rõ và chỉ ngả theo màu ánh sáng; không còn bị phủ một lớp màu đều như kiểu cộng sáng.
##
## - Sprite, mob, người chơi, bóng...: do PointLight2D thật chiếu.
## - Mặt đất dùng shader unshaded nên không nhận Light2D: các nguồn sáng đang bật (tối đa MAX_SLOTS) được đẩy vào biến
##   toàn cục fx_light0..3 / fx_color0..3 và terrain.gdshader tự cộng sáng với đúng công thức đó.
## Ban ngày hoặc khi hiệu ứng tắt: đèn tắt hẳn (enabled = false) và slot trên mặt đất về 0 => gần như không tốn gì.
##
## Cách dùng: var l := NightGlow.new(); l.setup(bán_kính_px, màu, độ_mạnh); add_child(l);
## rồi đặt l.level (0..1) mỗi khi hiệu ứng mạnh lên / yếu đi.

const TEX_SIZE := 128
const MAX_SLOTS := 4   # số nguồn sáng tối đa chiếu lên mặt đất (khớp với terrain.gdshader)

## Màu nhuộm ngày đêm hiện tại: world.gd gán mỗi khi đổi (NightGlow.tint = màu). Không đọc lại từ
## RenderingServer vì global_shader_parameter_get chỉ dùng được trong editor (gọi trong game sẽ báo lỗi liên tục).
static var tint := Color.WHITE

static var _tex: GradientTexture2D
static var _lights: Array = []        # các NightGlow đang nằm trong cây
static var _declared := false
static var _pushed_frame := -1
static var _slots: Array = []         # [Vector4, Color] đã đẩy lần trước (để chỉ cập nhật khi đổi)

var level := 1.0       # 0..1, do hiệu ứng điều khiển (nở ra, mờ dần...)
var strength := 1.0    # độ sáng tối đa khi trời tối nhất
var flicker := 0.0     # 0..1 mức nhấp nháy (lửa)
var _radius := 100.0
var _intensity := 0.0  # độ sáng hiện tại (0 = tắt)


## Khai báo biến toàn cục cho shader mặt đất. Gọi MỘT LẦN trước khi nạp terrain.gdshader (map.gd _ready).
## Nếu bạn đã khai báo fx_light0..3 (Vector4) và fx_color0..3 (Color) trong Project Settings > Shader Globals thì bỏ qua.
static func declare_globals() -> void:
	if _declared:
		return
	_declared = true
	for i in MAX_SLOTS:
		if not ProjectSettings.has_setting("shader_globals/fx_light%d" % i):
			RenderingServer.global_shader_parameter_add("fx_light%d" % i, RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0, 0, 1, 0))
		if not ProjectSettings.has_setting("shader_globals/fx_color%d" % i):
			RenderingServer.global_shader_parameter_add("fx_color%d" % i, RenderingServer.GLOBAL_VAR_TYPE_COLOR, Color.WHITE)
		_slots.append([Vector4(0, 0, 1, 0), Color.WHITE])


## radius: bán kính vùng sáng trên mặt đất (px). squash = 0.5 ép dẹt kiểu iso (cao bằng nửa rộng);
## shader mặt đất luôn dùng đúng tỉ lệ 2:1 này.
func setup(radius: float, light_color: Color, power := 1.0, squash := 0.5) -> void:
	_radius = radius
	texture = _light_texture()
	texture_scale = radius * 2.0 / float(TEX_SIZE)
	scale = Vector2(1.0, squash)
	color = light_color
	strength = power
	shadow_enabled = false # đổ bóng 2D rất tốn, không cần
	energy = 0.0
	enabled = false


func _enter_tree() -> void:
	_lights.append(self)


func _exit_tree() -> void:
	_lights.erase(self)
	_pushed_frame = -1
	_push_globals() # trả slot mặt đất về 0 khi nguồn sáng biến mất


func _process(_delta: float) -> void:
	var a := darkness() * level * strength
	if flicker > 0.0:
		a *= 1.0 - flicker * randf() * 0.35
	_intensity = a if a > 0.01 else 0.0
	enabled = _intensity > 0.0
	energy = _intensity
	_push_globals()


## Độ tối của ngày đêm: 0 = ban ngày, ~0.6 = nửa đêm.
static func darkness() -> float:
	return clampf((1.0 - (tint.r * 0.3 + tint.g * 0.59 + tint.b * 0.11)) * 1.5, 0.0, 1.0)


## Đẩy các nguồn sáng đang bật vào biến toàn cục (mỗi frame một lần, chỉ gọi RenderingServer khi giá trị đổi).
static func _push_globals() -> void:
	if _slots.is_empty():
		return # chưa khai báo biến toàn cục (map chưa chạy)
	var frame := Engine.get_process_frames()
	if frame == _pushed_frame:
		return
	_pushed_frame = frame
	var n := 0
	for l in _lights:
		if n >= MAX_SLOTS:
			break
		if l._intensity > 0.0:
			var g: Vector2 = l.global_position
			_set_slot(n, Vector4(g.x, g.y, l._radius, l._intensity), l.color)
			n += 1
	for i in range(n, MAX_SLOTS):
		_set_slot(i, Vector4(0, 0, 1, 0), Color.WHITE)


static func _set_slot(i: int, light: Vector4, light_color: Color) -> void:
	var cur: Array = _slots[i]
	if cur[0] != light:
		cur[0] = light
		RenderingServer.global_shader_parameter_set("fx_light%d" % i, light)
	if cur[1] != light_color:
		cur[1] = light_color
		RenderingServer.global_shader_parameter_set("fx_color%d" % i, light_color)


## Texture ánh sáng: tâm sáng nhất, tắt dần bậc hai (1 - r)^2 ra tới mép; khớp công thức trong terrain.gdshader.
static func _light_texture() -> GradientTexture2D:
	if _tex == null:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.25, 0.5, 0.75, 1.0])
		g.colors = PackedColorArray([
			Color(1, 1, 1, 1), Color(0.5625, 0.5625, 0.5625, 1), Color(0.25, 0.25, 0.25, 1),
			Color(0.0625, 0.0625, 0.0625, 1), Color(0, 0, 0, 1)])
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(0.5, 0.0)
		t.width = TEX_SIZE
		t.height = TEX_SIZE
		_tex = t
	return _tex
