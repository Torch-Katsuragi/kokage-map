// 持ち上げた線の頂点シェーダ。線分 1 本 = 頂点 4 つ（両端 × 左右）。
// 両端 a, b を mvp で画面に落とし、画面空間で線の向きに直交する方向へ width/2 ずらして太さを付ける。
// 端も width/2 だけ外に伸ばし、フラグメント側で丸める（丸い端 = 折れ線の角が丸くつながる）。
// 深度は線分上の点そのまま（深度テストで地形に隠れる）
uniform FrameInfo {
  mat4 mvp;
  vec2 viewport;      // 物理 px
  float pixel_ratio;  // 論理 px → 物理 px
}
frame_info;

in vec3 a;
in vec3 b;
in float t;      // 0 = a 側、1 = b 側
in float side;   // -1 / +1
in float width;  // 論理 px
in vec4 color;

out vec4 v_color;
out vec2 v_local;   // 線分に沿った座標（px）: x = 線に沿って（a = 0）、y = 直交方向
out vec2 v_extent;  // x = 線分の長さ（px）、y = 半分の太さ（px）
out float v_w;      // クリップ w（靄用）

void main() {
  vec4 pa = frame_info.mvp * vec4(a, 1.0);
  vec4 pb = frame_info.mvp * vec4(b, 1.0);
  vec2 half_viewport = frame_info.viewport * 0.5;
  vec2 sa = pa.xy / pa.w * half_viewport;
  vec2 sb = pb.xy / pb.w * half_viewport;
  vec2 dir = sb - sa;
  float len = length(dir);
  dir = len > 0.0001 ? dir / len : vec2(1.0, 0.0);
  vec2 normal = vec2(-dir.y, dir.x);
  vec4 p = mix(pa, pb, t);
  float half_width = width * frame_info.pixel_ratio * 0.5;
  float along = t * 2.0 - 1.0;
  vec2 offset = (normal * side + dir * along) * half_width;
  p.xy += offset / half_viewport * p.w;
  gl_Position = p;
  v_color = color;
  v_local = vec2(t * len + along * half_width, side * half_width);
  v_extent = vec2(len, half_width);
  v_w = p.w;
}
