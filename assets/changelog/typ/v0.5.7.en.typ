// Changelog (illustrated): v0.5.7. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

// A scanned paper map (two contours, a red boundary, a gray patch). paper: keep the paper background
#let scan-marks(w, h, paper: true, line-ink: ink, red: map-red, shade: rgb("#9e9e9e")) = box(width: w, height: h, {
  if paper { place(rect(width: w, height: h, fill: rgb("#f7f3e8"))) }
  if shade != none {
    place(dx: w * 0.55, dy: h * 0.12, rect(width: w * 0.35, height: h * 0.3, radius: 2pt, fill: shade))
  }
  let s = (paint: line-ink, thickness: 0.9pt, cap: "round")
  place(curve(stroke: s, curve.move((0pt, h * 0.35)), curve.cubic((w * 0.3, h * 0.15), (w * 0.6, h * 0.7), (w, h * 0.5))))
  place(curve(stroke: s, curve.move((0pt, h * 0.6)), curve.cubic((w * 0.3, h * 0.4), (w * 0.6, h * 0.95), (w, h * 0.75))))
  place(curve(stroke: (paint: red, thickness: 1.2pt, dash: "dashed"),
    curve.move((w * 0.15, h)), curve.line((w * 0.3, h * 0.1)), curve.line((w * 0.8, 0pt))))
})

#let overlaid(w, h, ..args) = box(width: w, height: h, clip: true, {
  place(mini-map(w, h))
  place(scan-marks(w, h, ..args))
})

#let map-with-sheet(w, h) = box(width: w, height: h, clip: true, {
  place(mini-map(w, h))
  place(dx: w * 0.18, dy: h * 0.22, rotate(-12deg, reflow: false,
    box(width: w * 0.64, height: h * 0.5, stroke: 0.8pt + accent,
      scan-marks(w * 0.64, h * 0.5, paper: false))))
})

#hero(
  "v0.5.7 — 2026/04/13",
  [Overlay images saved as GeoTIFF],
  [Overlay images are now saved as GeoTIFF. Position, scale and rotation live in the file itself, so they line up in the same place in QGIS and other GIS software.],
  grid(
    columns: (auto, 1fr, auto), align: (center + horizon, center + horizon, center + horizon),
    phone(label: "Overlay in the app", map-with-sheet(56pt, 98pt)),
    stack(dir: ttb, spacing: 3pt, file-icon(accent, w: 14pt), text(size: 7pt, weight: "bold", fill: accent)[GeoTIFF], arrow-r(w: 26pt)),
    pc(label: "Same place in QGIS", w: 110pt, h: 78pt, map-with-sheet(104pt, 63pt)),
  ),
)

#let result(label, body) = stack(dir: ttb, spacing: 4pt,
  box(stroke: 0.6pt + line-c, body),
  box(width: 74pt, align(center, caption(label))),
)

#scene(
  [See through scanned paper maps],
  [Make the paper background of a scanned map transparent to overlay it with GIS data. Three ways to convert, and you can name the output file.],
  stack(dir: ttb, spacing: 6pt,
    stack(dir: ttb, spacing: 4pt,
      box(stroke: 0.6pt + line-c, overlaid(96pt, 60pt)),
      caption[As scanned (hides the map below)],
    ),
    arrow-d(),
    grid(
      columns: (auto, auto, auto), column-gutter: 5pt,
      result([Brightness \ → alpha], overlaid(74pt, 48pt, paper: false,
        line-ink: ink.transparentize(25%), red: map-red.transparentize(35%), shade: rgb("#9e9e9e").transparentize(70%))),
      result([Threshold split \ (colors kept)], overlaid(74pt, 48pt, paper: false)),
      result([B&W, then \ white clear], overlaid(74pt, 48pt, paper: false, red: ink, shade: none)),
    ),
  ),
  note: [The opacity setting is gone. Transparency is kept in the image's alpha channel.],
)

#fixes(
  "Also in this release",
  [Overlay images have their own detail panel],
  [Overlay transforms are much faster],
  [Fixed overlay images not showing offline],
)
