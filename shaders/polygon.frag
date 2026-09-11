// premultiplied で出す（ブレンドは src=one, dst=oneMinusSrcAlpha）
uniform ShadeInfo {
  vec4 params;  // y/z = 靄の始まり/終わり（クリップ w）、w = 透視なら 1。x は地形用（ここでは使わない）
}
shade_info;

in vec4 v_color;
in float v_w;
out vec4 frag_color;

void main() {
  // 靄: 地形は空色に溶けるので、その上の面は薄くなって消える（空色に寄せると地形の靄と二重に掛かる）
  float a = v_color.a;
  if (shade_info.params.w > 0.5) {
    a *= 1.0 - smoothstep(shade_info.params.y, shade_info.params.z, v_w);
  }
  frag_color = vec4(v_color.rgb * a, a);
}
