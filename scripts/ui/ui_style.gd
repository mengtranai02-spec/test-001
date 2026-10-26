extends RefCounted
## Kiểu nút dùng chung cho mọi nút trên màn hình (nút chạy, nút tương tác, nút túi, dòng danh sách vật phẩm rơi...).
## Muốn đổi hình dạng / màu của TẤT CẢ nút thì chỉ cần sửa các hằng số ở đây.
##
## Vì sao không dùng một StyleBoxFlat có viền như trước?
## Nền và viền đều bán trong suốt. Khi bật anti_aliasing, StyleBoxFlat vẽ nền và viền thành hai vùng
## kề nhau, mỗi vùng tự làm mờ mép của nó ngay đường ranh giới => ở đó cả hai chỉ phủ được một phần điểm ảnh,
## phần còn lại để lộ nền phía sau, nhìn như một vệt sáng / trắng nằm giữa viền và nền trong.
## Cách sửa: vẽ nền phủ kín toàn bộ nút (kể cả dưới viền), rồi vẽ viền (không có nền) đè lên trên.
## Như vậy ranh giới nền - viền luôn có nền bên dưới nên không còn khe hở.

const FILL := Color(1.0, 0.93, 0.72, 0.34)
const FILL_PRESSED := Color(1.0, 0.93, 0.72, 0.55)
const BORDER := Color(0.62, 0.45, 0.30, 0.60)         # viền nằm đè lên nền nên trông đậm hơn giá trị alpha này
const BORDER_PRESSED := Color(0.62, 0.45, 0.30, 0.85)
const RADIUS := 0.25          # bo góc, tính theo cạnh ngắn của nút
const BORDER_WIDTH := 0.055   # độ dày viền, tính theo cạnh ngắn của nút
const PRESS_INSET := 0.03     # nút thu nhỏ bao nhiêu khi đang nhấn (theo cạnh ngắn)

const TEXT := Color(1.0, 0.95, 0.82)
const TEXT_OUTLINE := Color(0.12, 0.07, 0.04, 0.95)


## Vẽ một nút vào canvas ci (gọi trong _draw của ci), chiếm hình chữ nhật rect.
static func draw_button(ci: CanvasItem, rect: Rect2, pressed: bool = false) -> void:
	var u: float = minf(rect.size.x, rect.size.y)
	var r: Rect2 = rect
	if pressed:
		r = rect.grow(-u * PRESS_INSET)
	var radius: int = roundi(u * RADIUS)
	var width: int = maxi(2, roundi(u * BORDER_WIDTH))

	var fill := StyleBoxFlat.new()
	fill.bg_color = FILL_PRESSED if pressed else FILL
	fill.set_corner_radius_all(radius)
	fill.anti_aliasing = true
	ci.draw_style_box(fill, r)

	var ring := StyleBoxFlat.new()
	ring.draw_center = false
	ring.border_color = BORDER_PRESSED if pressed else BORDER
	ring.set_border_width_all(width)
	ring.set_corner_radius_all(radius)
	ring.anti_aliasing = true
	ci.draw_style_box(ring, r)
