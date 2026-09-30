// 更新履歴（図解）: v0.7.1。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup


// ---- この版だけの部品 ----

/// 現在位置の青い点
#let loc-dot(r: 5pt, alpha: 100%) = box(width: 2 * r, height: 2 * r,
  circle(radius: r, fill: accent.transparentize(100% - alpha), stroke: 1.4pt + white))

/// 地図の上の点（フィーチャ）
#let pt-mark(c: map-red, r: 2.6pt) = circle(radius: r, fill: c, stroke: 0.8pt + white)

/// レイヤ一覧（下半分）と、1 行目の ⋮ から開いたメニュー（menu は足した項目の名前）。上半分は何も無い地図と現在位置
#let layer-menu(w, h, title, rows, menu, mw: 52pt) = box(width: w, height: h, clip: true, {
  place(rect(width: w, height: h, fill: map-bg))
  place(dx: w * 0.6, dy: h * 0.14, loc-dot())
  let top = h * 0.4
  let rh = 12pt
  place(dy: top, rect(width: w, height: h - top, fill: white))
  place(dx: 4pt, dy: top + 3pt, text(size: 6pt, weight: "bold", fill: sub)[#title])
  for (i, name) in rows.enumerate() {
    let y = top + 13pt + i * rh
    if i == 0 { place(dy: y, rect(width: w, height: rh, fill: accent-soft)) }
    place(dx: 4pt, dy: y + 2.5pt, text(size: 6.5pt)[#name])
    place(dx: w - 7pt, dy: y + 2.5pt, text(size: 6.5pt, weight: "bold", fill: if i == 0 { accent } else { sub })[⋮])
  }
  place(dx: w - mw - 3pt, dy: top + 13pt + rh + 1pt, block(width: mw, fill: white, stroke: 0.6pt + line-c, radius: 3pt, {
    block(width: 100%, inset: (x: 4pt, y: 3pt), above: 0pt, below: 0pt, fill: accent-soft,
      text(size: 6pt, weight: "bold", fill: accent)[#menu])
    // ほかの項目は灰色の棒で済ませる
    for i in range(2) {
      block(width: 100%, inset: (x: 4pt, y: 4.5pt), above: 0pt, below: 0pt,
        rect(width: 60% - i * 15%, height: 3pt, radius: 1pt, fill: line-c))
    }
  }))
})

/// 地図の上に重ねた画像（GeoTIFF のオーバーレイ）
#let overlay-map(w, h) = box(width: w, height: h, clip: true, {
  place(mini-map(w, h))
  place(dx: w * 0.2, dy: h * 0.18, rect(width: w * 0.6, height: h * 0.5,
    fill: gradient.linear(rgb("#7a8f5a"), rgb("#a9b98a"), rgb("#6d7f4e"), angle: 35deg),
    stroke: 0.8pt + accent))
})

// ---- 頭: 遠くのデータへ寄る ----
#hero(
  "v0.7.1 — 2026/09/12",
  [遠くのデータへすぐ寄れる],
  [レイヤの ⋮ メニューに「レイヤへ寄せる」を足しました。行のダブルタップでも寄ります。],
  grid(
    columns: (auto, auto, auto), column-gutter: 10pt, align: horizon,
    phone(w: 72pt, h: 128pt, label: "⋮ から選ぶ",
      layer-menu(66pt, 114pt, "レイヤ", ("小班", "路網", "測点"), "レイヤへ寄せる")),
    arrow-r(w: 22pt),
    phone(w: 72pt, h: 128pt, label: "データのある所へ", mini-map(66pt, 114pt)),
  ),
)

// ---- GeoTIFF を QGIS へ ----
#scene(
  [重ねた画像も QGIS で開ける],
  [オーバーレイ画像（GeoTIFF）を、QGIS プロジェクト（`.qgs`）にラスタレイヤとして書きます。],
  grid(
    columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
    phone(w: 54pt, h: 96pt, label: "こかげマップ", overlay-map(48pt, 82pt)),
    stack(dir: ttb, spacing: 3pt, file-icon(accent, w: 12pt), text(size: 7pt, weight: "bold", fill: accent)[.qgs], arrow-r(w: 24pt)),
    pc(w: 104pt, h: 74pt, label: "QGIS でそのまま", overlay-map(98pt, 59pt)),
  ),
  note: [GeoTIFF でない画像は、これまでどおり書きません。QGIS 4.2 で書き出しと読み戻しの往復を確かめました。],
)

// ---- 現在位置の点 ----
#scene(
  [現在位置の点が下を隠さない],
  [青い点を半透明にしました。真下にある点や短い線が見えます。],
  grid(
    columns: (auto, auto, auto), column-gutter: 10pt, align: horizon,
    stack(dir: ttb, spacing: 4pt,
      caption[これまで],
      box(width: 88pt, height: 64pt, clip: true, radius: 4pt, {
        place(rect(width: 88pt, height: 64pt, fill: map-bg))
        place(dx: 24pt, dy: 38pt, line(length: 40pt, angle: -20deg, stroke: 2pt + map-road))
        place(dx: 41pt, dy: 26pt, pt-mark())
        place(dx: 34pt, dy: 22pt, loc-dot(r: 10pt))
      }),
    ),
    arrow-r(w: 18pt),
    stack(dir: ttb, spacing: 4pt,
      caption(fill: accent)[これから],
      box(width: 88pt, height: 64pt, clip: true, radius: 4pt, {
        place(rect(width: 88pt, height: 64pt, fill: map-bg))
        place(dx: 24pt, dy: 38pt, line(length: 40pt, angle: -20deg, stroke: 2pt + map-road))
        place(dx: 41pt, dy: 26pt, pt-mark())
        place(dx: 34pt, dy: 22pt, loc-dot(r: 10pt, alpha: 40%))
      }),
    ),
  ),
)

// ---- 細かな変更 ----
#fixes(
  "使い勝手",
  [「選択されたフォルダ」のタップで、そのまま地図へ戻る],
  [Drive フォルダ追加の画面も、英語表示に対応],
  [標高タイルの読み込みを速くした],
)

#fixes(
  "直したこと",
  [View を消したフィーチャが、地図に残ることがあった],
  [QGIS が GeoPackage を「不明な版」と警告した],
)
