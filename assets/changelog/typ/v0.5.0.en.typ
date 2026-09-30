// Changelog (illustrated): v0.5.0. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

// Laser rangefinder (side view)
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

// Survey points joined by lines. `gap` marks the misclosure
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

// Overlapping features (polygon, road, point). `sel` is drawn in blue
#let pick-map(w, h, sel) = box(width: w, height: h, clip: true, radius: 3pt, {
  place(rect(width: w, height: h, fill: map-bg))
  place(dx: w * 0.14, dy: h * 0.16, rect(width: w * 0.62, height: h * 0.64, radius: 1pt,
    fill: if sel == 2 { accent-soft } else { map-comp.lighten(20%) },
    stroke: if sel == 2 { 1.4pt + accent } else { 0.6pt + map-comp.darken(35%) }))
  place(curve(stroke: (paint: if sel == 1 { accent } else { map-road }, thickness: if sel == 1 { 2.6pt } else { 2pt }, cap: "round"),
    curve.move((-2pt, h * 0.75)), curve.cubic((w * 0.3, h * 0.3), (w * 0.6, h * 0.7), (w + 2pt, h * 0.2))))
  place(dx: w * 0.5 - 3.5pt, dy: h * 0.5 - 3.5pt, circle(radius: 3.5pt,
    fill: if sel == 0 { accent } else { map-red }, stroke: 1.2pt + white))
  // where the finger taps
  place(dx: w * 0.5 - 7pt, dy: h * 0.5 - 7pt, circle(radius: 7pt, stroke: (paint: ink.transparentize(40%), thickness: 0.8pt, dash: "dotted")))
})

// ---- head ----
#hero(
  "v0.5.0 — 2026/03/31",
  [Field surveying with a laser rangefinder],
  [Connects to the TruPulse 360R over Bluetooth. Each distance, azimuth and inclination you measure is recorded as a point right away.],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    rangefinder(label: "TruPulse 360R"),
    stack(dir: ttb, spacing: 3pt, caption(fill: accent)[Bluetooth], arrow-r(w: 26pt)),
    phone(w: 66pt, h: 118pt, label: "A point per shot", box(width: 60pt, height: 104pt, {
      place(rect(width: 60pt, height: 104pt, fill: map-bg))
      place(dy: 10pt, traverse(60pt, 60pt, ((0.2, 0.85), (0.3, 0.3), (0.72, 0.18), (0.82, 0.6)), close: false))
      place(dx: 4pt, dy: 76pt, block(width: 52pt, fill: white, radius: 3pt, inset: 3pt, {
        set text(size: 5.5pt, fill: sub)
        [Dist] ; h(1fr) ; [Az] ; h(1fr) ; [Incl]
      }))
    })),
  ),
)

// ---- closure ----
#scene(
  [Check closure on the spot],
  [The closure ratio is shown in real time, with an instant warning when accuracy falls short. Closure adjustment uses the Compass rule or the Transit rule.],
  grid(
    columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
    stack(dir: ttb, spacing: 5pt,
      traverse(84pt, 70pt, ((0.12, 0.8), (0.2, 0.2), (0.75, 0.1), (0.9, 0.6), (0.32, 0.9)), close: false, gap: true),
      caption[Does not quite close],
      warn-badge[Warns on a poor ratio],
    ),
    stack(dir: ttb, spacing: 3pt, caption(fill: accent)[Adjust], arrow-r(w: 22pt)),
    stack(dir: ttb, spacing: 5pt,
      traverse(84pt, 70pt, ((0.12, 0.8), (0.2, 0.2), (0.75, 0.1), (0.9, 0.6), (0.3, 0.88))),
      caption(fill: accent)[Error spread out, closed],
      badge[Accuracy ensured],
    ),
  ),
  note: [Magnetic declination, instrument height and target height corrections are supported too.],
)

// ---- points to lines ----
#scene(
  [Survey points become lines and polygons],
  [Survey points are converted to Line or Polygon automatically.],
  grid(
    columns: (auto, auto, auto, auto), column-gutter: 6pt, align: horizon,
    stack(dir: ttb, spacing: 4pt,
      traverse(60pt, 52pt, ((0.12, 0.8), (0.25, 0.2), (0.78, 0.12), (0.88, 0.7)), close: false, c: sub, dots: true),
      caption[Survey points]),
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

// ---- select tool ----
#scene(
  [Pick overlaps one by one],
  [The select tool now works across all layers. Tap the same spot again to cycle to the next candidate by priority.],
  grid(
    columns: (auto, auto, auto, auto, auto), column-gutter: 4pt, align: horizon,
    stack(dir: ttb, spacing: 4pt, pick-map(62pt, 56pt, 0), caption[1st tap: point]),
    arrow-r(w: 12pt),
    stack(dir: ttb, spacing: 4pt, pick-map(62pt, 56pt, 1), caption[2nd tap: line]),
    arrow-r(w: 12pt),
    stack(dir: ttb, spacing: 4pt, pick-map(62pt, 56pt, 2), caption[3rd tap: polygon]),
  ),
)

#fixes(
  "Small but important fixes",
  [Notification center in the app bar],
  [Custom path for the global folder],
  [GeoJSON import splits by geometry type],
  [Windows GPS, marker, first jump restored],
)

#fixes(
  "Overall stability",
  [State management rebuilt on Riverpod],
  [Async race conditions prevented],
  [Declarative settings framework],
  [Multi-geometry support],
)
