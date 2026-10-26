shader_type canvas_item;
render_mode blend_add, unshaded; // cộng sáng; unshaded = ban đêm không làm tối, vòng vẫn rực

uniform vec4 color : source_color = vec4(0.45, 0.75, 1.0, 1.0);
uniform float progress = 1.0;    // 0..1 vòng nở ra từ giữa
uniform float alpha = 1.0;       // 1..0 mờ dần khi biến mất
uniform int points = 3;          // 3 = sao 6 cánh, 4 = 8 cánh, 5 = 10 cánh
uniform float spin = 0.25;       // vòng/giây. 3600 * spin phải là số nguyên để không giật khi TIME quay vòng

float line(float x, float w) {   // nét mảnh sáng kèm hào quang
	float k = x / w;
	return exp(-k * k) + 0.25 * exp(-k * k * 0.04);
}

vec2 rotate(vec2 p, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec2(c * p.x - s * p.y, s * p.x + c * p.y);
}

// khoảng cách có dấu tới cạnh của đa giác đều n cạnh nội tiếp đường tròn bán kính r
float polygon_edge(vec2 p, float n, float r) {
	float k = TAU / n;
	float q = mod(atan(p.y, p.x), k) - k * 0.5;
	return length(p) * cos(q) - r * cos(PI / n);
}

void fragment() {
	vec2 p = (UV * 2.0 - 1.0) / max(progress, 0.001);
	float d = length(p);
	float t = TIME * spin * TAU;
	float n = float(points);

	float v = 0.0;
	v += line(d - 0.96, 0.012);                   // vòng ngoài
	v += line(d - 0.86, 0.008);                   // vòng trong của dải rune

	float x = (atan(p.y, p.x) + t * 0.5) / TAU * 32.0;    // dải rune 32 ô, ô nào sáng là ngẫu nhiên
	float cell = mod(floor(x), 32.0);
	float f = fract(x);
	float rune = step(0.45, fract(sin(cell * 12.9898) * 43758.5453)) * step(0.12, f) * step(f, 0.88);
	v += rune * smoothstep(0.87, 0.89, d) * (1.0 - smoothstep(0.93, 0.95, d)) * 0.8;

	vec2 ps = rotate(p, -t);                       // ngôi sao hai đa giác ngược nhau
	v += line(polygon_edge(ps, n, 0.80), 0.010);
	v += line(polygon_edge(rotate(ps, PI / n), n, 0.80), 0.010);

	v += line(d - 0.42, 0.010);                    // vòng nhỏ giữa + đa giác quay nhanh hơn
	v += line(polygon_edge(rotate(p, t * 2.0), n, 0.40), 0.008);
	v += 0.35 * exp(-d * d * 10.0);                // lõi sáng

	float a = clamp(v, 0.0, 1.0) * (1.0 - smoothstep(0.92, 1.0, d)) * alpha;
	COLOR = vec4(color.rgb, a);
}
