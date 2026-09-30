// 更新履歴（図解）の共通部品。
//
// 読み物ではなく「見てわかる」ページにする。1 つの変化を 1 場面（scene）にし、
// 大きな見出し → 1〜2 行 → 絵（実物に似せた端末・QGIS の画面・Drive）の順に置く。図番号や表は使わない。
// 絵は飾りではなく、どの端末で・何が・どう変わるかを見せるものだけ。
//
// 継ぎ目を見せない（縦読み漫画のように、スクロールで次々に出てくる）ための約束:
// - 背景は塗らない（アプリの画面の地がそのまま見える）。左右の余白も持たない（アプリが文章と同じ余白で置く）
// - 場面ごとにページを切る。1 ページ＝1 切れで、アプリはスクロールに合わせて切れを順に読み込む。
//   切れの高さは build.py が書き出す一覧に入るので、読み込みで画面がずれない
// - 幅は、アプリで文章と同じくらいの字の大きさになるよう狭めにとる
// アプリにダークテーマは無いので明るい配色だけ（付けるなら暗い配色で別に書き出して出し分ける）

// ---- 配色（増やさない。地図の中の色だけは地図らしさのために別に持つ）----
#let ink = rgb("#1c1b1f")
#let sub = rgb("#5f5b63")
#let line-c = rgb("#d6d3da")
#let accent = rgb("#1565c0")
#let accent-soft = rgb("#e3eefc")
#let okbg = rgb("#e6f4ea")
#let okink = rgb("#1e6b3a")
#let warm = rgb("#b45309")
#let white-c = white
// 地図
#let map-bg = rgb("#eef3e6")
#let map-comp = rgb("#f3c98b")
#let map-road = rgb("#8d6e63")
#let map-red = rgb("#d32f2f")
#let map-green = rgb("#9ccc65")

#let font-main = ("BIZ UDPGothic", "Yu Gothic", "Noto Sans CJK JP")

#let page-setup(body) = {
  set page(width: 252pt, height: auto, margin: 0pt, fill: none)
  set text(font: font-main, size: 10.5pt, fill: ink, lang: "ja")
  set par(leading: 0.65em, justify: false)
  show raw: set text(font: font-main, size: 1.08em, fill: accent)
  body
  // 次の版（md）の見出しとの間
  v(24pt)
}

// ---- 場面 ----

/// 版の頭。大きな一言と、その下に短い説明
#let hero(version, title, lead, visual) = {
  v(10pt)
  text(size: 9pt, weight: "bold", fill: accent, tracking: 0.5pt)[#version]
  v(4pt)
  text(size: 19pt, weight: "bold")[#title]
  v(6pt)
  text(size: 10.5pt, fill: sub)[#lead]
  v(14pt)
  align(center, visual)
}

/// 1 つの変化。前の場面とはページを切る（＝切れ）
#let scene(title, lead, visual, note: none) = {
  pagebreak(weak: true)
  v(30pt)
  text(size: 15pt, weight: "bold")[#title]
  v(5pt)
  text(size: 10.5pt, fill: sub)[#lead]
  v(14pt)
  align(center, visual)
  if note != none {
    v(10pt)
    text(size: 8.8pt, fill: sub)[#note]
  }
}

// ---- 小物 ----

#let caption(body, fill: sub) = text(size: 8pt, fill: fill)[#body]

#let badge(body, ok: true) = box(
  fill: if ok { okbg } else { rgb("#f1eff4") },
  radius: 20pt, inset: (x: 5pt, y: 2.5pt),
  text(size: 7.5pt, weight: "bold", fill: if ok { okink } else { sub })[#body],
)

/// 右向きの矢印（長さ w）
#let arrow-r(w: 18pt, c: accent) = box(width: w, height: 8pt, {
  place(dy: 4pt, line(length: w - 4pt, stroke: 1.6pt + c))
  place(dx: w - 6pt, polygon(fill: c, (0pt, 0pt), (6pt, 4pt), (0pt, 8pt)))
})
/// 左右の矢印（行き来）
#let arrow-lr(w: 26pt, c: accent) = box(width: w, height: 8pt, {
  place(dx: 4pt, dy: 4pt, line(length: w - 8pt, stroke: 1.6pt + c))
  place(polygon(fill: c, (6pt, 0pt), (0pt, 4pt), (6pt, 8pt)))
  place(dx: w - 6pt, polygon(fill: c, (0pt, 0pt), (6pt, 4pt), (0pt, 8pt)))
})
/// 左右の 2 か所から真ん中へ寄る矢印（2 台 → Drive）
#let arrows-in(w, h: 26pt, c: accent) = box(width: w, height: h, {
  let stroke = (paint: c, thickness: 1.6pt, cap: "round", join: "round")
  // 左右から下りてきて真ん中で合流し、下を向く
  place(curve(stroke: stroke, curve.move((w * 0.25, 0pt)), curve.cubic((w * 0.25, h * 0.55), (w * 0.5, h * 0.35), (w * 0.5, h - 7pt))))
  place(curve(stroke: stroke, curve.move((w * 0.75, 0pt)), curve.cubic((w * 0.75, h * 0.55), (w * 0.5, h * 0.35), (w * 0.5, h - 7pt))))
  place(dx: w * 0.5 - 4pt, dy: h - 7pt, polygon(fill: c, (0pt, 0pt), (8pt, 0pt), (4pt, 6pt)))
})
/// 下向きの矢印
#let arrow-d(h: 16pt, c: accent) = box(width: 8pt, height: h, {
  place(dx: 4pt, line(angle: 90deg, length: h - 4pt, stroke: 1.6pt + c))
  place(dy: h - 6pt, polygon(fill: c, (0pt, 0pt), (8pt, 0pt), (4pt, 6pt)))
})

#let file-icon(c, w: 9pt) = box(width: w, height: w * 1.25, baseline: 18%, {
  place(polygon(fill: white, stroke: 0.9pt + c, (0pt, 0pt), (w * 0.65, 0pt), (w, w * 0.3), (w, w * 1.25), (0pt, w * 1.25)))
})
#let folder-icon(c, w: 11pt) = box(width: w, height: w * 0.75, baseline: 10%, {
  place(rect(width: w * 0.45, height: w * 0.2, fill: c, radius: (top-left: 1pt, top-right: 1pt)))
  place(dy: w * 0.13, rect(width: w, height: w * 0.62, fill: c, radius: 1pt))
})
#let lock-icon(c) = box(width: 7pt, height: 8pt, baseline: 10%, {
  place(dx: 1.2pt, circle(radius: 2.3pt, stroke: 1pt + c))
  place(dy: 3.2pt, rect(width: 7pt, height: 4.8pt, fill: c, radius: 1pt))
})
#let check-box(on: true, c: accent) = box(width: 8pt, height: 8pt, baseline: 10%, {
  place(rect(width: 8pt, height: 8pt, radius: 1.5pt, fill: if on { c } else { white }, stroke: 0.8pt + if on { c } else { sub }))
  if on {
    place(curve(stroke: (paint: white, thickness: 1.3pt, cap: "round", join: "round"),
      curve.move((1.8pt, 4.2pt)), curve.line((3.5pt, 6pt)), curve.line((6.4pt, 2.2pt))))
  }
})

// ---- 地図の絵 ----

/// 小さな地図: 小班（区画 4 つ）と路網（曲線 1 本）。見せ方を引数で変える
#let mini-map(w, h, road: map-road, road-w: 2pt, comps: true, comp: map-comp) = box(width: w, height: h, clip: true, {
  place(rect(width: w, height: h, fill: map-bg))
  if comps {
    let cw = w * 0.42
    let ch = h * 0.36
    for (x, y) in ((0.05, 0.08), (0.52, 0.08), (0.05, 0.53), (0.52, 0.53)) {
      place(dx: w * x, dy: h * y, rect(width: cw, height: ch, radius: 1pt,
        fill: comp.lighten(20%), stroke: 0.6pt + comp.darken(35%)))
    }
  }
  place(curve(stroke: (paint: road, thickness: road-w, cap: "round"),
    curve.move((-2pt, h * 0.78)),
    curve.cubic((w * 0.3, h * 0.2), (w * 0.6, h * 1.0), (w + 2pt, h * 0.3))))
})

/// スマホ（こかげマップ）。中身は画面の大きさ（w-6pt × h-14pt）で渡す
#let phone(w: 62pt, h: 112pt, label: none, screen) = {
  box(width: w, height: h, {
    place(rect(width: w, height: h, radius: 9pt, fill: ink))
    place(dx: 3pt, dy: 7pt, box(width: w - 6pt, height: h - 14pt, radius: 3pt, clip: true, screen))
    place(dx: w / 2 - 6pt, dy: 2.5pt, rect(width: 12pt, height: 2pt, radius: 1pt, fill: rgb("#444")))
  })
  if label != none { linebreak(); caption(label) }
}

/// パソコン（QGIS）。中身は画面の大きさ（w-6pt × h-24pt）で渡す
#let pc(w: 118pt, h: 84pt, label: none, screen) = {
  box(width: w, height: h + 10pt, {
    place(rect(width: w, height: h, radius: 4pt, fill: ink))
    place(dx: 3pt, dy: 3pt, box(width: w - 6pt, height: 9pt, fill: rgb("#e9e7ee"), inset: (x: 3pt, y: 1.5pt),
      text(size: 5.5pt, fill: sub)[QGIS]))
    place(dx: 3pt, dy: 12pt, box(width: w - 6pt, height: h - 15pt, clip: true, screen))
    place(dx: w / 2 - 10pt, dy: h, polygon(fill: rgb("#8f8b95"), (4pt, 0pt), (16pt, 0pt), (20pt, 8pt), (0pt, 8pt)))
  })
  if label != none { linebreak(); caption(label) }
}

/// Drive（雲）
#let cloud(w: 58pt, label: none) = box(width: w, height: w * 0.52, {
  let c = accent-soft
  place(dx: w * 0.08, dy: w * 0.2, circle(radius: w * 0.16, fill: c))
  place(dx: w * 0.28, dy: w * 0.02, circle(radius: w * 0.22, fill: c))
  place(dx: w * 0.55, dy: w * 0.14, circle(radius: w * 0.18, fill: c))
  place(dx: w * 0.1, dy: w * 0.3, rect(width: w * 0.8, height: w * 0.2, radius: w * 0.1, fill: c))
  if label != none {
    place(dx: 0pt, dy: w * 0.27, box(width: w, align(center, text(size: 7.5pt, weight: "bold", fill: accent)[#label])))
  }
})

/// QGIS のレイヤパネル。rows は (字下げ, 種類 "dir"/"layer", 名前, 状態 "ok"/"lock"/"hi"[, レイヤの色])
#let layer-panel(w: 108pt, rows) = box(width: w, fill: white, stroke: 0.6pt + line-c, radius: 3pt, clip: true, {
  block(width: 100%, fill: rgb("#f1eff4"), inset: (x: 5pt, y: 3pt), below: 0pt, text(size: 6.5pt, weight: "bold", fill: sub)[レイヤ])
  for row in rows {
    let (depth, kind, name, state) = row.slice(0, 4)
    let swatch = row.at(4, default: map-road)
    let locked = state == "lock"
    block(width: 100%, inset: (left: 5pt + depth * 8pt, right: 5pt, y: 2.6pt), above: 0pt, below: 0pt,
      fill: if state == "hi" { accent-soft } else { white }, {
        if locked { box(width: 8pt, lock-icon(sub)) } else { check-box(on: true) }
        h(3pt)
        if kind == "dir" { folder-icon(if locked { sub.lighten(30%) } else { warm }, w: 9pt) } else { box(width: 9pt, height: 5pt, baseline: -10%, rect(width: 9pt, height: 5pt, fill: if locked { sub.lighten(30%) } else { swatch }, radius: 1pt)) }
        h(3pt)
        text(size: 7.5pt, fill: if locked { sub.lighten(15%) } else { ink })[#name]
      })
  }
})

/// 吹き出し（端末で何をしたか）
#let bubble(body) = box(fill: white, stroke: 0.7pt + line-c, radius: 6pt, inset: (x: 5pt, y: 3.5pt),
  text(size: 7.8pt)[#body])

/// 最後の「細かな修正」: チェックの付いた短い行
#let fixes(title, ..items) = {
  pagebreak(weak: true)
  v(30pt)
  text(size: 13pt, weight: "bold")[#title]
  v(8pt)
  block(width: 100%, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: (x: 9pt, y: 8pt), {
    for (i, it) in items.pos().enumerate() {
      if i > 0 { v(5.5pt) }
      grid(columns: (11pt, 1fr), column-gutter: 4pt, check-box(c: okink), text(size: 9pt)[#it])
    }
  })
}
