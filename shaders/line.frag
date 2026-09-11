// 線の端を丸める（両端に半径 width/2 の円）。折れ線の角は隣の線分の丸い端で埋まる。
// premultiplied で出す（ブレンドは src=one, dst=oneMinusSrcAlpha）
uniform ShadeInfo {
  vec4 params;  // y/z = 靄の始まり/終わり（クリップ w）、w = 透視なら 1
}
shade_info;

in vec4 v_color;
in vec2 v_local;
in vec2 v_extent;
in float v_w;
out vec4 frag_color;

void main() {
  float len = v_extent.x;
  float hw = v_extent.y;
  // 線分の内側なら直交距離、端より外なら端の点からの距離
  float ax = clamp(v_local.x, 0.0, len);
  float d = length(vec2(v_local.x - ax, v_local.y));
  // 縁を 1px なだらかに（MSAA と併用）
  float alpha = 1.0 - smoothstep(hw - 1.0, hw, d);
  if (alpha <= 0.0) {
    discard;
  }
  float a = v_color.a * alpha;
  if (shade_info.params.w > 0.5) {
    a *= 1.0 - smoothstep(shade_info.params.y, shade_info.params.z, v_w);
  }
  frag_color = vec4(v_color.rgb * a, a);
}
