// Changelog (illustrated): v0.5.6. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#let panel-btn(w, body, c: accent, on: false) = box(width: w, inset: (y: 2.5pt), radius: 3pt,
  fill: if on { c } else { white }, stroke: 0.7pt + c, {
    set par(leading: 0.35em)
    align(center, text(size: 5pt, weight: "bold", fill: if on { white } else { c })[#body])
  })

// Long-press delete button. p is how far the gauge has filled (0 to 1)
#let delete-btn(w, p, label, h: 13pt, size: 6.5pt) = box(width: w, height: h, radius: 3pt, clip: true,
  stroke: 0.8pt + map-red, fill: white, {
    place(rect(width: w * p, height: h, fill: map-red.lighten(55%)))
    place(box(width: w, height: h, align(center + horizon, text(size: size, weight: "bold", fill: map-red)[#label])))
  })

#let detail-screen(title, button) = box(width: 56pt, height: 98pt, {
  place(mini-map(56pt, 50pt))
  place(dx: 25pt, dy: 20pt, circle(radius: 3pt, fill: map-red, stroke: 1pt + white))
  place(dy: 46pt, rect(width: 56pt, height: 52pt, fill: white, radius: (top-left: 4pt, top-right: 4pt)))
  place(dx: 4pt, dy: 50pt, text(size: 6pt, weight: "bold")[#title])
  place(dx: 4pt, dy: 61pt, rect(width: 34pt, height: 2pt, fill: line-c))
  place(dx: 4pt, dy: 66pt, rect(width: 26pt, height: 2pt, fill: line-c))
  place(dx: 4pt, dy: 73pt, button)
})

#let gmaps-screen = box(width: 56pt, height: 98pt, clip: true, {
  place(rect(width: 56pt, height: 98pt, fill: rgb("#f1f3f4")))
  place(curve(stroke: 3pt + white, curve.move((0pt, 70pt)), curve.line((56pt, 40pt))))
  place(curve(stroke: 3pt + white, curve.move((20pt, 0pt)), curve.line((34pt, 98pt))))
  place(curve(stroke: 2pt + rgb("#fdd663"), curve.move((0pt, 30pt)), curve.cubic((20pt, 34pt), (40pt, 20pt), (56pt, 26pt))))
  place(dx: 4pt, dy: 4pt, box(width: 48pt, height: 10pt, radius: 5pt, fill: white, stroke: 0.4pt + line-c,
    align(horizon, pad(left: 4pt, text(size: 5pt, fill: sub)[Google Maps]))))
  place(dx: 23pt, dy: 42pt, box(width: 10pt, height: 14pt, {
    place(circle(radius: 5pt, fill: rgb("#ea4335")))
    place(dy: 6pt, polygon(fill: rgb("#ea4335"), (1pt, 0pt), (9pt, 0pt), (5pt, 8pt)))
    place(dx: 3pt, dy: 3pt, circle(radius: 2pt, fill: rgb("#a50e0e")))
  }))
})

#hero(
  "v0.5.6 — 2026/04/12",
  [Open points in Google Maps],
  [The point detail panel has an "Open in Google Maps" button. On Android it launches the Google Maps app directly; on PC or without the app, it opens in the browser.],
  grid(
    columns: (auto, auto, auto), column-gutter: 14pt, align: horizon,
    phone(label: "Tap in the detail panel", detail-screen([Point 12], panel-btn(48pt, [Open in \ Google Maps], on: true))),
    arrow-r(w: 26pt),
    phone(label: "Google Maps opens", gmaps-screen),
  ),
)

#scene(
  [Hold 1 second to delete],
  [Every feature and photo detail panel has a "Delete" button. To prevent accidents, you hold it for 1 second; a red gauge fills while you hold.],
  grid(
    columns: (auto, auto), column-gutter: 18pt, align: horizon,
    stack(dir: ttb, spacing: 4pt,
      bubble[Long press],
      phone(detail-screen([Point 12], delete-btn(48pt, 0.5, [Delete], h: 11pt, size: 5.5pt))),
    ),
    grid(
      columns: (auto, auto), column-gutter: 6pt, row-gutter: 9pt, align: (right + horizon, left + horizon),
      caption[Press], delete-btn(80pt, 0, [Delete]),
      caption[0.5 s], delete-btn(80pt, 0.5, [Delete]),
      caption(fill: map-red)[1 s], stack(dir: ltr, spacing: 4pt, delete-btn(80pt, 1, [Delete]), caption(fill: map-red)[Gone]),
    ),
  ),
)

#fixes(
  "Also in this release",
  [Clusters now scale with the point size],
  [Gallery photos lost location and time],
  [Photo markers and counts were missing],
  [Map text could disappear offline],
  [NaN GPS in a photo caused a crash],
  [Upgraded MapLibre to v0.3.5],
)
