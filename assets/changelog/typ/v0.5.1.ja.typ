// 更新履歴（図解）: v0.5.1。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

// 地図に重ねた画像（スキャンした図面など）。handles で変形ハンドルを出す
#let overlay-img(w, h, handles: true) = box(width: w, height: h, {
  place(rect(width: w, height: h, fill: rgb("#fffaf0").transparentize(10%), stroke: 0.8pt + if handles { accent } else { sub }))
  for (i, y) in (0.3, 0.55, 0.8).enumerate() {
    place(curve(stroke: 0.6pt + warm.lighten(30%),
      curve.move((w * 0.08, h * y)), curve.cubic((w * 0.35, h * (y - 0.2)), (w * 0.6, h * (y + 0.15)), (w * 0.92, h * (y - 0.1)))))
  }
  if handles {
    let s = 4pt
    for (x, y) in ((0, 0), (1, 0), (0, 1), (1, 1), (0.5, 0), (0.5, 1), (0, 0.5), (1, 0.5)) {
      place(dx: w * x - s / 2, dy: h * y - s / 2, rect(width: s, height: s, fill: white, stroke: 0.8pt + accent))
    }
    place(dx: w / 2, dy: -9pt, line(angle: 90deg, length: 7pt, stroke: 0.8pt + accent))
    place(dx: w / 2 - 2.5pt, dy: -12pt, circle(radius: 2.5pt, fill: white, stroke: 0.8pt + accent))
  }
})

// ---- 頭: 画像を指で変形 ----
#hero(
  "v0.5.1 — 2026/04/02",
  [地図の上の画像を指で自由に変形],
  [地図に重ねた画像に、Photoshop 風の変形ハンドルが付きました。ドラッグで移動・拡縮・回転でき、結果はすぐ地図に出ます。],
  grid(
    columns: (auto, auto, auto), column-gutter: 10pt, align: horizon,
    phone(w: 66pt, h: 118pt, label: "重ねただけ", box(width: 60pt, height: 104pt, {
      place(mini-map(60pt, 104pt))
      place(dx: 16pt, dy: 30pt, overlay-img(26pt, 20pt, handles: false))
    })),
    stack(dir: ttb, spacing: 5pt, bubble[ハンドルをドラッグ], arrow-r(w: 26pt)),
    phone(w: 66pt, h: 118pt, label: "移動・拡縮・回転", box(width: 60pt, height: 104pt, {
      place(mini-map(60pt, 104pt))
      place(dx: 9pt, dy: 30pt, rotate(-14deg, reflow: false, overlay-img(40pt, 32pt)))
    })),
  ),
)

#fixes(
  "データの検索・編集",
  [条件式（#box[`"面積" > 100`] など）でフィーチャを絞り込める],
  [既存のフィーチャを複製して、新しく作れる],
  [サブテーブルにタイムスタンプの列を表示],
  [選択のハイライトを切り替えるときのチラつきを解消],
  [小さい画像でも、変形ハンドルを掴みやすくした],
)

#fixes(
  "お知らせ",
  [Google Play の内部テストで公開],
  [Windows 版は一時凍結（maplibre の対応待ち）],
)
