// Changelog (illustrated): next release. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "Next release",
  [Areas stay visible between zoom levels],
  [In data with many areas (such as forest compartments), areas without a fill disappeared between zoom 14 and 15. Fixed.],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    box(width: 60pt, fill: white, stroke: 0.6pt + line-c, radius: 5pt, inset: 6pt, align(center, text(size: 7pt)[Zoom 14])),
    box(width: 60pt, fill: rgb("#fff4d6"), stroke: 0.6pt + line-c, radius: 5pt, inset: 6pt, align(center, text(size: 7pt)[Shown at 14.6 too])),
    box(width: 60pt, fill: white, stroke: 0.6pt + line-c, radius: 5pt, inset: 6pt, align(center, text(size: 7pt)[Zoom 15])),
  ),
)
