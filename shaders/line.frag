// 線の端を丸める（両端に半径 width/2 の円）。折れ線の角は隣の線分の丸い端で埋まる。
// v_dash.x > 0 のときは破線・点線・一点鎖線・二点鎖線として OFF 区間を抜く。
// premultiplied で出す（ブレンドは src=one, dst=oneMinusSrcAlpha）
uniform ShadeInfo {
  vec4 params;  // y/z = 靄の始まり/終わり（クリップ w）、w = 透視なら 1
}
shade_info;

in vec4 v_color;
in vec2 v_local;
in vec2 v_extent;
in float v_w;
in float v_arc_lpx;
in vec4 v_dash;
out vec4 frag_color;

float dash_interval_alpha(float s, float center, float half_len, float period) {
  float d = abs(mod(s - center + 0.5 * period, period) - 0.5 * period) - half_len;
  return 1.0 - smoothstep(-0.5, 0.5, d);
}

float eval_dash_alpha(float s, vec4 d) {
  float on1 = d.x;
  float off1 = d.y;
  if (abs(d.z) < 0.01) {
    float p = max(on1 + off1, 1.0);
    return dash_interval_alpha(s, 0.5 * on1, 0.5 * on1, p);
  }
  if (d.z > 0.0) {
    float on2 = d.z;
    float off2 = max(d.w, 0.5);
    float p = max(on1 + off1 + on2 + off2, 1.0);
    float a1 = dash_interval_alpha(s, 0.5 * on1, 0.5 * on1, p);
    float a2 = dash_interval_alpha(s, on1 + off1 + 0.5 * on2, 0.5 * on2, p);
    return max(a1, a2);
  }
  // d.z < 0: 二点鎖線 [on1, off1, on2, off2, on2, off2]
  float on2 = -d.z;
  float off2 = max(d.w, 0.5);
  float p = max(on1 + off1 + 2.0 * (on2 + off2), 1.0);
  float a1 = dash_interval_alpha(s, 0.5 * on1, 0.5 * on1, p);
  float a2 = dash_interval_alpha(s, on1 + off1 + 0.5 * on2, 0.5 * on2, p);
  float a3 = dash_interval_alpha(s, on1 + off1 + on2 + off2 + 0.5 * on2, 0.5 * on2, p);
  return max(a1, max(a2, a3));
}

void main() {
  float len = v_extent.x;
  float hw = v_extent.y;
  // 線分の内側なら直交距離、端より外なら端の点からの距離
  float ax = clamp(v_local.x, 0.0, len);
  float d = length(vec2(v_local.x - ax, v_local.y));
  // 縁を 1px なだらかに（MSAA と併用）
  float alpha = 1.0 - smoothstep(hw - 1.0, hw, d);
  if (v_dash.x > 0.0) {
    alpha *= eval_dash_alpha(v_arc_lpx, v_dash);
  }
  if (alpha <= 0.001) {
    discard;
  }
  float a = v_color.a * alpha;
  if (shade_info.params.w > 0.5) {
    a *= 1.0 - smoothstep(shade_info.params.y, shade_info.params.z, v_w);
  }
  frag_color = vec4(v_color.rgb * a, a);
}
