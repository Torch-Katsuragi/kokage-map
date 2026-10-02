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
  if located {
    place(rect(width: 40pt, height: 40pt, stroke: 2pt + okink))
    place(dx: 3pt, dy: 30pt, circle(radius: 4pt, fill: okink))
  } else {
    place(dy: 31pt, box(width: 40pt, height: 9pt, fill: rgb(0, 0, 0, 120), align(center + horizon, text(size: 5.5pt, fill: white)[No location])))
  }
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
  [Six chapters to choose from],
  [Map, data, recording, photos, GPS and your own data. Start from any chapter; finished ones get a mark.],
  box(width: 160pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: (y: 6pt), align(left, {
    block(inset: (x: 6pt), below: 4pt, text(size: 9pt, weight: "bold")[Tutorial])
    chapter-row(1, [Reading the map], done: true)
    chapter-row(2, [How data is organized], done: true)
    chapter-row(3, [Recording (points, names, lines)])
    chapter-row(4, [Importing photos])
    chapter-row(5, [Recording with GPS])
    chapter-row(6, [Your own data])
  })),
  note: [Offered once on first use. Later, start it from "Tutorial" on Home or from Settings. The practice map is recreated each time.],
)

#scene(
  [See which photos have a location],
  [Photos are now chosen inside the app. Those with a location have a green frame and a pin, so you no longer find out after importing.],
  stack(dir: ttb, spacing: 6pt,
    grid(columns: 4, column-gutter: 3pt,
      photo(rgb("#7a9a6b"), true), photo(rgb("#a08a70"), false), photo(rgb("#6b8aa0"), true), photo(rgb("#b0a090"), false)),
    badge["With location" filters them],
  ),
)

#fixes(
  "Also changed",
  [Edit shape and attributes right in the info panel (vertices, move, rotate, scale, extend, simplify, trim)],
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
)
