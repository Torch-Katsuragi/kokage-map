// 点マーカーの 2D SDF 描画（0:丸, 1:四角, 2:ひし形, 3:三角, 4:星, 5:十字, 6:×印）＋任意色の縁取り。
// premultiplied で出す
in vec4 v_color;
in vec4 v_outline_color;
in vec2 v_offset;
in vec3 v_style;
out vec4 frag_color;

float sd_box(vec2 p, vec2 b) {
  vec2 d = abs(p) - b;
  return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

float sd_equilateral_triangle(vec2 p, float r) {
  const float k = 1.7320508;
  vec2 tp = vec2(abs(p.x) - r * 0.8660254, p.y + r * 0.5);
  if (tp.x + k * tp.y > 0.0) {
    tp = vec2(tp.x - k * tp.y, -k * tp.x - tp.y) * 0.5;
  }
  tp.x -= clamp(tp.x, -r * 1.7320508, 0.0);
  return -length(tp) * sign(tp.y);
}

float sd_star5(vec2 p, float r, float rf) {
  const vec2 k1 = vec2(0.809016994375, -0.587785252292);
  const vec2 k2 = vec2(-0.809016994375, -0.587785252292);
  vec2 sp = vec2(abs(p.x), p.y);
  sp -= 2.0 * max(dot(k1, sp), 0.0) * k1;
  sp -= 2.0 * max(dot(k2, sp), 0.0) * k2;
  sp.x = abs(sp.x);
  sp.y -= r;
  vec2 ba = rf * vec2(-k1.y, k1.x) - vec2(0.0, 1.0);
  float h = clamp(dot(sp, ba) / dot(ba, ba), 0.0, r);
  return length(sp - ba * h) * sign(sp.y * ba.x - sp.x * ba.y);
}

float sd_marker(vec2 q, float r, int shape) {
  if (shape == 1) {
    return sd_box(q, vec2(r * 0.88));
  }
  if (shape == 2) {
    vec2 rq = vec2((q.x + q.y) * 0.70710678, (q.y - q.x) * 0.70710678);
    return sd_box(rq, vec2(r * 1.08 * 0.70710678));
  }
  if (shape == 3) {
    return sd_equilateral_triangle(q, r * 1.12);
  }
  if (shape == 4) {
    return sd_star5(q, r * 1.15, 0.42);
  }
  if (shape == 5) {
    float th = max(r * 0.28, 1.0);
    return min(sd_box(q, vec2(r, th)), sd_box(q, vec2(th, r)));
  }
  if (shape == 6) {
    vec2 rq = vec2((q.x + q.y) * 0.70710678, (q.y - q.x) * 0.70710678);
    float th = max(r * 0.28, 1.0);
    return min(sd_box(rq, vec2(r, th)), sd_box(rq, vec2(th, r)));
  }
  return length(q) - r;
}

void main() {
  float r = v_style.x;
  float edge = v_style.y;
  int shape = int(v_style.z + 0.5);
  float d = sd_marker(v_offset, r, shape);

  if (edge > 0.01 && v_outline_color.a > 0.0) {
    float outer = edge * 0.5;
    float alpha = 1.0 - smoothstep(outer - 1.0, outer, d);
    if (alpha <= 0.001) {
      discard;
    }
    float ring = smoothstep(-edge * 0.5 - 0.5, -edge * 0.5 + 0.5, d);
    vec4 pm_fill = vec4(v_color.rgb * v_color.a, v_color.a);
    vec4 pm_out = vec4(v_outline_color.rgb * v_outline_color.a, v_outline_color.a);
    vec4 pm = mix(pm_fill, pm_out, ring) * alpha;
    if (pm.a <= 0.001) {
      discard;
    }
    frag_color = pm;
  } else {
    float alpha = 1.0 - smoothstep(-1.0, 0.0, d);
    float a = v_color.a * alpha;
    if (a <= 0.001) {
      discard;
    }
    frag_color = vec4(v_color.rgb * a, a);
  }
}
