// 更新履歴（図解）: v0.7.0。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup


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
  [地図が 3D になりました],
  [林班・路線・写真・GPS 軌跡などが、地形の上に載ります。開いたときは、いつもどおり真上からの地図です。],
  phone(w: 88pt, h: 156pt, with-compass(82pt, terrain(82pt, 142pt))),
)

// ---- 回して傾ける ----
#scene(
  [指で回して傾ける],
  [1 本指のドラッグで回転と傾き、2 本指で移動と拡大縮小です。],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    phone(w: 60pt, h: 106pt, label: "真上から", with-compass(54pt, mini-map(54pt, 92pt))),

    stack(dir: ttb, spacing: 4pt, bubble[1 本指でドラッグ], arrow-r(w: 20pt)),
    stack(dir: ttb, spacing: 4pt,
      phone(w: 60pt, h: 106pt, label: "回して傾けた", with-compass(54pt, terrain(54pt, 92pt, horizon: 0.18))),
    ),
  ),
  note: [右上のコンパスをタップすると、北が上の真上に戻ります。],
)

// ---- 傾斜の陰影 ----
#scene(
  [急な斜面ほど濃く],
  [地形の陰影は、光の向きではなく傾斜の濃淡です。尾根と谷底は白く抜けます。],
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
      align(left, caption[横から見た山]),
      box(width: w, height: h, {
        place(curve(fill: map-bg.darken(6%), stroke: 1.2pt + map-road,
          curve.move((0pt, h * 0.85)),
          ..pts.slice(1).map(((x, y)) => curve.line((w * x, h * y))),
          curve.line((w, h)), curve.line((0pt, h)), curve.close()))
        place(dx: w * 0.33, dy: 0pt, box(width: w * 0.12, align(center, caption[尾根])))
        place(dx: w * 0.07, dy: h * 0.6, caption[谷底])
        place(dx: w * 0.62, dy: h * 0.6, box(width: w * 0.3, align(center, caption[谷底])))
      }),
      v(6pt),
      align(left, caption[上から見た陰影]),
      box(width: w, height: 22pt, radius: 3pt, clip: true, stroke: 0.6pt + line-c, rect(width: w, height: 22pt, fill: shade)),
      grid(columns: (w * 0.1, w * 0.24, w * 0.11, w * 0.26, w * 0.29), align: center,
        [], caption[急斜面], [], caption[急斜面], caption[ゆるい斜面]),
    )
  },
)

// ---- 眺めモード ----
#scene(
  [コンパスを長押しで眺めモード],
  [遠近のある眺めになり、遠くは靄に溶けます。もう一度長押しで戻ります。],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    stack(dir: ttb, spacing: 4pt,
      bubble[コンパスを長押し],
      phone(w: 60pt, h: 106pt, with-compass(54pt, terrain(54pt, 92pt, horizon: 0.18))),
    ),
    arrow-r(w: 20pt),
    stack(dir: ttb, spacing: 4pt,
      bubble[眺めモード],
      phone(w: 60pt, h: 106pt, with-compass(54pt, terrain(54pt, 92pt, horizon: 0.34, haze: true))),
    ),
  ),
)

// ---- web ----
#scene(
  [web でも同じ 3D の地図],
  [描画は WebGL2 で、こちらも GPU です。操作は Android と同じで、マウスでも動かせます。],
  stack(dir: ttb, spacing: 12pt,
    browser(w: 170pt, h: 100pt, terrain(170pt, 88pt)),
    grid(
      columns: (1fr, 1fr, 1fr), row-gutter: 4pt, align: center + top,
      mouse("left"), mouse("right"), mouse("wheel"),
      caption[左ドラッグ\ 移動], caption[右ドラッグ\ （Ctrl ＋ 左）\ 回転と傾き], caption[ホイール\ 拡大縮小],
    ),
  ),
)

// ---- 細かな変更 ----
#fixes(
  "ほかにも",
  [選択・情報カード・TruPulse も傾けたまま使える],
  [手で描く間は真上に固定し、終われば傾きを戻す],
  [標高は国土地理院 DEM、無い所は AWS で補う],
  [一度見た範囲は、電波が無くても地形が出る],
  [回転や傾きの最中も滑らか（GPU で描画）],
  [眺めモードや北上に戻したときも、中央に短く表示],
)

#fixes(
  "直したこと",
  [初回インストール時、位置情報の許可直後に落ちた],
)
