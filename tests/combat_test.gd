extends SceneTree
## Run: Godot --headless --path . --script res://tests/combat_test.gd

const Mob := preload("res://scripts/characters/mob.gd")
const Thrower := preload("res://scripts/pilmon/pil_thrower.gd")
const Fx := preload("res://scripts/pilmon/pil_fx.gd")
const ButtonScript := preload("res://scripts/ui/hud_button.gd")
var _failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(value: bool, message: String) -> void:
	if not value:
		_failures += 1
		push_error(message)

func _run() -> void:
	var player = load("res://scenes/characters/player.tscn").instantiate()
	root.add_child(player)
	player.set_physics_process(false)
	var mob := Mob.new()
	mob.position = Vector2(60, 0)
	root.add_child(mob)
	mob.set_physics_process(false)
	_check(is_equal_approx(mob.capture_chance(), 0.2), "Healthy mob starts at 20 percent")
	player.attack()
	_check(mob.health == 82.0 and mob.stun == 34.0, "Attack deals damage and builds stun")
	_check(mob._enemy == player, "Damaged mob retaliates")
	_check(mob.capture_chance() > 0.2, "Missing health raises catch chance")
	mob.take_damage(18, player)
	var before_stun := mob.capture_chance()
	mob.take_damage(18, player)
	_check(mob.stun_left > 0.0 and mob.stun == 100.0, "Three hits stun the mob")
	_check(mob.capture_chance() > before_stun + 0.2, "Stun adds a catch bonus")
	var hp: float = player.health
	mob._combat_tick(1.0)
	_check(player.health == hp and mob.velocity == Vector2.ZERO, "Stunned mob cannot attack or move")
	mob._combat_tick(3.0)
	_check(mob.stun == 0.0 and mob.stun_left == 0.0, "Stun expires and clears the meter")
	mob.health = 1
	mob.stun_left = 2
	_check(is_equal_approx(mob.capture_chance(), 0.95), "Catch chance is capped at 95 percent")

	var layer := CanvasLayer.new()
	root.add_child(layer)
	var button := ButtonScript.new()
	layer.add_child(button)
	var thrower := Thrower.new()
	root.add_child(thrower)
	thrower.setup(null, player, [mob], button, layer)
	thrower.set_process(false)
	var shot := Thrower.Shot.new()
	shot.ball = Fx.Ball.new()
	shot.ball.ground = mob.global_position
	var feet := mob.global_position
	var saved_scale := mob.scale
	var saved_layer := mob.collision_layer
	thrower._begin_capture(shot, mob)
	_check(mob.captured and not mob.is_in_group("pilmon"), "Capture reserves mob against duplicate hits")
	_check(thrower.caught.is_empty(), "Capture attempt does not grant a reward")
	await create_timer(0.5).timeout
	_check(is_instance_valid(mob), "Mob stays alive inside the ball until resolution")
	shot.success = false
	shot.state = Thrower.S.WOBBLE
	shot.sub = 1
	shot.wobble = 1
	thrower._step_shot(shot, 1.0)
	_check(not mob.captured and mob.is_in_group("pilmon"), "Failed catch releases mob")
	_check(mob.global_position.is_equal_approx(feet) and mob.scale == saved_scale and mob.collision_layer == saved_layer, "Escape restores transform and collision")
	_check(mob.health == 1 and mob._enemy == player, "Escape preserves health and provokes mob")
	_check(thrower.caught.is_empty(), "Failed catch gives no reward")
	# An undamaged mob must also retaliate after escaping.
	mob.health = mob.max_health
	mob._enemy = null
	thrower._begin_capture(shot, mob)
	thrower._begin_escape(shot)
	_check(mob._enemy == player, "Escape provokes an undamaged mob")
	player._invulnerable = 0
	mob._attack_timer = 0
	mob._combat_tick(0.01)
	_check(player.health < hp, "Provoked mob damages player in range")
	thrower._begin_capture(shot, mob)
	shot.success = true
	shot.state = Thrower.S.WOBBLE
	shot.sub = 1
	shot.wobble = 1
	thrower._step_shot(shot, 1.0)
	_check(thrower.caught.get("mod1", 0) == 1 and mob.is_queued_for_deletion(), "Successful catch removes mob and grants one reward")
	player._invulnerable = 0
	player.take_damage(1000)
	_check(player.dead and player.health == 0, "Lethal damage defeats player")
	player._physics_process(2.1)
	_check(not player.dead and player.health == player.max_health, "Player respawns at full health")
	player.take_damage(10)
	_check(player.health == player.max_health, "Respawn grants temporary protection")
	var second := Mob.new()
	second.position = Vector2(Thrower.HAND_OFFSET + Thrower.MAX_RANGE, 0)
	root.add_child(second)
	second.set_physics_process(false)
	thrower._mobs = [second]
	thrower.set_aim_mode(true)
	thrower._aim_joy.set("_knob_offset", Vector2(-float(thrower._aim_joy.get("_travel")), 0))
	thrower._update_aim()
	_check(thrower._fx.aim_lock and is_equal_approx(thrower._fx.aim_chance, second.capture_chance()), "Joystick aim displays the target's catch chance")
	second.health = 25
	second.stun_left = 2
	thrower._update_aim()
	_check(is_equal_approx(thrower._fx.aim_chance, second.capture_chance()), "Aim preview refreshes after health and stun changes")
	var pending := Thrower.Shot.new()
	pending.ball = Fx.Ball.new()
	thrower._begin_capture(pending, second)
	thrower._shots.append(pending)
	thrower.reset_throws()
	_check(not second.captured and thrower._shots.is_empty() and not thrower._aim_mode, "World reset clears throws and restores pending mobs")
	second.take_damage(1000, player)
	_check(second.health == 0 and second.is_queued_for_deletion() and not second.is_in_group("pilmon"), "Defeated mobs cannot be caught or attacked again")
	layer.free()
	thrower.free()
	player.free()
	await process_frame
	print("Combat checks completed; failures: ", _failures)
	quit(1 if _failures else 0)
