extends RefCounted
## Vẽ icon vật phẩm vào một ô vuông của canvas (gọi trong _draw). Có ảnh thì dùng ảnh, chưa có thì vẽ hình tạm.

const ItemDefs := preload("res://scripts/inventory/item_defs.gd")


static func draw(ci: CanvasItem, id: String, rect: Rect2) -> void:
	var tex := ItemDefs.icon_texture(id)
	if tex != null:
		var s := minf(rect.size.x / tex.get_width(), rect.size.y / tex.get_height())
		var sz := Vector2(tex.get_width(), tex.get_height()) * s
		ci.draw_texture_rect(tex, Rect2(rect.get_center() - sz * 0.5, sz), false)
		return
	var item := ItemDefs.get_item(id)
	var col: Color = item.get("color", Color(0.7, 0.7, 0.7))
	match String(item.get("shape", "")):
		"stone":
			_stone(ci, rect, col)
		"log":
			_log(ci, rect, col)
		_:
			_letter(ci, rect, col, str(item.get("name", "?")))


static func _poly(c: Vector2, h: Vector2, unit: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in unit:
		out.append(c + (p as Vector2) * h)
	return out


static func _stone(ci: CanvasItem, rect: Rect2, col: Color) -> void:
	var c := rect.get_center()
	var h := rect.size * 0.45
	var body := _poly(c, h, [Vector2(-0.95, 0.25), Vector2(-0.70, -0.45), Vector2(-0.15, -0.85), Vector2(0.50, -0.70),
		Vector2(0.95, -0.10), Vector2(0.80, 0.55), Vector2(0.10, 0.85), Vector2(-0.60, 0.70)])
	var shine := _poly(c, h, [Vector2(-0.55, -0.05), Vector2(-0.40, -0.45), Vector2(-0.05, -0.62), Vector2(0.20, -0.45),
		Vector2(-0.10, -0.25)])
	var loop := body.duplicate()
	loop.append(body[0])
	ci.draw_colored_polygon(body, col)
	ci.draw_colored_polygon(shine, col.lightened(0.35))
	ci.draw_polyline(loop, col.darkened(0.55), maxf(2.0, rect.size.x * 0.04), true)


static func _log(ci: CanvasItem, rect: Rect2, col: Color) -> void:
	var c := rect.get_center()
	var h := rect.size * 0.45
	var dark := col.darkened(0.55)
	var body := _poly(c, h, [Vector2(-0.95, -0.40), Vector2(0.60, -0.40), Vector2(0.60, 0.40), Vector2(-0.95, 0.40)])
	var cap := PackedVector2Array()
	for i in 20: # mặt cắt gỗ (hình elip) ở đầu bên phải
		var a := TAU * i / 20.0
		cap.append(c + Vector2(0.60 + cos(a) * 0.30, sin(a) * 0.40) * h)
	var cap_loop := cap.duplicate()
	cap_loop.append(cap[0])
	var w := maxf(2.0, rect.size.x * 0.04)
	ci.draw_colored_polygon(body, col)
	ci.draw_line(c + Vector2(-0.90, -0.12) * h, c + Vector2(0.55, -0.12) * h, dark, w * 0.6, true)
	ci.draw_line(c + Vector2(-0.80, 0.14) * h, c + Vector2(0.55, 0.14) * h, dark, w * 0.6, true)
	ci.draw_line(c + Vector2(-0.95, -0.40) * h, c + Vector2(0.60, -0.40) * h, dark, w, true)
	ci.draw_line(c + Vector2(-0.95, 0.40) * h, c + Vector2(0.60, 0.40) * h, dark, w, true)
	ci.draw_line(c + Vector2(-0.95, -0.40) * h, c + Vector2(-0.95, 0.40) * h, dark, w, true)
	ci.draw_colored_polygon(cap, col.lightened(0.40))
	ci.draw_arc(c + Vector2(0.60, 0.0) * h, h.y * 0.18, 0.0, TAU, 16, dark, w * 0.6, true)
	ci.draw_polyline(cap_loop, dark, w, true)


static func _letter(ci: CanvasItem, rect: Rect2, col: Color, item_name: String) -> void:
	var u := minf(rect.size.x, rect.size.y)
	var box := Rect2(rect.get_center() - Vector2(u, u) * 0.42, Vector2(u, u) * 0.84)
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.border_color = col.darkened(0.55)
	sb.set_border_width_all(maxi(2, roundi(u * 0.04)))
	sb.set_corner_radius_all(roundi(u * 0.16))
	ci.draw_style_box(sb, box)
	var font := ThemeDB.fallback_font
	var fs := roundi(u * 0.5)
	var ch := item_name.substr(0, 1).to_upper()
	var sz := font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	ci.draw_string(font, rect.get_center() + Vector2(-sz.x * 0.5, fs * 0.35), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.95))
