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
var _attacking := false
var _idle_after_attack := false
var _attack_hit_pending := false
var _attack_hit_timer := 0.0

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
		_attacking = false
		_attack_hit_pending = false
		_idle_after_attack = false
		_update_sword_sprites()
		_sprite.stop()
		_sprite.speed_scale = 1.0
		_sprite.play(_get_idle_animation())
		var sword_animation := get_node_or_null("AnimationPlayer") as AnimationPlayer
		if sword_animation != null:
			sword_animation.stop()

func attack() -> void:
	if dead or _attack_cooldown > 0.0 or _attacking:
		return
	_attack_cooldown = attack_interval
	_attacking = true
	_idle_after_attack = false
	_update_sword_sprites()
	_attack_hit_pending = true
	_attack_hit_timer = 0.3
	if _sprite.sprite_frames.has_animation("atk1"):
		_sprite.play("atk1")
		# atk1 is a one-shot; restore locomotion when its last frame finishes.
	else:
		_attacking = false
		_swing_left = 0.18
	var sword_animation := get_node_or_null("AnimationPlayer") as AnimationPlayer
	if sword_animation != null and sword_animation.has_animation("atk1"):
		var sword_attack := sword_animation.get_animation("atk1")
		if sword_attack != null:
			sword_attack.loop_mode = Animation.LOOP_NONE
		_sprite.pause()
		_sprite.set_frame_and_progress(0, 0.0)
		sword_animation.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		sword_animation.play("atk1")
		sword_animation.advance(0.0)
	throw_pose(facing_direction)

func _apply_attack_damage() -> void:
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
@onready var _sword_pivot: Node2D = $sword_pivot
@onready var _sword1: Sprite2D = $sword1
@onready var _sword2: Sprite2D = $sword_pivot/sword_anim/sword2

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
	_setup_attack_animation()
	_sprite.animation_finished.connect(_on_sprite_animation_finished)
	var sword_animation := get_node_or_null("AnimationPlayer") as AnimationPlayer
	if sword_animation != null and not sword_animation.animation_finished.is_connected(_on_sword_animation_finished):
		sword_animation.animation_finished.connect(_on_sword_animation_finished)
	_update_sword_sprites()
	_sprite.play(_get_idle_animation())
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

func _setup_attack_animation() -> void:
	var frames := _sprite.sprite_frames
	if frames.has_animation("atk1"):
		frames.set_animation_loop("atk1", false)
		return
	var directory := DirAccess.open("res://anim/player/atk1")
	if directory == null:
		return
	var frame_paths: Array[String] = []
	for file_name in directory.get_files():
		if file_name.get_extension().to_lower() == "png":
			frame_paths.append("res://anim/player/atk1/" + file_name)
	frame_paths.sort()
	if frame_paths.is_empty():
		return
	frames.add_animation("atk1")
	frames.set_animation_loop("atk1", false)
	frames.set_animation_speed("atk1", 20.0)
	for frame_path in frame_paths:
		var texture := load(frame_path) as Texture2D
		if texture != null:
			frames.add_frame("atk1", texture)

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
			_attack_cooldown = 0.0
			_attacking = false
			_idle_after_attack = false
			_attack_hit_pending = false
			_update_sword_sprites()
			_sprite.play(_get_idle_animation())
			health_changed.emit(health, max_health)
		return
	var sword_animation := get_node_or_null("AnimationPlayer") as AnimationPlayer
	if _attacking and sword_animation != null and sword_animation.current_animation == "atk1" and sword_animation.is_playing():
		sword_animation.advance(delta)
	if _attack_hit_pending:
		_attack_hit_timer -= delta
		if _attack_hit_timer <= 0.0:
			_attack_hit_pending = false
			_apply_attack_damage()
	var focus := get_viewport().gui_get_focus_owner()
	var ui_manager := get_tree().get_first_node_in_group("ui_manager")
	var ui_locked := ui_manager != null and bool(ui_manager.call("gameplay_input_blocked"))
	if focus is LineEdit or ui_locked:
		if not _attacking:
			_play_animation(_get_idle_animation())
		velocity = Vector2.ZERO
		move_and_slide()
		return
	if Input.is_action_just_pressed("attack"):
		attack()
	# Di chuyển theo đúng hướng trên màn hình: A/D đi ngang, W/S đi dọc.
	var direction := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var joystick = get_tree().get_first_node_in_group("mobile_joystick")
	if joystick != null:
		direction = (direction + joystick.get_direction()).limit_length(1.0)
	if not _attacking and not aiming:
		if direction.x != 0.0:
			_sprite.flip_h = direction.x < 0.0
			_update_sword_facing()
		if not direction.is_zero_approx():
			facing_direction = direction
	if _attacking:
		direction = Vector2.ZERO
	var running := Input.is_action_pressed("run") or run_toggled
	if not _attacking:
		if not direction.is_zero_approx():
			_idle_after_attack = false
			_update_sword_sprites()
			_play_animation("run" if running else "walk")
		else:
			_play_animation(_get_idle_animation())
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

func _get_idle_animation() -> StringName:
	var wanted: StringName = "idle2" if _idle_after_attack else "idle1"
	if _sprite.sprite_frames.has_animation(wanted):
		return wanted
	var alternate: StringName = "idle1" if _idle_after_attack else "idle2"
	if _sprite.sprite_frames.has_animation(alternate):
		return alternate
	var animation_names := _sprite.sprite_frames.get_animation_names()
	if not animation_names.is_empty():
		return StringName(animation_names[0])
	return StringName()

func _on_sprite_animation_finished() -> void:
	var sword_animation := get_node_or_null("AnimationPlayer") as AnimationPlayer
	if _sprite.animation == "atk1" and (sword_animation == null or not sword_animation.is_playing() or sword_animation.current_animation != "atk1"):
		_attacking = false
		_idle_after_attack = true
		_update_sword_sprites()
		_sprite.speed_scale = 1.0

func _on_sword_animation_finished(animation_name: StringName) -> void:
	if animation_name == "atk1" and _attacking:
		_sprite.stop()
		_sprite.speed_scale = 1.0
		_attacking = false
		_idle_after_attack = true
		_update_sword_sprites()

func _update_sword_sprites() -> void:
	var use_sword2 := _attacking or _idle_after_attack
	_sword1.visible = not use_sword2
	_sword2.visible = use_sword2

## Quay mặt về hướng dir (chỉ lật ngang sprite).
func face_toward(dir: Vector2) -> void:
	if dir.x != 0.0:
		_sprite.flip_h = dir.x < 0.0
		_update_sword_facing()
	if not dir.is_zero_approx():
		facing_direction = dir

func _update_sword_facing() -> void:
	# Reflect the full animated sword transform across the player's vertical axis.
	_sword_pivot.scale.x = -1.0 if _sprite.flip_h else 1.0

## Tư thế ném: quay mặt + nhún nhẹ (co ngang rồi bật lại).
func throw_pose(dir: Vector2) -> void:
	face_toward(dir)
	if _pose_tween != null and _pose_tween.is_valid():
		_pose_tween.kill()
	_sprite.scale = _sprite_scale * Vector2(1.14, 0.86)
	_pose_tween = create_tween()
	_pose_tween.tween_property(_sprite, "scale", _sprite_scale, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
