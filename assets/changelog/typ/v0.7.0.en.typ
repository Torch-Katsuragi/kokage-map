// Changelog (illustrated): v0.7.0. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")


// ---- この版だけの部品 ----

/// 傾けた地図（地形）。horizon は空の高さの割合、haze で遠くを靄に溶かす
#let terrain(w, h, horizon: 0.22, haze: false, data: true) = box(width: w, height: h, clip: true, {
  let hz = h * horizon
  place(rect(width: w, height: h, fill: gradient.linear(white, accent-soft, angle: 90deg)))
  // 奥から手前へ 3 つの尾根
  let ridge(y0, amp, c) = place(curve(fill: c, stroke: none,
    curve.move((0pt, y0 + amp * 0.3)),
    curve.cubic((w * 0.2, y0 - amp), (w * 0.4, y0 + amp * 0.6), (w * 0.62, y0 - amp * 0.4)),
    curve.cubic((w * 0.78, y0 - amp), (w * 0.9, y0 + amp * 0.2), (w, y0 - amp * 0.2)),
    curve.line((w, h)), curve.line((0pt, h)), curve.close()))
  ridge(hz + 4pt, 6pt, rgb("#cdd8bf"))
  ridge(hz + (h - hz) * 0.25, 9pt, rgb("#b3c59d"))
  ridge(hz + (h - hz) * 0.5, 12pt, map-bg.darken(8%))
  if data {
    // 手前の斜面に載った小班と路網
    let c = map-comp.lighten(15%)
    let s = 0.6pt + map-comp.darken(35%)
    place(polygon(fill: c, stroke: s,
      (w * 0.1, h * 0.8), (w * 0.44, h * 0.77), (w * 0.47, h * 0.93), (w * 0.05, h * 0.97)))
    place(polygon(fill: c, stroke: s,
      (w * 0.52, h * 0.76), (w * 0.88, h * 0.74), (w * 0.95, h * 0.9), (w * 0.55, h * 0.92)))
    place(curve(stroke: (paint: map-road, thickness: 2pt, cap: "round"),
      curve.move((w * 0.02, h * 1.02)), curve.cubic((w * 0.3, h * 0.7), (w * 0.6, h * 0.95), (w * 0.95, h * 0.62))))
  }
  if haze {
    place(dy: hz - 6pt, rect(width: w, height: (h - hz) * 0.6,
      fill: gradient.linear(white.transparentize(5%), white.transparentize(100%), angle: 90deg)))
  }
})

/// 右上のコンパス
#let compass(r: 6pt) = box(width: 2 * r, height: 2 * r, {
  place(circle(radius: r, fill: white, stroke: 0.6pt + line-c))
  place(polygon(fill: map-red, (r - r * 0.35, r), (r, r * 0.25), (r + r * 0.35, r)))
  place(polygon(fill: sub.lighten(30%), (r - r * 0.35, r), (r, r * 1.75), (r + r * 0.35, r)))
})

/// 画面の右上にコンパスを載せる
#let with-compass(w, body) = box({
  body
  place(top + right, dx: -3pt, dy: 3pt, compass())
})

/// ブラウザ（web 版）。中身は画面の大きさ（w × h - 12pt）で渡す
#let browser(w: 150pt, h: 92pt, screen) = box(width: w, height: h, radius: 4pt, clip: true, stroke: 0.8pt + line-c, {
  place(rect(width: w, height: 12pt, fill: rgb("#e9e7ee")))
  for i in range(3) { place(dx: 5pt + i * 6pt, dy: 4pt, circle(radius: 2pt, fill: sub.lighten(40%))) }
  place(dx: 26pt, dy: 2.5pt, rect(width: w - 32pt, height: 7pt, radius: 3pt, fill: white))
  place(dy: 12pt, screen)
})

/// マウス。hit は押すところ "left" / "right" / "wheel"
#let mouse(hit) = box(width: 22pt, height: 32pt, {
  place(rect(width: 22pt, height: 32pt, radius: 11pt, fill: white, stroke: 0.9pt + sub))
  if hit == "left" { place(rect(width: 11pt, height: 13pt, radius: (top-left: 11pt), fill: accent)) }
  if hit == "right" { place(dx: 11pt, rect(width: 11pt, height: 13pt, radius: (top-right: 11pt), fill: accent)) }
  place(dx: 11pt, line(angle: 90deg, length: 13pt, stroke: 0.9pt + sub))
  place(dy: 13pt, line(length: 22pt, stroke: 0.9pt + sub))
  place(dx: 9pt, dy: 4pt, rect(width: 4pt, height: 7pt, radius: 2pt,
    fill: if hit == "wheel" { accent } else { white }, stroke: 0.9pt + if hit == "wheel" { accent } else { sub }))
})

// ---- 頭: 地図が 3D に ----
#hero(
  "v0.7.0 — 2026/09/11",
  [The map is now 3D],
  [Compartments, routes, photos, GPS tracks and more are draped on the terrain. It still opens top-down.],
  phone(w: 88pt, h: 156pt, with-compass(82pt, terrain(82pt, 142pt))),
)

// ---- 回して傾ける ----
#scene(
  [Rotate and tilt with a finger],
  [Drag with one finger to rotate and tilt, use two fingers to pan and zoom.],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    phone(w: 60pt, h: 106pt, label: "Top-down", with-compass(54pt, mini-map(54pt, 92pt))),

    stack(dir: ttb, spacing: 4pt, bubble[Drag with one finger], arrow-r(w: 20pt)),
    stack(dir: ttb, spacing: 4pt,
      phone(w: 60pt, h: 106pt, label: "Rotated and tilted", with-compass(54pt, terrain(54pt, 92pt, horizon: 0.18))),
    ),
  ),
  note: [Tap the compass at the top right to return to north-up, top-down.],
)

// ---- 傾斜の陰影 ----
#scene(
  [Steeper is darker],
  [Terrain shading follows slope rather than a light direction. Ridges and valley floors stay bright.],
  {
    let w = 220pt
    let h = 64pt
    let dark = rgb("#6b7063")
    let mid = rgb("#aeb2a6")
    let shade = gradient.linear(
      (white, 0%), (white, 10%), (dark, 14%), (dark, 30%), (white, 34%), (white, 44%),
      (dark, 49%), (dark, 66%), (white, 71%), (white, 80%), (mid, 85%), (mid, 100%))
    let pts = ((0, 0.85), (0.1, 0.85), (0.33, 0.24), (0.45, 0.24), (0.7, 0.85), (0.8, 0.85), (1, 0.42))
    stack(dir: ttb, spacing: 4pt,
      align(left, caption[A mountain from the side]),
      box(width: w, height: h, {
        place(curve(fill: map-bg.darken(6%), stroke: 1.2pt + map-road,
          curve.move((0pt, h * 0.85)),
          ..pts.slice(1).map(((x, y)) => curve.line((w * x, h * y))),
          curve.line((w, h)), curve.line((0pt, h)), curve.close()))
        place(dx: w * 0.33, dy: 0pt, box(width: w * 0.12, align(center, caption[Ridge])))
        place(dx: 0pt, dy: h * 0.58, caption[Valley])
        place(dx: w * 0.62, dy: h * 0.6, box(width: w * 0.3, align(center, caption[Valley])))
      }),
      v(6pt),
      align(left, caption[Shading seen from above]),
      box(width: w, height: 22pt, radius: 3pt, clip: true, stroke: 0.6pt + line-c, rect(width: w, height: 22pt, fill: shade)),
      grid(columns: (w * 0.1, w * 0.24, w * 0.11, w * 0.26, w * 0.29), align: center,
        [], caption[Steep], [], caption[Steep], caption[Gentle]),
    )
  },
)

// ---- 眺めモード ----
#scene(
  [Long-press the compass for the view mode],
  [A perspective view where the distance fades into haze. Long-press again to return.],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    stack(dir: ttb, spacing: 4pt,
      bubble[Long-press the compass],
      phone(w: 60pt, h: 106pt, with-compass(54pt, terrain(54pt, 92pt, horizon: 0.18))),
    ),
    arrow-r(w: 20pt),
    stack(dir: ttb, spacing: 4pt,
      bubble[View mode],
      phone(w: 60pt, h: 106pt, with-compass(54pt, terrain(54pt, 92pt, horizon: 0.34, haze: true))),
    ),
  ),
)

// ---- web ----
#scene(
  [The same 3D map on the web],
  [Drawn on the GPU through WebGL2. Controls match Android, and a mouse works too.],
  stack(dir: ttb, spacing: 12pt,
    browser(w: 170pt, h: 100pt, terrain(170pt, 88pt)),
    grid(
      columns: (1fr, 1fr, 1fr), row-gutter: 4pt, align: center + top,
      mouse("left"), mouse("right"), mouse("wheel"),
      caption[Left-drag\ pans], caption[Right-drag\ (or Ctrl + left)\ rotates and tilts], caption[Wheel\ zooms],
    ),
  ),
)

// ---- 細かな変更 ----
#fixes(
  "Also",
  [Selecting and TruPulse work while tilted],
  [Drawing locks the view top-down],
  [Elevation: GSI DEM, AWS as fallback],
  [Areas you have viewed once work offline],
  [Smooth rotating and tilting on the GPU],
  [View mode and north-up flash a label],
)

#fixes(
  "Fixes",
  [New installs quit after location access],
)
