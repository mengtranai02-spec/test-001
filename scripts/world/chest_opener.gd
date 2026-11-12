extends RefCounted
## Mở / đóng nắp rương: nảy nén/giãn nhẹ -> đổi texture (-> phát hiệu ứng khi mở lần đầu).
## Chỉ dùng Tween (không _process), không tạo node thừa ngoài hiệu ứng.
##
##   ChestOpener.open(sprite, open_texture, true)    # true = có hiệu ứng ánh sáng / đồng vàng
##   ChestOpener.close(sprite, closed_texture)

const ChestOpenFx := preload("chest_open_fx.gd")
const META_BASE_SCALE := &"chest_base_scale"
const META_TWEEN := &"chest_tween"


static func open(sprite: Sprite2D, open_texture: Texture2D, with_fx := true) -> void:
	if not is_instance_valid(sprite) or sprite.texture == null or open_texture == null:
		return
	var parent := sprite.get_parent()
	if parent == null:
		return
	var base_scale := _base_scale(sprite)
	var tex_size := sprite.texture.get_size()
	# Miệng rương nằm quanh tâm hình, hơi lệch lên trên.
	var fx_pos := sprite.position + Vector2(0.0, sprite.offset.y - tex_size.y * 0.06)
	var size_factor := clampf(tex_size.x * absf(base_scale.x) / ChestOpenFx.BASE, 0.5, 2.0)

	var tween := _new_tween(sprite)
	# 1) Nén nhẹ (tích lực).
	tween.tween_property(sprite, "scale", base_scale * Vector2(1.07, 0.9), 0.08) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	# 2) Bật nắp: đổi texture (+ phát hiệu ứng).
	tween.tween_callback(_swap_texture.bind(sprite, open_texture, with_fx, parent, fx_pos, size_factor))
	# 3) Giãn lên rồi về kích thước gốc.
	tween.tween_property(sprite, "scale", base_scale * Vector2(0.96, 1.08), 0.09) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(sprite, "scale", base_scale, 0.22) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## Đóng nắp: đổi lại texture đóng kèm một nhịp nén nhẹ, không hiệu ứng hạt.
static func close(sprite: Sprite2D, closed_texture: Texture2D) -> void:
	if not is_instance_valid(sprite) or closed_texture == null:
		return
	var base_scale := _base_scale(sprite)
	var tween := _new_tween(sprite)
	tween.tween_property(sprite, "scale", base_scale * Vector2(1.04, 0.94), 0.06) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_callback(_swap_texture.bind(sprite, closed_texture, false, null, Vector2.ZERO, 1.0))
	tween.tween_property(sprite, "scale", base_scale, 0.14) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## Scale gốc của sprite, ghi nhớ lần đầu để mở/đóng liên tục không làm scale bị lệch dần.
static func _base_scale(sprite: Sprite2D) -> Vector2:
	if not sprite.has_meta(META_BASE_SCALE):
		sprite.set_meta(META_BASE_SCALE, sprite.scale)
	var base: Vector2 = sprite.get_meta(META_BASE_SCALE)
	return base


## Tween mới gắn vào sprite (sprite bị xoá thì tween tự dừng); huỷ tween cũ nếu còn chạy.
static func _new_tween(sprite: Sprite2D) -> Tween:
	if sprite.has_meta(META_TWEEN):
		var old := sprite.get_meta(META_TWEEN) as Tween
		if old != null and old.is_valid():
			old.kill()
		var base: Vector2 = sprite.get_meta(META_BASE_SCALE)
		sprite.scale = base
	var tween := sprite.create_tween()
	sprite.set_meta(META_TWEEN, tween)
	return tween


static func _swap_texture(sprite: Sprite2D, texture: Texture2D, with_fx: bool, parent: Node, fx_pos: Vector2, size_factor: float) -> void:
	if not is_instance_valid(sprite):
		return
	sprite.texture = texture
	# Giữ đúng quy ước offset của building_system.
	sprite.offset = Vector2(0.0, -texture.get_size().y * 0.25)
	if with_fx and is_instance_valid(parent):
		var fx: Node2D = ChestOpenFx.new()
		fx.position = fx_pos
		parent.add_child(fx)
		fx.play(size_factor)
