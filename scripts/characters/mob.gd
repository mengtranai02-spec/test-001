extends CharacterBody2D

const CharacterDefs := preload("res://scripts/world/character_defs.gd")

@export_enum("mod1", "mod2") var mob_type := "mod1"
@export var speed := 55.0
@export var roam_radius := Vector2(850.0, 600.0)
@export var state_change_min := 1.5
@export var state_change_max := 4.0
var terrain_map

## SpriteFrames dựng một lần cho mỗi loại mob rồi dùng chung cho mọi mob
## => sinh mob mới không còn quét thư mục / nạp ảnh mỗi lần (tránh giật khi sinh bù).
static var _frames_cache: Dictionary = {}

var _rng := RandomNumberGenerator.new()
var _sprite: AnimatedSprite2D
var _home_position := Vector2.ZERO
var _move_direction := Vector2.ZERO
var _state_timer := 0.0
var _is_walking := false
var _foot_half_width := 0.0 # nửa dài đoạn chân khi xét va chạm vật tĩnh
## Đã bị Pilball bắt: đứng yên, không còn bị ném trúng nữa (xem capture_into).
var captured := false
@export var max_health := 100.0
@export var attack_damage := 10.0
@export var attack_range := 64.0
@export var attack_interval := 1.1
@export var stun_threshold := 100.0
@export var stun_duration := 3.5
var health := 100.0
var stun := 0.0
var stun_left := 0.0
var _enemy: Node2D
var _attack_timer := 0.0
var _capture_tween: Tween
var _saved_layer := 0
var _saved_mask := 0
var _saved_scale := Vector2.ONE
var _capture_feet := Vector2.ZERO
var _hit_flash := 0.0

func capture_chance() -> float:
	return clampf(0.20 + 0.65 * (1.0 - health / max_health) + (0.20 if stun_left > 0.0 else 0.0), 0.05, 0.95)

func provoke(attacker: Node2D) -> void:
	_enemy = attacker
	_attack_timer = maxf(_attack_timer, 0.45)

func take_damage(amount: float, attacker: Node2D, stun_amount: float = 34.0) -> void:
	if captured or health <= 0.0:
		return
	health = maxf(0.0, health - amount)
	provoke(attacker)
	_hit_flash = 0.15
	if stun_left <= 0.0:
		stun = minf(stun_threshold, stun + stun_amount)
		if stun >= stun_threshold:
			stun_left = stun_duration
	queue_redraw()
	if health <= 0.0:
		remove_from_group("pilmon")
		queue_free()

func _combat_tick(delta: float) -> bool:
	_attack_timer = maxf(0.0, _attack_timer - delta)
	_hit_flash = maxf(0.0, _hit_flash - delta)
	_sprite.self_modulate = Color(2.0, 0.5, 0.5) if _hit_flash > 0.0 else Color.WHITE
	queue_redraw()
	if stun_left > 0.0:
		stun_left = maxf(0.0, stun_left - delta)
		if stun_left == 0.0:
			stun = 0.0
		velocity = Vector2.ZERO
		_sprite.play("idle")
		return true
	if not is_instance_valid(_enemy):
		return false
	if _enemy.get("dead") or global_position.distance_to(_enemy.global_position) > 850.0:
		_enemy = null
		_change_state()
		return false
	var offset := _enemy.global_position - global_position
	velocity = offset.normalized() * speed * 1.8 if offset.length() > attack_range else Vector2.ZERO
	if terrain_map != null and not terrain_map.can_walk(global_position, global_position + velocity * delta, _foot_half_width):
		velocity = Vector2.ZERO
	_sprite.flip_h = offset.x < 0.0
	_sprite.play("idle" if velocity.is_zero_approx() else "walk")
	if offset.length() <= attack_range and _attack_timer <= 0.0:
		_attack_timer = attack_interval
		_enemy.call("take_damage", attack_damage)
		_hit_flash = 0.12
	move_and_slide()
	return true

func release_from_ball(attacker: Node2D) -> void:
	if _capture_tween != null and _capture_tween.is_valid():
		_capture_tween.kill()
	global_position = _capture_feet
	scale = _saved_scale
	_sprite.self_modulate = Color.WHITE
	collision_layer = _saved_layer
	collision_mask = _saved_mask
	captured = false
	add_to_group("pilmon")
	add_to_group("collider_debug")
	# Escaping breaks the stun and starts retaliation even without prior damage.
	stun = 0.0
	stun_left = 0.0
	provoke(attacker)
	_sprite.play("idle")
	queue_redraw()

func _draw() -> void:
	if captured or health <= 0.0:
		return
	var origin := Vector2(-34.0, -78.0)
	draw_rect(Rect2(origin - Vector2(2, 2), Vector2(72, 17)), Color(0.08, 0.06, 0.08, 0.9))
	draw_rect(Rect2(origin, Vector2(68.0 * health / max_health, 6)), Color(0.4, 0.9, 0.35))
	draw_rect(Rect2(origin + Vector2(0, 9), Vector2(68.0 * stun / stun_threshold, 4)), Color(1.0, 0.8, 0.2))
	if stun_left > 0.0:
		var font := ThemeDB.fallback_font
		draw_string_outline(font, Vector2(-30, -87), "CHOÁNG", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 4, Color.BLACK)
		draw_string(font, Vector2(-30, -87), "CHOÁNG", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1.0, 0.85, 0.2))

func _ready() -> void:
	health = max_health
	# Game nhìn từ trên xuống, không có "sàn": GROUNDED khiến mob bị coi là nền/tường và dính vào người chơi.
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	add_to_group("collider_debug") # để bản đồ vẽ collider khi bật nút Collider
	add_to_group("pilmon")         # mục tiêu của Pilball (pil_thrower.gd)
	CharacterDefs.apply_collider(self, CharacterDefs.mob_collider(mob_type), "mob:" + mob_type) # elip lấy từ data/mobs.json
	_foot_half_width = float(get_meta("foot_half_width", 0.0))
	_rng.randomize()
	_home_position = global_position
	_sprite = AnimatedSprite2D.new()
	_sprite.name = "AnimatedSprite2D"
	_sprite.sprite_frames = _get_frames(mob_type)
	add_child(_sprite)
	_change_state()

func _physics_process(delta: float) -> void:
	if captured:
		return
	if _combat_tick(delta):
		return
	_state_timer -= delta
	if _state_timer <= 0.0:
		_change_state()

	if _is_walking:
		var to_home := _home_position - global_position
		if absf(to_home.x) > roam_radius.x or absf(to_home.y) > roam_radius.y:
			_move_direction = to_home.normalized()
		velocity = _move_direction * speed
		if terrain_map != null and not terrain_map.can_walk(global_position, global_position + velocity * delta, _foot_half_width):
			velocity = Vector2.ZERO
			_move_direction = Vector2.ZERO
			_state_timer = minf(_state_timer, 0.4)
		if not is_zero_approx(_move_direction.x):
			_sprite.flip_h = _move_direction.x < 0.0
	else:
		velocity = Vector2.ZERO

	move_and_slide()

## Hút vào cầu, giữ lại thực thể để có thể phục hồi nếu bắt thất bại.
func capture_into(target: Vector2, suck_time: float) -> void:
	if captured:
		return
	captured = true
	_saved_layer = collision_layer
	_saved_mask = collision_mask
	_saved_scale = scale
	_capture_feet = global_position
	queue_redraw()
	velocity = Vector2.ZERO
	collision_layer = 0
	collision_mask = 0
	remove_from_group("pilmon")
	remove_from_group("collider_debug")
	_sprite.pause()
	var pull := suck_time - 0.10
	var tw := create_tween().set_parallel(true)
	_capture_tween = tw
	tw.tween_property(_sprite, "self_modulate", Color(4.0, 4.0, 4.0, 1.0), 0.07)
	tw.tween_property(_sprite, "self_modulate", Color(1.7, 0.75, 0.45, 0.0), pull).from(Color(4.0, 4.0, 4.0, 1.0)).set_delay(0.10).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(self, "global_position", target, pull).set_delay(0.10).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.tween_property(self, "scale", Vector2(0.08, 0.08), pull).set_delay(0.10).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	# Keep the mob alive inside the ball until the thrower resolves the roll.

func _change_state() -> void:
	_is_walking = _rng.randf() < 0.65
	if _is_walking:
		_move_direction = Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)).normalized()
		_sprite.play("walk")
	else:
		_move_direction = Vector2.ZERO
		_sprite.play("idle")
	_state_timer = _rng.randf_range(state_change_min, state_change_max)

static func _get_frames(type: String) -> SpriteFrames:
	if not _frames_cache.has(type):
		_frames_cache[type] = _build_sprite_frames(type)
	return _frames_cache[type]

static func _build_sprite_frames(type: String) -> SpriteFrames:
	var frames := SpriteFrames.new()
	frames.remove_animation(&"default")
	for animation_name in ["idle", "walk"]:
		frames.add_animation(animation_name)
		frames.set_animation_loop(animation_name, true)
		frames.set_animation_speed(animation_name, 5.0 if animation_name == "idle" else 10.0)
		var folder := "res://anim/%s/%s" % [type, animation_name]
		# Khi export (APK...) ảnh trong res:// không còn là "xxx.png" mà chỉ còn "xxx.png.import" (hoặc ".remap"):
		# bỏ đuôi đó để lấy lại tên ảnh gốc, load() vẫn nạp được bằng tên gốc.
		var names: Array[String] = []
		for f in DirAccess.get_files_at(folder):
			var n := f.trim_suffix(".import").trim_suffix(".remap")
			if n.get_extension().to_lower() == "png" and not names.has(n):
				names.append(n)
		names.sort()
		for file_name in names:
			var texture := load(folder.path_join(file_name)) as Texture2D
			if texture != null:
				frames.add_frame(animation_name, texture)
	return frames
