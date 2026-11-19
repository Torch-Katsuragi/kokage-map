// Changelog (illustrated): v0.16.2. Exported to chunked SVGs by tool/changelog/build.py
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "v0.16.2 — 2026/11/19",
  [Back-Navigation Guard During Survey & GPU Map Rendering Fix],
  [Returning to the Home Screen is now limited to the top-left "←" button so accidental Android Back presses or edge swipes never interrupt field work. Tapping "←" with unconfirmed survey or drawing data asks for confirmation first.],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    phone(w: 98pt, h: 126pt, label: [Map Screen (Top-Left ← Only)], {
      place(mini-map(92pt, 112pt))
      place(rect(width: 92pt, height: 15pt, fill: white))
      place(dx: 4pt, dy: 3pt, text(size: 7pt, weight: "bold", fill: ink)[←   Field Survey])
      place(dx: 2pt, dy: 1.5pt, spot(11.5pt, 12pt))
      place(curve(stroke: (paint: map-red, thickness: 1.6pt, cap: "round"),
        curve.move((18pt, 78pt)), curve.line((46pt, 46pt)), curve.line((76pt, 62pt))))
      place(dx: 16pt, dy: 76pt, circle(radius: 2pt, fill: map-red))
      place(dx: 44pt, dy: 44pt, circle(radius: 2pt, fill: map-red))
      place(dx: 74pt, dy: 60pt, circle(radius: 2pt, fill: map-red))
      place(dx: 6pt, dy: 92pt, rect(width: 80pt, height: 15pt, radius: 3pt, fill: white, stroke: 0.5pt + line-c, inset: 2.5pt, align(center + horizon, {
        text(size: 5.1pt, fill: sub)[Edge swipe / Back blocked]
      })))
    }),
    arrow-r(w: 16pt),
    phone(w: 98pt, h: 126pt, label: [Unconfirmed Data Guard], {
      place(mini-map(92pt, 112pt))
      place(rect(width: 92pt, height: 112pt, fill: rgb(0, 0, 0, 28%)))
      place(dx: 6pt, dy: 28pt, rect(width: 80pt, height: 56pt, radius: 5pt, fill: white, stroke: 0.6pt + line-c, inset: 5pt, align(left, {
        text(size: 5.5pt, weight: "bold", fill: ink)[Unconfirmed survey data]
        v(2pt)
        text(size: 4.9pt, fill: sub)[Discard and leave map?]
        v(6pt)
        grid(columns: (1fr, 1fr), column-gutter: 3pt,
          box(width: 100%, fill: accent-soft, radius: 3pt, inset: (x: 2pt, y: 3pt), align(center, text(size: 4.9pt, weight: "bold", fill: accent)[Stay])),
          box(width: 100%, fill: accent, radius: 3pt, inset: (x: 2pt, y: 3pt), align(center, text(size: 4.9pt, weight: "bold", fill: white)[Leave])),
        )
      })))
    }),
  ),
  note: [Pressing system Back while a radial menu is open or while editing a feature still closes the menu or cancels the edit without leaving the map.],
)

#fixes(
  "Improvements & Bug Fixes",
  [Blocked accidental return to the Home Screen via the Android system Back button or edge-swipe gesture (limited to top-left "←")],
  [Added a confirmation dialog when tapping "←" with unconfirmed drawing vertices, active GPS long-press survey, or an active TruPulse station],
  [Fixed the map turning solid grey during pinch-zoom with a GeoTIFF selected or at high zoom with TruPulse survey legs],
)
