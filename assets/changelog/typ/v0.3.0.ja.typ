// 更新履歴（図解）: v0.3.0。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

// 点がたくさん（重なり合う）
#let many-dots(w, h) = box(width: w, height: h, {
  place(mini-map(w, h))
  let pts = ((0.2, 0.2), (0.25, 0.25), (0.3, 0.18), (0.22, 0.3), (0.28, 0.32), (0.7, 0.3), (0.74, 0.35), (0.68, 0.38),
    (0.72, 0.26), (0.66, 0.33), (0.78, 0.31), (0.4, 0.7), (0.45, 0.74), (0.5, 0.68), (0.42, 0.78), (0.48, 0.8),
    (0.36, 0.73), (0.52, 0.76), (0.44, 0.66))
  for (x, y) in pts { place(dx: w * x - 3pt, dy: h * y - 3pt, circle(radius: 3pt, fill: map-red, stroke: 0.8pt + white)) }
})
// まとめた点（数字入りの丸）
#let clusters(w, h) = box(width: w, height: h, {
  place(mini-map(w, h))
  for (x, y, n, r) in ((0.25, 0.25, "5", 6pt), (0.72, 0.32, "6", 6.5pt), (0.45, 0.73, "8", 7.5pt)) {
    place(dx: w * x - r, dy: h * y - r, circle(radius: r, fill: accent, stroke: 1.2pt + white,
      align(center + horizon, text(size: 6pt, weight: "bold", fill: white)[#n])))
  }
})

// ---- 頭: MapLibre ----
#hero(
  "v0.3.0 — 2026/03/09",
  [地図の描画を、爆速に],
  [地図エンジンを FlutterMap から MapLibre に全面移行しました。大量の点もまとめて表示して（クラスタリング）、なめらかに動きます。],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    phone(w: 66pt, h: 118pt, label: "点が多いと重なる", many-dots(60pt, 104pt)),
    arrow-r(w: 26pt),
    phone(w: 66pt, h: 118pt, label: "まとめて表示", clusters(60pt, 104pt)),
  ),
)

#fixes(
  "ほかにも",
  [写真マーカーを GPU で描画],
  [Windows 版の描画を最適化],
  [設定画面をそろえ、画面の幅に合わせて分割表示],
)
