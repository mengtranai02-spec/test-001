extends Node2D
## Hiệu ứng mở rương – nhẹ và tự huỷ sau ~1.3 giây.
##
## Chi phí mỗi lần mở: 3 Sprite2D (additive, dùng chung 1 material)
## + 2 CPUParticles2D (tối đa ~21 hạt). Không shader, không ảnh ngoài.
## Texture / material / curve chỉ tạo MỘT lần rồi dùng chung cho mọi rương.
##
## Cách dùng (thường gọi qua chest_opener.gd):
##   var fx: Node2D = ChestOpenFx.new()
##   fx.position = vi_tri_mieng_ruong
##   parent.add_child(fx)
##   fx.play(1.0)

const LIFETIME := 1.3
const BASE := 128.0

## Đặt true trên máy yếu: bỏ vòng sáng + tia sáng, giảm nửa số hạt.
static var low_quality := false

static var _additive: CanvasItemMaterial
static var _tex_glow: Texture2D
static var _tex_ring: Texture2D
static var _tex_spark: Texture2D
static var _tex_coin: Texture2D
static var _curve_spark: Curve
static var _ramp_spark: Gradient
static var _ramp_coin: Gradient


static func _ensure_resources() -> void:
	if _additive != null:
		return
	_additive = CanvasItemMaterial.new()
	_additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD

	# Quầng sáng mềm (dùng cho flash và tia sáng – kéo giãn trục Y thành tia).
	_tex_glow = _radial_texture(
		PackedFloat32Array([0.0, 0.3, 1.0]),
		PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.4), Color(1, 1, 1, 0.0)]))
	# Vòng sáng (nén trục Y để ra hình elip theo góc nhìn iso).
	_tex_ring = _radial_texture(
		PackedFloat32Array([0.0, 0.68, 0.86, 1.0]),
		PackedColorArray([Color(1, 1, 1, 0), Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0)]))
	_tex_spark = _make_spark()
	_tex_coin = _make_coin()

	_curve_spark = Curve.new()
	_curve_spark.add_point(Vector2(0.0, 0.2))
	_curve_spark.add_point(Vector2(0.2, 1.0))
	_curve_spark.add_point(Vector2(1.0, 0.0))

	_ramp_spark = Gradient.new()
	_ramp_spark.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	_ramp_spark.colors = PackedColorArray([Color(1.0, 0.97, 0.7, 1.0), Color(1.0, 0.8, 0.3, 1.0), Color(1.0, 0.7, 0.2, 0.0)])

	_ramp_coin = Gradient.new()
	_ramp_coin.offsets = PackedFloat32Array([0.0, 0.7, 1.0])
	_ramp_coin.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)])


static func _radial_texture(offsets: PackedFloat32Array, colors: PackedColorArray) -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.offsets = offsets
	gradient.colors = colors
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 64
	tex.height = 64
	return tex


static func _make_spark() -> Texture2D:
	# Ngôi sao 4 cánh 11x11.
	var img := Image.create(11, 11, false, Image.FORMAT_RGBA8)
	for y in 11:
		for x in 11:
			var dx := absi(x - 5)
			var dy := absi(y - 5)
			var a := clampf(1.0 - float(maxi(dx, dy)) / 5.5, 0.0, 1.0) \
				* clampf(1.0 - float(mini(dx, dy)) * 0.75, 0.0, 1.0)
			if a > 0.0:
				img.set_pixel(x, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)


static func _make_coin() -> Texture2D:
	# Đồng xu vàng 7x7.
	var img := Image.create(7, 7, false, Image.FORMAT_RGBA8)
	var center := Vector2(3.0, 3.0)
	for y in 7:
		for x in 7:
			var d := Vector2(float(x), float(y)).distance_to(center)
			if d > 3.2:
				continue
			var col := Color(1.0, 0.82, 0.25)
			if d > 2.3:
				col = Color(0.78, 0.5, 0.1)
			elif x + y < 5:
				col = Color(1.0, 0.95, 0.6)
			img.set_pixel(x, y, col)
	return ImageTexture.create_from_image(img)


func play(size_factor := 1.0) -> void:
	_ensure_resources()
	z_as_relative = false
	z_index = 40
	var s := size_factor

	# 1) Flash: quầng sáng bùng ra rồi tắt nhanh.
	var flash := _add_glow_sprite(_tex_glow, Color(1.0, 0.88, 0.5, 0.0))
	_grow(flash, Vector2(1.4, 1.0) * s, Vector2(3.4, 2.4) * s, 0.45)
	_pulse(flash, 1.0, 0.07, 0.4)

	if not low_quality:
		# 2) Vòng sáng elip lan ra mặt đất.
		var ring := _add_glow_sprite(_tex_ring, Color(1.0, 0.85, 0.45, 0.0))
		ring.position = Vector2(0.0, 8.0 * s)
		_grow(ring, Vector2(0.6, 0.3) * s, Vector2(3.0, 1.5) * s, 0.55, 0.05)
		_pulse(ring, 0.8, 0.08, 0.5, 0.05)

		# 3) Tia sáng bắn lên từ miệng rương.
		var beam := _add_glow_sprite(_tex_glow, Color(1.0, 0.9, 0.55, 0.0))
		beam.position = Vector2(0.0, -70.0 * s)
		_grow(beam, Vector2(0.25, 0.6) * s, Vector2(0.75, 3.4) * s, 0.5, 0.03)
		_pulse(beam, 0.75, 0.1, 0.55, 0.03)

	# 4) Hạt lấp lánh (additive).
	var sparks := CPUParticles2D.new()
	sparks.material = _additive
	sparks.texture = _tex_spark
	sparks.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	sparks.one_shot = true
	sparks.explosiveness = 0.9
	sparks.amount = 7 if low_quality else 14
	sparks.lifetime = 0.9
	sparks.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	sparks.emission_sphere_radius = 14.0 * s
	sparks.direction = Vector2(0.0, -1.0)
	sparks.spread = 70.0
	sparks.initial_velocity_min = 60.0 * s
	sparks.initial_velocity_max = 150.0 * s
	sparks.damping_min = 40.0
	sparks.damping_max = 80.0
	sparks.gravity = Vector2(0.0, -20.0)
	sparks.scale_amount_min = 0.7 * s
	sparks.scale_amount_max = 1.4 * s
	sparks.scale_amount_curve = _curve_spark
	sparks.color_ramp = _ramp_spark
	add_child(sparks)
	sparks.emitting = true

	# 5) Đồng vàng bắn lên rồi rơi xuống.
	var coins := CPUParticles2D.new()
	coins.texture = _tex_coin
	coins.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	coins.one_shot = true
	coins.explosiveness = 1.0
	coins.amount = 4 if low_quality else 7
	coins.lifetime = 0.75
	coins.direction = Vector2(0.0, -1.0)
	coins.spread = 40.0
	coins.initial_velocity_min = 170.0 * s
	coins.initial_velocity_max = 260.0 * s
	coins.gravity = Vector2(0.0, 700.0 * s)
	coins.angle_min = -180.0
	coins.angle_max = 180.0
	coins.angular_velocity_min = -360.0
	coins.angular_velocity_max = 360.0
	coins.scale_amount_min = 1.3 * s
	coins.scale_amount_max = 1.8 * s
	coins.color_ramp = _ramp_coin
	add_child(coins)
	coins.emitting = true

	# Tự dọn sau khi mọi thứ kết thúc.
	var timer := create_tween()
	timer.tween_interval(LIFETIME)
	timer.tween_callback(queue_free)


func _add_glow_sprite(tex: Texture2D, color: Color) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.texture = tex
	sprite.material = _additive
	sprite.modulate = color
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(sprite)
	return sprite


func _pulse(node: CanvasItem, peak: float, rise: float, fall: float, delay := 0.0) -> void:
	var tween := node.create_tween()
	if delay > 0.0:
		tween.tween_interval(delay)
	tween.tween_property(node, "modulate:a", peak, rise)
	tween.tween_property(node, "modulate:a", 0.0, fall).set_ease(Tween.EASE_IN)


func _grow(node: Node2D, from: Vector2, to: Vector2, duration: float, delay := 0.0) -> void:
	node.scale = from
	var tween := node.create_tween()
	if delay > 0.0:
		tween.tween_interval(delay)
	tween.tween_property(node, "scale", to, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
