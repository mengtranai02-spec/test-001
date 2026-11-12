extends Node2D
## Ném Pilball để bắt Pilmon (mob).
##
## Cách chơi (cảm ứng): nhấn nút tròn nhỏ, kéo theo hướng NGƯỢC với hướng muốn ném, rồi thả để ném.
## Kéo càng xa, ném càng xa; vòng ngắm hiển điểm rơi và khóa mục tiêu Pilmon.
## Bóng trúng Pilmon: thử bắt theo máu và choáng; thất bại thì mob thoát cầu và phản công.
## Bàn phím: R ném thẳng về phía đang quay mặt.
##
## Ảnh: res://assets/ui/pilball.png (128x128, icon nút) và pilball_small.png (64x64, quả bóng trong game). Thiếu ảnh thì vẽ tạm bằng code.

signal captured(mob_type: String, world_pos: Vector2)

const PilFx := preload("res://scripts/pilmon/pil_fx.gd")
const ItemDefs := preload("res://scripts/inventory/item_defs.gd")
const HudButton := preload("res://scripts/ui/hud_button.gd")

# --- ngắm / ném ---
const MIN_PULL := 0.28          # kéo joystick tối thiểu (0..1) mới tính là ném
const MIN_RANGE := 150.0        # quãng ném ngắn nhất (px)
const MAX_RANGE := 520.0        # quãng ném xa nhất (px)
const THROW_SPEED := 820.0      # tốc độ bay (px/giây)
const MIN_FLIGHT := 0.26        # thời gian bay ngắn nhất / dài nhất (giây)
const MAX_FLIGHT := 0.70
const COOLDOWN := 0.30          # giây giữa hai lần ném
const MAX_SHOTS := 3            # số bóng đang bay / đang bắt cùng lúc
const HAND_OFFSET := 16.0       # bóng xuất phát cách chân người chơi bấy nhiêu px theo hướng ném

# --- trúng / bắt ---
const HIT_RADIUS := 46.0        # bán kính trúng trên mặt đất (elip iso: ngang 46, dọc 23)
const HIT_MAX_H := 80.0         # bóng cao hơn mức này thì bay qua đầu, không trúng
const MOB_CENTER_H := 26.0      # độ cao thân Pilmon (bóng hút vào điểm này)
const SUCK_TIME := 0.42
const WOBBLES := 2              # số lần bóng lắc trước khi báo bắt được
const WOBBLE_TIME := 0.40
const WOBBLE_REST := 0.22
const GRAVITY := 1500.0

const DISPLAY_NAMES := {"mod1": "Mod 1", "mod2": "Mod 2"}

enum S { FLY, SUCK, DROP, WOBBLE, WIN, LAND, FADE }


class Shot extends RefCounted:
	var ball
	var state := 0
	var t := 0.0
	var dur := 0.5
	var from := Vector2.ZERO
	var to := Vector2.ZERO
	var dir := Vector2.RIGHT
	var dist := 0.0
	var spin := 0.0
	var vy := 0.0
	var sub := 0
	var wobble := 0
	var bounced := 0
	var mob_type := ""
	var hover := Vector2.ZERO
	var enter_ground := Vector2.ZERO
	var enter_h := 0.0
	var slide := Vector2.ZERO
	var in_water := false
	var mob: CharacterBody2D
	var success := false


## Số Pilmon đã bắt theo loại: {"mod1": 3, ...}
var caught: Dictionary = {}

var _map
var _player: Node2D
var _mobs: Array
var _button: HudButton
var _fx # pil_fx.gd (không khai báo kiểu để truy cập thuộc tính của nó)
var _dragging := false
var _pull := Vector2.ZERO
var _cooldown := 0.0
var _shots: Array[Shot] = []


## mobs: mảng mob của world.gd (giữ nguyên tham chiếu, world tự thêm / bớt phần tử).
func setup(map: Node, player: Node2D, mobs: Array, button: HudButton, _hud_layer: CanvasLayer) -> void:
	_map = map
	_player = player
	_mobs = mobs
	_button = button
	_register_actions()
	_fx = PilFx.new()
	add_child(_fx)
	# Quả bóng đang bay chỉ ~42px trên màn hình: dùng bản 64x64 (pilball_small.png) cho nét và nhẹ; icon nút dùng bản 128x128 (pilball.png).
	_fx.ball_tex = ItemDefs.ui_icon("pilball_small")
	if _fx.ball_tex == null:
		_fx.ball_tex = ItemDefs.ui_icon("pilball")
	_button.circular = true
	_button.drag_mode = true
	_button.drag_changed.connect(_on_drag_changed)
	_button.drag_ended.connect(_on_drag_ended)
	_button.set_prompt("pilball", "")


func _register_actions() -> void:
	for pair in [["pilball_throw", KEY_R]]:
		var action := StringName(pair[0])
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		var ev := InputEventKey.new()
		ev.physical_keycode = pair[1]
		if not InputMap.action_has_event(action, ev):
			InputMap.action_add_event(action, ev)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"pilball_throw") and is_instance_valid(_player):
		var face: Vector2 = _player.get("facing_direction")
		_try_throw(-face.normalized() * 0.75) # phím R: ném thẳng về phía đang quay mặt, lực vừa


func _process(delta: float) -> void:
	_cooldown = maxf(0.0, _cooldown - delta)
	if is_instance_valid(_player) and _player.get("dead"):
		_cancel_aim()
	if _dragging and is_instance_valid(_player):
		_update_aim(_pull)
	if not _shots.is_empty():
		_update_shots(delta)


# ---------------------------------------------------------------- ngắm

func _update_aim(pull: Vector2) -> void:
	if pull == Vector2.ZERO:
		_fx.aim_on = false
		return
	var pull_len := pull.length()
	var valid := pull_len >= MIN_PULL
	var power := clampf((pull_len - MIN_PULL) / (1.0 - MIN_PULL), 0.0, 1.0)
	var dir := (-pull).normalized() # ném ngược với hướng kéo
	var to := _origin(dir) + dir * lerpf(MIN_RANGE, MAX_RANGE, power)
	_fx.aim_on = true
	_fx.aim_valid = valid
	_fx.aim_power = power if valid else clampf(pull_len / MIN_PULL, 0.0, 1.0) * 0.3
	_fx.aim_from = _player.global_position
	_fx.aim_to = to
	var target: CharacterBody2D = _find_hit(to, 0.0) if valid else null
	_fx.aim_lock = target != null
	if target != null:
		_fx.aim_lock_pos = target.global_position
		_fx.aim_chance = float(target.call("capture_chance"))
	_player.call("face_toward", dir)


func _on_drag_changed(direction: Vector2) -> void:
	_dragging = true
	_pull = direction
	if is_instance_valid(_player):
		_player.set("aiming", true)


func _on_drag_ended(direction: Vector2) -> void:
	if direction.length() > 0.0:
		_try_throw(direction)
	_cancel_aim()


func _cancel_aim() -> void:
	_dragging = false
	_pull = Vector2.ZERO
	_fx.aim_on = false
	if is_instance_valid(_player):
		_player.set("aiming", false)


func _origin(dir: Vector2) -> Vector2:
	return _player.global_position + dir * HAND_OFFSET


# ---------------------------------------------------------------- ném

func _try_throw(pull: Vector2) -> void:
	if not is_instance_valid(_player) or _player.get("dead"):
		return
	if pull.length() < MIN_PULL or _cooldown > 0.0 or _shots.size() >= MAX_SHOTS:
		return
	var power := clampf((pull.length() - MIN_PULL) / (1.0 - MIN_PULL), 0.0, 1.0)
	var dir := (-pull).normalized()
	var dist := lerpf(MIN_RANGE, MAX_RANGE, power)
	var s := Shot.new()
	var b := PilFx.Ball.new()
	s.ball = b
	s.dir = dir
	s.dist = dist
	s.from = _origin(dir)
	s.to = s.from + dir * dist
	s.dur = clampf(dist / THROW_SPEED, MIN_FLIGHT, MAX_FLIGHT)
	s.spin = 16.0 * (1.0 if dir.x >= 0.0 else -1.0)
	s.state = S.FLY
	b.ground = s.from
	b.h = PilFx.HAND_H
	b.flying = true
	_fx.balls.append(b)
	_fx.fx_launch(b.visual(), dir)
	_shots.append(s)
	_cooldown = COOLDOWN
	_player.call("throw_pose", dir)


# ---------------------------------------------------------------- bay / bắt

func _update_shots(delta: float) -> void:
	var i := _shots.size() - 1
	while i >= 0:
		var s: Shot = _shots[i]
		if _step_shot(s, delta):
			_fx.balls.erase(s.ball)
			_shots.remove_at(i)
		i -= 1


## Trả về true khi quả bóng đã xong việc và cần xoá.
func _step_shot(s: Shot, delta: float) -> bool:
	var b = s.ball
	match s.state:
		S.FLY:
			s.t += delta
			var k := minf(s.t / s.dur, 1.0)
			b.ground = s.from.lerp(s.to, k)
			b.h = PilFx.flight_height(k, s.dist)
			b.rot += s.spin * delta
			var hit := _find_hit(b.ground, b.h)
			if hit != null:
				_begin_capture(s, hit)
			elif k >= 1.0:
				_begin_landing(s)
		S.SUCK:
			s.t += delta
			var k2 := minf(s.t / 0.10, 1.0) # bóng dính vào thân Pilmon trong 0.1 giây đầu
			b.ground = s.enter_ground.lerp(s.hover, k2)
			b.h = lerpf(s.enter_h, MOB_CENTER_H, k2) + 3.0 * sin(s.t * 30.0)
			b.rot += delta * 14.0
			b.glow = 0.65 + 0.35 * sin(s.t * 24.0)
			_fx.fx_suck_tick(b.visual(), delta)
			if s.t >= SUCK_TIME:
				s.state = S.DROP
				s.vy = 0.0
				s.bounced = 0
				_fx.fx_wobble_ping(b.visual())
		S.DROP:
			s.vy -= GRAVITY * delta
			b.h += s.vy * delta
			b.rot = lerpf(b.rot, 0.0, minf(1.0, delta * 12.0))
			b.glow = maxf(0.0, b.glow - delta * 2.0)
			if b.h <= 0.0:
				b.h = 0.0
				if absf(s.vy) < 90.0 or s.bounced >= 2:
					_fx.fx_land(b.ground, 0.6)
					s.state = S.WOBBLE
					s.t = 0.0
					s.sub = 0
					s.wobble = 0
					b.rot = 0.0
					_fx.fx_wobble_ping(b.visual())
				else:
					s.vy = -s.vy * 0.4
					s.bounced += 1
					_fx.fx_land(b.ground, 0.8)
		S.WOBBLE:
			s.t += delta
			b.glow = maxf(0.0, b.glow - delta * 3.0)
			if s.sub == 0:
				var kw := minf(s.t / WOBBLE_TIME, 1.0)
				b.rot = sin(kw * TAU) * 0.55 * (1.0 if s.wobble % 2 == 0 else -1.0)
				if kw >= 1.0:
					s.sub = 1
					s.t = 0.0
					b.rot = 0.0
			elif s.t >= WOBBLE_REST:
				s.wobble += 1
				if s.wobble >= WOBBLES:
					if s.success and is_instance_valid(s.mob):
						_begin_win(s)
					else:
						_begin_escape(s)
				else:
					s.sub = 0
					s.t = 0.0
					b.glow = 1.0
					_fx.fx_wobble_ping(b.visual())
		S.WIN:
			s.t += delta
			var kv := minf(s.t / 0.5, 1.0)
			b.scale = 1.0 + 0.7 * sin(minf(kv * 2.0, 1.0) * PI * 0.5) - 0.5 * maxf(0.0, kv * 2.0 - 1.0)
			b.alpha = 1.0 - kv * kv
			b.h = kv * 30.0
			b.rot += delta * 6.0
			b.glow = 1.0 - kv
			if kv >= 1.0:
				return true
		S.LAND: # ném trượt: nảy 2 lần + lăn nhẹ rồi tan
			s.vy -= GRAVITY * delta
			b.h += s.vy * delta
			b.ground += s.slide * delta
			s.slide *= maxf(0.0, 1.0 - 4.0 * delta)
			b.rot += s.spin * 0.3 * delta
			if b.h <= 0.0:
				b.h = 0.0
				s.bounced += 1
				if s.bounced >= 2:
					s.state = S.FADE
					s.t = 0.0
					s.dur = 0.35
					_fx.fx_poof(b.ground)
				else:
					s.vy = 100.0
					_fx.fx_land(b.ground, 0.5)
		S.FADE:
			s.t += delta
			var kf := minf(s.t / s.dur, 1.0)
			b.alpha = 1.0 - kf
			b.scale = 1.0 - 0.35 * kf
			if s.in_water:
				b.h = -kf * 8.0
			if kf >= 1.0:
				return true
	return false


## Có Pilmon nào trong tầm trúng của bóng ở (ground, h) không (gần nhất). null nếu không.
func _find_hit(ground: Vector2, h: float) -> CharacterBody2D:
	if h > HIT_MAX_H:
		return null
	var best: CharacterBody2D = null
	var best_d := HIT_RADIUS * HIT_RADIUS
	for m in _mobs:
		if not is_instance_valid(m):
			continue
		var d: Vector2 = m.global_position - ground
		d.y *= 2.0 # mặt đất iso: dọc bị ép 1/2 nên hit-box là elip
		var dd := d.length_squared()
		if dd < best_d and m.visible and m.is_in_group(&"pilmon"):
			best_d = dd
			best = m
	return best


func _begin_capture(s: Shot, mob: CharacterBody2D) -> void:
	var b = s.ball
	b.flying = false
	b.glow = 1.0
	s.state = S.SUCK
	s.t = 0.0
	s.mob_type = str(mob.get("mob_type"))
	s.mob = mob
	# Snapshot and roll once on impact; preview and resolution share one formula.
	s.success = randf() < float(mob.call("capture_chance"))
	s.enter_ground = b.ground
	s.enter_h = b.h
	s.hover = mob.global_position
	var vis := s.hover + Vector2(0.0, -MOB_CENTER_H)
	mob.call("capture_into", vis, SUCK_TIME)
	_fx.fx_impact(vis, s.hover)


func _begin_landing(s: Shot) -> void:
	var b = s.ball
	b.flying = false
	s.t = 0.0
	s.bounced = 0
	if _map != null and not _map.is_land_at(b.ground):
		s.in_water = true
		s.state = S.FADE
		s.dur = 0.30
		_fx.fx_splash(b.ground)
		return
	s.state = S.LAND
	s.vy = 240.0
	s.slide = s.dir * 150.0
	_fx.fx_land(b.ground, 1.0)


func _begin_win(s: Shot) -> void:
	if is_instance_valid(s.mob):
		s.mob.queue_free()
	var b = s.ball
	s.state = S.WIN
	s.t = 0.0
	var vis: Vector2 = b.visual()
	_fx.fx_win(vis, b.ground)
	var count := int(caught.get(s.mob_type, 0)) + 1
	caught[s.mob_type] = count
	var shown: String = DISPLAY_NAMES.get(s.mob_type, s.mob_type.capitalize())
	var text := "Bắt được %s!" % shown
	if count > 1:
		text += " x%d" % count
	_fx.fx_toast(text, vis + Vector2(0.0, -34.0), PilFx.CREAM)
	captured.emit(s.mob_type, b.ground)


func _begin_escape(s: Shot) -> void:
	var b = s.ball
	if is_instance_valid(s.mob):
		s.mob.call("release_from_ball", _player)
	_fx.fx_escape(b.visual(), b.ground)
	s.state = S.FADE
	s.t = 0.0
	s.dur = 0.25


func reset_throws() -> void:
	_cancel_aim()
	for s in _shots:
		if is_instance_valid(s.mob) and bool(s.mob.get("captured")):
			s.mob.call("release_from_ball", _player)
	_shots.clear()
	_fx.balls.clear()
	_cooldown = 0.0
