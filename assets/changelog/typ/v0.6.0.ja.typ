// 更新履歴（図解）: v0.6.0。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

// ---- この版だけの部品 ----

/// 水準器の画面（スマホの画面の大きさで描く）。compass は N/E/S/W の文字
#let level-screen(w, h, compass: ("N", "E", "S", "W")) = box(width: w, height: h, fill: white, {
  let r = w * 0.4
  let cx = w / 2
  let cy = r + 8pt
  place(dx: cx - r, dy: cy - r, circle(radius: r, fill: accent-soft, stroke: 0.8pt + accent))
  place(dx: cx - r * 0.5, dy: cy - r * 0.5, circle(radius: r * 0.5, stroke: 0.5pt + accent.lighten(40%)))
  // 方位（北が少し回っている）
  for (i, t) in compass.enumerate() {
    let a = -60deg + i * 90deg
    let x = cx + (r + 4.5pt) * calc.cos(a)
    let y = cy + (r + 4.5pt) * calc.sin(a)
    place(dx: x - 3pt, dy: y - 3pt, box(width: 6pt, height: 6pt, align(center + horizon,
      text(size: 4.8pt, weight: "bold", fill: if i == 0 { map-red } else { sub })[#t])))
  }
  // 中心と流動点、その間の線と角度
  let fx = cx + r * 0.42
  let fy = cy - r * 0.3
  place(line(start: (cx, cy), end: (fx, fy), stroke: 0.9pt + ink))
  place(dx: cx - 1.5pt, dy: cy - 1.5pt, circle(radius: 1.5pt, fill: ink))
  place(dx: fx - 4pt, dy: fy - 4pt, circle(radius: 4pt, fill: okink.lighten(20%), stroke: 0.8pt + white))
  place(dx: cx - 12pt, dy: cy - r * 0.34, text(size: 5pt, weight: "bold", fill: ink)[3.2°])
  // 情報パネル（数値の行と直角三角形）
  let py = cy + r + 12pt
  for k in range(3) {
    place(dx: 5pt, dy: py + k * 6pt, rect(width: w * 0.42, height: 2.6pt, radius: 1pt, fill: line-c))
  }
  place(dx: w * 0.58, dy: py - 1pt, polygon(fill: accent-soft, stroke: 0.7pt + accent,
    (0pt, 15pt), (w * 0.34, 15pt), (w * 0.34, 0pt)))
})

/// 背景地図: 標準地図（道と地名のある白い地図）
#let std-map(w, h, bg: true) = box(width: w, height: h, clip: true, {
  if bg { place(rect(width: w, height: h, fill: rgb("#f7f5ef"))) }
  place(curve(stroke: (paint: rgb("#9e9e9e"), thickness: 1.2pt, cap: "round"),
    curve.move((-2pt, h * 0.7)), curve.cubic((w * 0.3, h * 0.3), (w * 0.6, h * 0.9), (w + 2pt, h * 0.35))))
  place(curve(stroke: (paint: rgb("#7fa7d9"), thickness: 1.8pt, cap: "round"),
    curve.move((w * 0.2, -2pt)), curve.cubic((w * 0.1, h * 0.4), (w * 0.5, h * 0.5), (w * 0.35, h + 2pt))))
  for (x, y, l) in ((0.52, 0.18, 0.3), (0.15, 0.58, 0.25), (0.6, 0.72, 0.28)) {
    place(dx: w * x, dy: h * y, rect(width: w * l, height: 2.4pt, radius: 1pt, fill: ink.lighten(35%)))
  }
})

/// 背景地図: 赤色立体図（尾根が赤く、谷が暗い）。alpha で薄くできる
#let relief-map(w, h, alpha: 100%) = box(width: w, height: h, clip: true, {
  let t(c) = c.transparentize(100% - alpha)
  place(rect(width: w, height: h, fill: t(rgb("#f1d2c4"))))
  for (k, c) in ((0, rgb("#c62828")), (1, rgb("#e57373")), (2, rgb("#8d3b2f")), (3, rgb("#ef9a9a"))) {
    place(curve(stroke: (paint: t(c), thickness: 2.2pt, cap: "round"),
      curve.move((-2pt, h * (0.15 + k * 0.24))),
      curve.cubic((w * 0.35, h * (0.02 + k * 0.24)), (w * 0.6, h * (0.32 + k * 0.24)), (w + 2pt, h * (0.1 + k * 0.24)))))
  }
})

/// スライダー（比率 ratio は 0〜1）
#let slider(w, ratio, left, right) = box(width: w, {
  stack(dir: ttb, spacing: 3pt, box(width: w, height: 8pt, {
    place(dy: 3pt, rect(width: w, height: 2pt, radius: 1pt, fill: line-c))
    place(dy: 3pt, rect(width: w * ratio, height: 2pt, radius: 1pt, fill: accent))
    place(dx: w * ratio - 4pt, circle(radius: 4pt, fill: accent, stroke: 1pt + white))
  }), box(width: w, { caption(left); h(1fr); caption(right) }))
})

/// 区画 4 つだけの地図（塗りの色と濃さを渡す）
#let comp-map(w, h, c, fill-alpha) = box(width: w, height: h, clip: true, {
  place(rect(width: w, height: h, fill: map-bg))
  let cw = w * 0.42
  let ch = h * 0.36
  for (x, y) in ((0.05, 0.08), (0.52, 0.08), (0.05, 0.53), (0.52, 0.53)) {
    place(dx: w * x, dy: h * y, rect(width: cw, height: ch, radius: 1pt,
      fill: c.transparentize(100% - fill-alpha), stroke: 0.9pt + c))
  }
})

// ---- 頭: 水準器 ----
#hero(
  "v0.6.0 — 2026/04/16",
  [水準器が\ 付きました],
  [地図画面の上のバーから開く、全画面の水準器です。加速度計・コンパス・GPS をまとめて使います。],
  grid(
    columns: (auto, auto), column-gutter: 14pt, align: horizon,
    phone(w: 80pt, h: 144pt, level-screen(74pt, 130pt)),
    align(left, stack(dir: ttb, spacing: 7pt,
      bubble[傾きを角度で],
      bubble[N/E/S/W が回って北を指す],
      bubble[緯度・経度・標高・精度],
      bubble[方位角・Pitch / Roll],
      bubble[直角三角形の計算],
    )),
  ),
  note: [水平になると振動と色で知らせます。縦にも横にも使えます。三角形はタップで基準の辺を切り替えられます。],
)

// ---- 座標系 ----
#scene(
  [どの座標系でも、そのまま開ける],
  [QGIS などで作った、任意の EPSG の GeoPackage を読み込み・編集できます。表示は WGS84 に変換し、保存は元の座標系に戻します。],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    pc(w: 84pt, h: 58pt, label: "QGIS で作った", mini-map(78pt, 43pt)),
    stack(dir: ttb, spacing: 3pt,
      file-icon(accent, w: 14pt),
      text(size: 7pt, weight: "bold", fill: accent)[小班.gpkg],
      badge(ok: false)[JGD2011 平面直角],
      arrow-r(w: 30pt),
    ),
    phone(w: 50pt, h: 88pt, label: "そのまま編集", mini-map(44pt, 74pt)),
  ),
  note: [座標系は GeoPackage の中の定義から自動で見分けます。定義が無いときは epsg.io に問い合わせ、結果を GeoPackage に書き戻します（次からはオフラインでも読めます）。],
)

// ---- 背景地図のブレンド ----
#scene(
  [背景地図を、重ねて見る],
  [「高度な設定」で、背景地図をスライダーの比率で重ねられます。国土地理院の赤色立体図も加えました。],
  stack(dir: ttb, spacing: 8pt,
    grid(
      columns: (auto, auto, auto, auto, auto), column-gutter: 5pt, align: horizon,
      stack(dir: ttb, spacing: 3pt, box(stroke: 0.6pt + line-c, std-map(54pt, 54pt)), caption[標準地図]),
      text(size: 12pt, weight: "bold", fill: accent)[+],
      stack(dir: ttb, spacing: 3pt, box(stroke: 0.6pt + line-c, relief-map(54pt, 54pt)), caption[赤色立体図]),
      arrow-r(w: 16pt),
      phone(w: 50pt, h: 88pt, label: "地名と地形を一度に", box(width: 44pt, height: 74pt, {
        place(relief-map(44pt, 74pt))
        place(box(width: 44pt, height: 74pt, fill: white.transparentize(45%)))
        place(std-map(44pt, 74pt, bg: false))
      })),
    ),
    slider(150pt, 0.5, "標準地図", "赤色立体図"),
  ),
)

// ---- 描画スタイル ----
#scene(
  [ポリゴンの既定は、黒の薄塗りに],
  [既定の色を、枠線・塗りともオレンジから黒にしました。塗りの不透明度は 30% から 10% に。],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    stack(dir: ttb, spacing: 4pt, caption[これまで], box(stroke: 0.6pt + line-c, comp-map(78pt, 60pt, rgb("#ef8a2e"), 30%)), caption[オレンジ・30%]),
    arrow-r(w: 18pt),
    stack(dir: ttb, spacing: 4pt, caption(fill: accent)[これから], box(stroke: 0.6pt + line-c, comp-map(78pt, 60pt, ink, 10%)), caption(fill: accent)[黒・10%]),
  ),
)

// ---- 一覧 ----
#fixes(
  "ほかに変わったこと",
  [設定で Google アカウントを切替・サインアウトできる],
  [Drive 連携ダイアログにも「アカウント切替」],
  [GPS 軌跡の未反映分も、すぐ地図に出る],
  [クラスタの半径をポイントの大きさに合わせる],
  [QGIS / GeoPandas 製 GeoPackage のトリガーを、書き込む直前に外す（読むだけなら変えない）],
  [WebView をやめ MapLibre Native に統一（Windows 版は休止）],
  [依存パッケージ 37 個を最新版に],
)

#fixes(
  "直したこと",
  [レイヤを続けてダブルタップすると固まっていた],
  [GPS 軌跡の表示が途切れていた],
  [座標系の番号がいつも 4326 で書かれていた],
)
