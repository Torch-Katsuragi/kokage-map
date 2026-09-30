// 更新履歴（図解）: v0.5.7。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

// 紙の地図のスキャン（等高線 2 本・赤の境界・灰色の塗り）。paper: 紙の地を残すか
#let scan-marks(w, h, paper: true, line-ink: ink, red: map-red, shade: rgb("#9e9e9e")) = box(width: w, height: h, {
  if paper { place(rect(width: w, height: h, fill: rgb("#f7f3e8"))) }
  if shade != none {
    place(dx: w * 0.55, dy: h * 0.12, rect(width: w * 0.35, height: h * 0.3, radius: 2pt, fill: shade))
  }
  let s = (paint: line-ink, thickness: 0.9pt, cap: "round")
  place(curve(stroke: s, curve.move((0pt, h * 0.35)), curve.cubic((w * 0.3, h * 0.15), (w * 0.6, h * 0.7), (w, h * 0.5))))
  place(curve(stroke: s, curve.move((0pt, h * 0.6)), curve.cubic((w * 0.3, h * 0.4), (w * 0.6, h * 0.95), (w, h * 0.75))))
  place(curve(stroke: (paint: red, thickness: 1.2pt, dash: "dashed"),
    curve.move((w * 0.15, h)), curve.line((w * 0.3, h * 0.1)), curve.line((w * 0.8, 0pt))))
})

// 地図の上に、スキャンを重ねた絵
#let overlaid(w, h, ..args) = box(width: w, height: h, clip: true, {
  place(mini-map(w, h))
  place(scan-marks(w, h, ..args))
})

// 地図の上に、傾けた紙を半分透かして重ねた絵（位置・回転が保たれることを見せる）
#let map-with-sheet(w, h) = box(width: w, height: h, clip: true, {
  place(mini-map(w, h))
  place(dx: w * 0.18, dy: h * 0.22, rotate(-12deg, reflow: false,
    box(width: w * 0.64, height: h * 0.5, stroke: 0.8pt + accent,
      scan-marks(w * 0.64, h * 0.5, paper: false))))
})

// ---- 頭 ----
#hero(
  "v0.5.7 — 2026/04/13",
  [重ねた画像は、\ GeoTIFF で保存],
  [オーバーレイ画像が GeoTIFF で保存されるようになりました。位置・大きさ・回転はファイルそのものに入るので、QGIS などの GIS ソフトで開いても同じ場所に重なります。],
  grid(
    columns: (auto, 1fr, auto), align: (center + horizon, center + horizon, center + horizon),
    phone(label: "アプリで重ねる", map-with-sheet(56pt, 98pt)),
    stack(dir: ttb, spacing: 3pt, file-icon(accent, w: 14pt), text(size: 7pt, weight: "bold", fill: accent)[GeoTIFF], arrow-r(w: 26pt)),
    pc(label: "QGIS でも同じ位置", w: 110pt, h: 78pt, map-with-sheet(104pt, 63pt)),
  ),
)

// ---- 変換ダイアログ ----
#let result(label, body) = stack(dir: ttb, spacing: 4pt,
  box(stroke: 0.6pt + line-c, body),
  box(width: 74pt, align(center, caption(label))),
)

#scene(
  [紙の地図を、透かして重ねる],
  [スキャンした紙の地図の白い地を消して、下の地図と重ねて見られます。変換のしかたは 3 つ。変換後のファイル名も決められます。],
  stack(dir: ttb, spacing: 6pt,
    stack(dir: ttb, spacing: 4pt,
      box(stroke: 0.6pt + line-c, overlaid(96pt, 60pt)),
      caption[スキャンしたまま（下の地図が隠れる）],
    ),
    arrow-d(),
    grid(
      columns: (auto, auto, auto), column-gutter: 5pt,
      result([明るさで透かす], overlaid(74pt, 48pt, paper: false,
        line-ink: ink.transparentize(25%), red: map-red.transparentize(35%), shade: rgb("#9e9e9e").transparentize(70%))),
      result([透明か不透明か\ （色はそのまま）], overlaid(74pt, 48pt, paper: false)),
      result([白黒にして白を消す], overlaid(74pt, 48pt, paper: false, red: ink, shade: none)),
    ),
  ),
  note: [不透明度の設定はなくなりました。透け具合は画像のアルファチャンネルで持ちます。],
)

// ---- 細かな変更 ----
#fixes(
  "ほかにも",
  [オーバーレイ画像に専用の詳細パネルが付いた],
  [オーバーレイ画像の移動・拡縮・回転が軽くなった],
  [圏外でオーバーレイ画像が表示されなかった],
)
