// Changelog (illustrated): next release. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "Next release",
  [Choose folders inside the app],
  ["Choose a folder to open" on Home browses the folders inside your everyday map, styled like the layer panel, instead of the device's file picker. Places outside it are in the top-right menu.],
  box(width: 150pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 0pt, clip: true, {
    box(width: 100%, fill: rgb("#424242"), inset: (x: 6pt, y: 5pt), align(left, text(size: 8pt, fill: white, weight: "bold")[KokageMap]))
    box(width: 100%, inset: (x: 6pt, y: 4pt), align(left, grid(columns: (10pt, 1fr), column-gutter: 4pt, align: horizon, box(width: 8pt, height: 6pt, fill: rgb("#ffc107"), radius: 1pt), text(size: 7pt)[共有])))
    box(width: 100%, inset: (x: 6pt, y: 4pt), align(left, grid(columns: (10pt, 1fr), column-gutter: 4pt, align: horizon, box(width: 8pt, height: 6pt, fill: rgb("#7eb0d5"), radius: 1pt), text(size: 7pt)[龍神村])))
    box(width: 100%, inset: (x: 6pt, y: 4pt), align(left, grid(columns: (10pt, 1fr), column-gutter: 4pt, align: horizon, box(width: 8pt, height: 6pt, fill: rgb("#b0bec5"), radius: 1pt), text(size: 7pt, fill: gray)[マイ地図.gpkg])))
    box(width: 100%, inset: 6pt, box(width: 100%, fill: rgb("#2e6b4f"), radius: 8pt, inset: 4pt, align(center, text(size: 7pt, fill: white)[Open "共有"])))
  }),
)

#fixes(
  "Lighter",
  [Less battery drain while the map sits open],
  [Memory no longer grows while panning],
  [Faster loading of data with many areas],
)

#fixes(
  "Changed",
  [Layer panel: tighter rows, only the eye at the right; long-press for the menu, swipe left to move],
  [Layer rows show a color sample and the feature count],
  [A path above the list takes you back to any level],
)

#fixes(
  "Safer",
  [Asks before importing a received map, showing its folder and owner],
  [Location sharing: leaves ended or expired rooms on its own],
  [Location sharing: removed members cannot rejoin with the same code],
  [A received map cannot write outside the app's folders],
)

#fixes(
  "Fixed",
  [Areas without a fill disappeared between zoom 14 and 15 in data with many areas],
)
