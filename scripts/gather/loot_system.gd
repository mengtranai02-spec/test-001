extends Node
## Vật phẩm rơi trên đất: chặt cây / đập đá xong thì vật phẩm bắn ra quanh vật thể, nằm đó cho tới khi được nhặt.
## Quét các vật phẩm quanh người chơi, báo danh sách cho loot_panel.gd hiển thị, nhặt bằng phím F (món gần nhất)
## hoặc bằng cách chạm vào dòng của món đó trên danh sách. Gọi setup() một lần sau khi map, người chơi, túi đồ và giao diện đã có.

const ItemDefs := preload("res://scripts/inventory/item_defs.gd")

const SCAN_INTERVAL := 0.1       # giây giữa các lần quét vật phẩm quanh người chơi
const PICKUP_RADIUS := 150.0     # vật phẩm trong bán kính này (px) thì hiện trong danh sách và nhặt được
const SORT_BUCKET := 24.0        # xếp theo khoảng cách làm tròn theo nấc này để danh sách không nhảy loạn khi đi lại
const MAX_DROPS := 150           # quá số này thì vật phẩm cũ nhất biến mất
const SCATTER_MIN := 34.0        # vật phẩm văng cách vật thể tối thiểu / tối đa (px)
const SCATTER_MAX := 78.0
const MIN_SEPARATION := 30.0     # hai vật phẩm rơi cùng lúc không nằm sát nhau hơn mức này (px)

## entries: [{"drop": Drop, "id": String, "count": int, ...}], gần nhất trước.
signal nearby_changed(entries: Array)

var map
var player: Node2D
var inventory
var hud                          # cần hàm toast(text) và is_open()

var _drops: Array = []           # mọi vật phẩm đang nằm trên đất
var _nearby: Array = []          # các mục trong tầm nhặt, gần nhất trước
var _last_sig: Array = []
var _scan := 0.0
var _rng := RandomNumberGenerator.new()


## Một vật phẩm nằm trên đất: bóng + icon (icon nhấp nhô nhẹ cho dễ thấy). Là con của lớp vật thể để y-sort chung.
class Drop extends Node2D:
	const ItemIcon := preload("res://scripts/inventory/item_icon.gd")
	const ICON_SIZE := 46.0
	const ARC_HEIGHT := 46.0     # độ cao đường bay lúc văng ra (px)
	const BOB := 5.0             # biên độ nhấp nhô (px)

	var id := ""
	var count := 1
	var landed := false          # đã chạm đất mới nhặt được
	var _icon: Node2D

	func _ready() -> void:
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST # icon pixel art
		_icon = Node2D.new()
		add_child(_icon)
		_icon.draw.connect(_draw_icon)

	func set_count(n: int) -> void:
		count = n
		if _icon != null:
			_icon.queue_redraw()

	## Văng từ origin tới landing theo đường vòng cung (bóng đi thẳng trên đất, icon bay lên rồi rơi xuống).
	func launch(origin: Vector2, landing: Vector2) -> void:
		global_position = origin
		var tw := create_tween()
		tw.tween_method(_fly.bind(origin, landing), 0.0, 1.0, 0.4)
		tw.tween_callback(_land)

	## Bay về phía người nhặt rồi biến mất.
	func collect(target: Vector2) -> void:
		landed = false
		var tw := create_tween()
		tw.tween_property(self, "global_position", target + Vector2(0.0, -28.0), 0.16)
		tw.parallel().tween_property(self, "modulate:a", 0.0, 0.16)
		tw.tween_callback(queue_free)

	func _fly(t: float, origin: Vector2, landing: Vector2) -> void:
		global_position = origin.lerp(landing, t)
		_icon.position.y = -sin(t * PI) * ARC_HEIGHT

	func _land() -> void:
		landed = true
		_icon.position.y = 0.0
		var tw := create_tween().set_loops()
		tw.set_trans(Tween.TRANS_SINE)
		tw.tween_property(_icon, "position:y", -BOB, 0.8).from(0.0)
		tw.tween_property(_icon, "position:y", 0.0, 0.8).from(-BOB)

	func _draw() -> void:
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0, 0.45))
		draw_circle(Vector2.ZERO, ICON_SIZE * 0.32, Color(0.0, 0.0, 0.0, 0.28))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	func _draw_icon() -> void:
		var rect := Rect2(Vector2(-ICON_SIZE * 0.5, -ICON_SIZE - 8.0), Vector2(ICON_SIZE, ICON_SIZE))
		ItemIcon.draw(_icon, id, rect)


func _ready() -> void:
	_rng.randomize()
	_ensure_action("pickup", KEY_F)


func setup(p_map, p_player: Node2D, p_inventory, p_hud) -> void:
	map = p_map
	player = p_player
	inventory = p_inventory
	hud = p_hud
	map.world_reset.connect(_on_world_reset)


func _physics_process(delta: float) -> void:
	if map == null or not is_instance_valid(player):
		return
	_scan -= delta
	if _scan > 0.0:
		return
	_scan = SCAN_INTERVAL
	_rescan()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("pickup"):
		return
	if is_instance_valid(hud) and hud.is_open():
		return
	if _nearby.is_empty():
		return
	var first: Dictionary = _nearby[0]
	pickup(first["drop"])
	get_viewport().set_input_as_handled()


# ---------------------------------------------------------------- rơi vật phẩm

## Gọi khi chặt / đập xong: drops = [{"id": String, "count": int}, ...] văng ra quanh world_pos.
func spawn_drops(world_pos: Vector2, drops: Array) -> void:
	if map == null:
		return
	var root: Node = map.object_root if is_instance_valid(map.object_root) else map
	var used: Array = []
	for d: Dictionary in drops:
		var amount: int = int(d["count"])
		if amount <= 0 or not ItemDefs.has_item(str(d["id"])):
			continue
		var drop := Drop.new()
		drop.id = str(d["id"])
		drop.count = amount
		root.add_child(drop)
		var landing: Vector2 = _pick_landing(world_pos, used)
		used.append(landing)
		drop.launch(world_pos, landing)
		drop.tree_exiting.connect(_on_drop_exiting.bind(drop))
		_drops.append(drop)
	while _drops.size() > MAX_DROPS:
		var oldest = _drops.pop_front()
		if is_instance_valid(oldest):
			oldest.queue_free()


## Điểm rơi: quanh origin, phải là đất, không nằm trong collider, và không sát vật phẩm vừa rơi cùng lúc.
func _pick_landing(origin: Vector2, used: Array) -> Vector2:
	for i in 12:
		var offset := Vector2.from_angle(_rng.randf() * TAU) * _rng.randf_range(SCATTER_MIN, SCATTER_MAX)
		offset.y *= 0.6 # nền iso: ép dẹt theo chiều dọc
		var p: Vector2 = origin + offset
		if not (map.is_land_at(p) and not map.is_blocked_at(p)):
			continue
		var crowded := false
		for u: Vector2 in used:
			if u.distance_to(p) < MIN_SEPARATION:
				crowded = true
				break
		if not crowded:
			return p
	return origin


# ---------------------------------------------------------------- nhặt

## Nhặt cả chồng vào túi. Túi không đủ chỗ thì nhặt được bao nhiêu lấy bấy nhiêu, phần còn lại nằm lại trên đất.
func pickup(drop) -> bool:
	if not is_instance_valid(drop) or not _drops.has(drop):
		return false
	var leftover: int = inventory.add(drop.id, drop.count)
	var taken: int = drop.count - leftover
	if leftover > 0 and is_instance_valid(hud):
		hud.toast("Túi đồ đã đầy")
	if taken <= 0:
		return false
	if leftover > 0:
		drop.set_count(leftover)
	else:
		_drops.erase(drop)
		drop.collect(player.global_position)
	_rescan() # cập nhật danh sách ngay, không chờ lần quét kế tiếp
	return true


# ---------------------------------------------------------------- quét quanh người chơi

func _rescan() -> void:
	if not is_instance_valid(player):
		return
	var here: Vector2 = player.global_position
	var found: Array = []
	for node in _drops:
		if not is_instance_valid(node):
			continue
		var drop := node as Drop
		if drop == null or not drop.landed:
			continue
		var dist: float = drop.global_position.distance_to(here)
		if dist > PICKUP_RADIUS:
			continue
		found.append({
			"drop": drop, "id": drop.id, "count": drop.count,
			"bucket": int(dist / SORT_BUCKET), "order": drop.get_instance_id(),
		})
	found.sort_custom(_by_distance)

	var sig: Array = [] # chỉ phát tín hiệu khi danh sách thật sự đổi (món nào, thứ tự, số lượng)
	for e: Dictionary in found:
		sig.append(int(e["order"]))
		sig.append(int(e["count"]))
	if sig == _last_sig:
		return
	_last_sig = sig
	_nearby = found
	nearby_changed.emit(found)


static func _by_distance(a: Dictionary, b: Dictionary) -> bool:
	var ba: int = int(a["bucket"])
	var bb: int = int(b["bucket"])
	if ba != bb:
		return ba < bb
	return int(a["order"]) < int(b["order"])


func _on_drop_exiting(drop) -> void:
	_drops.erase(drop)


func _on_world_reset() -> void:
	for node in _drops:
		if is_instance_valid(node):
			node.queue_free()
	_drops.clear()
	_nearby.clear()
	_last_sig = []
	nearby_changed.emit([])


func _ensure_action(action: StringName, keycode: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode
	if not InputMap.action_has_event(action, ev):
		InputMap.action_add_event(action, ev)
