// 円の塗り + 白い縁（Canvas の drawCircle + 1.5px の白い stroke と同じ見た目）。premultiplied で出す
in vec4 v_color;
in vec2 v_offset;
in vec2 v_radius;
out vec4 frag_color;

void main() {
  float d = length(v_offset);
  float r = v_radius.x;
  float edge = v_radius.y;
  float outer = r + edge * 0.5;
  float alpha = 1.0 - smoothstep(outer - 1.0, outer, d);
  if (alpha <= 0.0) {
    discard;
  }
  // 縁（r ± edge/2）は白、内側は点の色
  float ring = smoothstep(r - edge * 0.5 - 0.5, r - edge * 0.5 + 0.5, d);
  vec4 c = mix(v_color, vec4(1.0, 1.0, 1.0, 1.0), ring);
  float a = c.a * alpha;
  frag_color = vec4(c.rgb * a, a);
}
