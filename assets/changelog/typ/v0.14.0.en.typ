// Changelog (illustrated): v0.14.0. Exported to chunked SVGs by tool/changelog/build.py
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "v0.14.0 — 2026/10/28",
  [Shared Folder Sets (JSON) & Live Sync Progress],
  [Clone and track multiple Drive shared folders at once from a single JSON manifest link or QR code. Also adds 3-phase background transfer progress and a button to jump from any feature directly to its layer in the layer tree.],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    block(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, width: 96pt, align(left, {
      grid(columns: (10pt, 1fr), column-gutter: 3pt, align: horizon,
        file-icon(accent, w: 8.5pt),
        text(size: 6.3pt, weight: "bold", fill: accent)[Field Survey Set.json],
      )
      v(4pt)
      text(size: 6.5pt, fill: sub)[· Survey Area A#linebreak()· Survey Area B#linebreak()· Routes & Points]
    })),
    arrow-r(w: 18pt),
    layer-panel(w: 118pt, header: "Layer tree", (
      (0, "dir", [Field Survey Set], "hi"),
      (1, "dir", [Survey Area A], "lock"),
      (1, "dir", [Survey Area B], "lock"),
      (1, "dir", [Routes & Points], "ok"),
    )),
  ),
  note: [Folders removed from the JSON are automatically deleted only after verifying they have no unsynced local changes (folders with local edits are kept and reported). Lock icons indicate read-only folders.],
)

#scene(
  [3-Phase Sync Progress & Background Transfer],
  [Live progress ("1. Checking structure → 2. Transferring files (% · MB · filename) → 3. Applying map data") appears in notifications and on folder rows. On Android, a foreground service keeps large downloads running with the screen off.],
  stack(dir: ttb, spacing: 6pt,
    block(fill: white, stroke: 1pt + accent, radius: 6pt, inset: (x: 8pt, y: 6pt), width: 220pt, align(left, {
      grid(columns: (1fr, auto), align: horizon,
        text(size: 8pt, weight: "bold", fill: ink)[Downloading Survey Area A...],
        text(size: 7.5pt, weight: "bold", fill: accent)[64%],
      )
      v(4pt)
      box(width: 100%, height: 4pt, fill: accent-soft, radius: 2pt,
        place(rect(width: 64%, height: 4pt, fill: accent, radius: 2pt)))
      v(4pt)
      text(size: 7pt, fill: sub)[17.6 / 27.5 MB · area2026.gpkg]
    })),
    grid(
      columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
      badge[1. Check folder],
      badge[2. Transfer files],
      badge[3. Apply map data],
    ),
  ),
)

#scene(
  ["Open in layer tree" from the Info Panel],
  [Jump directly from a selected feature or photo's info panel to its layer or photo row in the layer tree, automatically expanding parent folders.],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    block(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, width: 98pt, align(left, {
      text(size: 7.5pt, weight: "bold", fill: ink)[Zone 12-A]
      v(3pt)
      text(size: 6.5pt, fill: sub)[Status: Surveyed / Team A]
      v(5pt)
      box(width: 100%, fill: accent-soft, stroke: 0.7pt + accent, radius: 4pt, inset: (x: 4pt, y: 3pt),
        align(center, text(size: 6.8pt, weight: "bold", fill: accent)[Open in layer tree]))
    })),
    arrow-r(w: 18pt),
    layer-panel(w: 114pt, header: "Layer tree", (
      (0, "dir", [Field Survey], "ok"),
      (1, "layer", [Routes], "ok", map-road),
      (1, "layer", [Survey Zones], "hi", rgb("#2e6b4f")),
    )),
  ),
)

#fixes(
  "Improvements & Changes",
  [Prioritize GPS current location at startup (fit all features only while waiting for GPS, then jump to current location once acquired)],
  [Unified UI terminology from "Layer drawer" to "Layer tree"],
  [Removed the "Guide me here" point guidance feature],
)
