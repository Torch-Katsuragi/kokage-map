// Changelog (illustrated): v0.16.0. Exported to chunked SVGs by tool/changelog/build.py
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "v0.16.0 — 2026/11/13",
  [Cased Lines, Hatching Fills & 19 Style Templates],
  [Multi-layer QGIS symbology—including white-cased lines, diagonal/cross hatching, dashed strokes, and SVG markers—now renders and round-trips cleanly with `.qml` import/export, alongside 19 one-tap style templates.],
  grid(
    columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
    box(width: 102pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.5pt, weight: "bold", fill: accent)[One-Tap Templates]
      v(4pt)
      stack(dir: ttb, spacing: 3.5pt,
        box(width: 100%, fill: accent-soft, stroke: 0.7pt + accent, radius: 3pt, inset: (x: 4pt, y: 2.8pt), {
          grid(columns: (16pt, 1fr), column-gutter: 4pt, align: horizon,
            box(width: 16pt, height: 6pt, {
              place(dy: 0.8pt, line(length: 16pt, stroke: 4.2pt + white))
              place(dy: 0.8pt, line(length: 16pt, stroke: 3.6pt + line-c))
              place(dy: 0.8pt, line(length: 16pt, stroke: 1.8pt + map-red))
            }),
            text(size: 6pt, weight: "bold", fill: accent)[Cased Line],
          )
        }),
        box(width: 100%, fill: white, stroke: 0.5pt + line-c, radius: 3pt, inset: (x: 4pt, y: 2.8pt), {
          grid(columns: (16pt, 1fr), column-gutter: 4pt, align: horizon,
            box(width: 14pt, height: 8pt, clip: true, stroke: 0.8pt + warm, {
              place(line(start: (-2pt, 9pt), end: (7pt, -1pt), stroke: 0.8pt + warm))
              place(line(start: (3pt, 9pt), end: (12pt, -1pt), stroke: 0.8pt + warm))
              place(line(start: (8pt, 9pt), end: (17pt, -1pt), stroke: 0.8pt + warm))
            }),
            text(size: 6pt, fill: ink)[Diagonal Hatch],
          )
        }),
        box(width: 100%, fill: white, stroke: 0.5pt + line-c, radius: 3pt, inset: (x: 4pt, y: 2.8pt), {
          grid(columns: (16pt, 1fr), column-gutter: 4pt, align: horizon,
            align(center, box(width: 8pt, height: 8pt, {
              place(circle(radius: 4pt, fill: white, stroke: 1pt + okink))
              place(dx: 2pt, dy: 2pt, circle(radius: 2pt, fill: okink))
            })),
            text(size: 6pt, fill: ink)[Target Marker],
          )
        }),
      )
    })),
    arrow-r(w: 14pt),
    box(width: 108pt, fill: white, stroke: 0.7pt + okink, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.5pt, weight: "bold", fill: okink)[Crisp Over Imagery]
      v(4pt)
      box(width: 96pt, height: 54pt, fill: rgb("#dce7d0"), stroke: 0.5pt + line-c, radius: 3pt, clip: true, {
        place(dx: 8pt, dy: 7pt, box(width: 44pt, height: 28pt, clip: true, fill: rgb(255, 243, 224, 120), stroke: 1.1pt + warm, radius: 2pt, {
          for k in range(-3, 8) {
            place(line(start: (k * 7pt, 30pt), end: (k * 7pt + 22pt, -2pt), stroke: 0.8pt + warm))
          }
        }))
        place(curve(stroke: (paint: white, thickness: 4.2pt, cap: "round"),
          curve.move((4pt, 46pt)), curve.cubic((32pt, 38pt), (58pt, 18pt), (92pt, 12pt))))
        place(curve(stroke: (paint: map-red, thickness: 2pt, cap: "round"),
          curve.move((4pt, 46pt)), curve.cubic((32pt, 38pt), (58pt, 18pt), (92pt, 12pt))))
        place(dx: 66pt, dy: 28pt, circle(radius: 4.8pt, fill: white, stroke: 1.2pt + accent))
        place(dx: 68.6pt, dy: 30.6pt, circle(radius: 2.2pt, fill: accent))
      })
      v(3pt)
      text(size: 5.8pt, fill: okink)[Seamless `.qgs` / `.qml` round-trip]
    })),
  ),
)

#scene(
  [Fast, Resilient Sync for Large Shared Drive Folders],
  [Multi-parent batched folder scanning and `Changes API` caching dramatically cut API calls on folders with thousands of subfolders, while two-pass smart scheduling marks synced folders immediately and transfers light folders first.],
  grid(
    columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
    box(width: 102pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.5pt, weight: "bold", fill: sub)[Before]
      v(4pt)
      text(size: 6pt, fill: map-red)[• Per-subfolder API bursts#linebreak()• Heavy archives blocked light folders]
      v(4pt)
      box(width: 100%, fill: rgb("#fdecea"), radius: 3pt, inset: (x: 4pt, y: 3pt),
        text(size: 5.8pt, weight: "bold", fill: map-red)[× Rate-limit sync errors])
    })),
    arrow-r(w: 14pt),
    box(width: 110pt, fill: white, stroke: 0.7pt + okink, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.5pt, weight: "bold", fill: okink)[Now (Batched + 2-Pass)]
      v(4pt)
      stack(dir: ttb, spacing: 3pt,
        box(width: 100%, fill: okbg, radius: 3pt, inset: (x: 4pt, y: 2.5pt),
          text(size: 5.8pt, weight: "bold", fill: okink)[1. Instant synced status ✓]),
        box(width: 100%, fill: accent-soft, radius: 3pt, inset: (x: 4pt, y: 2.5pt),
          text(size: 5.8pt, weight: "bold", fill: accent)[2. Light folders sync first ↗]),
      )
      v(3pt)
      text(size: 5.6pt, fill: sub)[Protects read-only folders from pushes]
    })),
  ),
)

#fixes(
  "Improvements & Bug Fixes",
  [Restored deleted child presets on manual sync, migrated reference-mounted folders on deletion, auto-loaded visible layers in new child sets, and pruned orphaned cache entries],
  [Supported 4-band GeoTIFFs with Undefined alpha and 5+ band rasters, showing a notification if conversion fails],
  [Fixed a race condition where GPS points arriving right as recording stopped could miss consolidation],
)
