// Changelog (illustrated): v0.5.5. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

// App icon and name on the home screen. state: "old" (earlier name) / "this" (this release) / "later" (later name)
#let app-tile(name, state: "this", sub-label: none) = stack(dir: ttb, spacing: 4pt,
  box(width: 34pt, height: 34pt, radius: 8pt, clip: true,
    stroke: if state == "this" { 1.2pt + accent } else if state == "later" { (paint: line-c, thickness: 0.8pt, dash: "dashed") } else { 0.6pt + line-c },
    if state == "old" { mini-map(34pt, 34pt, road: sub.lighten(30%), comp: rgb("#d9d6dc")) } else { mini-map(34pt, 34pt, road: map-road) }),
  box(width: 62pt, align(center, text(size: 8pt, weight: if state == "this" { "bold" } else { "regular" }, fill: if state == "this" { ink } else { sub })[#name])),
  if sub-label != none { box(width: 62pt, align(center, caption(sub-label))) },
)

#hero(
  "v0.5.5 — 2026/04/11",
  [First rename: k\_maps → RootMap GIS],
  [The app was renamed from "k\_maps" to "RootMap GIS". Its current name, Kokage Map, dates from v0.6.1.],
  stack(dir: ttb, spacing: 14pt,
    grid(
      columns: (auto, auto, auto, auto, auto), column-gutter: 5pt, align: horizon,
      app-tile([k\_maps], state: "old", sub-label: [up to v0.5.4]),
      arrow-r(w: 16pt),
      app-tile([RootMap GIS], sub-label: [from this release]),
      arrow-r(w: 16pt, c: line-c),
      app-tile([Kokage Map], state: "later", sub-label: [v0.6.1 on]),
    ),
    box(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: (x: 9pt, y: 7pt), align(left, {
      caption[Google Drive sync folder, too (still named this)]
      v(3pt)
      folder-icon(warm); h(4pt); text(size: 8.5pt, weight: "bold")[RootMap GIS Projects]
    })),
  ),
)

#fixes(
  "Also in this release",
  [Feedback form pre-fills version and model],
)
