// 更新履歴（図解）: v0.5.0。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

// レーザー距離計（横から）
#let rangefinder(w: 54pt, label: none) = {
  box(width: w, height: w * 0.62, {
    place(dy: w * 0.12, rect(width: w * 0.82, height: w * 0.46, radius: 5pt, fill: rgb("#3b3a3f")))
    place(dx: w * 0.64, dy: w * 0.08, rect(width: w * 0.3, height: w * 0.54, radius: 4pt, fill: rgb("#2a292d")))
    place(dx: w * 0.72, dy: w * 0.2, circle(radius: w * 0.11, fill: rgb("#5d7fa3"), stroke: 1.5pt + rgb("#18171a")))
    place(dx: w * 0.2, dy: w * 0.05, rect(width: w * 0.16, height: w * 0.08, radius: 1pt, fill: map-red))
    place(dx: -w * 0.04, dy: w * 0.22, rect(width: w * 0.08, height: w * 0.26, radius: 1.5pt, fill: rgb("#18171a")))
  })
  if label != none { linebreak(); caption(label) }
}

// 測点を結んだ折れ線。gap で最後の点を始点から離す（閉じない分）
#let traverse(w, h, pts, close: true, c: accent, gap: none, dots: true) = box(width: w, height: h, {
  let p = pts.map(((x, y)) => (w * x, h * y))
  let seg = (curve.move(p.at(0)),) + p.slice(1).map(q => curve.line(q))
  if close { seg.push(curve.close()) }
  place(curve(stroke: (paint: c, thickness: 1.4pt, join: "round"), ..seg))
  if gap != none {
    let (a, b) = (p.at(-1), p.at(0))
    place(line(start: a, end: b, stroke: (paint: map-red, thickness: 1.2pt, dash: "dashed")))
  }
  if dots {
    for q in p { place(dx: q.at(0) - 2.3pt, dy: q.at(1) - 2.3pt, circle(radius: 2.3pt, fill: white, stroke: 1.2pt + c)) }
  }
})

#let warn-badge(body) = box(fill: rgb("#fdecea"), radius: 20pt, inset: (x: 5pt, y: 2.5pt),
  text(size: 7.5pt, weight: "bold", fill: map-red)[#body])

// 重なった地物（区画・路網・点）。sel で選ばれているものを青く
#let pick-map(w, h, sel) = box(width: w, height: h, clip: true, radius: 3pt, {
  place(rect(width: w, height: h, fill: map-bg))
  place(dx: w * 0.14, dy: h * 0.16, rect(width: w * 0.62, height: h * 0.64, radius: 1pt,
    fill: if sel == 2 { accent-soft } else { map-comp.lighten(20%) },
    stroke: if sel == 2 { 1.4pt + accent } else { 0.6pt + map-comp.darken(35%) }))
  place(curve(stroke: (paint: if sel == 1 { accent } else { map-road }, thickness: if sel == 1 { 2.6pt } else { 2pt }, cap: "round"),
    curve.move((-2pt, h * 0.75)), curve.cubic((w * 0.3, h * 0.3), (w * 0.6, h * 0.7), (w + 2pt, h * 0.2))))
  place(dx: w * 0.5 - 3.5pt, dy: h * 0.5 - 3.5pt, circle(radius: 3.5pt,
    fill: if sel == 0 { accent } else { map-red }, stroke: 1.2pt + white))
  // 指で押したところ
  place(dx: w * 0.5 - 7pt, dy: h * 0.5 - 7pt, circle(radius: 7pt, stroke: (paint: ink.transparentize(40%), thickness: 0.8pt, dash: "dotted")))
})

// ---- 頭: レーザー距離計 ----
#hero(
  "v0.5.0 — 2026/03/31",
  [レーザー距離計で現場測量],
  [TruPulse 360R と Bluetooth でつながります。測った距離・方位角・傾斜角が、そのまま点として記録されます。],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    rangefinder(label: "TruPulse 360R"),
    stack(dir: ttb, spacing: 3pt, caption(fill: accent)[Bluetooth], arrow-r(w: 26pt)),
    phone(w: 66pt, h: 118pt, label: "測るたびに点が増える", box(width: 60pt, height: 104pt, {
      place(rect(width: 60pt, height: 104pt, fill: map-bg))
      place(dy: 10pt, traverse(60pt, 60pt, ((0.2, 0.85), (0.3, 0.3), (0.72, 0.18), (0.82, 0.6)), close: false))
      place(dx: 4pt, dy: 76pt, block(width: 52pt, fill: white, radius: 3pt, inset: 3pt, {
        set text(size: 5.5pt, fill: sub)
        [距離] ; h(1fr) ; [方位角] ; h(1fr) ; [傾斜角]
      }))
    })),
  ),
)

// ---- 閉合 ----
#scene(
  [閉じ具合をその場で確かめる],
  [閉合比をリアルタイムに表示し、精度が足りなければすぐ警告します。閉合補正はコンパス法則・トランシット法則から選べます。],
  grid(
    columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
    stack(dir: ttb, spacing: 5pt,
      traverse(84pt, 70pt, ((0.12, 0.8), (0.2, 0.2), (0.75, 0.1), (0.9, 0.6), (0.32, 0.9)), close: false, gap: true),
      caption[始点に戻りきらない],
      warn-badge[閉合比が足りないと警告],
    ),
    stack(dir: ttb, spacing: 3pt, caption(fill: accent)[閉合補正], arrow-r(w: 22pt)),
    stack(dir: ttb, spacing: 5pt,
      traverse(84pt, 70pt, ((0.12, 0.8), (0.2, 0.2), (0.75, 0.1), (0.9, 0.6), (0.3, 0.88))),
      caption(fill: accent)[ずれを配って閉じる],
      badge[精度を担保],
    ),
  ),
  note: [磁気偏角・器械高・目標高の補正にも対応しています。],
)

// ---- 点から線・面 ----
#scene(
  [測った点がそのまま線や面に],
  [測量の点から、Line や Polygon のレイヤを自動で作れます。],
  grid(
    columns: (auto, auto, auto, auto), column-gutter: 6pt, align: horizon,
    stack(dir: ttb, spacing: 4pt,
      traverse(60pt, 52pt, ((0.12, 0.8), (0.25, 0.2), (0.78, 0.12), (0.88, 0.7)), close: false, c: sub, dots: true),
      caption[測った点]),
    arrow-r(w: 18pt),
    stack(dir: ttb, spacing: 4pt,
      traverse(60pt, 52pt, ((0.12, 0.8), (0.25, 0.2), (0.78, 0.12), (0.88, 0.7)), close: false, c: map-road, dots: false),
      caption[Line]),
    stack(dir: ttb, spacing: 4pt,
      box(width: 60pt, height: 52pt, {
        place(polygon(fill: map-comp.lighten(20%), stroke: 1.2pt + map-comp.darken(35%),
          (7.2pt, 41.6pt), (15pt, 10.4pt), (46.8pt, 6.24pt), (52.8pt, 36.4pt)))
      }),
      caption[Polygon]),
  ),
)

// ---- 選択ツール ----
#scene(
  [重なっていてもタップで順に選べる],
  [選択ツールがすべてのレイヤをまたいで選ぶようになりました。同じ場所をもう一度タップすると、次の候補に移ります。],
  grid(
    columns: (auto, auto, auto, auto, auto), column-gutter: 4pt, align: horizon,
    stack(dir: ttb, spacing: 4pt, pick-map(62pt, 56pt, 0), caption[1 回目: 点]),
    arrow-r(w: 12pt),
    stack(dir: ttb, spacing: 4pt, pick-map(62pt, 56pt, 1), caption[2 回目: 線]),
    arrow-r(w: 12pt),
    stack(dir: ttb, spacing: 4pt, pick-map(62pt, 56pt, 2), caption[3 回目: 面]),
  ),
)

#fixes(
  "細かいけど大事な改善",
  [画面上部のバーに通知センターを追加],
  [グローバルフォルダの場所を自由に設定できる],
  [GeoJSON の読み込みでジオメトリ型ごとに分割],
  [Windows 版で GPS・マーカー・初回ジャンプが復活],
)

#fixes(
  "アプリ全体の安定性",
  [状態管理を Riverpod に統一して作り直した],
  [非同期処理どうしの競合を防いだ],
  [設定の仕組みを宣言的に整理した],
  [マルチジオメトリに対応した],
)
