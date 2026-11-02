extends Node2D
## Toàn bộ hiệu ứng ném Pilball, vẽ bằng code (không cần ảnh, không PointLight, không node cho từng hạt).
##
## Cách giữ nhẹ:
##  - 4 node "lớp vẽ", mỗi lớp 1 lệnh _draw; chỉ vẽ lại khi đang có thứ để vẽ (ngắm / bóng bay / hạt còn sống),
##    rảnh thì không tốn gì cả.
##  - Tối đa MAX_PARTICLES hạt cùng lúc, hạt chết được dọn ngay (hoán đổi với phần tử cuối).
##  - Lớp phát sáng dùng blend ADD; ban đêm nhân ngược màu nhuộm ngày đêm để hiệu ứng vẫn sáng rực.
## Lớp: 0 mặt đất (bóng, vòng ngắm, bụi; vẫn tối theo ban đêm) | 1 phát sáng | 2 quả bóng | 3 chữ + giấy confetti (1-3 luôn sáng).

const NightGlow := preload("res://scripts/world/night_glow.gd")

const Z_GROUND := -2   # cùng lớp với vòng phép: chỉ đè lên mặt đất và bóng
const Z_GLOW := 5
const Z_BALL := 6
const Z_TEXT := 7
const MAX_PARTICLES := 140
const TRAIL_MAX := 12          # số điểm của vệt sáng sau quả bóng
const BALL_PX := 42.0          # kích thước quả bóng trên màn hình
const HAND_H := 34.0           # độ cao bàn tay lúc ném (px so với chân)
const GROUND_SQUASH := 0.5     # hình tròn trên mặt đất iso bị ép còn 1/2 chiều cao

const GOLD := Color(1.0, 0.82, 0.32)
const ORANGE := Color(1.0, 0.52, 0.18)
const CREAM := Color(1.0, 0.96, 0.82)
const RED := Color(1.0, 0.36, 0.30)
const WATER_COL := Color(0.62, 0.86, 1.0)
const CONFETTI := [Color(1.0, 0.82, 0.32), Color(1.0, 0.45, 0.35), Color(0.45, 0.85, 1.0), Color(0.62, 1.0, 0.55), Color(1.0, 0.62, 0.92)]

enum K { DOT, STAR, DUST, RING_G, RING_V, FLASH, CONFETTI, ATTRACT, RAYS, TOAST }


## Quả bóng đang hiện (thrower điều khiển trạng thái, fx chỉ vẽ).
class Ball extends RefCounted:
	var ground := Vector2.ZERO   # vị trí dưới đất
	var h := 0.0                 # độ cao so với mặt đất (px)
	var rot := 0.0
	var scale := 1.0
	var alpha := 1.0
	var glow := 0.0              # 0..1 quầng sáng quanh bóng
	var flying := false          # đang bay thì để lại vệt sáng
	var trail: Array[Vector2] = []

	func visual() -> Vector2:
		return ground + Vector2(0.0, -h)


class P extends RefCounted:
	var kind := 0
	var pos := Vector2.ZERO
	var vel := Vector2.ZERO
	var grav := 0.0
	var drag := 0.0
	var life := 1.0
	var max_life := 1.0
	var size := 4.0
	var size2 := 0.0
	var col := Color.WHITE
	var rot := 0.0
	var spin := 0.0
	var center := Vector2.ZERO
	var r0 := 0.0
	var n := 0
	var text := ""


class Layer extends Node2D:
	var fx
	var which := 0

	func _draw() -> void:
		fx.draw_layer(self, which)


# --- trạng thái ngắm (thrower ghi, fx vẽ) ---
var aim_on := false
var aim_valid := false          # kéo đủ xa để ném
var aim_power := 0.0            # 0..1
var aim_from := Vector2.ZERO    # chân người chơi
var aim_to := Vector2.ZERO      # điểm bóng sẽ rơi
var aim_lock := false           # điểm rơi đang nằm trên một Pilmon
var aim_lock_pos := Vector2.ZERO
var aim_chance := 0.0

var balls: Array[Ball] = []
var ball_tex: Texture2D

var _time := 0.0
var _ps: Array[P] = []
var _dummy := P.new()           # trả về khi hết chỗ hạt để nơi gọi cứ gán thuộc tính bình thường
var _suck_acc := 0.0
var _layers: Array[Layer] = []
var _star_pts := PackedVector2Array()
var _was_busy := false


## Chiều cao quả bóng theo tiến độ bay t (0..1): hạ từ độ cao bàn tay xuống đất, vòng cung cao tuỳ quãng ném.
static func flight_height(t: float, dist: float) -> float:
	var apex := clampf(dist * 0.24, 36.0, 110.0)
	return HAND_H * (1.0 - t) + apex * 4.0 * t * (1.0 - t)


func _ready() -> void:
	for i in 8: # ngôi sao 4 cánh bán kính 1, nhân với kích thước khi vẽ
		var a := TAU * i / 8.0 - PI * 0.5
		_star_pts.append(Vector2(cos(a), sin(a)) * (1.0 if i % 2 == 0 else 0.2))
	var add_mat := CanvasItemMaterial.new()
	add_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	var zs := [Z_GROUND, Z_GLOW, Z_BALL, Z_TEXT]
	for i in 4:
		var l := Layer.new()
		l.fx = self
		l.which = i
		l.top_level = true          # toạ độ cục bộ = toạ độ thế giới, bất kể node cha
		l.z_as_relative = false
		l.z_index = zs[i]
		l.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		if i == 1:
			l.material = add_mat
		add_child(l)
		_layers.append(l)


func _process(delta: float) -> void:
	var busy := aim_on or not balls.is_empty() or not _ps.is_empty()
	if not busy:
		if _was_busy: # vẽ nốt một lần để xoá sạch
			_was_busy = false
			_redraw()
		return
	_was_busy = true
	_time += delta
	_step_particles(delta)
	_step_trails()
	_apply_tint()
	_redraw()


func _redraw() -> void:
	for l in _layers:
		l.queue_redraw()


## Ban đêm CanvasModulate làm tối cả hiệu ứng: nhân ngược lại để tia sáng, quả bóng, chữ vẫn sáng (giao diện không bị nhuộm).
func _apply_tint() -> void:
	var t: Color = NightGlow.tint
	var comp := Color(1.0 / maxf(t.r, 0.35), 1.0 / maxf(t.g, 0.35), 1.0 / maxf(t.b, 0.35), 1.0)
	_layers[1].modulate = comp
	_layers[2].modulate = comp # quả bóng cũng không bị tối đi ban đêm
	_layers[3].modulate = comp


func _step_trails() -> void:
	for b in balls:
		if b.flying:
			b.trail.append(b.visual())
			if b.trail.size() > TRAIL_MAX:
				b.trail.pop_front()
		elif not b.trail.is_empty():
			b.trail.pop_front()


func _step_particles(delta: float) -> void:
	var i := _ps.size() - 1
	while i >= 0:
		var p: P = _ps[i]
		p.life -= delta
		if p.life <= 0.0:
			_ps[i] = _ps[_ps.size() - 1]
			_ps.pop_back()
		elif p.kind == K.ATTRACT:
			p.rot += p.spin * delta
			var u := 1.0 - p.life / p.max_life
			p.pos = p.center + Vector2(cos(p.rot), sin(p.rot)) * (p.r0 * pow(1.0 - u, 1.6))
		else:
			p.vel.y += p.grav * delta
			if p.drag > 0.0:
				p.vel *= maxf(0.0, 1.0 - p.drag * delta)
			p.pos += p.vel * delta
			p.rot += p.spin * delta
		i -= 1


func _add(kind: int, pos: Vector2, life: float, size: float, size2: float, col: Color, force := false) -> P:
	if not force and _ps.size() >= MAX_PARTICLES:
		return _dummy
	var p := P.new()
	p.kind = kind
	p.pos = pos
	p.life = life
	p.max_life = life
	p.size = size
	p.size2 = size2
	p.col = col
	_ps.append(p)
	return p


func _burst_dots(pos: Vector2, count: int, speed_min: float, speed_max: float, life_min: float, life_max: float, grav: float, c1: Color, c2: Color) -> void:
	for i in count:
		var a := randf() * TAU
		var p := _add(K.DOT, pos, randf_range(life_min, life_max), randf_range(2.6, 4.6), 0.5, c1.lerp(c2, randf()))
		p.vel = Vector2(cos(a), sin(a)) * randf_range(speed_min, speed_max)
		p.grav = grav
		p.drag = 2.0


# ---------------------------------------------------------------- hiệu ứng (thrower gọi)

## Lúc ném: vệt gió + sao nhỏ ở bàn tay.
func fx_launch(vis: Vector2, dir: Vector2) -> void:
	for i in 7:
		var p := _add(K.DOT, vis, randf_range(0.18, 0.32), randf_range(2.4, 4.0), 0.4, GOLD.lerp(CREAM, randf()))
		p.vel = -dir * randf_range(60.0, 200.0) + Vector2(randf_range(-40.0, 40.0), randf_range(-40.0, 40.0))
		p.drag = 4.0
	var s := _add(K.STAR, vis, 0.28, 12.0, 2.0, CREAM)
	s.spin = 5.0
	_add(K.RING_V, vis, 0.22, 6.0, 26.0, GOLD, true)


## Bóng trúng Pilmon: loé sáng, vòng sốc, tia, tia lửa.
func fx_impact(vis: Vector2, feet: Vector2) -> void:
	_add(K.FLASH, vis, 0.26, 10.0, 64.0, Color(1.0, 0.92, 0.65), true)
	_add(K.RING_V, vis, 0.34, 10.0, 80.0, CREAM, true)
	_add(K.RING_G, feet, 0.40, 14.0, 74.0, GOLD, true)
	var r := _add(K.RAYS, vis, 0.28, 74.0, 0.0, Color(1.0, 0.9, 0.55), true)
	r.n = 8
	r.rot = randf() * TAU
	_burst_dots(vis, 12, 130.0, 340.0, 0.35, 0.65, 520.0, GOLD, ORANGE)
	for i in 3:
		var s := _add(K.STAR, vis + Vector2(randf_range(-22.0, 22.0), randf_range(-22.0, 22.0)), randf_range(0.3, 0.5), randf_range(10.0, 16.0), 1.0, CREAM)
		s.spin = randf_range(-6.0, 6.0)


## Pilmon đang bị hút vào bóng: các hạt xoáy dồn về tâm bóng (gọi mỗi frame, tự tính số hạt theo thời gian).
func fx_suck_tick(center: Vector2, delta: float) -> void:
	_suck_acc += delta * 110.0
	while _suck_acc >= 1.0:
		_suck_acc -= 1.0
		var p := _add(K.ATTRACT, center, randf_range(0.24, 0.34), randf_range(2.6, 4.2), 0.8, [GOLD, ORANGE, CREAM][randi() % 3])
		p.center = center
		p.r0 = randf_range(34.0, 66.0)
		p.rot = randf() * TAU
		p.spin = randf_range(7.0, 11.0) * (1.0 if randf() < 0.5 else -1.0)


## Bóng chạm đất: bụi + vòng nhỏ trên mặt đất.
func fx_land(ground: Vector2, strength: float) -> void:
	for i in int(4.0 * strength) + 2:
		var a := randf() * TAU
		var p := _add(K.DUST, ground, randf_range(0.30, 0.50), randf_range(4.0, 6.0), randf_range(11.0, 16.0), Color(0.86, 0.80, 0.68, 0.7))
		p.vel = Vector2(cos(a), sin(a)) * randf_range(20.0, 60.0) * strength
		p.drag = 3.0
	_add(K.RING_G, ground, 0.30, 6.0, 30.0 * strength + 10.0, CREAM, true)


## Bóng rơi xuống nước: giọt nước bắn lên + sóng.
func fx_splash(ground: Vector2) -> void:
	for i in 10:
		var p := _add(K.DOT, ground + Vector2(0.0, -4.0), randf_range(0.35, 0.60), randf_range(2.4, 4.0), 0.6, WATER_COL.lerp(Color.WHITE, randf() * 0.6))
		p.vel = Vector2(randf_range(-90.0, 90.0), randf_range(-260.0, -120.0))
		p.grav = 760.0
	_add(K.RING_G, ground, 0.55, 8.0, 56.0, WATER_COL, true)
	_add(K.RING_G, ground, 0.70, 4.0, 40.0, Color.WHITE, true)


## Bóng biến mất sau khi ném trượt: làn khói bụi + vài đốm vàng.
func fx_poof(ground: Vector2) -> void:
	for i in 5:
		var p := _add(K.DUST, ground + Vector2(randf_range(-8.0, 8.0), 0.0), randf_range(0.35, 0.55), randf_range(5.0, 8.0), randf_range(14.0, 20.0), Color(0.9, 0.86, 0.76, 0.6))
		p.vel = Vector2(randf_range(-30.0, 30.0), randf_range(-26.0, -4.0))
		p.drag = 2.0
	_burst_dots(ground + Vector2(0.0, -10.0), 5, 40.0, 110.0, 0.3, 0.5, 200.0, GOLD, CREAM)


## Bóng lắc: một nhịp sáng nhỏ mỗi lần lắc.
func fx_wobble_ping(vis: Vector2) -> void:
	_add(K.RING_V, vis, 0.26, 12.0, 40.0, GOLD, true)
	var s := _add(K.STAR, vis + Vector2(randf_range(-10.0, 10.0), -14.0), 0.3, 11.0, 1.0, CREAM)
	s.spin = 4.0


## Bắt thành công: loé lớn, tia, vòng, sao, pháo giấy.
func fx_win(vis: Vector2, ground: Vector2) -> void:
	_add(K.FLASH, vis, 0.34, 14.0, 96.0, Color(1.0, 0.95, 0.75), true)
	var r := _add(K.RAYS, vis, 0.55, 100.0, 0.0, Color(1.0, 0.88, 0.45), true)
	r.n = 14
	r.rot = randf() * TAU
	_add(K.RING_V, vis, 0.50, 12.0, 120.0, CREAM, true)
	_add(K.RING_V, vis, 0.70, 8.0, 150.0, GOLD, true)
	_add(K.RING_G, ground, 0.65, 16.0, 130.0, GOLD, true)
	_burst_dots(vis, 14, 120.0, 300.0, 0.5, 0.9, 380.0, GOLD, CREAM)
	for i in 6:
		var a := -PI * 0.5 + randf_range(-1.1, 1.1)
		var s := _add(K.STAR, vis, randf_range(0.5, 0.9), randf_range(12.0, 22.0), 1.0, CREAM.lerp(GOLD, randf()))
		s.vel = Vector2(cos(a), sin(a)) * randf_range(80.0, 220.0)
		s.grav = 160.0
		s.drag = 1.5
		s.spin = randf_range(-5.0, 5.0)
	for i in 26:
		var a := -PI * 0.5 + randf_range(-1.25, 1.25)
		var p := _add(K.CONFETTI, vis, randf_range(0.9, 1.5), randf_range(3.0, 5.0), 0.0, CONFETTI[randi() % CONFETTI.size()])
		p.vel = Vector2(cos(a), sin(a)) * randf_range(140.0, 380.0)
		p.grav = 420.0
		p.drag = 1.6
		p.rot = randf() * TAU
		p.spin = randf_range(-9.0, 9.0)
		p.n = randi() % 100


func fx_toast(text: String, pos: Vector2, col: Color) -> void:
	var p := _add(K.TOAST, pos, 1.5, 0.0, 0.0, col, true)
	p.text = text


func fx_escape(vis: Vector2, ground: Vector2) -> void:
	_add(K.FLASH, vis, 0.25, 8.0, 70.0, RED, true)
	_add(K.RING_V, vis, 0.4, 10.0, 100.0, RED, true)
	_add(K.RING_G, ground, 0.4, 10.0, 80.0, ORANGE, true)
	_burst_dots(vis, 18, 100.0, 280.0, 0.3, 0.7, 350.0, RED, CREAM)
	fx_toast("Thoát cầu!", vis + Vector2(0, -40), RED)


# ---------------------------------------------------------------- vẽ

func draw_layer(ci: CanvasItem, which: int) -> void:
	match which:
		0: _draw_ground(ci)
		1: _draw_glow(ci)
		2: _draw_balls(ci)
		3: _draw_text(ci)
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_ground(ci: CanvasItem) -> void:
	if aim_on:
		var col := GOLD.lerp(ORANGE, aim_power)
		if aim_lock:
			col = RED
		# vòng sức mạnh quanh chân: kéo càng xa vòng càng đầy
		ci.draw_set_transform(aim_from, 0.0, Vector2(1.0, GROUND_SQUASH))
		ci.draw_arc(Vector2.ZERO, 48.0, 0.0, TAU, 40, Color(1, 1, 1, 0.16), 3.0, true)
		if aim_valid:
			ci.draw_arc(Vector2.ZERO, 48.0, -PI * 0.5, -PI * 0.5 + TAU * maxf(aim_power, 0.04), 40, Color(col, 0.9), 4.5, true)
			# vòng ngắm tại điểm rơi
			ci.draw_set_transform(aim_to, 0.0, Vector2(1.0, GROUND_SQUASH))
			var r := (30.0 if aim_lock else 34.0) + 2.5 * sin(_time * 7.0)
			ci.draw_circle(Vector2.ZERO, r, Color(col, 0.16))
			for k in 4:
				var a0 := _time * 2.4 + k * PI * 0.5
				ci.draw_arc(Vector2.ZERO, r, a0, a0 + 0.95, 8, Color(col, 0.95), 3.5, true)
			ci.draw_circle(Vector2.ZERO, 3.0, Color(col, 0.9))
			if aim_lock:
				ci.draw_arc(Vector2.ZERO, r * 1.35, 0.0, TAU, 32, Color(col, 0.45), 2.0, true)
	for b in balls: # bóng đổ nhỏ dần và mờ dần khi bóng bay cao
		var high := clampf(b.h / 220.0, 0.0, 0.6)
		ci.draw_set_transform(b.ground, 0.0, Vector2(1.0, GROUND_SQUASH))
		ci.draw_circle(Vector2.ZERO, 13.0 * b.scale * (1.0 - high * 0.5), Color(0, 0, 0, 0.32 * b.alpha * (1.0 - high)))
	for p in _ps:
		var u := 1.0 - p.life / p.max_life
		if p.kind == K.DUST:
			var c := p.col
			c.a *= (1.0 - u) * 0.8
			ci.draw_set_transform(p.pos, 0.0, Vector2(1.0, GROUND_SQUASH))
			ci.draw_circle(Vector2.ZERO, lerpf(p.size, p.size2, u), c)
		elif p.kind == K.RING_G:
			var c2 := p.col
			c2.a *= 1.0 - u
			var e := 1.0 - (1.0 - u) * (1.0 - u)
			ci.draw_set_transform(p.pos, 0.0, Vector2(1.0, GROUND_SQUASH))
			ci.draw_arc(Vector2.ZERO, lerpf(p.size, p.size2, e), 0.0, TAU, 36, c2, lerpf(4.0, 1.0, u), true)


func _draw_glow(ci: CanvasItem) -> void:
	# đường ném chấm chấm chạy về phía điểm rơi
	if aim_on and aim_valid:
		var col := GOLD.lerp(ORANGE, aim_power)
		if aim_lock:
			col = RED
		var dist := aim_from.distance_to(aim_to)
		var n := 14
		var march := fposmod(_time * 0.9, 1.0)
		for i in n:
			var t := (float(i) + march) / float(n)
			var pos := aim_from.lerp(aim_to, t) + Vector2(0.0, -flight_height(t, dist))
			ci.draw_circle(pos, lerpf(3.6, 2.0, t), Color(col, 0.30 + 0.70 * t))
		if aim_lock: # mũi tên đỏ nhấp nhô trên đầu Pilmon bị khoá
			var ap := aim_lock_pos + Vector2(0.0, -78.0 + 5.0 * sin(_time * 9.0))
			ci.draw_colored_polygon(PackedVector2Array([ap, ap + Vector2(-9.0, -14.0), ap + Vector2(9.0, -14.0)]), Color(RED, 0.95))
	for b in balls:
		if b.glow > 0.0 or b.flying:
			var vis := b.visual()
			var g := (0.20 + 0.40 * b.glow) * b.alpha
			var r := (20.0 + 16.0 * b.glow) * b.scale
			ci.draw_circle(vis, r, Color(GOLD, g * 0.35))
			ci.draw_circle(vis, r * 0.65, Color(GOLD, g * 0.55))
			ci.draw_circle(vis, r * 0.35, Color(CREAM, g))
		var n2 := b.trail.size() # vệt sáng mảnh dần về phía đuôi
		for i in n2 - 1:
			var k := float(i + 1) / float(n2)
			ci.draw_line(b.trail[i], b.trail[i + 1], Color(GOLD, 0.55 * k * b.alpha), 1.5 + 7.0 * k)
	for p in _ps:
		var u := 1.0 - p.life / p.max_life
		var c := p.col
		c.a *= 1.0 - u
		match p.kind:
			K.DOT:
				ci.draw_circle(p.pos, maxf(0.5, lerpf(p.size, p.size2, u)), c)
			K.STAR:
				var s := lerpf(p.size, p.size2, u)
				if s > 0.6:
					ci.draw_set_transform(p.pos, p.rot, Vector2(s, s))
					ci.draw_colored_polygon(_star_pts, c)
					ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			K.RING_V:
				var e := 1.0 - (1.0 - u) * (1.0 - u)
				ci.draw_arc(p.pos, lerpf(p.size, p.size2, e), 0.0, TAU, 40, c, lerpf(4.0, 1.0, u), true)
			K.FLASH:
				var e2 := 1.0 - (1.0 - u) * (1.0 - u)
				var fr := lerpf(p.size, p.size2, e2)
				ci.draw_circle(p.pos, fr, Color(c, c.a * 0.28))
				ci.draw_circle(p.pos, fr * 0.66, Color(c, c.a * 0.45))
				ci.draw_circle(p.pos, fr * 0.34, Color(c, c.a * 0.95))
			K.ATTRACT:
				ci.draw_circle(p.pos, lerpf(p.size, p.size2, u), Color(p.col, 0.35 + 0.65 * u))
			K.RAYS:
				var e3 := 1.0 - (1.0 - u) * (1.0 - u)
				for k in p.n:
					var a := p.rot + TAU * k / float(p.n)
					var d := Vector2(cos(a), sin(a))
					var len_k := 1.0 if k % 2 == 0 else 0.55
					ci.draw_line(p.pos + d * p.size * e3 * 0.28, p.pos + d * p.size * e3 * len_k, c, lerpf(5.0, 1.0, u))


func _draw_balls(ci: CanvasItem) -> void:
	for b in balls:
		ci.draw_set_transform(b.visual(), b.rot, Vector2(b.scale, b.scale))
		if ball_tex != null:
			var s := Vector2(BALL_PX, BALL_PX)
			ci.draw_texture_rect(ball_tex, Rect2(-s * 0.5, s), false, Color(1, 1, 1, b.alpha))
		else: # chưa có ảnh pilball.png: vẽ tạm một quả cầu vàng
			var a := b.alpha
			ci.draw_circle(Vector2.ZERO, 15.0, Color(0.30, 0.16, 0.08, a))
			ci.draw_circle(Vector2.ZERO, 13.0, Color(0.93, 0.64, 0.22, a))
			ci.draw_circle(Vector2(0.0, 3.0), 9.5, Color(0.80, 0.45, 0.16, a))
			ci.draw_line(Vector2(-13.0, 0.0), Vector2(13.0, 0.0), Color(0.30, 0.16, 0.08, a), 2.0)
			ci.draw_circle(Vector2(0.0, 0.0), 3.6, Color(1.0, 0.95, 0.8, a))
			ci.draw_circle(Vector2(-5.0, -6.0), 3.2, Color(1.0, 0.93, 0.72, a * 0.9))


func _draw_text(ci: CanvasItem) -> void:
	var font := ThemeDB.fallback_font
	if aim_on and aim_valid and aim_lock:
		var label := "Bắt: %d%%" % roundi(aim_chance * 100.0)
		var width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 23).x
		var pos := aim_lock_pos + Vector2(-width * 0.5, -120.0)
		ci.draw_string_outline(font, pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 23, 6, Color(0.08, 0.05, 0.04))
		ci.draw_string(font, pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 23, CREAM)
	for p in _ps:
		var u := 1.0 - p.life / p.max_life
		if p.kind == K.CONFETTI:
			var c := p.col
			c.a *= clampf((1.0 - u) / 0.35, 0.0, 1.0)
			ci.draw_set_transform(p.pos, p.rot, Vector2(1.0, cos(p.rot * 1.7 + float(p.n))))
			ci.draw_rect(Rect2(-p.size, -p.size * 0.5, p.size * 2.0, p.size), c)
		elif p.kind == K.TOAST:
			var fs := 28
			var pop := 1.0 + 0.45 * maxf(0.0, 1.0 - u * 7.0)
			var a2 := clampf((1.0 - u) / 0.3, 0.0, 1.0)
			var w := font.get_string_size(p.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			ci.draw_set_transform(p.pos + Vector2(0.0, -46.0 * u), 0.0, Vector2(pop, pop))
			var o := Vector2(-w * 0.5, 0.0)
			ci.draw_string_outline(font, o, p.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 8, Color(0.12, 0.07, 0.04, a2))
			ci.draw_string(font, o, p.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(p.col, a2))
