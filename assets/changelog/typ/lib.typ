// 更新履歴（図解）の共通部品。スマホの幅に合わせた縦長 1 ページ（高さは中身なり）。
// アプリにダークテーマは無いので明るい配色だけ（付けるなら暗い配色で別に書き出して出し分ける）

// 配色。増やさない
#let bg = white
#let ink = rgb("#1c1b1f")
#let sub = rgb("#5f5b63")
#let line-c = rgb("#d6d3da")
#let accent = rgb("#1565c0")
#let okbg = rgb("#e6f4ea")
#let okink = rgb("#1e6b3a")
#let warm = rgb("#b45309")
#let panel-bg = rgb("#f6f5f8")

#let page-setup(body) = {
  set page(width: 320pt, height: auto, margin: (x: 12pt, y: 14pt), fill: bg)
  set text(font: ("BIZ UDPGothic", "Yu Gothic", "Noto Sans CJK JP"), size: 10.5pt, fill: ink, lang: "ja")
  set par(leading: 0.62em, justify: false)
  // ファイル名などは本文と同じ字で、色だけ変える（等幅の和文フォントだと詰まって読みにくい）
  show raw: set text(font: ("BIZ UDPGothic", "Yu Gothic", "Noto Sans CJK JP"), size: 1.08em, fill: accent)
  body
}

#let release-head(version, lead) = {
  text(size: 17pt, weight: "bold")[#version]
  v(2pt)
  text(size: 11pt, fill: sub)[#lead]
  v(10pt)
}

#let _fig-no = counter("kfig")
#let fig(title, point) = {
  _fig-no.step()
  v(8pt)
  block(width: 100%)[
    #text(weight: "bold", size: 11.5pt)[図#context _fig-no.display()　#title]
    #linebreak()
    #text(fill: accent, size: 10pt)[#point]
  ]
  v(4pt)
}

#let fignote(body) = {
  v(4pt)
  text(size: 9pt, fill: sub)[#body]
  v(4pt)
}

#let section(title) = {
  v(12pt)
  block(width: 100%, stroke: (bottom: 0.8pt + line-c), inset: (bottom: 4pt))[
    #text(weight: "bold", size: 11.5pt)[#title]
  ]
  v(4pt)
}

#let panel(dim: false, body) = block(
  width: 100%,
  fill: panel-bg,
  stroke: if dim { 0.6pt + line-c } else { 1.2pt + accent },
  radius: 5pt,
  inset: 7pt,
  text(fill: if dim { sub } else { ink }, body),
)

#let label-small(body) = {
  text(size: 8.5pt, weight: "bold", fill: sub)[#body]
  v(2pt)
}

// フォルダの見出し行（アイコンは描く。絵文字は使わない）
#let folder-icon(c) = box(width: 11pt, height: 8pt, baseline: 0pt, {
  place(dx: 0pt, dy: 0pt, rect(width: 5pt, height: 2pt, fill: c, radius: (top-left: 1pt, top-right: 1pt)))
  place(dx: 0pt, dy: 1.5pt, rect(width: 11pt, height: 6.5pt, fill: c, radius: 1pt))
})
#let file-icon(c) = box(width: 7pt, height: 9pt, baseline: 1pt, rect(width: 7pt, height: 9pt, stroke: 0.8pt + c, radius: 1pt))

#let folder(name) = {
  box(folder-icon(warm))
  h(3pt)
  text(weight: "bold")[#name]
  v(2pt)
}

#let file-row(name, hot: false, note: none) = {
  h(8pt)
  box(file-icon(if hot { accent } else { sub }))
  h(3pt)
  text(size: 9.5pt, fill: if hot { accent } else { ink }, weight: if hot { "bold" } else { "regular" })[#name]
  if note != none {
    linebreak()
    h(20pt)
    text(size: 8pt, fill: if hot { accent } else { sub })[#note]
  }
  v(1pt)
}

#let chip-on(body) = box(fill: okbg, radius: 3pt, inset: (x: 4pt, y: 2.5pt), text(size: 8.5pt, fill: okink, weight: "bold")[#body])
#let chip-off(body) = box(fill: panel-bg, stroke: 0.6pt + line-c, radius: 3pt, inset: (x: 4pt, y: 2.5pt), text(size: 8.5pt, fill: sub)[#body])

#let arrow-r() = text(size: 16pt, fill: accent)[▶]

// レイヤツリーの 1 行（depth で字下げ）。locked は網掛けの帯で「直せない」を示す
#let tree-node(depth, name, open: false, file: false, locked: false, hot: false, note: none) = {
  let row = {
    h(depth * 10pt)
    if depth > 0 { text(fill: sub, size: 9pt)[└ ] }
    box(if open { file-icon(accent) } else if file { file-icon(sub) } else { folder-icon(if locked { sub } else { warm }) })
    h(3pt)
    text(size: 9.5pt, weight: if open { "bold" } else { "regular" })[#name]
    if note != none {
      h(1fr)
      if locked {
        box(fill: panel-bg, stroke: 0.6pt + line-c, radius: 2pt, inset: (x: 3pt, y: 1.5pt), text(size: 7.5pt, fill: warm)[#note])
      } else if hot {
        box(fill: okbg, radius: 2pt, inset: (x: 3pt, y: 1.5pt), text(size: 7.5pt, fill: okink, weight: "bold")[#note])
      } else {
        text(size: 7.5pt, fill: sub)[#note]
      }
    }
  }
  block(width: 100%, above: 3pt, below: 3pt, row)
}

// 2 台の変更がそろう図: 上に 2 台、下に結果
#let merge-diagram(a: (), b: (), result: ()) = {
  let dev(who, what) = block(
    width: 100%, fill: panel-bg, stroke: 0.6pt + line-c, radius: 5pt, inset: 6pt,
  )[#text(size: 8.5pt, weight: "bold", fill: sub)[#who] #linebreak() #text(size: 9.5pt)[#what]]
  grid(
    columns: (1fr, 1fr), column-gutter: 8pt, row-gutter: 3pt,
    dev(..a), dev(..b),
    align(center, text(fill: accent, size: 12pt)[▼]), align(center, text(fill: accent, size: 12pt)[▼]),
    grid.cell(colspan: 2, block(
      width: 100%, fill: okbg, radius: 5pt, inset: 6pt,
    )[#text(size: 8.5pt, weight: "bold", fill: okink)[#result.at(0)] #linebreak() #text(size: 9.5pt, fill: ink)[#result.at(1)]]),
  )
}

#let fixes(..items) = {
  for it in items.pos() {
    block(width: 100%, above: 4pt, below: 4pt, grid(
      columns: (8pt, 1fr), column-gutter: 3pt,
      text(fill: okink, weight: "bold")[・], text(size: 9.5pt)[#it],
    ))
  }
}
