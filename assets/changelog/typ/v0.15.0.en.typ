// Changelog (illustrated): v0.15.0. Exported to chunked SVGs by tool/changelog/build.py
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#let terrain-card(fine: false, label: "", sub-label: "") = box(width: 108pt, fill: white, stroke: 0.7pt + if fine { accent } else { line-c }, radius: 6pt, inset: 6pt, align(left, {
  text(size: 6.3pt, weight: "bold", fill: if fine { accent } else { sub })[#label]
  v(4pt)
  box(width: 96pt, height: 48pt, fill: rgb("#f4f7ef"), stroke: 0.5pt + line-c, radius: 3pt, clip: true, {
    if not fine {
      place(polygon(fill: rgb("#cfe0be"), stroke: 0.8pt + rgb("#7cb342"),
        (0pt, 44pt), (24pt, 22pt), (58pt, 12pt), (96pt, 26pt), (96pt, 48pt), (0pt, 48pt)))
      place(curve(stroke: (paint: rgb("#9ab882"), thickness: 0.6pt),
        curve.move((16pt, 48pt)), curve.line((38pt, 17pt))))
      place(curve(stroke: (paint: rgb("#9ab882"), thickness: 0.6pt),
        curve.move((48pt, 48pt)), curve.line((66pt, 15pt))))
      place(curve(stroke: (paint: rgb("#7cb342"), thickness: 0.6pt),
        curve.move((10pt, 34pt)), curve.line((96pt, 38pt))))
    } else {
      place(polygon(fill: rgb("#cfe0be"), stroke: 0.8pt + okink,
        (0pt, 44pt), (12pt, 34pt), (16pt, 28pt), (28pt, 27pt), (32pt, 19pt),
        (44pt, 18pt), (52pt, 10pt), (68pt, 14pt), (76pt, 22pt), (88pt, 21pt),
        (96pt, 28pt), (96pt, 48pt), (0pt, 48pt)))
      place(polygon(fill: rgb("#ffe0b2"), stroke: 0.8pt + warm,
        (16pt, 28pt), (28pt, 27pt), (88pt, 21pt), (76pt, 22pt)))
      place(polygon(fill: rgb("#ffe0b2"), stroke: 0.8pt + warm,
        (32pt, 19pt), (44pt, 18pt), (72pt, 15pt), (62pt, 16pt)))
      place(dx: 14pt, dy: 32pt, box(fill: rgb(255, 255, 255, 210), radius: 2pt, inset: (x: 3pt, y: 1.5pt),
        text(size: 5.5pt, weight: "bold", fill: warm)[▲ Road cut/fill benches]))
    }
  })
  v(3pt)
  text(size: 5.6pt, fill: if fine { accent } else { sub })[#sub-label]
}))

#let toggle-pill(on: true) = box(
  width: 16pt, height: 9pt, radius: 4.5pt,
  fill: if on { accent } else { rgb("#c4c0c9") },
  place(dx: if on { 8pt } else { 1pt }, dy: 1pt, circle(radius: 3.5pt, fill: white)),
)

#hero(
  "v0.15.0 — 2026/11/02",
  [Advanced 3D Map: See Mountain Paths & Micro-Terrain],
  [Added "Advanced 3D Map" under Settings → 3D Terrain. Automatically composites 0.25–1 m high-resolution DEMs across 25 regions in Japan (including Wakayama's 1 m point cloud), seamlessly filling outside areas with GSI DEMs.],
  grid(
    columns: (auto, auto, auto), column-gutter: 5pt, align: horizon,
    terrain-card(fine: false, label: "Standard (5m–10m)", sub-label: "Broad ridges & valleys only"),
    arrow-r(w: 14pt),
    terrain-card(fine: true, label: "Advanced 3D (0.25–1m)", sub-label: "Mountain roads & micro-relief"),
  ),
)

#scene(
  [No Mesh Tearing While Zooming or Panning 3D Terrain],
  [Previously, fine child tiles appeared one by one as they finished baking, causing coarse and fine meshes to overlap. Now all 4 child tiles (2×2) finish baking in the background before swapping in together.],
  grid(
    columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
    box(width: 104pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.3pt, weight: "bold", fill: sub)[Before (1 by 1)]
      v(4pt)
      box(width: 92pt, height: 48pt, fill: map-bg, stroke: 0.6pt + line-c, radius: 3pt, clip: true, {
        place(curve(stroke: (paint: map-road.lighten(35%), thickness: 3.5pt),
          curve.move((0pt, 38pt)), curve.line((92pt, 12pt))))
        place(rect(width: 46pt, height: 24pt, fill: rgb("#e2edd8"), stroke: 0.8pt + map-red))
        place(curve(stroke: (paint: map-road, thickness: 1.4pt),
          curve.move((0pt, 35pt)), curve.line((46pt, 22pt))))
        place(dx: 4pt, dy: 3pt, text(size: 5.5pt, weight: "bold", fill: map-red)[Fine])
        place(dx: 52pt, dy: 4pt, text(size: 5.5pt, fill: sub)[Coarse])
        place(dx: 8pt, dy: 34pt, text(size: 5.5pt, fill: sub)[Coarse])
      })
      v(3pt)
      text(size: 5.6pt, fill: map-red)[Coarse & fine tiles mixed]
    })),
    arrow-r(w: 14pt),
    box(width: 104pt, fill: white, stroke: 0.7pt + okink, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.3pt, weight: "bold", fill: okink)[Now (Atomic 2×2 Swap)]
      v(4pt)
      box(width: 92pt, height: 48pt, fill: rgb("#e2edd8"), stroke: 0.7pt + okink, radius: 3pt, clip: true, {
        place(dx: 46pt, line(angle: 90deg, length: 48pt, stroke: (paint: okink.lighten(40%), thickness: 0.5pt, dash: "dashed")))
        place(dy: 24pt, line(length: 92pt, stroke: (paint: okink.lighten(40%), thickness: 0.5pt, dash: "dashed")))
        place(curve(stroke: (paint: map-road, thickness: 1.5pt),
          curve.move((0pt, 38pt)), curve.line((92pt, 12pt))))
        place(dx: 4pt, dy: 3pt, text(size: 5.5pt, weight: "bold", fill: okink)[Fine ✓])
        place(dx: 50pt, dy: 3pt, text(size: 5.5pt, weight: "bold", fill: okink)[Fine ✓])
        place(dx: 4pt, dy: 27pt, text(size: 5.5pt, weight: "bold", fill: okink)[Fine ✓])
        place(dx: 50pt, dy: 27pt, text(size: 5.5pt, weight: "bold", fill: okink)[Fine ✓])
      })
      v(3pt)
      text(size: 5.6pt, fill: okink)[Swaps after all 4 are ready]
    })),
  ),
)

#scene(
  [GSI Map Background in Layer Style Preview],
  [The preview at the top of Layer Style Settings now renders over a GSI map background and adapts to point, line, or polygon layers, making it easy to see how colors and opacity blend with contours and roads.],
  grid(
    columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
    box(width: 100pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.3pt, weight: "bold", fill: sub)[Before (Plain White)]
      v(4pt)
      box(width: 88pt, height: 42pt, fill: white, stroke: 0.5pt + line-c, radius: 3pt, {
        place(dx: 16pt, dy: 7pt, rect(width: 56pt, height: 28pt, fill: rgb(33, 150, 243, 110), stroke: 1.2pt + accent, radius: 2pt))
      })
      v(3pt)
      text(size: 5.6pt, fill: sub)[Hard to judge transparency]
    })),
    arrow-r(w: 14pt),
    box(width: 112pt, fill: white, stroke: 0.7pt + accent, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.3pt, weight: "bold", fill: accent)[Now (Over GSI Map)]
      v(4pt)
      box(width: 100pt, height: 42pt, fill: rgb("#ece8dc"), stroke: 0.5pt + line-c, radius: 3pt, clip: true, {
        place(curve(stroke: (paint: rgb("#c4a482"), thickness: 0.6pt),
          curve.move((0pt, 12pt)), curve.cubic((30pt, 4pt), (60pt, 22pt), (100pt, 10pt))))
        place(curve(stroke: (paint: rgb("#c4a482"), thickness: 0.6pt),
          curve.move((0pt, 26pt)), curve.cubic((35pt, 18pt), (65pt, 36pt), (100pt, 24pt))))
        place(curve(stroke: (paint: rgb("#8d6e63"), thickness: 1.4pt),
          curve.move((8pt, 40pt)), curve.line((92pt, 6pt))))
        place(dx: 18pt, dy: 7pt, rect(width: 64pt, height: 28pt, fill: rgb(33, 150, 243, 105), stroke: 1.3pt + accent, radius: 2pt))
        place(dx: 31pt, dy: 15pt, box(fill: rgb(255, 255, 255, 210), radius: 2pt, inset: (x: 3pt, y: 1.5pt),
          text(size: 6pt, weight: "bold", fill: ink)[Sample]))
      })
      v(3pt)
      text(size: 5.6pt, fill: accent)[Contours & roads show through]
    })),
  ),
)

#scene(
  [Auto-Collapsing Settings When Toggled Off],
  [Sub-settings for labels, vertex points, 3D coloring, auto-sync, and GNSS thresholds stay folded while their parent switch is OFF, and expand only when turned ON.],
  grid(
    columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
    box(width: 98pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.3pt, weight: "bold", fill: sub)[When OFF]
      v(4pt)
      grid(columns: (1fr, auto), align: horizon,
        text(size: 7pt, fill: ink)[Show Labels],
        toggle-pill(on: false),
      )
      v(3pt)
      text(size: 5.6pt, fill: sub)[Details stay folded]
    })),
    arrow-r(w: 14pt),
    box(width: 114pt, fill: white, stroke: 0.7pt + accent, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.3pt, weight: "bold", fill: accent)[When ON (Expanded)]
      v(4pt)
      grid(columns: (1fr, auto), align: horizon,
        text(size: 7pt, weight: "bold", fill: ink)[Show Labels],
        toggle-pill(on: true),
      )
      v(4pt)
      block(inset: (left: 6pt), stroke: (left: 1.5pt + accent-soft), {
        text(size: 6pt, fill: ink)[Field: Name#linebreak()Font Size: 12 pt#linebreak()Text & Halo Color]
      })
    })),
  ),
)

#fixes(
  "Bug Fixes",
  [Fixed Layer Style opacity changes not propagating to existing View styles and the active current-day GPS track],
  [Sanitized invalid filename characters (replaced with underscores) when exporting CSV files from the attribute table],
)
