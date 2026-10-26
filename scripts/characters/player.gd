extends CharacterBody2D

const CharacterDefs := preload("res://scripts/world/character_defs.gd")

# Phun lửa (fire_breath.gd) và vòng ma pháp (magic_circle.gd) tạm bỏ khỏi người chơi: sẽ gắn lại khi có hệ thống kỹ năng.

@export var speed := 220.0
@export var run_multiplier := 1.7
var terrain_map
var run_toggled := false
var facing_direction := Vector2.RIGHT
var _foot_half_width := 0.0 # nửa dài đoạn chân khi xét va chạm vật tĩnh
@onready var _sprite: AnimatedSprite2D = $AnimatedSprite2D

func _ready() -> void:
	# Game nhìn từ trên xuống, không có "sàn": GROUNDED khiến mob bị coi là nền/tường và dính vào nhau.
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	add_to_group("collider_debug") # để bản đồ vẽ collider khi bật nút Collider
	CharacterDefs.apply_collider(self, CharacterDefs.player_collider(), "player") # elip lấy từ data/player.json
	_foot_half_width = float(get_meta("foot_half_width", 0.0))
	$Camera2D.make_current()
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

func _add_key_binding(action: StringName, keycode: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	if not InputMap.action_has_event(action, event):
		InputMap.action_add_event(action, event)

func _physics_process(delta: float) -> void:
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit:
		_play_animation("idle")
		velocity = Vector2.ZERO
		move_and_slide()
		return
	# Di chuyển theo đúng hướng trên màn hình: A/D đi ngang, W/S đi dọc.
	var direction := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var joystick = get_tree().get_first_node_in_group("mobile_joystick")
	if joystick != null:
		direction = (direction + joystick.get_direction()).limit_length(1.0)
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
