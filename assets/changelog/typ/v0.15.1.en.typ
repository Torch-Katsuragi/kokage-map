// Changelog (illustrated): v0.15.1. Exported to chunked SVGs by tool/changelog/build.py
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "v0.15.1 — 2026/11/04",
  [Hierarchical Shared Folder Sets (Combining JSON Presets)],
  [You can now nest JSON presets inside another JSON preset to organize shared folders into a multi-level folder hierarchy. Each JSON preset works both standalone and as part of a larger site-wide preset.],
  grid(
    columns: (auto, auto, auto), column-gutter: 7pt, align: horizon,
    stack(dir: ttb, spacing: 5pt,
      block(fill: white, stroke: 0.7pt + accent, radius: 6pt, inset: 6pt, width: 98pt, align(left, {
        grid(columns: (9pt, 1fr), column-gutter: 3pt, align: horizon,
          file-icon(accent, w: 8pt),
          text(size: 6.5pt, weight: "bold", fill: accent)[all_sites.json],
        )
        v(3pt)
        text(size: 6.2pt, fill: sub)[· north_area.json (RO)#linebreak()· south_area.json#linebreak()· Base Map]
      })),
      block(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, width: 98pt, align(left, {
        grid(columns: (9pt, 1fr), column-gutter: 3pt, align: horizon,
          file-icon(sub, w: 8pt),
          text(size: 6.5pt, weight: "bold", fill: ink)[north_area.json],
        )
        v(3pt)
        text(size: 6.2pt, fill: sub)[· Zone A Plan#linebreak()· Zone A Photos]
      })),
    ),
    arrow-r(w: 16pt),
    layer-panel(w: 120pt, header: "Layer tree", (
      (0, "dir", [All Sites], "hi"),
      (1, "dir", [North Area], "lock"),
      (2, "dir", [Zone A Plan], "lock"),
      (2, "dir", [Zone A Photos], "lock"),
      (1, "dir", [South Area], "ok"),
      (1, "dir", [Base Map], "ok"),
    )),
  ),
  note: [Coordinators can load "all_sites.json" for the whole project while field teams load "north_area.json" for just their zone, using the exact same JSON files.],
)

#fixes(
  "New Features & Improvements",
  [Combine multiple JSON presets inside a parent JSON preset to build multi-level folder hierarchies in the layer tree],
  [Use any JSON preset either standalone via its own shared link / QR code or as a child inside a larger preset],
  [Mark specific child presets as read-only (readOnly: true) in a parent JSON to bundle reference-only zones alongside your editable work zone],
)
