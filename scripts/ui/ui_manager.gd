extends CanvasLayer
## CanvasLayer duy nhất chứa UI trong màn chơi.

var _gameplay_controls: Array[CanvasItem] = []
var map_open := false
var inventory_open := false
var inventory_ui: Control
@onready var controls: Control = $Controls
@onready var modal_overlay: Control = $ModalOverlay


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("ui_manager")


func set_inventory_ui(ui: Control) -> void:
	inventory_ui = ui


func set_inventory_open(open: bool) -> void:
	inventory_open = open
	modal_overlay.visible = open


func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null:
		return
	if inventory_open:
		if key.physical_keycode == KEY_E or key.physical_keycode == KEY_ESCAPE:
			return
		get_viewport().set_input_as_handled()
		return
	if map_open:
		if key.physical_keycode == KEY_M or key.physical_keycode == KEY_ESCAPE:
			return
		get_viewport().set_input_as_handled()
		return
	if key.pressed and not key.echo and key.physical_keycode == KEY_E and is_instance_valid(inventory_ui):
		inventory_ui.call("toggle")
		get_viewport().set_input_as_handled()


func gameplay_input_blocked() -> bool:
	return inventory_open or map_open


func register_gameplay_control(control: CanvasItem) -> void:
	if control not in _gameplay_controls:
		_gameplay_controls.append(control)
	control.visible = not map_open


func set_map_open(open: bool) -> void:
	map_open = open
	for control in _gameplay_controls:
		if not is_instance_valid(control):
			continue
		if control.has_method("set_active"):
			control.call("set_active", not open)
		else:
			control.visible = not open
