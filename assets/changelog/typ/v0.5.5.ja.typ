// 更新履歴（図解）: v0.5.5。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

// ホーム画面のアプリアイコンと名前。state は "old"（前の名前）/ "this"（この版）/ "later"（のちの名前）
#let app-tile(name, state: "this", sub-label: none) = stack(dir: ttb, spacing: 4pt,
  box(width: 34pt, height: 34pt, radius: 8pt, clip: true,
    stroke: if state == "this" { 1.2pt + accent } else if state == "later" { (paint: line-c, thickness: 0.8pt, dash: "dashed") } else { 0.6pt + line-c },
    if state == "old" { mini-map(34pt, 34pt, road: sub.lighten(30%), comp: rgb("#d9d6dc")) } else { mini-map(34pt, 34pt, road: map-road) }),
  box(width: 62pt, align(center, text(size: 8pt, weight: if state == "this" { "bold" } else { "regular" }, fill: if state == "this" { ink } else { sub })[#name])),
  if sub-label != none { box(width: 62pt, align(center, caption(sub-label))) },
)

// ---- 頭 ----
#hero(
  "v0.5.5 — 2026/04/11",
  [最初の改名 k\_maps → RootMap GIS],
  [「k\_maps」から「RootMap GIS」に改名しました。いまの「こかげマップ」は v0.6.1 からの名前です。],
  stack(dir: ttb, spacing: 14pt,
    grid(
      columns: (auto, auto, auto, auto, auto), column-gutter: 5pt, align: horizon,
      app-tile([k\_maps], state: "old", sub-label: [〜v0.5.4]),
      arrow-r(w: 16pt),
      app-tile([RootMap GIS], sub-label: [この版から]),
      arrow-r(w: 16pt, c: line-c),
      app-tile([こかげマップ], state: "later", sub-label: [v0.6.1〜]),
    ),
    box(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: (x: 9pt, y: 7pt), align(left, {
      caption[Google Drive の連携フォルダも（いまもこの名前）]
      v(3pt)
      folder-icon(warm); h(4pt); text(size: 8.5pt, weight: "bold")[RootMap GIS Projects]
    })),
  ),
)

// ---- 細かな変更 ----
#fixes(
  "ほかにも",
  [フィードバックフォームに版と機種が自動で入る],
)
