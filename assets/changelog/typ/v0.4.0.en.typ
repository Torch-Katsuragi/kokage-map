// Changelog (illustrated): v0.4.0. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

// Attribute table. rows are (value, kept)
#let attr-table(w: 150pt, field, expr, rows) = box(width: w, fill: white, stroke: 0.6pt + line-c, radius: 4pt, clip: true, {
  block(width: 100%, fill: rgb("#f1eff4"), inset: 4pt, below: 0pt,
    box(width: 100%, fill: white, stroke: 0.8pt + accent, radius: 3pt, inset: (x: 4pt, y: 3pt), align(left, text(size: 7.5pt)[#expr])))
  block(width: 100%, inset: (x: 6pt, y: 3pt), above: 0pt, below: 0pt, stroke: (bottom: 0.6pt + line-c),
    text(size: 7pt, weight: "bold", fill: sub)[ID #h(1fr) #field])
  for (i, (v, keep)) in rows.enumerate() {
    block(width: 100%, inset: (x: 6pt, y: 3pt), above: 0pt, below: 0pt,
      fill: if keep { white } else { rgb("#f6f5f8") },
      text(size: 7.5pt, fill: if keep { ink } else { sub.lighten(40%) })[#(i + 1) #h(1fr) #v])
  }
})

// Sync button (cloud in a circle)
#let sync-icon(r: 6pt) = box(width: r * 2, height: r * 2, baseline: 25%, {
  place(circle(radius: r, fill: accent))
  place(dx: r * 0.3, dy: r * 0.62, cloud(w: r * 1.4))
})

// ---- head ----
#hero(
  "v0.4.0 — 2026/03/18",
  [Share & back up data via Google Drive],
  [Sign in with Google to clone a folder to Drive and sync it by hand (Push/Pull).],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    phone(w: 62pt, h: 112pt, label: "Folder by folder", mini-map(56pt, 98pt)),
    stack(dir: ttb, spacing: 4pt,
      caption(fill: accent)[Push],
      arrow-lr(w: 40pt),
      caption(fill: accent)[Pull],
    ),
    stack(dir: ttb, spacing: 4pt, cloud(w: 78pt, label: "Drive"), caption[Share & backup]),
  ),
)

// ---- title bar ----
#scene(
  [One-tap sync in the title bar],
  [Drive sync now lives in the title bar. An icon shows the sync status, and the app checks it automatically too.],
  grid(
    columns: (auto, auto), column-gutter: 12pt, align: horizon,
    phone(w: 62pt, h: 112pt, box(width: 56pt, height: 98pt, {
      place(mini-map(56pt, 98pt))
      place(rect(width: 56pt, height: 14pt, fill: white))
      place(dx: 4pt, dy: 3.5pt, text(size: 5.5pt, weight: "bold")[Stands])
      place(dx: 40pt, dy: 1.5pt, sync-icon(r: 5.5pt))
    })),
    stack(dir: ttb, spacing: 6pt,
      bubble[Tap here to sync],
      block(width: 120pt, fill: white, stroke: 0.6pt + line-c, radius: 5pt, inset: 6pt, align(left, {
        folder-icon(warm); h(3pt); text(size: 8.5pt, weight: "bold")[Stands]; h(1fr); sync-icon(r: 7pt)
        v(4pt)
        text(size: 7.5pt, fill: sub)[Shows the sync status]
      })),
    ),
  ),
  note: [Drive info is kept in `.kmeta.json`, so the state is restored on the next launch.],
)

// ---- filter ----
#scene(
  [Filter by expression],
  [The attribute table gets a QGIS-style filter for quick searching through large datasets.],
  stack(dir: ttb, spacing: 5pt,
    attr-table(w: 160pt, "area", [`"area" > 100`], (("85", false), ("240", true), ("130", true), ("60", false))),
    caption[Rows that do not match drop out],
  ),
  note: [Feature duplication is new too: one-click copy of similarly structured data.],
)

#fixes(
  "Faster data loading",
  [GeoPackage loading sped up],
  [maplibre now from official pub.dev],
  [Large files split up],
)
