extends CharacterBody2D

signal health_changed(current: float, maximum: float)
@export var max_health := 100.0
@export var attack_damage := 18.0
@export var attack_range := 115.0
@export var attack_interval := 0.45
var health := 100.0
var dead := false
var _attack_cooldown := 0.0
var _invulnerable := 0.0
var _respawn_left := 0.0
var _respawn_position := Vector2.ZERO
var _swing_left := 0.0

func take_damage(amount: float) -> void:
	if dead or _invulnerable > 0.0:
		return
	health = maxf(0.0, health - amount)
	_invulnerable = 0.35
	health_changed.emit(health, max_health)
	if health <= 0.0:
		dead = true
		_respawn_left = 2.0
		velocity = Vector2.ZERO
		_play_animation("idle")

func attack() -> void:
	if dead or _attack_cooldown > 0.0:
		return
	_attack_cooldown = attack_interval
	_swing_left = 0.18
	throw_pose(facing_direction)
	var best: Node2D = null
	var best_distance := attack_range
	for mob in get_tree().get_nodes_in_group("pilmon"):
		if not mob is Node2D or not mob.visible or mob.is_queued_for_deletion():
			continue
		var offset: Vector2 = mob.global_position - global_position
		var distance := offset.length()
		if distance < best_distance and (distance < 40.0 or offset.normalized().dot(facing_direction.normalized()) >= 0.25):
			best = mob
			best_distance = distance
	if best != null:
		best.call("take_damage", attack_damage, self, 34.0)

func _draw() -> void:
	if _swing_left > 0.0:
		var angle := facing_direction.angle()
		draw_arc(Vector2(0, -22), attack_range * 0.8, angle - 0.9, angle + 0.9, 24, Color(1.0, 0.85, 0.4, _swing_left / 0.18), 6.0, true)

const CharacterDefs := preload("res://scripts/world/character_defs.gd")

# Phun lửa (fire_breath.gd) và vòng ma pháp (magic_circle.gd) tạm bỏ khỏi người chơi: sẽ gắn lại khi có hệ thống kỹ năng.

@export var speed := 220.0
@export var run_multiplier := 1.7
var terrain_map
var run_toggled := false
var facing_direction := Vector2.RIGHT
var _foot_half_width := 0.0 # nửa dài đoạn chân khi xét va chạm vật tĩnh
## true: đang ngắm ném Pilball => mặt luôn quay theo hướng ném (không quay theo hướng đi).
var aiming := false
var _sprite_scale := Vector2.ONE
var _pose_tween: Tween
@onready var _sprite: AnimatedSprite2D = $AnimatedSprite2D

func _ready() -> void:
	health = max_health
	_respawn_position = global_position
	# Game nhìn từ trên xuống, không có "sàn": GROUNDED khiến mob bị coi là nền/tường và dính vào nhau.
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	add_to_group("collider_debug") # để bản đồ vẽ collider khi bật nút Collider
	CharacterDefs.apply_collider(self, CharacterDefs.player_collider(), "player") # elip lấy từ data/player.json
	_foot_half_width = float(get_meta("foot_half_width", 0.0))
	$Camera2D.make_current()
	_sprite_scale = _sprite.scale
	_sprite.play("idle")
	_add_key_binding("move_left", KEY_A)
	_add_key_binding("move_left", KEY_LEFT)
	_add_key_binding("move_right", KEY_D)
	_add_key_binding("move_right", KEY_RIGHT)
	_add_key_binding("move_up", KEY_W)
	_add_key_binding("move_up", KEY_UP)
	_add_key_binding("move_down", KEY_S)
	_add_key_binding("move_down", KEY_DOWN)
	_add_key_binding("run", KEY_SHIFT)
	_add_key_binding("attack", KEY_SPACE)

func _add_key_binding(action: StringName, keycode: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	if not InputMap.action_has_event(action, event):
		InputMap.action_add_event(action, event)

func _physics_process(delta: float) -> void:
	_attack_cooldown = maxf(0.0, _attack_cooldown - delta)
	_invulnerable = maxf(0.0, _invulnerable - delta)
	_swing_left = maxf(0.0, _swing_left - delta)
	_sprite.self_modulate = Color(1.0, 0.4, 0.4, 0.65) if _invulnerable > 0.0 else Color.WHITE
	queue_redraw()
	if dead:
		_respawn_left -= delta
		if _respawn_left <= 0.0:
			global_position = terrain_map.find_nearest_land(_respawn_position) if terrain_map != null else _respawn_position
			health = max_health
			dead = false
			_invulnerable = 2.0
			health_changed.emit(health, max_health)
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit:
		_play_animation("idle")
		velocity = Vector2.ZERO
		move_and_slide()
		return
	if Input.is_action_pressed("attack"):
		attack()
	# Di chuyển theo đúng hướng trên màn hình: A/D đi ngang, W/S đi dọc.
	var direction := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var joystick = get_tree().get_first_node_in_group("mobile_joystick")
	if joystick != null:
		direction = (direction + joystick.get_direction()).limit_length(1.0)
	if not aiming:
		if direction.x != 0.0:
			_sprite.flip_h = direction.x < 0.0
		if not direction.is_zero_approx():
			facing_direction = direction
	var running := Input.is_action_pressed("run") or run_toggled
	_play_animation("run" if running and not direction.is_zero_approx() else ("walk" if not direction.is_zero_approx() else "idle"))
	velocity = direction.normalized() * speed * (run_multiplier if running else 1.0)
	if terrain_map != null and not terrain_map.can_walk(global_position, global_position + velocity * delta, _foot_half_width):
		var horizontal := Vector2(velocity.x, 0.0)
		var vertical := Vector2(0.0, velocity.y)
		var can_move_x: bool = terrain_map.can_walk(global_position, global_position + horizontal * delta, _foot_half_width)
		var can_move_y: bool = terrain_map.can_walk(global_position, global_position + vertical * delta, _foot_half_width)
		if can_move_x and not can_move_y:
			velocity = horizontal
		elif can_move_y and not can_move_x:
			velocity = vertical
		else:
			velocity = Vector2.ZERO
	move_and_slide()

func _play_animation(animation_name: StringName) -> void:
	if _sprite.animation != animation_name:
		_sprite.play(animation_name)

## Quay mặt về hướng dir (chỉ lật ngang sprite).
func face_toward(dir: Vector2) -> void:
	if dir.x != 0.0:
		_sprite.flip_h = dir.x < 0.0
	if not dir.is_zero_approx():
		facing_direction = dir

## Tư thế ném: quay mặt + nhún nhẹ (co ngang rồi bật lại).
func throw_pose(dir: Vector2) -> void:
	face_toward(dir)
	if _pose_tween != null and _pose_tween.is_valid():
		_pose_tween.kill()
	_sprite.scale = _sprite_scale * Vector2(1.14, 0.86)
	_pose_tween = create_tween()
	_pose_tween.tween_property(_sprite, "scale", _sprite_scale, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
