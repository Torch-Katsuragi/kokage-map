// Changelog (illustrated): v0.7.2. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

// ---- この版だけの部品 ----

// 地形の色分けの 3 色（地図の中の色）
#let slope-c = (rgb("#9ccc65"), rgb("#fdd835"), rgb("#e57373"))

/// 傾けた地形（3D）。cells は色の番号（0〜2、none で塗らない）を奥から手前へ 4 行 × 5 列
#let terrain(w, h, cells: none, contours: false, road: none, road-w: 1.6pt) = box(width: w, height: h, clip: true, {
  let top = h * 0.3
  place(rect(width: w, height: h, fill: rgb("#dbe9f7")))
  let p(u, v) = {
    let ww = w * 0.9 + w * 1.3 * v
    (w / 2 + (u - 0.5) * ww, top + v * (h - top))
  }
  place(polygon(fill: map-bg, p(0, 0), p(1, 0), p(1, 1), p(0, 1)))
  if cells != none {
    for (r, row) in cells.enumerate() {
      for (c, k) in row.enumerate() {
        if k != none {
          let (u0, u1, v0, v1) = (c / 5, (c + 1) / 5, r / 4, (r + 1) / 4)
          place(polygon(fill: slope-c.at(k), p(u0, v0), p(u1, v0), p(u1, v1), p(u0, v1)))
        }
      }
    }
  }
  if contours {
    for v in (0.2, 0.45, 0.72) {
      place(curve(stroke: 0.7pt + map-road.darken(10%),
        curve.move(p(0, v)), curve.line(p(0.25, v - 0.08)), curve.line(p(0.5, v + 0.06)), curve.line(p(0.75, v - 0.05)), curve.line(p(1, v + 0.04))))
    }
  }
  if road != none {
    place(curve(stroke: (paint: road, thickness: road-w, cap: "round"),
      curve.move(p(0, 0.78)), curve.line(p(0.3, 0.45)), curve.line(p(0.6, 0.8)), curve.line(p(1, 0.3))))
  }
})

// 尾根を斜めに横切る傾斜の並び
#let slope-cells = (
  (0, 1, 2, 1, 0),
  (1, 2, 2, 1, 0),
  (1, 2, 1, 0, 0),
  (2, 1, 0, 0, 1),
)

/// 設定の画面（見出しと行）。rows は (名前, 中身)
#let settings-panel(w: 120pt, title, rows) = box(width: w, fill: white, stroke: 0.6pt + line-c, radius: 3pt, clip: true, align(left, {
  block(width: 100%, fill: rgb("#f1eff4"), inset: (x: 5pt, y: 3pt), below: 0pt, text(size: 6.5pt, weight: "bold", fill: sub)[#title])
  for (name, body) in rows {
    block(width: 100%, inset: (x: 5pt, y: 3.5pt), above: 0pt, below: 0pt, stroke: (top: 0.4pt + line-c),
      grid(columns: (auto, 1fr), column-gutter: 4pt, align: (left + horizon, right + horizon),
        text(size: 7pt)[#name], body))
  }
}))

#let seg(..items, on: 0) = {
  for (i, it) in items.pos().enumerate() {
    box(fill: if i == on { accent } else { white }, stroke: 0.5pt + if i == on { accent } else { line-c },
      inset: (x: 3pt, y: 1.5pt), radius: 2pt,
      text(size: 6pt, weight: "bold", fill: if i == on { white } else { sub })[#it])
  }
}
#let swatch(c) = box(width: 8pt, height: 8pt, radius: 1.5pt, fill: c, stroke: 0.4pt + c.darken(25%), baseline: 15%)
#let slider(op) = box(width: 36pt, height: 3pt, baseline: -30%, {
  place(rect(width: 100%, height: 3pt, radius: 1.5pt, fill: line-c))
  place(rect(width: op * 100%, height: 3pt, radius: 1.5pt, fill: accent))
})

/// 画面の中の配置。card: "bottom"/"right"、bar: "left"/"right"
#let layout-screen(w, h, card: "bottom", bar: "left") = box(width: w, height: h, clip: true, {
  place(mini-map(w, h))
  let bx = if bar == "left" { 3pt } else { w - 11pt }
  place(dx: bx, dy: 5pt, rect(width: 8pt, height: 30pt, radius: 3pt, fill: white, stroke: 0.4pt + line-c))
  for i in range(3) { place(dx: bx + 2pt, dy: 8pt + i * 9pt, circle(radius: 2pt, fill: accent)) }
  if card == "bottom" {
    place(dy: h * 0.62, rect(width: w, height: h * 0.38, radius: (top-left: 4pt, top-right: 4pt), fill: white, stroke: 0.5pt + line-c))
    for (i, k) in (0.55, 0.8, 0.4).enumerate() { place(dx: 5pt, dy: h * 0.62 + 5pt + i * 5pt, rect(width: (w - 10pt) * k, height: 2pt, fill: line-c)) }
  } else {
    place(dx: w * 0.58, rect(width: w * 0.42, height: h, fill: white, stroke: 0.5pt + line-c))
    for (i, k) in (0.55, 0.8, 0.4).enumerate() { place(dx: w * 0.58 + 4pt, dy: 5pt + i * 5pt, rect(width: (w * 0.42 - 8pt) * k, height: 2pt, fill: line-c)) }
  }
})

/// ラベルの付いた地図（小班 4 つに ラベル）
#let label-map(w, h, labels) = box(width: w, height: h, clip: true, {
  place(mini-map(w, h))
  for ((x, y), l) in ((0.05, 0.08), (0.52, 0.08), (0.05, 0.53), (0.52, 0.53)).zip(labels) {
    place(dx: w * x, dy: h * y, box(width: w * 0.42, height: h * 0.36, align(center + horizon,
      text(size: 6pt, weight: "bold", fill: ink)[#l])))
  }
})

/// スタイルの 1 行（名前と値）。inherit: レイヤから届いた値
#let style-card(title, rows, stroke: 0.6pt + line-c) = box(width: 84pt, fill: white, stroke: stroke, radius: 3pt, clip: true, align(left, {
  block(width: 100%, fill: rgb("#f1eff4"), inset: (x: 5pt, y: 3pt), below: 0pt, text(size: 6.5pt, weight: "bold", fill: sub)[#title])
  for (name, body, own) in rows {
    block(width: 100%, inset: (x: 5pt, y: 3pt), above: 0pt, below: 0pt, stroke: (top: 0.4pt + line-c),
      grid(columns: (1fr, auto), align: (left + horizon, right + horizon),
        text(size: 7pt, fill: if own { ink } else { sub })[#name],
        text(size: 7pt, weight: if own { "bold" } else { "regular" }, fill: if own { ink } else { sub })[#body]))
  }
}))


// ---- Head: Terrain look ----
#hero(
  "v0.7.2 — 2026/09/13",
  [Color the terrain by slope or elevation],
  [New "Terrain look" settings: color the terrain by slope or elevation, and draw contour lines from the elevation tiles.],
  grid(
    columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
    settings-panel(w: 116pt, "Terrain look", (
      ([Color by], seg([Slope], [Elev.])),
      ([Colors], { swatch(slope-c.at(0)); h(2pt); swatch(slope-c.at(1)); h(2pt); swatch(slope-c.at(2)) }),
      ([Blend], { slider(0.6); h(3pt); text(size: 6pt, fill: sub)[60%] }),
      ([Contours], check-box()),
    )),
    arrow-r(w: 16pt),
    phone(w: 62pt, h: 104pt, terrain(56pt, 90pt, cells: slope-cells, contours: true)),
  ),
  note: [Pick your own three colors. At 100% blend you see the terrain only, without the base map. Both come from the terrain mesh itself, so they stay sharp when tilted.],
)

#scene(
  [Pick a screen layout],
  [Choose Auto, Portrait, Landscape or Left-handed in Settings. The info card slides up from the bottom like the attribute table, and the two never show together.],
  grid(
    columns: (auto, auto, auto), column-gutter: 10pt, align: bottom,
    phone(w: 50pt, h: 88pt, label: "Portrait", layout-screen(44pt, 74pt)),
    phone(w: 92pt, h: 56pt, label: "Landscape", layout-screen(86pt, 42pt, card: "right")),
    phone(w: 50pt, h: 88pt, label: "Left-handed", layout-screen(44pt, 74pt, bar: "right")),
  ),
  note: [Landscape puts the card on the right; Left-handed moves the toolbar and buttons to the right.],
)

#scene(
  [Labels use QGIS expressions],
  [Labels are composed in the style screen (layer / View) and work for line and polygon layers too. They go into `.qgs` as expressions.],
  stack(dir: ttb, spacing: 8pt,
    box(fill: white, stroke: 0.6pt + line-c, radius: 3pt, inset: (x: 6pt, y: 4pt),
      text(size: 7.5pt)[`concat("compt", '-', "stand")`]),
    arrow-d(),
    grid(
      columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
      phone(w: 50pt, h: 88pt, label: "Kokage Map", label-map(44pt, 74pt, ([12-1], [12-2], [12-3], [12-4]))),
      arrow-lr(w: 26pt),
      pc(w: 96pt, h: 66pt, label: "QGIS", label-map(90pt, 51pt, ([12-1], [12-2], [12-3], [12-4]))),
    ),
  ),
  note: [Labels set in QGIS are read back, and existing settings are converted automatically. Columns are ordered by how often they hold a value, and expressions can be typed directly.],
)

#scene(
  [Views hold only differences],
  [A View's style holds only the items that differ from the layer, so layer changes reach the View for untouched items.],
  stack(dir: ttb, spacing: 8pt,
    grid(
      columns: (auto, auto, auto), column-gutter: 6pt, align: bottom,
      stack(dir: ttb, spacing: 4pt,
        bubble[Layer color to green],
        style-card("Layer", (([Color], swatch(map-green), true), ([Width], [2], true)), stroke: 1.2pt + accent),
      ),
      arrow-r(w: 16pt),
      style-card("View", (([Color], swatch(map-green), false), ([Width], [4], true))),
    ),
    grid(
      columns: (auto, auto), column-gutter: 16pt,
      phone(w: 50pt, h: 88pt, label: "Layer", mini-map(44pt, 74pt, road: map-green.darken(20%), road-w: 1.6pt)),
      phone(w: 50pt, h: 88pt, label: "View (width stays 4)", mini-map(44pt, 74pt, road: map-green.darken(20%), road-w: 3.4pt)),
    ),
  ),
  note: ["Follow the layer" resets the View.],
)

#fixes(
  "Also changed",
  [Zoom 13 and below: features baked in; 10,000 polygons stay smooth],
  [CLI and URL control: open, look, reload],
  [Map menu: "Reload project from disk"],
  [View row shows even for a single View],
  [Photo card copies a Google Maps link],
)

#fixes(
  "Fixes",
  [3D terrain: no more seams between tiles],
  [Erased features could stay on the map],
  [GPS tracks split after a 10-minute gap],
  [Leftover strings follow the app language],
  [Web: the map could open without a folder],
  [Web: right-drag rotation popped up a menu],
)
