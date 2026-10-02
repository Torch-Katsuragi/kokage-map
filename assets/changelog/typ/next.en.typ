// Changelog (illustrated): next release. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "Next release",
  [Style changes now stick],
  [Color and opacity changed for the default View in the style screen reverted when the project was reopened. They are now kept as the layer style.],
  grid(
    columns: (auto, auto, auto), column-gutter: 10pt, align: horizon,
    stack(dir: ttb, spacing: 4pt, box(width: 40pt, height: 36pt, polygon(fill: rgb(46, 125, 50, 150), stroke: 0.8pt + ink, (10pt, 0pt), (30pt, 0pt), (40pt, 18pt), (30pt, 36pt), (10pt, 36pt), (0pt, 18pt))), caption[Changed]),
    arrow-r(w: 24pt),
    stack(dir: ttb, spacing: 4pt, box(width: 40pt, height: 36pt, polygon(fill: rgb(46, 125, 50, 150), stroke: 0.8pt + ink, (10pt, 0pt), (30pt, 0pt), (40pt, 18pt), (30pt, 36pt), (10pt, 36pt), (0pt, 18pt))), caption[Same after reopening]),
  ),
)

#fixes(
  "Other fixes",
  [Areas in the practice map had a 10% black fill, so changing the color showed nothing],
)
