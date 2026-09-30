// Changelog (illustrated): v0.5.5. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

// App icon and name on the home screen
#let app-tile(name, on: true) = stack(dir: ttb, spacing: 4pt,
  box(width: 34pt, height: 34pt, radius: 8pt, clip: true, stroke: 0.6pt + line-c,
    if on { mini-map(34pt, 34pt, road: map-road) } else { mini-map(34pt, 34pt, road: sub.lighten(30%), comp: rgb("#d9d6dc")) }),
  box(width: 80pt, align(center, text(size: 8pt, weight: if on { "bold" } else { "regular" }, fill: if on { ink } else { sub })[#name])),
)

#hero(
  "v0.5.5 — 2026/04/11",
  [Rebranded to \ "RootMap GIS"],
  [The app is renamed from "k\_maps". The same name now shows on Android, Windows and Web.],
  stack(dir: ttb, spacing: 14pt,
    grid(
      columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
      app-tile([k\_maps], on: false),
      arrow-r(w: 22pt),
      app-tile([RootMap GIS]),
    ),
    box(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: (x: 9pt, y: 7pt), align(left, {
      caption[Google Drive sync folder, too]
      v(3pt)
      folder-icon(warm); h(4pt); text(size: 8.5pt, weight: "bold")[RootMap GIS Projects]
    })),
  ),
)

#fixes(
  "Also in this release",
  [Feedback form pre-fills version and model],
)
