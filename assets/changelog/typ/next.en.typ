// Changelog (illustrated): Next release. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

// A screen (56 × 98pt) with the guide's frame and card on top
#let screen(body, card: none, ring: none, dot: none) = box(width: 56pt, height: 98pt, {
  place(body)
  if dot != none { let (x, y) = dot; place(dx: x - 3pt, dy: y - 3pt, circle(radius: 3pt, fill: map-red, stroke: 1pt + white)) }
  if ring != none { let (x, y, w, h) = ring; place(dx: x, dy: y, spot(w, h)) }
  if card != none { place(dx: 3pt, dy: 74pt, card) }
})
// Top bar. The right end is the layer list button (stacked sheets)
#let bar = box(width: 56pt, height: 9pt, fill: white, {
  place(dx: 45.5pt, dy: 3.4pt, polygon(fill: sub.lighten(30%), (0pt, 2pt), (3.5pt, 0pt), (7pt, 2pt), (3.5pt, 4pt)))
  place(dx: 45.5pt, dy: 1.4pt, polygon(fill: sub, (0pt, 2pt), (3.5pt, 0pt), (7pt, 2pt), (3.5pt, 4pt)))
})
#let map-with-bar(comps: true) = stack(bar, mini-map(56pt, 89pt, comps: comps))

#let chapter-row(n, name, done: false) = block(width: 100%, inset: (x: 6pt, y: 3.2pt), above: 0pt, below: 0pt, {
  let c = if done { okink } else { line-c }
  let f = if done { okink } else { white }
  box(width: 8pt, height: 8pt, baseline: 10%, circle(radius: 3.6pt, fill: f, stroke: 0.8pt + c))
  h(4pt)
  text(size: 7.5pt)[#n. #name]
})

#let photo(c, located) = box(width: 40pt, height: 40pt, {
  place(rect(width: 40pt, height: 40pt, fill: c))
  if not located {
    place(rect(width: 40pt, height: 40pt, fill: rgb(255, 255, 255, 140)))
    place(dx: 13pt, dy: 13pt, {
      place(circle(radius: 7pt, fill: rgb(0, 0, 0, 90)))
      place(dx: 4.5pt, dy: 3pt, circle(radius: 2.5pt, stroke: 1pt + white))
      place(line(start: (3pt, 11pt), end: (11pt, 3pt), stroke: 1.2pt + white))
    })
  }
})

// 編集中の画面: 左に編集の道具、赤い形と頂点、下にパネル
#let edit-screen = box(width: 56pt, height: 98pt, clip: true, {
  place(mini-map(56pt, 98pt, comps: false))
  place(dx: 0pt, dy: 0pt, rect(width: 9pt, height: 70pt, fill: white))
  for i in range(5) { place(dx: 2pt, dy: 4pt + i * 9pt, rect(width: 5pt, height: 5pt, radius: 1pt, fill: if i == 0 { accent } else { sub.lighten(40%) })) }
  let pts = ((18pt, 14pt), (44pt, 10pt), (50pt, 38pt), (30pt, 50pt), (16pt, 36pt))
  place(polygon(fill: rgb(211, 47, 47, 50), stroke: 1.2pt + map-red, ..pts))
  for p in pts { let (x, y) = p; place(dx: x - 2pt, dy: y - 2pt, circle(radius: 2pt, fill: white, stroke: 1pt + map-red)) }
  place(dy: 70pt, rect(width: 56pt, height: 28pt, fill: white, stroke: (top: 0.6pt + line-c)))
  place(dx: 30pt, dy: 86pt, box(width: 22pt, height: 8pt, radius: 4pt, fill: accent, align(center + horizon, text(size: 4.5pt, fill: white)[Save])))
})

#hero(
  "Next release",
  [Try the basics on a practice map],
  [No data of your own needed. A practice map opens and a frame shows where to tap. Tap it to move on.],
  grid(
    columns: (auto, auto, auto, auto, auto), column-gutter: 4pt, align: horizon,
    phone(label: "Move the map", screen(map-with-bar(), card: coach-card(50pt, none, [Move the map]))),
    arrow-r(w: 10pt),
    phone(label: "Open layers", screen(map-with-bar(), ring: (42pt, 0pt, 13pt, 9pt), card: coach-card(50pt, none, [Open layers]))),
    arrow-r(w: 10pt),
    phone(label: "Place a point", screen(map-with-bar(), dot: (28pt, 42pt), card: coach-card(50pt, none, [Place a point]))),
  ),
)

#scene(
  [Eight chapters to choose from],
  [Map, data, look, recording, fixing, photos, GPS and your own data. Start from any chapter; finished ones get a mark. Each chapter starts from the same screen layout.],
  box(width: 160pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: (y: 6pt), align(left, {
    block(inset: (x: 6pt), below: 4pt, text(size: 9pt, weight: "bold")[Tutorial])
    chapter-row(1, [Reading the map], done: true)
    chapter-row(2, [How data is organized], done: true)
    chapter-row(3, [Changing the look])
    chapter-row(4, [Recording (points, names, lines, areas)])
    chapter-row(5, [Fixing and deleting])
    chapter-row(6, [Importing photos])
    chapter-row(7, [Recording with GPS])
    chapter-row(8, [Your own data])
  })),
  note: [Offered once on first use. Later, start it from "Tutorial" on Home or from Settings. The practice map is recreated each time.],
)

#scene(
  [See which photos have a location],
  [Photos are now chosen inside the app. Thumbnails are grouped by date; tap one to import it, long-press to pick several. Photos without a location are dimmed and marked, so you no longer find out after importing.],
  stack(dir: ttb, spacing: 6pt,
    grid(columns: 4, column-gutter: 3pt,
      photo(rgb("#7a9a6b"), true), photo(rgb("#a08a70"), false), photo(rgb("#6b8aa0"), true), photo(rgb("#b0a090"), false)),
    badge["With location" filters them],
  ),
)

#scene(
  [Edit shapes right in the info panel],
  [Tap "Edit" and the map locks to top-down while the left toolbar switches to edit tools: vertices, move, rotate, scale, extend, simplify, trim. Undo and redo too. Switching to attributes raises the panel to the top.],
  phone(label: "Editing", edit-screen),
  note: [Map buttons hide while editing. The ← and the device back button stop editing. The old edit screen is gone.],
)

#fixes(
  "Also changed",
  [The info panel shows the selected feature's shape faintly],
  [On a phone in portrait, the layer list starts closed when the map opens],
)

#fixes(
  "Fixes",
  [Layers whose names contain spaces or quotes could not be written to],
  [In the attribute table, cells other than the first in a row sometimes could not be edited],
  [Opening the attribute table after selecting on the map did not highlight that row],
  [Lines and areas got thin and faint when zoomed out],
  [The color of a selected area had gaps on ridges],
  [A selected line was drawn under its unselected self],
  [Point labels put a black dot over the point],
  [The color chooser in the style screen did not open],
  [The area shown while drawing an area was far off],
  [The panel overflowed when the keyboard was up while entering attributes],
)
