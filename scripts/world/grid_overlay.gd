extends Node2D

var _was_on := false

func _process(_delta: float) -> void:
	var map := get_parent()
	var on: bool = map.show_iso_grid or map.show_chunk_grid or map.show_colliders
	# Khi vừa tắt vẫn phải vẽ lại 1 lần: draw_grid sẽ thoát sớm => xoá sạch đường kẻ cũ.
	if on or _was_on:
		queue_redraw()
	_was_on = on
	visible = on

func _draw() -> void:
	get_parent().draw_grid(self)
