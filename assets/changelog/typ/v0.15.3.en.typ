// Changelog (illustrated): v0.15.3. Exported to chunked SVGs by tool/changelog/build.py
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "v0.15.3 — 2026/11/10",
  [One-Tap Google Play Update Banner on Home Screen],
  [On Android, when a newer version is available, an update banner now appears at the top of the Home Screen. Tap it to open Kokage Map directly in the Google Play Store.],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    phone(w: 98pt, h: 122pt, label: [Home Screen], {
      place(rect(width: 92pt, height: 108pt, fill: white))
      place(dx: 5pt, dy: 5pt, rect(width: 82pt, height: 24pt, radius: 4pt, fill: rgb("#e3f0e8"), inset: 4pt, align(left + bottom, {
        text(size: 6.5pt, weight: "bold", fill: rgb("#2e6b4f"))[Kokage Map]
      })))
      place(dx: 5pt, dy: 33pt, rect(width: 82pt, height: 24pt, radius: 4pt, fill: accent-soft, stroke: 0.7pt + accent, inset: 3.5pt, align(left + horizon, {
        text(size: 5.3pt, weight: "bold", fill: accent)[New version (v0.15.3)]
        linebreak()
        text(size: 4.8pt, fill: sub)[Update on Google Play ↗]
      })))
      place(dx: 4pt, dy: 32pt, spot(84pt, 26pt))
      place(dx: 5pt, dy: 62pt, rect(width: 82pt, height: 22pt, radius: 4pt, fill: rgb("#2e6b4f"), inset: 4pt, align(left + horizon, {
        text(size: 6pt, weight: "bold", fill: white)[Open my map]
      })))
    }),
    arrow-r(w: 16pt),
    block(fill: white, stroke: 0.7pt + okink, radius: 6pt, inset: 8pt, width: 98pt, align(left, {
      text(size: 7pt, weight: "bold", fill: okink)[Google Play Store]
      v(4pt)
      text(size: 6.2pt, fill: ink)[Kokage Map]
      v(5pt)
      box(width: 100%, fill: okink, radius: 4pt, inset: (x: 6pt, y: 4pt), align(center, {
        text(size: 6.5pt, weight: "bold", fill: white)[Update]
      }))
    })),
  ),
  note: [When offline in the mountains, the version check is silently skipped without delaying startup or showing any error.],
)

#fixes(
  "Improvements & Bug Fixes",
  [Added a Google Play Store update banner on the Android Home Screen when a newer version is available],
  [Fixed repeated debug log output on every pointer interaction on Web when not signed in to Google Drive],
  [Improved cross-platform path separator normalization for folder names in transfer progress on Linux and Web],
)
