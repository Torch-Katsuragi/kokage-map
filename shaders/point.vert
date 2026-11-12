// 点（画面に正対するマーカー）の頂点シェーダ。点 1 つ = 頂点 4 つ（角 ±1）。
// 地形上の位置を mvp で落とし、画面空間で外接半径ぶん広げる。深度は地形上の点そのまま
// （深度テストで丘の裏の点が隠れる。Dart 側の視線なぞりが要らない）
uniform FrameInfo {
  mat4 mvp;
  vec2 viewport;      // 物理 px
  float pixel_ratio;  // 論理 px → 物理 px
}
frame_info;

in vec3 position;
in vec2 corner;          // (-1|+1, -1|+1)
in float size;           // 半径（論理 px）
in vec4 color;
in vec4 outline_color;
in vec4 marker_style;    // x = outlineWidthPx, y = shapeId (0..6), z = angleRad, w = 0

out vec4 v_color;
out vec4 v_outline_color;
out vec2 v_offset;       // 回転適用後の中心からの距離（物理 px、+y = 画面上向き）
out vec3 v_style;        // x = 塗りの半径（物理 px）、y = 縁の太さ（物理 px）、z = shapeId

void main() {
  vec4 p = frame_info.mvp * vec4(position, 1.0);
  float r = size * frame_info.pixel_ratio;
  float edge = max(marker_style.x, 0.0) * frame_info.pixel_ratio;
  float extent = r * 1.2 + edge * 0.5 + 1.5;
  vec2 half_viewport = frame_info.viewport * 0.5;
  p.xy += corner * extent / half_viewport * p.w;
  gl_Position = p;
  v_color = color;
  v_outline_color = outline_color;
  vec2 raw_off = corner * extent;
  float ang = marker_style.z;
  float ca = cos(ang);
  float sa = sin(ang);
  v_offset = vec2(ca * raw_off.x - sa * raw_off.y, sa * raw_off.x + ca * raw_off.y);
  v_style = vec3(r, edge, marker_style.y);
}
