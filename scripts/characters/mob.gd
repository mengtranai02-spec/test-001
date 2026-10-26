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

func _ready() -> void:
	# Game nhìn từ trên xuống, không có "sàn": GROUNDED khiến mob bị coi là nền/tường và dính vào người chơi.
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	add_to_group("collider_debug") # để bản đồ vẽ collider khi bật nút Collider
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
