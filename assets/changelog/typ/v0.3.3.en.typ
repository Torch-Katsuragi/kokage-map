// Changelog (illustrated): v0.3.3. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

// ---- head ----
#hero(
  "v0.3.3 — 2026/03/11",
  [Download maps ahead \ for offline use],
  [Pick an area and zoom levels to bulk-download the basemap. It stays on screen with no signal.],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    phone(w: 66pt, h: 118pt, label: "Area and zoom", box(width: 60pt, height: 104pt, {
      place(mini-map(60pt, 104pt))
      place(dx: 8pt, dy: 22pt, rect(width: 44pt, height: 54pt, fill: accent.transparentize(85%),
        stroke: (paint: accent, thickness: 1.2pt, dash: "dashed")))
    })),
    stack(dir: ttb, spacing: 4pt, caption(fill: accent)[Bulk download], arrow-r(w: 30pt)),
    phone(w: 66pt, h: 118pt, label: "No signal, still there", box(width: 60pt, height: 104pt, {
      place(mini-map(60pt, 104pt))
      place(dx: 3pt, dy: 3pt, box(fill: white, radius: 20pt, inset: (x: 4pt, y: 1.5pt), text(size: 5.5pt, weight: "bold", fill: sub)[Offline]))
    })),
  ),
)

#fixes(
  "Also",
  [Added Drive auto-sync check],
  [Fixed SymbolStyleLayer rendering],
  [Network switch no longer hides layers],
  [Fixed dragging GeoPackages],
)
