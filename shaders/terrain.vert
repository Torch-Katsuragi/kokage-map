// 地形（DEM 格子）の頂点シェーダ。座標は DEM 原点基準の Mercator m（z は標高 m）。
// 投影は Dart 側で組んだ mvp 1 本（正射影か透視）。頂点はデバイスバッファに一度だけ上げる
uniform FrameInfo {
  mat4 mvp;
}
frame_info;

in vec3 position;
in vec2 uv;
in float shade;
in float slope;  // 傾斜（0〜1 = 度/90）。色分け用

out vec2 v_uv;
out float v_shade;
out float v_w;  // クリップ座標の w（透視なら視点からの奥行き。靄に使う）
out float v_slope;
out float v_height;  // 標高 m。色分け用

void main() {
  v_uv = uv;
  v_shade = shade;
  v_slope = slope;
  v_height = position.z;
  gl_Position = frame_info.mvp * vec4(position, 1.0);
  v_w = gl_Position.w;
}
