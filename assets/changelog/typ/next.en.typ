// Changelog (illustrated): next release. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "Next release",
  [The tutorial on the web],
  [Start it from "Tutorial" on Home. The practice map is made inside the browser, so no folder needs to be chosen. The photo chapter is not shown on the web.],
  grid(
    columns: (auto, auto, auto), column-gutter: 10pt, align: horizon,
    box(width: 120pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 8pt, align(center, {
      text(size: 8pt, fill: sub)[Start a project]
      v(4pt)
      box(fill: accent, radius: 8pt, inset: (x: 8pt, y: 3pt), text(size: 7pt, fill: white)[Choose folder])
      v(3pt)
      box(stroke: 1.4pt + rgb("#c0504d"), radius: 3pt, inset: (x: 4pt, y: 2pt), text(size: 7pt, fill: accent)[Tutorial])
    })),
    arrow-r(w: 20pt),
    phone(label: "Practice map", box(width: 56pt, height: 98pt, mini-map(56pt, 98pt))),
  ),
)

#fixes(
  "Tutorial",
  [Each chapter starts in 2D, north up],
)
