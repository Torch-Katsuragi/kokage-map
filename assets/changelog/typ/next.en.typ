// Changelog (illustrated): next release. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "Next release",
  [The user guide follows the new Home],
  ["Getting started" in the user guide and the tutorial's "Your own data" now describe "Open my map" and receiving maps by QR.],
  box(width: 150pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 8pt, {
    box(width: 100%, fill: rgb("#2e6b4f"), radius: 5pt, inset: (x: 6pt, y: 6pt), text(size: 8pt, fill: white, weight: "bold")[Open my map])
    v(4pt)
    box(width: 100%, stroke: 0.6pt + line-c, radius: 4pt, inset: (x: 6pt, y: 4pt), text(size: 7pt)[Scan a QR])
  }),
)

#fixes(
  "Also",
  [Jumping with the layer panel open lands outside the panel],
  [Removed an unused old map engine (less traffic at startup)],
)
