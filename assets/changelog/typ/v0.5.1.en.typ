// Changelog (illustrated): v0.5.1. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

// An image overlaid on the map. `handles` shows the transform handles
#let overlay-img(w, h, handles: true) = box(width: w, height: h, {
  place(rect(width: w, height: h, fill: rgb("#fffaf0").transparentize(10%), stroke: 0.8pt + if handles { accent } else { sub }))
  for (i, y) in (0.3, 0.55, 0.8).enumerate() {
    place(curve(stroke: 0.6pt + warm.lighten(30%),
      curve.move((w * 0.08, h * y)), curve.cubic((w * 0.35, h * (y - 0.2)), (w * 0.6, h * (y + 0.15)), (w * 0.92, h * (y - 0.1)))))
  }
  if handles {
    let s = 4pt
    for (x, y) in ((0, 0), (1, 0), (0, 1), (1, 1), (0.5, 0), (0.5, 1), (0, 0.5), (1, 0.5)) {
      place(dx: w * x - s / 2, dy: h * y - s / 2, rect(width: s, height: s, fill: white, stroke: 0.8pt + accent))
    }
    place(dx: w / 2, dy: -9pt, line(angle: 90deg, length: 7pt, stroke: 0.8pt + accent))
    place(dx: w / 2 - 2.5pt, dy: -12pt, circle(radius: 2.5pt, fill: white, stroke: 0.8pt + accent))
  }
})

#hero(
  "v0.5.1 — 2026/04/02",
  [Freely transform \ images on the map],
  [Images on the map now have Photoshop-style transform handles. Drag them to move, scale and rotate; the map shows the result instantly.],
  grid(
    columns: (auto, auto, auto), column-gutter: 10pt, align: horizon,
    phone(w: 66pt, h: 118pt, label: "Just overlaid", box(width: 60pt, height: 104pt, {
      place(mini-map(60pt, 104pt))
      place(dx: 16pt, dy: 30pt, overlay-img(26pt, 20pt, handles: false))
    })),
    stack(dir: ttb, spacing: 5pt, bubble[Drag the handles], arrow-r(w: 26pt)),
    phone(w: 66pt, h: 118pt, label: "Move, scale, rotate", box(width: 60pt, height: 104pt, {
      place(mini-map(60pt, 104pt))
      place(dx: 9pt, dy: 30pt, rotate(-14deg, reflow: false, overlay-img(40pt, 32pt)))
    })),
  ),
)

#fixes(
  "Search & editing",
  [Filter by expressions like #box[`"area" > 100`]],
  [Duplicate a feature to make a new one],
  [Sub-tables show a timestamp column],
  [No flicker when toggling highlights],
  [Handles easier to grab on small images],
)

#fixes(
  "Notices",
  [Published to Google Play internal testing],
  [Windows version paused, awaiting maplibre],
)
