// 点（画面に正対する円）の頂点シェーダ。点 1 つ = 頂点 4 つ（角 ±1）。
// 地形上の位置を mvp で落とし、画面空間で半径ぶん広げる。深度は地形上の点そのまま
// （深度テストで丘の裏の点が隠れる。Dart 側の視線なぞりが要らない）
uniform FrameInfo {
  mat4 mvp;
  vec2 viewport;      // 物理 px
  float pixel_ratio;  // 論理 px → 物理 px
}
frame_info;

in vec3 position;
in vec2 corner;   // (-1|+1, -1|+1)
in float size;    // 半径（論理 px）
in vec4 color;

out vec4 v_color;
out vec2 v_offset;  // 中心からの距離（物理 px）
out vec2 v_radius;  // x = 塗りの半径、y = 縁の太さ（物理 px）

void main() {
  vec4 p = frame_info.mvp * vec4(position, 1.0);
  float r = size * frame_info.pixel_ratio;
  float edge = 1.5 * frame_info.pixel_ratio;
  float extent = r + edge * 0.5 + 1.0;
  vec2 half_viewport = frame_info.viewport * 0.5;
  p.xy += corner * extent / half_viewport * p.w;
  gl_Position = p;
  v_color = color;
  v_offset = corner * extent;
  v_radius = vec2(r, edge);
}
