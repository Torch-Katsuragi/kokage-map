// Changelog (illustrated): v0.7.3. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

// ---- この版だけの部品 ----

/// 属性テーブル（画面の中）。rows は (小班, 状態, 直したか)
#let attr-table(w, head, rows) = box(width: w, height: 100%, fill: white, {
  let cell(body, fill: white, bold: false, c: ink) = box(width: 100%, fill: fill, inset: (x: 2.5pt, y: 2.2pt),
    text(size: 6pt, weight: if bold { "bold" } else { "regular" }, fill: c)[#body])
  grid(columns: (1fr, 1fr), stroke: 0.4pt + line-c,
    ..head.map(h => cell(h, fill: rgb("#f1eff4"), bold: true, c: sub)),
    ..rows.map(r => {
      let (a, b, on) = r
      (cell(a, fill: if on { accent-soft } else { white }), cell(b, fill: if on { accent-soft } else { white }, bold: on, c: if on { accent } else { ink }))
    }).flatten(),
  )
})

/// 「地図・タイル」の画面。rows は (名前, 表示, 不透明度 0〜1, 合成モード)
#let tiles-panel(w: 132pt, title: "地図・タイル", rows) = box(width: w, fill: white, stroke: 0.6pt + line-c, radius: 3pt, clip: true, align(left, {
  block(width: 100%, fill: rgb("#f1eff4"), inset: (x: 5pt, y: 3pt), below: 0pt, text(size: 6.5pt, weight: "bold", fill: sub)[#title])
  for (name, on, op, mode) in rows {
    block(width: 100%, inset: (x: 5pt, y: 3pt), above: 0pt, below: 0pt, stroke: (top: 0.4pt + line-c), stack(dir: ttb, spacing: 3pt,
      grid(columns: (8pt, 1fr, auto), column-gutter: 3pt, align: horizon,
        check-box(on: on),
        text(size: 7.3pt, fill: if on { ink } else { sub })[#name],
        text(size: 6pt, fill: sub)[≡],
      ),
      grid(columns: (1fr, auto), column-gutter: 4pt, align: horizon,
        box(width: 100%, height: 3pt, {
          place(rect(width: 100%, height: 3pt, radius: 1.5pt, fill: line-c))
          place(rect(width: op * 100%, height: 3pt, radius: 1.5pt, fill: if on { accent } else { sub.lighten(40%) }))
        }),
        text(size: 6pt, fill: sub)[#calc.round(op * 100)% · #mode],
      ),
    ))
  }
}))

/// 等高線の入った地図。n 本の輪
#let contour-map(w, h, n, bg: true) = box(width: w, height: h, clip: true, {
  if bg { place(rect(width: w, height: h, fill: map-bg)) }
  for i in range(n) {
    let k = (i + 1) / n
    let ew = w * 1.5 * k
    let eh = h * 1.2 * k
    place(dx: w * 0.55 - ew / 2, dy: h * 0.5 - eh / 2, ellipse(width: ew, height: eh, stroke: 0.5pt + map-road.lighten(20%)))
  }
})

/// 傾けた地図（3D）。上は空、下は奥へ細る地面
#let tilted-map(w, h) = box(width: w, height: h, clip: true, {
  let top = h * 0.3
  place(rect(width: w, height: h, fill: rgb("#dbe9f7")))
  let p(u, v) = {
    let tw = w * 0.9
    let bw = w * 2.2
    let ww = tw + (bw - tw) * v
    (w / 2 + (u - 0.5) * ww, top + v * (h - top))
  }
  place(polygon(fill: map-bg, p(0, 0), p(1, 0), p(1, 1), p(0, 1)))
  for (x, y) in ((0.05, 0.08), (0.52, 0.08), (0.05, 0.53), (0.52, 0.53)) {
    place(polygon(fill: map-comp.lighten(20%), stroke: 0.6pt + map-comp.darken(35%),
      p(x, y), p(x + 0.42, y), p(x + 0.42, y + 0.36), p(x, y + 0.36)))
  }
  place(curve(stroke: (paint: map-road, thickness: 1.6pt, cap: "round"),
    curve.move(p(0, 0.78)), curve.line(p(0.3, 0.45)), curve.line(p(0.6, 0.8)), curve.line(p(1, 0.3))))
})

/// コンパスのボタン
#let compass-btn(label) = box(width: 22pt, height: 22pt, {
  place(circle(radius: 11pt, fill: white, stroke: 0.7pt + line-c))
  place(dx: 11pt - 3pt, dy: 4pt, polygon(fill: map-red, (3pt, 0pt), (6pt, 7pt), (0pt, 7pt)))
  place(dy: 12pt, box(width: 22pt, align(center, text(size: 5.5pt, weight: "bold", fill: ink)[#label])))
})

/// lib の layer-panel を左寄せで（場面の中は中央寄せなので、字下げが消えないように）

/// hero の下の注記（scene の note と同じ字）

// ---- Head: two devices, merged row by row ----
#hero(
  "v0.7.3 — 2026/09/27",
  [Two devices, \ merged row by row],
  [When two devices edit the same GeoPackage, Drive sync merges the changes row by row. Edits to different rows are both kept.],
  {
    let head = ([Stand], [Status])
    stack(dir: ttb, spacing: 5pt,
      grid(
        columns: (96pt, 96pt), align: center,
        stack(dir: ttb, spacing: 4pt, bubble[Edit row 1],
          phone(w: 58pt, h: 60pt, label: "Device A", attr-table(52pt, head, (([1], [Done], true), ([2], [Todo], false), ([3], [Todo], false))))),
        stack(dir: ttb, spacing: 4pt, bubble[Edit row 3],
          phone(w: 58pt, h: 60pt, label: "Device B", attr-table(52pt, head, (([1], [Todo], false), ([2], [Todo], false), ([3], [Done], true))))),
      ),
      arrows-in(192pt),
      cloud(w: 64pt, label: "Drive"),
      arrow-d(),
      stack(dir: ttb, spacing: 4pt,
        phone(w: 58pt, h: 60pt, attr-table(52pt, head, (([1], [Done], true), ([2], [Todo], false), ([3], [Done], true)))),
        badge[Both edits are kept],
      ),
    )
  },
  note: [If both sides changed the same column of the same row, this device's value wins. "Revert to cloud value" in the notification restores the other side.],
)

#scene(
  [Stack base maps like layers],
  [In Maps & Tiles you can reorder base maps, show or hide them, and set opacity and blend mode (multiply, screen, …).],
  grid(
    columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
    tiles-panel(w: 128pt, title: "Maps & Tiles", (
      ([Contours], true, 1.0, [Normal]),
      ([GSI map], true, 0.6, [Multiply]),
      ([OpenStreetMap], false, 1.0, [Normal]),
    )),
    arrow-r(w: 16pt),
    phone(w: 58pt, h: 100pt, {
      place(mini-map(52pt, 86pt, comps: false, road-w: 1.6pt))
      place(contour-map(52pt, 86pt, 5, bg: false))
    }),
  ),
  note: [Existing stacks keep their look, and the settings screen shows a one-tile preview.],
)

#scene(
  [Contours are a base map now],
  [Intervals match the GSI standard map and get finer as you zoom in. Generated tiles stay in the cache, so they work offline.],
  stack(dir: ttb, spacing: 8pt,
    grid(
      columns: (auto,) * 4, column-gutter: 6pt, align: center,
      ..(("Zoom 18", "2 m", 12), ("15–17", "10 m", 8), ("12–14", "100 m", 5), ("9–11", "200 m", 3)).map(((z, iv, n)) =>
        stack(dir: ttb, spacing: 3pt,
          box(stroke: 0.6pt + line-c, radius: 2pt, clip: true, contour-map(52pt, 52pt, n)),
          text(size: 7.5pt, weight: "bold")[#iv],
          caption(z),
        )
      ),
    ),
    badge[Works offline],
  ),
)

#scene(
  [Compass toggles 2D and 3D],
  [2D looks straight down; 3D is tilted. Each has its own gestures.],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: (top, top + center, top),
    stack(dir: ttb, spacing: 4pt,
      phone(w: 58pt, h: 100pt, label: "2D", {
        place(mini-map(52pt, 86pt))
        place(dx: 27pt, dy: 61pt, compass-btn[2D])
      }),
      bubble[1 finger: pan\ 2 fingers: zoom, rotate],
    ),
    pad(top: 46pt, arrow-lr(w: 26pt)),
    stack(dir: ttb, spacing: 4pt,
      phone(w: 58pt, h: 100pt, label: "3D", {
        place(tilted-map(52pt, 86pt))
        place(dx: 27pt, dy: 61pt, compass-btn[3D])
      }),
      bubble[1 finger: rotate, tilt],
    ),
  ),
  note: [Double-tap resets north. In 3D, long-press toggles the perspective view.],
)

#scene(
  [A "System" folder at the top],
  [The global folder has moved inside "System". It holds device-side data that doesn't belong to the project.],
  grid(
    columns: (auto, auto, auto), column-gutter: 5pt, align: horizon,
    stack(dir: ttb, spacing: 4pt,
      caption[Before],
      layer-panel(w: 84pt, header: "Layers", (
        (0, "dir", "Global", "ok"),
        (0, "layer", "Roads", "ok"),
        (0, "layer", "Stands", "ok", map-comp),
      )),
    ),
    arrow-r(w: 14pt),
    stack(dir: ttb, spacing: 4pt,
      caption(fill: accent)[Now],
      layer-panel(w: 84pt, header: "Layers", (
        (0, "dir", "System", "hi"),
        (1, "dir", "Global", "ok"),
        (0, "layer", "Roads", "ok"),
        (0, "layer", "Stands", "ok", map-comp),
      )),
    ),
  ),
  note: [The folder stays where it was on disk, and its shown/hidden state carries over.],
)

#fixes(
  "Also changed",
  [New columns on one side are aligned first],
  [Auto-sync uploads only files that changed],
  [Opens at the extent of all features],
  [3D loads coarse first; waits cut by half],
  [2× base maps on high-density screens],
  [Bulk download saves all stacked layers (contours too) except OpenStreetMap],
  [Attributions: Maps & Tiles → Data sources],
  [Attribute form saves on leaving a field],
  [Numeric columns open a number keyboard],
)

#fixes(
  "Fixes",
  [Android edits missed QGIS's spatial index],
  [Opening a downloaded file re-uploaded it],
  [Another path re-downloaded every file],
  [Android: slope coloring had no effect],
  [3D: plateaus over rivers and lakes],
  [Heading indicator is a fan again, as in 2D],
  [The keyboard hid dialogs and the toolbar],
  [Portrait: table buttons ran off screen],
  [Left-handed layout: web zoom buttons overlapped the record button],
  [Web: the first "Choose folder" failed],
)
