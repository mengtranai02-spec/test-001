extends RefCounted
## Hiển thị ảnh vật phẩm (trong túi, danh sách nhặt, vật rơi trên map): mọi nơi gọi ItemIcon.draw(canvas, id, rect).
## Ảnh của vật phẩm nằm ở res://assets/items/<id>.png (id = khoá trong items.json, ví dụ stone.png, wood.png).
## Ảnh vẽ vừa khung rect, giữ nguyên tỉ lệ, nên mỗi nơi chỉ cần đưa khung to nhỏ khác nhau, không cần ảnh riêng từng cỡ.
## Khuyên dùng ảnh nền trong suốt, cạnh dài khoảng 96px (đủ nét cho khung tới ~48px, vẫn nhẹ).
## Ảnh được bọc CanvasTexture với bộ lọc mượt riêng, nên không phụ thuộc texture_filter của node vẽ (không còn kiểu pixel art).
## Không có ảnh ở đó thì thử ItemDefs.icon_texture(id) (đường dẫn cũ); vẫn không có thì vẽ tạm hình tròn màu kèm chữ cái đầu.

const ItemDefs := preload("res://scripts/inventory/item_defs.gd")

const DIR := "res://assets/items/"

static var _cache := {} # id -> CanvasTexture hoặc null (cũng nhớ cả ảnh không có, khỏi dò file mỗi lần vẽ)


## Ảnh của vật phẩm, null nếu chưa có file.
static func texture(id: String) -> Texture2D:
	if _cache.has(id):
		return _cache[id]
	var base: Texture2D = null
	var path := DIR + id + ".png"
	if ResourceLoader.exists(path):
		base = load(path) as Texture2D
	if base == null:
		base = ItemDefs.icon_texture(id) # ảnh cũ nếu item_defs.gd đang nạp từ thư mục khác: vẫn hiện, không mất icon
	var result: Texture2D = null
	if base != null:
		var ct := CanvasTexture.new()
		ct.diffuse_texture = base
		ct.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS # có bật Mipmaps khi import thì thu nhỏ mịn hơn nữa
		result = ct
	_cache[id] = result
	return result


## Vẽ icon vừa khung rect (giữ tỉ lệ ảnh). shadow: bóng đổ mềm phía dưới; bottom: áp sát đáy khung thay vì giữa khung
## (dùng cho vật nằm trên đất để đáy ảnh chạm bóng).
static func draw(ci: CanvasItem, id: String, rect: Rect2, shadow := true, bottom := false) -> void:
	var tex := texture(id)
	if tex == null:
		_draw_fallback(ci, id, rect)
		return
	var ts := tex.get_size()
	var k := minf(rect.size.x / ts.x, rect.size.y / ts.y)
	var sz := ts * k
	var pos := rect.position + (rect.size - sz) * 0.5
	if bottom:
		pos.y = rect.end.y - sz.y
	if shadow:
		ci.draw_texture_rect(tex, Rect2(pos + Vector2(0.0, 1.5 + sz.y * 0.05), sz), false, Color(0.0, 0.0, 0.0, 0.32))
	ci.draw_texture_rect(tex, Rect2(pos, sz), false)


static func _draw_fallback(ci: CanvasItem, id: String, rect: Rect2) -> void:
	var r := minf(rect.size.x, rect.size.y) * 0.42
	var c := rect.get_center()
	ci.draw_circle(c, r, Color.from_hsv(float(absi(hash(id)) % 360) / 360.0, 0.45, 0.85))
	ci.draw_arc(c, r, 0.0, TAU, 24, Color(0.15, 0.09, 0.06, 0.9), maxf(1.5, r * 0.12), true)
	var letter := id.capitalize().left(1)
	var font := ThemeDB.fallback_font
	var fs := maxi(10, roundi(r * 1.1))
	var w := font.get_string_size(letter, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	ci.draw_string(font, c + Vector2(-w * 0.5, fs * 0.35), letter, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.15, 0.09, 0.06))
