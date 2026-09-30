// Changelog (illustrated): v0.3.2. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

// A tiny photo (sky and hills)
#let photo(w, h) = box(width: w, height: h, clip: true, radius: 1pt, {
  place(rect(width: w, height: h, fill: rgb("#cfe3f5")))
  place(polygon(fill: rgb("#6b9a5b"), (0pt, h), (w * 0.35, h * 0.35), (w * 0.6, h * 0.7), (w * 0.8, h * 0.5), (w, h * 0.75), (w, h)))
})

// ---- head ----
#hero(
  "v0.3.2 — 2026/03/10",
  [Pick photos from \ your gallery],
  [Camera capture is replaced with gallery import, so photos you already have are easier to use.],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    phone(w: 66pt, h: 118pt, label: "Gallery", box(width: 60pt, height: 104pt, {
      place(rect(width: 60pt, height: 104pt, fill: white))
      for i in range(12) {
        let (x, y) = (calc.rem(i, 3), calc.quo(i, 3))
        place(dx: 2pt + x * 19pt, dy: 2pt + y * 19pt, photo(18pt, 18pt))
      }
      place(dx: 21pt, dy: 21pt, rect(width: 18pt, height: 18pt, stroke: 1.6pt + accent))
      place(dx: 31pt, dy: 23pt, check-box())
    })),
    arrow-r(w: 26pt),
    phone(w: 66pt, h: 118pt, label: "On the map", box(width: 60pt, height: 104pt, {
      place(mini-map(60pt, 104pt))
      place(dx: 20pt, dy: 34pt, box(fill: white, radius: 2pt, inset: 1.5pt, photo(18pt, 14pt)))
      place(dx: 27pt, dy: 51pt, polygon(fill: white, (0pt, 0pt), (6pt, 0pt), (3pt, 4pt)))
    })),
  ),
)

#fixes(
  "Layer panel",
  [A single add button],
  [New folder action menu],
)
