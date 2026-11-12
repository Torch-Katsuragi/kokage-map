// 持ち上げた線の頂点シェーダ。線分 1 本 = 頂点 4 つ（両端 × 左右）。
// 両端 a, b を mvp で画面に落とし、画面空間で線の向きに直交する方向へ width/2 ずらして太さを付ける。
// 端も width/2 だけ外に伸ばし、フラグメント側で丸める（丸い端 = 折れ線の角が丸くつながる）。
// 破線（dash.x > 0）は折れ線累積距離 arc（Mercator m）× 水平画面倍率で連続位相を保つ。
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
in vec2 arc;     // a, b それぞれの折れ線始点からの累積距離（Mercator m）
in vec4 dash;    // (on1, off1, on2_signed, off2) 論理 px（0 なら実線）

out vec4 v_color;
out vec2 v_local;   // 線分に沿った座標（物理 px）: x = 線に沿って（a = 0）、y = 直交方向
out vec2 v_extent;  // x = 線分の長さ（物理 px）、y = 半分の太さ（物理 px）
out float v_w;      // クリップ w（靄用）
out float v_arc_lpx;
out vec4 v_dash;

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
  float pr = max(frame_info.pixel_ratio, 0.001);
  float half_width = width * pr * 0.5;
  float along = t * 2.0 - 1.0;
  vec2 offset = (normal * side + dir * along) * half_width;
  p.xy += offset / half_viewport * p.w;
  gl_Position = p;
  v_color = color;
  v_local = vec2(t * len + along * half_width, side * half_width);
  v_extent = vec2(len, half_width);
  v_w = p.w;
  // 水平面上の 1 Mercator m が画面上で何論理 px に相当するか（方位・傾きに不変で頂点間で連続）
  float horiz_px_per_m = length(vec2(frame_info.mvp[0].x, frame_info.mvp[1].x)) * half_viewport.x / max(abs(p.w), 0.001);
  float lpx_per_m = horiz_px_per_m / pr;
  v_arc_lpx = mix(arc.x, arc.y, t) * lpx_per_m + along * (width * 0.5);
  v_dash = dash;
}
