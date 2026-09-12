// 背景地図のテクスチャに陰影を重ねる。テクスチャは premultiplied RGBA。
// v_shade は「オーバーレイ用のグレー」（0.5 = 変化なし、小さいほど暗い。TerrainShading 参照）。
// shade_info.params: x = 1 でオーバーレイ（中間調のコントラストを上げ、白は白のまま）、0 で乗算（2 × shade を掛ける）
//                    y, z = 靄の始まりと終わり（クリップ w = 視点からの奥行き、透視のとき）、w = 1 で透視（靄あり）
// color_info（TerrainAppearance）: a.x = 色分けの種類（0 なし、1 傾斜、2 標高）、a.y = 基図に被せる強さ（0〜1）、
//                    a.z, a.w = 標高の下限・上限（見えている範囲）、b.x = 傾斜の上限（度）。
//                    色は ramp（256×1）を t で引く。頂点の傾斜・標高から引くのでメッシュの解像度で滑らか（テクスチャに依らない）
uniform sampler2D tex;
uniform sampler2D ramp;

uniform ShadeInfo {
  vec4 params;
}
shade_info;

uniform ColorInfo {
  vec4 a;
  vec4 b;
}
color_info;

in vec2 v_uv;
in float v_shade;
in float v_w;
in float v_slope;
in float v_height;
out vec4 frag_color;

const vec3 kSky = vec3(0.78, 0.86, 0.95);

void main() {
  vec4 c = texture(tex, v_uv);
  float a = max(c.a, 1e-4);
  vec3 base = c.rgb / a;
  float mode = color_info.a.x;
  if (mode > 0.5) {
    float t = mode > 1.5
        ? clamp((v_height - color_info.a.z) / max(color_info.a.w - color_info.a.z, 1.0), 0.0, 1.0)
        : clamp(v_slope * 90.0 / max(color_info.b.x, 1.0), 0.0, 1.0);
    vec3 rc = texture(ramp, vec2(t, 0.5)).rgb;
    base = mix(base, rc, color_info.a.y);
  }
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
