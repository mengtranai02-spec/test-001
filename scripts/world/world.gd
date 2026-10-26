extends Node2D

@export var map_scene: PackedScene
@export var player_scene: PackedScene
@export var mob_scene: PackedScene = preload("res://scenes/characters/mob.tscn")
@export var world_seed := 7

const MOB_TYPES := ["mod1", "mod2"]
const HudButton := preload("res://scripts/ui/hud_button.gd")
const NightGlow := preload("res://scripts/world/night_glow.gd")
const Inventory := preload("res://scripts/inventory/inventory.gd")
const InventoryUI := preload("res://scripts/inventory/inventory_ui.gd")
const GatherSystem := preload("res://scripts/gather/gather_system.gd")
const LootSystem := preload("res://scripts/gather/loot_system.gd")
const LootPanel := preload("res://scripts/gather/loot_panel.gd")

# --- sinh mob lần đầu khi chunk được dựng (kể cả vùng ban đầu) ---
const SPAWN_CHANCE := 0.6                     # xác suất mỗi chunk mới có mob
const MAX_MOBS_PER_CHUNK := 6                 # số mob tối đa mỗi chunk lúc sinh ra (= "sức chứa" của chunk; chunk 16 ô nên rộng gấp 4 chunk cũ)
const MAX_ALIVE_MOBS := 60                    # trần an toàn số mob đang tồn tại cùng lúc
const MIN_SPAWN_DISTANCE_TO_PLAYER := 250.0   # không sinh mob sát người chơi (px)

# --- bật/tắt/xoá mob theo khoảng cách ---
const ACTIVE_MARGIN_CHUNKS := 1               # mob ngoài (màn hình + margin này) bị đóng băng
const DESPAWN_MARGIN_CHUNKS := 2              # mob ngoài (màn hình + margin này) bị xoá hẳn
const MOB_CHECK_INTERVAL := 0.5               # giây giữa các lần kiểm tra

# --- sinh bù cho khu vực thiếu mob (bị giết / bị xoá) ---
const RESPAWN_INTERVAL := 3.0                 # giây giữa các lần xét sinh bù
const RESPAWN_MARGIN_CHUNKS := 1              # chỉ sinh bù quanh người chơi (phải nhỏ hơn DESPAWN_MARGIN_CHUNKS)
const RESPAWN_CHANCE := 0.2                   # xác suất mỗi chunk thiếu mob được sinh bù mỗi lần xét
const RESPAWN_MAX_PER_TICK := 3               # tối đa mob sinh bù mỗi lần xét (tránh giật)
const RESPAWN_HIDE_MARGIN := 200.0            # không sinh bù trong khung nhìn camera + viền này (px)

# --- chu kỳ ngày đêm (CanvasModulate nhuộm màu cả thế giới; giao diện nằm trên CanvasLayer nên không bị nhuộm) ---
const DAY_LENGTH := 240.0   # số giây cho một ngày đêm đầy đủ
const DAY_START := 0.30     # giờ bắt đầu: 0 = nửa đêm, 0.25 = bình minh, 0.5 = trưa, 0.75 = hoàng hôn
const DAY_KEYS := [         # [mốc trong ngày 0..1, màu nhuộm]; mốc đầu và cuối phải cùng màu để nối vòng
	[0.00, Color(0.30, 0.36, 0.60)],  # nửa đêm
	[0.20, Color(0.38, 0.42, 0.66)],  # trước bình minh
	[0.28, Color(1.00, 0.80, 0.68)],  # bình minh
	[0.38, Color(1.00, 0.97, 0.92)],  # buổi sáng
	[0.62, Color(1.00, 1.00, 1.00)],  # trưa, chiều
	[0.74, Color(1.00, 0.84, 0.66)],  # xế chiều
	[0.82, Color(0.95, 0.58, 0.46)],  # hoàng hôn
	[0.90, Color(0.50, 0.44, 0.66)],  # chạng vạng
	[1.00, Color(0.30, 0.36, 0.60)],  # nửa đêm
]

var _map
var _day_tint: CanvasModulate
var _day_gradient := Gradient.new()
var _day_time := DAY_START
var _day_auto := true            # true: thời gian tự trôi; false: đứng yên ở giờ đã chọn
var _time_slider: HSlider
var _time_label: Label
var _player: Node2D
var _inventory                     # Inventory (inventory.gd)
var _inventory_ui: Control         # inventory_ui.gd
var _gather                        # gather_system.gd
var _interact_button: HudButton    # nút tương tác theo ngữ cảnh (Chặt / Đập / Nhặt)
var _loot                          # loot_system.gd
var _loot_panel: Control           # loot_panel.gd
var _seed_input: LineEdit
var _coordinate_label: Label
var _minimap: Control
var _last_coord := Vector2i(1 << 30, 1 << 30)

var _rng := RandomNumberGenerator.new()
var _mobs: Array[CharacterBody2D] = []
var _chunk_capacity: Dictionary = {}  # Vector2i -> số mob chunk đó có lúc mới sinh ra (chỉ chunk đã từng dựng)
var _chunk_counts: Dictionary = {}    # Vector2i -> số mob hiện có (làm mới mỗi MOB_CHECK_INTERVAL)
var _mob_timer := 0.0
var _respawn_timer := RESPAWN_INTERVAL


func _ready() -> void:
	_register_actions()
	_rng.randomize()
	# Vật / thực thể (con trực tiếp của node này) nằm thấp hơn trên màn hình => gần camera hơn => vẽ đè lên vật phía sau.
	y_sort_enabled = true
	_map = map_scene.instantiate()
	_map.object_root = self # cây / đá... là con của world => y-sort chung với người chơi và mob
	_map.z_index = _map.Z_TERRAIN # mặt đất luôn nằm dưới bóng và mọi vật thể (lưới debug z=10 bên trong vẫn nằm trên)
	add_child(_map)
	_map.chunk_built.connect(_on_chunk_built)
	_map.set_world_seed(world_seed)
	_player = player_scene.instantiate()
	_player.position = _map.find_nearest_land(Vector2.ZERO)
	_player.set("terrain_map", _map)
	add_child(_player)
	_map.target = _player
	_create_seed_ui()
	_create_mobile_joystick()
	_create_gameplay_ui()
	_create_day_night()
	_create_inventory_and_gather()


func _process(delta: float) -> void:
	_update_coordinate_label()
	_update_day_night(delta)

	_mob_timer -= delta
	if _mob_timer <= 0.0:
		_mob_timer = MOB_CHECK_INTERVAL
		_update_mobs()

	_respawn_timer -= delta
	if _respawn_timer <= 0.0:
		_respawn_timer = RESPAWN_INTERVAL
		_respawn_tick()


func _update_coordinate_label() -> void:
	if not is_instance_valid(_player) or not is_instance_valid(_coordinate_label):
		return
	# Toạ độ theo màn hình, đơn vị = kích thước 1 ô iso (rộng TILE_W, cao TILE_H):
	# đi ngang (A/D) chỉ đổi X, đi dọc (W/S) chỉ đổi Y.
	var local: Vector2 = _map.to_local(_player.global_position)
	var coord := Vector2i(floori(local.x / _map.TILE_W), floori(local.y / _map.TILE_H))
	if coord == _last_coord:
		return
	_last_coord = coord
	_coordinate_label.text = "X: %d   Y: %d" % [coord.x, coord.y]


# ---------------------------------------------------------------- mob

## Chunk được dựng lần đầu (kể cả vùng ban đầu) => sinh mob trong chính chunk đó
## và ghi nhớ "sức chứa" của chunk để sau này sinh bù khi thiếu mob.
func _on_chunk_built(coord: Vector2i) -> void:
	if _chunk_capacity.has(coord):
		return # chunk load lại: không sinh lần đầu nữa, việc sinh bù do _respawn_tick lo
	var capacity := 0
	if _rng.randf() <= SPAWN_CHANCE:
		var want := _rng.randi_range(1, MAX_MOBS_PER_CHUNK)
		var land_found := false
		for i in want:
			var pos: Vector2 = _map.random_land_in_chunk(coord, _rng)
			if not pos.is_finite():
				continue
			land_found = true
			if _mobs.size() >= MAX_ALIVE_MOBS or _is_too_close_to_player(pos):
				continue # chưa sinh được lúc này; sức chứa vẫn giữ để sinh bù sau
			_spawn_mob(pos, coord)
		if land_found:
			capacity = want
	_chunk_capacity[coord] = capacity


func _is_too_close_to_player(pos: Vector2) -> bool:
	return is_instance_valid(_player) \
		and pos.distance_squared_to(_player.global_position) < MIN_SPAWN_DISTANCE_TO_PLAYER * MIN_SPAWN_DISTANCE_TO_PLAYER


func _spawn_mob(world_pos: Vector2, chunk: Vector2i) -> void:
	var mob := mob_scene.instantiate() as CharacterBody2D
	mob.position = to_local(world_pos) # đặt trước add_child để _home_position đúng
	mob.set("mob_type", MOB_TYPES[_rng.randi() % MOB_TYPES.size()])
	mob.set("terrain_map", _map)
	mob.tree_exiting.connect(_on_mob_exiting.bind(mob)) # mob bị queue_free (bị giết...) tự rời danh sách
	add_child(mob)
	_mobs.append(mob)
	_chunk_counts[chunk] = int(_chunk_counts.get(chunk, 0)) + 1


func _on_mob_exiting(mob: CharacterBody2D) -> void:
	_mobs.erase(mob)


## Mob gần màn hình: chạy bình thường. Hơi xa: đóng băng (không tốn CPU). Rất xa: xoá hẳn.
## Đồng thời đếm lại số mob mỗi chunk cho _respawn_tick.
func _update_mobs() -> void:
	_chunk_counts.clear()
	for i in range(_mobs.size() - 1, -1, -1):
		var mob := _mobs[i]
		if mob.is_queued_for_deletion():
			continue
		var chunk: Vector2i = _map.world_to_chunk(mob.global_position)
		if not _map.is_chunk_near_view(chunk, DESPAWN_MARGIN_CHUNKS):
			mob.queue_free()
			_mobs.remove_at(i)
			continue
		_chunk_counts[chunk] = int(_chunk_counts.get(chunk, 0)) + 1
		var mode := Node.PROCESS_MODE_INHERIT if _map.is_chunk_near_view(chunk, ACTIVE_MARGIN_CHUNKS) \
			else Node.PROCESS_MODE_DISABLED
		if mob.process_mode != mode: # chỉ đổi khi trạng thái thật sự thay đổi
			mob.process_mode = mode
			mob.visible = mode == Node.PROCESS_MODE_INHERIT


## Chunk quanh người chơi có ít mob hơn "sức chứa" => có xác suất sinh thêm 1 mob,
## nhưng chỉ ở điểm KHÔNG nằm trong khung nhìn camera.
func _respawn_tick() -> void:
	if _mobs.size() >= MAX_ALIVE_MOBS:
		return
	var r: Rect2i = _map.get_chunk_range(RESPAWN_MARGIN_CHUNKS)
	if r.size.x <= 0 or r.size.y <= 0:
		return

	var candidates: Array[Vector2i] = []
	for cy in range(r.position.y, r.end.y):
		for cx in range(r.position.x, r.end.x):
			var c := Vector2i(cx, cy)
			if int(_chunk_capacity.get(c, 0)) > int(_chunk_counts.get(c, 0)):
				candidates.append(c)
	candidates.shuffle()

	var spawned := 0
	for c in candidates:
		if spawned >= RESPAWN_MAX_PER_TICK or _mobs.size() >= MAX_ALIVE_MOBS:
			break
		if _rng.randf() > RESPAWN_CHANCE:
			continue
		var pos := _find_hidden_land_point(c)
		if not pos.is_finite():
			continue
		_spawn_mob(pos, c)
		spawned += 1


## Điểm đất ngẫu nhiên trong chunk, nằm ngoài khung nhìn camera. Vector2.INF nếu không có.
func _find_hidden_land_point(c: Vector2i) -> Vector2:
	for i in 6:
		var p: Vector2 = _map.random_land_in_chunk(c, _rng, 4)
		if p.is_finite() and not _map.is_world_pos_on_screen(p, RESPAWN_HIDE_MARGIN):
			return p
	return Vector2.INF


func _clear_mobs() -> void:
	for mob in _mobs:
		mob.queue_free()
	_mobs.clear()
	_chunk_capacity.clear()
	_chunk_counts.clear()


# ---------------------------------------------------------------- UI

func _create_mobile_joystick() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 1
	add_child(layer)
	var joystick := Control.new()
	joystick.set_script(preload("res://scripts/world/mobile_joystick.gd"))
	layer.add_child(joystick)
	# Hiện chỉ có nút chạy; phun lửa và vòng ma pháp tạm bỏ, sẽ quay lại khi có hệ thống kỹ năng.
	_add_hud_button(layer, &"run", "run", 0.160, 0.462, 0.237)


## Nút trên màn hình: kích thước và vị trí tính theo chiều cao màn hình (xem hud_button.gd).
func _add_hud_button(layer: CanvasLayer, action: StringName, icon: String, size_h: float, from_right_h: float, from_bottom_h: float) -> HudButton:
	var button := HudButton.new()
	button.action = action
	button.icon_kind = icon
	button.size_h = size_h
	button.from_right_h = from_right_h
	button.from_bottom_h = from_bottom_h
	layer.add_child(button)
	return button


## Phím tắt của giao diện, đăng ký một lần ở đây (phím di chuyển do player.gd tự đăng ký).
func _register_actions() -> void:
	for pair in [["interact", KEY_E], ["pickup", KEY_F], ["inventory", KEY_I]]:
		var action := StringName(pair[0])
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		var ev := InputEventKey.new()
		ev.physical_keycode = pair[1]
		if not InputMap.action_has_event(action, ev):
			InputMap.action_add_event(action, ev)


## Túi đồ + thu thập (layer 5, đè lên minimap): nút túi và bảng túi đồ, nút tương tác theo ngữ cảnh,
## hệ thống thu thập, vật phẩm rơi trên đất + danh sách nhặt.
func _create_inventory_and_gather() -> void:
	_inventory = Inventory.new()
	var layer := CanvasLayer.new() # CanvasLayer riêng nên không bị CanvasModulate ban đêm nhuộm tối
	layer.layer = 5
	add_child(layer)
	_loot_panel = Control.new() # thêm TRƯỚC bảng túi đồ: mở túi thì lớp mờ của bảng che và chặn luôn danh sách này
	_loot_panel.set_script(LootPanel)
	layer.add_child(_loot_panel)
	_inventory_ui = Control.new()
	_inventory_ui.set_script(InventoryUI)
	layer.add_child(_inventory_ui)
	_inventory_ui.setup(_inventory)

	_interact_button = _add_hud_button(layer, &"interact", "", 0.16, 0.462, 0.50)
	_interact_button.hide_when_idle = true
	_interact_button.visible = false

	_gather = GatherSystem.new()
	add_child(_gather)
	_gather.setup(_map, _player, _inventory, _inventory_ui)
	_gather.prompt_changed.connect(_interact_button.set_prompt)

	_loot = LootSystem.new()
	add_child(_loot)
	_loot.setup(_map, _player, _inventory, _inventory_ui)
	_loot_panel.setup(_loot, _inventory_ui.bag_button())
	_gather.drops_spawned.connect(Callable(_loot, "spawn_drops")) # chặt cây / đập đá xong => vật phẩm rơi ra đất
	_inventory_ui.item_dropped.connect(Callable(_loot, "drop_at_player")) # kéo vật phẩm ra ngoài bảng túi => vứt ra đất


func _create_day_night() -> void:
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for key in DAY_KEYS:
		offsets.append(key[0])
		colors.append(key[1])
	_day_gradient.offsets = offsets
	_day_gradient.colors = colors
	_day_tint = CanvasModulate.new()
	add_child(_day_tint)
	_apply_day_tint()


## Đặt giờ trong ngày (0..1) khi cần, ví dụ nạp game hoặc nút debug.
func set_time_of_day(t: float) -> void:
	_day_time = fposmod(t, 1.0)
	_apply_day_tint()
	_refresh_time_ui()


func _update_day_night(delta: float) -> void:
	if not is_instance_valid(_day_tint):
		return
	if not _day_auto:
		return
	_day_time = fposmod(_day_time + delta / DAY_LENGTH, 1.0)
	_apply_day_tint()
	_refresh_time_ui()


## Cập nhật thanh trượt + nhãn giờ (0 = 00:00 nửa đêm, 0.5 = 12:00 trưa) mà không phát lại tín hiệu.
func _refresh_time_ui() -> void:
	if is_instance_valid(_time_slider):
		_time_slider.set_value_no_signal(_day_time)
	if is_instance_valid(_time_label):
		var hours := int(_day_time * 24.0)
		var mins := int(fposmod(_day_time * 1440.0, 60.0))
		_time_label.text = "Giờ %02d:%02d" % [hours, mins]


## CanvasModulate nhuộm sprite, bóng, mob...; mặt đất dùng shader unshaded nên nhận màu qua biến toàn cục day_tint.
func _apply_day_tint() -> void:
	if not is_instance_valid(_day_tint):
		return
	var c := _day_gradient.sample(_day_time)
	_day_tint.color = c
	NightGlow.tint = c # hiệu ứng lửa / ma pháp dùng để biết trời tối cỡ nào
	RenderingServer.global_shader_parameter_set("day_tint", c)


func _create_seed_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(14, 14)
	layer.add_child(panel)
	var row := HBoxContainer.new()
	panel.add_child(row)
	_coordinate_label = Label.new()
	_coordinate_label.text = "X: 0   Y: 0"
	row.add_child(_coordinate_label)
	var label := Label.new()
	label.text = "Seed"
	row.add_child(label)
	_seed_input = LineEdit.new()
	_seed_input.text = str(world_seed)
	_seed_input.custom_minimum_size = Vector2(150, 0)
	_seed_input.placeholder_text = "Enter seed"
	_seed_input.text_submitted.connect(_on_seed_submitted)
	row.add_child(_seed_input)
	var button := Button.new()
	button.text = "Generate world"
	button.pressed.connect(_apply_seed_from_ui)
	row.add_child(button)

func _create_gameplay_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 2
	add_child(layer)
	_minimap = Control.new()
	_minimap.set_script(preload("res://scripts/world/minimap.gd"))
	_minimap.player = _player
	_minimap.terrain_map = _map
	layer.add_child(_minimap)
	var panel := VBoxContainer.new()
	panel.position = Vector2(14, 72)
	layer.add_child(panel)
	_create_day_controls(panel)
	var iso := Button.new()
	iso.text = "Iso grid: OFF"
	iso.toggle_mode = true
	iso.toggled.connect(func(on: bool):
		_map.show_iso_grid = on
		iso.text = "Iso grid: ON" if on else "Iso grid: OFF")
	panel.add_child(iso)
	var chunks := Button.new()
	chunks.text = "Chunk grid: OFF"
	chunks.toggle_mode = true
	chunks.toggled.connect(func(on: bool):
		_map.show_chunk_grid = on
		chunks.text = "Chunk grid: ON" if on else "Chunk grid: OFF")
	panel.add_child(chunks)
	var colliders := Button.new()
	colliders.text = "Collider: OFF"
	colliders.toggle_mode = true
	colliders.toggled.connect(func(on: bool):
		_map.show_colliders = on
		colliders.text = "Collider: ON" if on else "Collider: OFF")
	panel.add_child(colliders)


## Điều khiển ngày đêm: thanh trượt chọn giờ + nút bật / tắt tự trôi.
func _create_day_controls(panel: VBoxContainer) -> void:
	_time_label = Label.new()
	panel.add_child(_time_label)
	_time_slider = HSlider.new()
	_time_slider.min_value = 0.0
	_time_slider.max_value = 1.0
	_time_slider.step = 0.001
	_time_slider.custom_minimum_size = Vector2(200, 24)
	_time_slider.focus_mode = Control.FOCUS_NONE # không cướp phím mũi tên của người chơi
	_time_slider.value_changed.connect(set_time_of_day) # kéo thanh trượt = chọn giờ
	panel.add_child(_time_slider)
	var auto := Button.new()
	auto.text = "Ngày đêm: TỰ TRÔI"
	auto.toggle_mode = true
	auto.button_pressed = _day_auto
	auto.focus_mode = Control.FOCUS_NONE
	auto.toggled.connect(func(on: bool):
		_day_auto = on
		auto.text = "Ngày đêm: TỰ TRÔI" if on else "Ngày đêm: DỪNG")
	panel.add_child(auto)
	_refresh_time_ui()


func _on_seed_submitted(_text: String) -> void:
	_apply_seed_from_ui()


func _apply_seed_from_ui() -> void:
	if not _seed_input.text.is_valid_int():
		_seed_input.text = str(world_seed)
		return
	world_seed = _seed_input.text.to_int()
	_clear_mobs() # mob + sức chứa chunk của thế giới cũ không còn hợp lệ
	_map.set_world_seed(world_seed)
	_minimap.clear_exploration()
	# Let WASD / arrow keys return to the player after submitting the seed.
	get_viewport().gui_release_focus()
