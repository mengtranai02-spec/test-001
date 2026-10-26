// Đung đưa: chỉ dịch ngang các đỉnh phía trên của sprite (sprite là 1 hình chữ nhật nên thành nghiêng nhẹ), càng cao so với
// gốc node càng lệch nhiều. Mỗi vật lệch pha theo vị trí để không lắc đồng loạt. Dùng chung 2 material cho mọi vật thể (map.gd).
shader_type canvas_item;

uniform float strength = 4.0;    // px lệch tối đa ở ngọn (px sprite gốc, trước khi nhân scale)
uniform float height = 170.0;    // cao hơn gốc node bao nhiêu px thì lệch tối đa

// Chu kỳ lắc (giây). 3600 / PERIOD là số nguyên nên không giật khi TIME quay vòng sau 3600 giây.
const float PERIOD = 3.6;

void vertex() {
	float a = TIME * TAU / PERIOD;
	vec2 p = MODEL_MATRIX[3].xy;
	float ph = p.x * 0.013 + p.y * 0.009;
	float gust = sin(a + ph) + 0.4 * sin(2.0 * a + ph * 1.7);
	float w = clamp(-VERTEX.y / height, 0.0, 1.0);
	VERTEX.x += gust * strength * w * w;
}
