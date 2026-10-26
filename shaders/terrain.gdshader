// Shader mặt đất: trộn nước / cát / đất / cỏ theo weight map + nước động + màu ngày đêm.
// Nạp bằng load() trong map.gd SAU khi biến toàn cục day_tint được tạo (xem map.gd _ready).
shader_type canvas_item;
render_mode unshaded;

// Màu ngày đêm do world.gd đặt mỗi frame. Shader unshaded KHÔNG bị CanvasModulate nhuộm màu nên mặt đất tự nhân màu này.
global uniform vec4 day_tint : source_color;

// Nguồn sáng ban đêm (lửa, ma pháp) do night_glow.gd đẩy vào mỗi frame: xy = vị trí thế giới (px), z = bán kính (px), w = độ sáng (0 = tắt).
// Ánh sáng NHÂN với màu đất cùng công thức PointLight2D dùng cho sprite: màu = đất * (day_tint + ánh sáng).
global uniform vec4 fx_light0;
global uniform vec4 fx_light1;
global uniform vec4 fx_light2;
global uniform vec4 fx_light3;
global uniform vec4 fx_color0 : source_color;
global uniform vec4 fx_color1 : source_color;
global uniform vec4 fx_color2 : source_color;
global uniform vec4 fx_color3 : source_color;

// Vector từ mỗi nguồn sáng tới điểm đang vẽ, tính ở vertex (chunk chỉ có 4 đỉnh, nội suy tuyến tính là chính xác)
// và dùng toạ độ tương đối nên không mất độ chính xác khi ở rất xa gốc thế giới.
varying vec2 to_light0;
varying vec2 to_light1;
varying vec2 to_light2;
varying vec2 to_light3;

uniform sampler2D weight_map : filter_linear, repeat_disable;
uniform sampler2D edge_noise : filter_linear, repeat_enable;
uniform sampler2D tex_water : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_sand : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_dirt : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_grass : source_color, filter_linear_mipmap, repeat_enable;

uniform vec2 tex_origin;     // gốc chunk (tile), đã wrap theo chu kỳ texture
uniform vec2 edge_origin;    // gốc chunk (tile), đã wrap theo chu kỳ noise
uniform float tex_period = 3.0;
uniform float edge_period = 8.0;
uniform float weight_scale = 0.1;
uniform float weight_bias = 0.01;
uniform float edge_jitter = 0.22;
uniform float edge_softness = 0.14;

// Nước động: hai lớp texture nước trôi ngược chiều + méo sóng + bọt sáng ở bờ.
// Mọi pha đều là bội SỐ NGUYÊN của tuv (tuv của mỗi chunk chỉ lệch nguyên so với toạ độ thế giới) nên không hở khe giữa
// các chunk, và là bội số nguyên của (TIME * water_speed) với 3600 * water_speed nguyên nên không giật khi TIME quay vòng
// (mặc định Godot quay vòng TIME sau 3600 giây). Muốn đổi water_speed hãy chọn giá trị mà 3600 * giá trị là số nguyên.
uniform float water_speed = 0.04;   // tốc độ trôi (chu kỳ texture / giây)
uniform float water_wave = 0.012;   // độ méo sóng (đơn vị UV texture), 0 = tắt méo
uniform float water_foam = 0.30;    // độ sáng bọt ở bờ, 0 = tắt bọt

void vertex() {
	vec2 world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
	to_light0 = world - fx_light0.xy;
	to_light1 = world - fx_light1.xy;
	to_light2 = world - fx_light2.xy;
	to_light3 = world - fx_light3.xy;
}

// Một nguồn sáng: vùng sáng là elip 2:1 (khớp ô iso), tắt dần bậc hai ra tới mép.
vec3 point_light(vec4 light, vec4 light_color, vec2 d) {
	if (light.w <= 0.0) {
		return vec3(0.0);
	}
	float f = clamp(1.0 - length(vec2(d.x, d.y * 2.0)) / light.z, 0.0, 1.0);
	return light_color.rgb * (f * f * light.w);
}

vec3 water_color(vec2 tuv, vec2 dx, vec2 dy) {
	float t = TIME * water_speed;
	vec2 warp = vec2(
		sin((tuv.y * 3.0 + t * 8.0) * TAU),
		sin((tuv.x * 2.0 - t * 6.0) * TAU)
	) * water_wave;
	vec2 uv1 = tuv + warp + vec2(t, t * 0.5);
	vec2 uv2 = tuv * 2.0 - warp * 1.5 + vec2(-t * 0.5, t * 0.25);
	return textureGrad(tex_water, uv1, dx, dy).rgb * 0.65 + textureGrad(tex_water, uv2, dx * 2.0, dy * 2.0).rgb * 0.35;
}

void fragment() {
	// UV = toạ độ tile cục bộ trong chunk (0..CHUNK_SIZE), nội suy affine nên chính xác.
	vec2 local = UV;
	vec4 w = texture(weight_map, local * weight_scale + weight_bias);
	vec4 n = texture(edge_noise, (edge_origin + local) / edge_period);

	// height-blend: mỗi loại có nhiễu riêng => ranh giới cong, mềm.
	vec4 h = w + (n - 0.5) * edge_jitter;
	float m = max(max(h.r, h.g), max(h.b, h.a));
	vec4 k = clamp((h - m) / edge_softness + 1.0, 0.0, 1.0);
	k /= (k.r + k.g + k.b + k.a);

	vec2 tuv = (tex_origin + local) / tex_period;
	vec2 dx = dFdx(tuv);
	vec2 dy = dFdy(tuv);
	vec3 col = vec3(0.0);
	if (k.r > 0.002) col += water_color(tuv, dx, dy) * k.r;
	if (k.g > 0.002) col += textureGrad(tex_sand,  tuv, dx, dy).rgb * k.g;
	if (k.b > 0.002) col += textureGrad(tex_dirt,  tuv, dx, dy).rgb * k.b;
	if (k.a > 0.002) col += textureGrad(tex_grass, tuv, dx, dy).rgb * k.a;
	// Bọt ở bờ: sáng nhất ở giữa dải chuyển tiếp nước - đất, nhấp nhô chậm theo sóng.
	if (k.r > 0.002 && k.r < 0.998) {
		float edge = k.r * (1.0 - k.r) * 4.0;
		float ripple = 0.65 + 0.35 * sin((tuv.x * 2.0 + tuv.y * 2.0 - TIME * water_speed * 10.0) * TAU);
		col += vec3(0.85, 0.95, 1.0) * (edge * edge * ripple * water_foam);
	}
	vec3 lit = day_tint.rgb
		+ point_light(fx_light0, fx_color0, to_light0)
		+ point_light(fx_light1, fx_color1, to_light1)
		+ point_light(fx_light2, fx_color2, to_light2)
		+ point_light(fx_light3, fx_color3, to_light3);
	COLOR = vec4(col * lit, 1.0);
}
