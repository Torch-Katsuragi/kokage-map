// 背景地図のテクスチャに陰影を重ねる。テクスチャは premultiplied RGBA。
// v_shade は「オーバーレイ用のグレー」（0.5 = 変化なし、小さいほど暗い。TerrainShading 参照）。
// shade_info.params: x = 1 でオーバーレイ（中間調のコントラストを上げ、白は白のまま）、0 で乗算（2 × shade を掛ける）
//                    y, z = 靄の始まりと終わり（クリップ w = 視点からの奥行き、透視のとき）、w = 1 で透視（靄あり）
uniform sampler2D tex;

uniform ShadeInfo {
  vec4 params;
}
shade_info;

in vec2 v_uv;
in float v_shade;
in float v_w;
out vec4 frag_color;

const vec3 kSky = vec3(0.78, 0.86, 0.95);

void main() {
  vec4 c = texture(tex, v_uv);
  float a = max(c.a, 1e-4);
  vec3 base = c.rgb / a;
  vec3 g = vec3(v_shade);
  vec3 lo = 2.0 * base * g;
  vec3 hi = 1.0 - 2.0 * (1.0 - base) * (1.0 - g);
  vec3 overlay = mix(lo, hi, step(0.5, base));
  vec3 multiply = base * clamp(2.0 * v_shade, 0.0, 1.0);
  vec3 o = mix(multiply, overlay, shade_info.params.x);
  if (shade_info.params.w > 0.5) {
    float fog = smoothstep(shade_info.params.y, shade_info.params.z, v_w);
    o = mix(o, kSky, fog);
  }
  frag_color = vec4(o * c.a, c.a);
}
