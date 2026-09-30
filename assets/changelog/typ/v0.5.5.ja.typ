// 更新履歴（図解）: v0.5.5。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

// ホーム画面のアプリアイコンと名前
#let app-tile(name, on: true) = stack(dir: ttb, spacing: 4pt,
  box(width: 34pt, height: 34pt, radius: 8pt, clip: true, stroke: 0.6pt + line-c,
    if on { mini-map(34pt, 34pt, road: map-road) } else { mini-map(34pt, 34pt, road: sub.lighten(30%), comp: rgb("#d9d6dc")) }),
  box(width: 80pt, align(center, text(size: 8pt, weight: if on { "bold" } else { "regular" }, fill: if on { ink } else { sub })[#name])),
)

// ---- 頭 ----
#hero(
  "v0.5.5 — 2026/04/11",
  [アプリ名が\ 「RootMap GIS」に],
  [「k\_maps」から改名しました。Android・Windows・Web のどれでも同じ名前で表示されます。],
  stack(dir: ttb, spacing: 14pt,
    grid(
      columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
      app-tile([k\_maps], on: false),
      arrow-r(w: 22pt),
      app-tile([RootMap GIS]),
    ),
    box(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: (x: 9pt, y: 7pt), align(left, {
      caption[Google Drive の連携フォルダも]
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
