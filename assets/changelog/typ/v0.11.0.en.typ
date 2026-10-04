// Changelog (illustrated): v0.11.0. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "v0.11.0 — 2026/10/04",
  ["Open my map" opens your everyday map],
  [No folder to choose: "Open my map" on Home opens Documents/KokageMap. "マイ地図" is ready to write to, and maps received by QR go into "共有".],
  grid(
    columns: (auto, auto, auto), column-gutter: 10pt, align: horizon,
    box(width: 120pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 8pt, {
      box(width: 100%, fill: rgb("#2e6b4f"), radius: 5pt, inset: (x: 6pt, y: 6pt), text(size: 8pt, fill: white, weight: "bold")[Open my map])
      v(4pt)
      box(width: 100%, stroke: 0.6pt + line-c, radius: 4pt, inset: (x: 6pt, y: 4pt), text(size: 7pt)[Open another folder])
    }),
    arrow-r(w: 20pt),
    layer-panel(w: 110pt, header: "Layers", (
      (0, "dir", [共有], "ok"),
      (1, "dir", [組合 間伐調査], "ok"),
      (0, "layer", [マイ地図 / 点], "hi", rgb("#2e6b4f")),
    )),
  ),
)

#scene(
  [Scan a QR, the map opens],
  [Scan a "Share by QR" code with the phone camera: Kokage Map opens, adds the map to "共有" and shows where it is. Phones and PCs without the app get install instructions.],
  grid(
    columns: (auto, auto, auto, auto, auto), column-gutter: 6pt, align: horizon,
    stack(dir: ttb, spacing: 4pt, box(width: 36pt, height: 36pt, stroke: 2pt + ink, inset: 4pt, grid(columns: 3, gutter: 2pt, ..range(9).map(i => box(width: 8pt, height: 8pt, fill: if calc.rem(i, 2) == 0 { ink } else { white })))), caption[Scan]),
    arrow-r(w: 16pt),
    stack(dir: ttb, spacing: 4pt, box(width: 36pt, height: 36pt, fill: rgb("#2e6b4f"), radius: 8pt), caption[App opens]),
    arrow-r(w: 16pt),
    stack(dir: ttb, spacing: 4pt, box(width: 36pt, height: 36pt, fill: rgb("#e3f0e8"), radius: 4pt, align(center + horizon, folder-icon(warm, w: 16pt))), caption[Added to 共有]),
  ),
)

#fixes(
  "Tutorial",
  [The tutorial runs on the web too (without the photo chapter)],
  [Each chapter starts in 2D, north up],
)

#fixes(
  "Also",
  [App folders (Global, practice) moved into .kokage (automatically on first launch)],
)
