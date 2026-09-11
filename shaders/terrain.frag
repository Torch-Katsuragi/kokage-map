// 背景地図のテクスチャに陰影を重ねる。テクスチャは premultiplied RGBA。
// v_shade は「オーバーレイ用のグレー」（0.5 = 変化なし、小さいほど暗い。TerrainShading 参照）。
// shade_info.params.x: 1 = オーバーレイ（中間調のコントラストを上げ、白は白のまま）、0 = 乗算（2 × shade を掛ける）
uniform sampler2D tex;

uniform ShadeInfo {
  vec4 params;
}
shade_info;

in vec2 v_uv;
in float v_shade;
out vec4 frag_color;

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
  frag_color = vec4(o * c.a, c.a);
}
