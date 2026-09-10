// 背景地図のテクスチャ × 陰影。テクスチャは premultiplied RGBA
uniform sampler2D tex;

in vec2 v_uv;
in float v_shade;
out vec4 frag_color;

void main() {
  vec4 c = texture(tex, v_uv);
  frag_color = vec4(c.rgb * v_shade, c.a);
}
