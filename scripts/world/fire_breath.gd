extends Node2D
## Phun lửa: lớp lửa (cộng sáng) + lớp khói nhẹ. Gắn làm con của nhân vật, đặt position ở miệng / ngực.

const REACH := 140.0                       # tầm phun ước lượng (px) ≈ v·t − ½·damping·t², chỉnh theo mắt
const HALF_ANGLE := deg_to_rad(22.0)       # nửa góc hình quạt gây sát thương

const NightGlow := preload("res://scripts/world/night_glow.gd")
const GLOW_RADIUS := 190.0                 # bán kính vùng sáng trên mặt đất (px)
const GLOW_COLOR := Color(1.0, 0.55, 0.2)
const GLOW_STRENGTH := 0.9

static var _soft_texture: GradientTexture2D

var _flame: CPUParticles2D
var _smoke: CPUParticles2D
var _dir := Vector2.RIGHT
var _active := false
var _glow: NightGlow


func _ready() -> void:
	# Không nâng z_index: lửa cùng lớp z = 0 và cùng vị trí y-sort với người chơi => vật nằm thấp hơn người chơi
	# trên màn hình (gần camera hơn) sẽ che lửa, vật phía sau thì bị lửa đè lên.
	_smoke = _make_smoke()
	_flame = _make_flame()
	add_child(_smoke)                      # khói vẽ trước => nằm dưới lửa
	add_child(_flame)
	_glow = NightGlow.new()                # vùng sáng trước mặt người chơi, chỉ hiện khi trời tối
	_glow.setup(GLOW_RADIUS, GLOW_COLOR, GLOW_STRENGTH)
	_glow.flicker = 1.0
	_glow.level = 0.0
	add_child(_glow)


func _process(delta: float) -> void:
	_glow.level = move_toward(_glow.level, 1.0 if _active else 0.0, delta * 5.0) # sáng lên / tắt dần mượt
	# Vùng sáng nằm trên mặt đất (cách miệng 34px xuống chân), lệch về phía đang phun.
	_glow.position = Vector2(0.0, 34.0) + _dir * REACH * 0.4


func set_active(on: bool) -> void:
	_active = on
	_flame.emitting = on
	_smoke.emitting = on


func aim(dir: Vector2) -> void:
	if dir.length_squared() < 0.0001:
		return
	_dir = dir.normalized()
	_flame.direction = _dir
	_smoke.direction = _dir


## Các mục tiêu (mob...) đang nằm trong hình quạt lửa. Đo trên màn hình để khớp đúng với hình người chơi thấy.
func targets_in_cone(candidates: Array) -> Array:
	var out: Array = []
	for c in candidates:
		var to: Vector2 = c.global_position - global_position
		if to.length() <= REACH and absf(_dir.angle_to(to)) <= HALF_ANGLE:
			out.append(c)
	return out


func _make_flame() -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.emitting = false
	p.amount = 36                          # 24–40 là đủ, tăng nhiều sẽ nặng
	p.lifetime = 0.5
	p.lifetime_randomness = 0.3
	p.local_coords = false                 # lửa ở lại thế giới khi nhân vật di chuyển => có vệt đuôi
	p.texture = _soft_circle()
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 5.0
	p.direction = _dir
	p.spread = 12.0
	p.initial_velocity_min = 260.0
	p.initial_velocity_max = 360.0
	p.damping_min = 120.0
	p.damping_max = 180.0
	p.gravity = Vector2(0, -60)            # lửa bốc nhẹ lên trên
	p.scale_amount_min = 1.0
	p.scale_amount_max = 1.6
	var curve := Curve.new()               # nhỏ -> to ra -> tan dần
	curve.add_point(Vector2(0.0, 0.5))
	curve.add_point(Vector2(0.3, 1.0))
	curve.add_point(Vector2(1.0, 0.3))
	p.scale_amount_curve = curve
	var g := Gradient.new()                # trắng vàng -> cam -> đỏ -> tắt
	g.offsets = PackedFloat32Array([0.0, 0.25, 0.6, 1.0])
	g.colors = PackedColorArray([
		Color(1.0, 0.95, 0.6, 1.0), Color(1.0, 0.6, 0.15, 0.9),
		Color(0.8, 0.2, 0.05, 0.5), Color(0.2, 0.05, 0.02, 0.0)])
	p.color_ramp = g
	var m := CanvasItemMaterial.new()
	m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	m.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED   # không bị ban đêm nhuộm tối: lửa vẫn rực
	p.material = m
	return p


func _make_smoke() -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.emitting = false
	p.amount = 8
	p.lifetime = 0.9
	p.local_coords = false
	p.texture = _soft_circle()
	p.direction = _dir
	p.spread = 20.0
	p.initial_velocity_min = 80.0
	p.initial_velocity_max = 150.0
	p.damping_min = 60.0
	p.damping_max = 90.0
	p.gravity = Vector2(0, -45)
	p.scale_amount_min = 1.4
	p.scale_amount_max = 2.2
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.3, 1.0])
	g.colors = PackedColorArray([Color(0.3, 0.3, 0.3, 0.0), Color(0.3, 0.3, 0.3, 0.25), Color(0.2, 0.2, 0.2, 0.0)])
	p.color_ramp = g
	return p


static func _soft_circle() -> GradientTexture2D:
	if _soft_texture == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(0.5, 0.0)
		t.width = 32
		t.height = 32
		_soft_texture = t
	return _soft_texture