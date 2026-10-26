extends Node2D
## Vòng phép thuật dưới chân. Gọi MagicCircle.cast(...), vòng tự nở ra, giữ một lúc rồi mờ dần và tự xoá.

const SHADER := preload("res://shaders/magic_circle.gdshader")
const SIZE := 256.0
const NightGlow := preload("res://scripts/world/night_glow.gd")
const GLOW_SCALE := 1.5                    # vùng sáng rộng gấp mấy lần vòng phép

static var _white_tex: ImageTexture

var _mat := ShaderMaterial.new()
var _glow: NightGlow
var _progress := 0.0
var _alpha := 1.0


static func cast(parent: Node, world_pos: Vector2, radius := 110.0, color := Color(0.45, 0.75, 1.0), points := 3, hold := 1.5) -> Node2D:
	var c := new()
	parent.add_child(c)
	c.global_position = world_pos
	c.setup(radius, color, points, hold)
	return c


func setup(radius: float, color: Color, points: int, hold: float) -> void:
	z_as_relative = false
	z_index = -2                               # = Z_GROUND_FX của map.gd: chỉ đè lên mặt đất (-4) và bóng (-3); dưới vật không che lấp (-1: khúc gỗ, đá nhỏ...) và mọi nhân vật / vật (0)
	_glow = NightGlow.new()                    # ban đêm: vùng quanh vòng phép sáng lên cùng màu phép
	_glow.setup(radius * GLOW_SCALE, color, 0.8)
	_glow.level = 0.0
	add_child(_glow)
	var tex := _white()
	var sprite := Sprite2D.new()
	sprite.texture = tex
	sprite.scale = Vector2(radius * 2.0, radius) / float(tex.get_width())   # rộng 2r, cao r: ép dẹt kiểu iso (TILE_H / TILE_W = 0.5)
	sprite.material = _mat
	add_child(sprite)
	_mat.shader = SHADER
	_mat.set_shader_parameter("color", color)
	_mat.set_shader_parameter("points", points)
	_mat.set_shader_parameter("progress", 0.0)
	_mat.set_shader_parameter("alpha", 1.0)
	var tw := create_tween()
	tw.tween_method(_set_progress, 0.0, 1.0, 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_interval(hold)
	tw.tween_method(_set_alpha, 1.0, 0.0, 0.4)
	tw.tween_callback(queue_free)


func _set_progress(v: float) -> void:
	_progress = v
	_mat.set_shader_parameter("progress", v)
	_glow.level = _progress * _alpha


func _set_alpha(v: float) -> void:
	_alpha = v
	_mat.set_shader_parameter("alpha", v)
	_glow.level = _progress * _alpha


static func _white() -> ImageTexture:
	if _white_tex == null:
		var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		_white_tex = ImageTexture.create_from_image(img)
	return _white_tex