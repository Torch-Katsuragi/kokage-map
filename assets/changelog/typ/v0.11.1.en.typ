// Changelog (illustrated): v0.11.1. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "v0.11.1 — 2026/10/05",
  [First-time Google accounts can sign in],
  [A Google account used for the first time sees a Drive permission screen after choosing it. The app used to say "Sign-in failed" in the middle of it; it now waits until permission is given.],
  grid(
    columns: (auto, auto, auto, auto, auto), column-gutter: 6pt, align: horizon,
    box(width: 70pt, fill: white, stroke: 0.6pt + line-c, radius: 5pt, inset: 6pt, align(center, text(size: 7pt)[Choose an account])),
    arrow-r(w: 14pt),
    box(width: 80pt, fill: rgb("#fff4d6"), stroke: 0.6pt + line-c, radius: 5pt, inset: 6pt, align(center, text(size: 7pt)[Drive permission (first time only)])),
    arrow-r(w: 14pt),
    box(width: 60pt, fill: rgb("#2e6b4f"), radius: 5pt, inset: 6pt, align(center, text(size: 7pt, fill: white, weight: "bold")[Open the map])),
  ),
)

#fixes(
  "Also",
  [The user guide and the tutorial follow the new Home],
  [Jumping with the layer panel open lands outside the panel],
  [Removed an unused old map engine (less traffic at startup)],
)
