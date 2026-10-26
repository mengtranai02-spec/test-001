extends Node
## Thu thập: tìm vật thể (cây, khúc gỗ, đá nhỏ, tảng đá) trong tầm với của người chơi theo luật data/gather.json,
## ra đòn khi bấm "interact" (phím E / nút tương tác), phát vật phẩm và đổi vật thể (cây -> gốc cây, đá -> biến mất).
## Chặt / đập: vật phẩm rơi ra đất (signal drops_spawned, loot_system.gd lo phần nhặt). Nhặt thẳng (icon "pickup"): vào túi luôn.
## Gọi setup() một lần sau khi map, người chơi, túi đồ và giao diện đã có.

const ItemDefs := preload("res://scripts/inventory/item_defs.gd")
const DATA_PATH := "res://data/gather.json"
const SCAN_INTERVAL := 0.1     # giây giữa các lần quét tìm mục tiêu
const MAX_REACH := 2.0         # chỉ xét vật thể trong bán kính này (ô), luật riêng của từng vật còn có reach nhỏ hơn
const HIT_BAR_SECONDS := 1.6   # thanh số đòn hiện bao lâu sau mỗi đòn
const SHAKE_PX := 3.0          # vật thể rung ngang bao nhiêu px khi trúng đòn
const FX_COLORS := {
	"wood": Color(0.64, 0.43, 0.25),
	"stone": Color(0.72, 0.74, 0.78),
}
const RULE_DEFAULTS := {
	"verb": "Tương tác", "target_name": "", "icon": "pickup",
	"hits": 1, "reach": 1.0, "cooldown": 0.4, "repeat": false, "tool": "",
	"drops": [], "leaves": [], "fx": "",
}

## icon_kind rỗng = không có mục tiêu (ẩn nút). label = chữ hiện dưới nút tương tác.
signal prompt_changed(icon_kind: String, label: String)

## Chặt / đập xong: vật phẩm rơi ra đất tại world_pos (loot_system.gd nhận và tạo vật phẩm). drops = [{"id", "count"}].
signal drops_spawned(world_pos: Vector2, drops: Array)

var map
var player: Node2D
var inventory
var hud                          # cần hàm toast(text) và is_open()

var _rules: Dictionary = {}      # id nhóm -> luật
var _sprite_rules: Dictionary = {} # tên sprite -> khoá ghi đè luật
var _rule_cache: Dictionary = {} # tên sprite -> luật đã gộp
var _target: Dictionary = {}
var _hits: Dictionary = {}       # Vector2i (khoá vật thể) -> số đòn đã nhận
var _cooldown := 0.0
var _scan := 0.0
var _bar: Node2D
var _rng := RandomNumberGenerator.new()


## Thanh số đòn nhỏ hiện phía trên vật thể đang bị đánh.
class HitBar extends Node2D:
	var fraction := 0.0
	var life := 0.0

	func show_bar(pos: Vector2, frac: float, seconds: float) -> void:
		global_position = pos
		fraction = frac
		life = seconds
		visible = true
		set_process(true)
		queue_redraw()

	func _process(delta: float) -> void:
		life -= delta
		if life <= 0.0:
			visible = false
			set_process(false)

	func _draw() -> void:
		var w := 46.0
		draw_rect(Rect2(-w * 0.5 - 2.0, -2.0, w + 4.0, 10.0), Color(0.12, 0.07, 0.04, 0.8))
		draw_rect(Rect2(-w * 0.5, 0.0, w * clampf(fraction, 0.0, 1.0), 6.0), Color(0.96, 0.80, 0.35, 0.95))


func _ready() -> void:
	_rng.randomize()
	_ensure_action("interact", KEY_E)
	_load_rules()


func setup(p_map, p_player: Node2D, p_inventory, p_hud) -> void:
	map = p_map
	player = p_player
	inventory = p_inventory
	hud = p_hud
	map.world_reset.connect(_on_world_reset)


func _physics_process(delta: float) -> void:
	if map == null or not is_instance_valid(player):
		return
	_cooldown = maxf(0.0, _cooldown - delta)
	_scan -= delta
	if _scan <= 0.0:
		_scan = SCAN_INTERVAL
		_set_target(_find_target())
	if _target.is_empty() or _cooldown > 0.0:
		return
	if get_viewport().gui_get_focus_owner() is LineEdit:
		return # đang gõ seed
	if is_instance_valid(hud) and hud.is_open():
		return
	var rule: Dictionary = _target["rule"]
	var wants := Input.is_action_pressed("interact") if rule["repeat"] else Input.is_action_just_pressed("interact")
	if wants:
		_strike(_target)


# ---------------------------------------------------------------- tìm mục tiêu
func _find_target() -> Dictionary:
	var best: Dictionary = {}
	var best_score := INF
	var facing: Vector2 = player.get("facing_direction") if player.get("facing_direction") != null else Vector2.ZERO
	for c: Dictionary in map.find_gatherables(player.global_position, MAX_REACH):
		var rule := _rule_for(c["name"], c["group"])
		if rule.is_empty() or float(c["dist"]) > float(rule["reach"]):
			continue
		var score: float = c["dist"]
		var to: Vector2 = (c["world"] as Vector2) - player.global_position
		if facing != Vector2.ZERO and to.length() > 1.0:
			score -= 0.25 * facing.normalized().dot(to.normalized()) # ưu tiên vật ở phía người chơi đang nhìn
		if score < best_score:
			best_score = score
			best = {"key": c["key"], "name": c["name"], "world": c["world"], "rule": rule}
	return best


func _set_target(t: Dictionary) -> void:
	var changed: bool = t.is_empty() != _target.is_empty() or (not t.is_empty() and t["key"] != _target["key"])
	_target = t
	if changed:
		_emit_prompt()


func _emit_prompt() -> void:
	if _target.is_empty():
		prompt_changed.emit("", "")
		return
	var rule: Dictionary = _target["rule"]
	var label := ("%s %s" % [rule["verb"], rule["target_name"]]).strip_edges()
	var taken := int(_hits.get(_target["key"], 0))
	if taken > 0 and int(rule["hits"]) > 1:
		label += " (%d/%d)" % [taken, int(rule["hits"])]
	prompt_changed.emit(str(rule["icon"]), label)


# ---------------------------------------------------------------- ra đòn
func _strike(t: Dictionary) -> void:
	var rule: Dictionary = t["rule"]
	var key: Vector2i = t["key"]
	var tool_id := str(rule["tool"])
	if tool_id != "" and not inventory.has(tool_id):
		_say("Cần %s để %s" % [ItemDefs.item_name(tool_id), str(rule["verb"]).to_lower()])
		_cooldown = 0.7
		return
	var taken := int(_hits.get(key, 0)) + 1
	var is_last := taken >= int(rule["hits"])
	var to_ground: bool = str(rule["icon"]) != "pickup" # chặt / đập: vật phẩm rơi ra đất; nhặt thẳng (đá nhỏ...): vào túi luôn
	var drops: Array = []
	if is_last:
		drops = _roll_drops(rule)
		if not to_ground and not inventory.can_add_all(drops):
			_say("Túi đồ đã đầy")
			_cooldown = 0.7
			return
	_cooldown = float(rule["cooldown"])
	_hit_fx(t, rule)
	if not is_last:
		_hits[key] = taken
		_show_bar(t, float(taken) / float(rule["hits"]))
		_emit_prompt()
		return
	_hits.erase(key)
	if is_instance_valid(_bar):
		_bar.visible = false
		_bar.set_process(false)
	if to_ground:
		var origin: Vector2 = t["world"]
		drops_spawned.emit(origin, drops)
	else:
		for d: Dictionary in drops:
			inventory.add(d["id"], int(d["count"]))
	var leaves: Array = rule["leaves"]
	var new_name := "" if leaves.is_empty() else str(leaves[absi(hash(key)) % leaves.size()])
	map.replace_prop(key, new_name)
	_target = {}
	_set_target(_find_target())
	_emit_prompt()


func _roll_drops(rule: Dictionary) -> Array:
	var merged: Dictionary = {}
	for d: Dictionary in rule["drops"]:
		if _rng.randf() > float(d.get("chance", 1.0)):
			continue
		var n := _rng.randi_range(int(d.get("min", 1)), int(d.get("max", 1)))
		if n > 0:
			merged[str(d["item"])] = int(merged.get(str(d["item"]), 0)) + n
	var out: Array = []
	for id in merged:
		out.append({"id": id, "count": merged[id]})
	return out


func _say(text: String) -> void:
	if is_instance_valid(hud):
		hud.toast(text)


# ---------------------------------------------------------------- hiệu ứng
func _hit_fx(t: Dictionary, rule: Dictionary) -> void:
	var node: Node2D = map.get_prop_node(t["key"])
	if node != null:
		if not node.has_meta("home_x"):
			node.set_meta("home_x", node.position.x) # luôn về đúng chỗ dù hai đòn chồng nhau
		var x0: float = node.get_meta("home_x")
		var tw := node.create_tween()
		tw.tween_property(node, "position:x", x0 + SHAKE_PX, 0.04)
		tw.tween_property(node, "position:x", x0 - SHAKE_PX, 0.06)
		tw.tween_property(node, "position:x", x0, 0.05)
	_spawn_chips(t["world"], str(rule["fx"]))


func _spawn_chips(world_pos: Vector2, fx: String) -> void:
	var p := CPUParticles2D.new()
	p.one_shot = true
	p.explosiveness = 0.95
	p.amount = 8
	p.lifetime = 0.5
	p.direction = Vector2(0, -1)
	p.spread = 75.0
	p.gravity = Vector2(0, 520)
	p.initial_velocity_min = 90.0
	p.initial_velocity_max = 170.0
	p.scale_amount_min = 2.0
	p.scale_amount_max = 3.5
	p.color = FX_COLORS.get(fx, Color(0.8, 0.8, 0.8))
	p.z_index = 3
	var root: Node = map.object_root if is_instance_valid(map.object_root) else map
	root.add_child(p)
	p.global_position = world_pos + Vector2(0, -18)
	p.emitting = true
	get_tree().create_timer(1.0).timeout.connect(p.queue_free)


func _show_bar(t: Dictionary, fraction: float) -> void:
	if _bar == null or not is_instance_valid(_bar):
		_bar = HitBar.new()
		_bar.z_index = 4
		var root: Node = map.object_root if is_instance_valid(map.object_root) else map
		root.add_child(_bar)
	var node: Sprite2D = map.get_prop_node(t["key"])
	var top := 70.0
	if node != null and node.texture != null:
		top = node.texture.get_height() * node.scale.y + 8.0
	_bar.show_bar((t["world"] as Vector2) + Vector2(0, -top), fraction, HIT_BAR_SECONDS)


# ---------------------------------------------------------------- dữ liệu
func _on_world_reset() -> void:
	_hits.clear()
	_target = {}
	_emit_prompt()


func _rule_for(sprite_name: String, group_id: String) -> Dictionary:
	if _rule_cache.has(sprite_name):
		return _rule_cache[sprite_name]
	var rule: Dictionary = {}
	if _rules.has(group_id):
		rule = RULE_DEFAULTS.duplicate(true)
		rule.merge(_rules[group_id], true)
		rule.merge(_sprite_rules.get(sprite_name, {}), true)
	_rule_cache[sprite_name] = rule
	return rule


func _load_rules() -> void:
	var res = load(DATA_PATH)
	var raw = res.data if res is JSON else JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
	if not (raw is Dictionary):
		push_warning("Không đọc được %s" % DATA_PATH)
		return
	_rules = raw.get("rules", {})
	_sprite_rules = raw.get("sprites", {})
	_rule_cache.clear()


func _ensure_action(action: StringName, keycode: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode
	if not InputMap.action_has_event(action, ev):
		InputMap.action_add_event(action, ev)
