// 更新履歴（図解）: v0.5.6。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

// 詳細パネルのボタン
#let panel-btn(w, body, c: accent, on: false) = box(width: w, inset: (y: 2.5pt), radius: 3pt,
  fill: if on { c } else { white }, stroke: 0.7pt + c, {
    set par(leading: 0.35em)
    align(center, text(size: 5pt, weight: "bold", fill: if on { white } else { c })[#body])
  })

// 長押しの削除ボタン。p はゲージの進み（0〜1）
#let delete-btn(w, p, label, h: 13pt, size: 6.5pt) = box(width: w, height: h, radius: 3pt, clip: true,
  stroke: 0.8pt + map-red, fill: white, {
    place(rect(width: w * p, height: h, fill: map-red.lighten(55%)))
    place(box(width: w, height: h, align(center + horizon, text(size: size, weight: "bold", fill: map-red)[#label])))
  })

// 地図＋下の詳細パネル（スマホの画面 56 × 98）
#let detail-screen(title, button) = box(width: 56pt, height: 98pt, {
  place(mini-map(56pt, 50pt))
  place(dx: 25pt, dy: 20pt, circle(radius: 3pt, fill: map-red, stroke: 1pt + white))
  place(dy: 46pt, rect(width: 56pt, height: 52pt, fill: white, radius: (top-left: 4pt, top-right: 4pt)))
  place(dx: 4pt, dy: 50pt, text(size: 6pt, weight: "bold")[#title])
  place(dx: 4pt, dy: 61pt, rect(width: 34pt, height: 2pt, fill: line-c))
  place(dx: 4pt, dy: 66pt, rect(width: 26pt, height: 2pt, fill: line-c))
  place(dx: 4pt, dy: 73pt, button)
})

// Google Maps アプリの画面（道と赤いピン）
#let gmaps-screen = box(width: 56pt, height: 98pt, clip: true, {
  place(rect(width: 56pt, height: 98pt, fill: rgb("#f1f3f4")))
  place(curve(stroke: 3pt + white, curve.move((0pt, 70pt)), curve.line((56pt, 40pt))))
  place(curve(stroke: 3pt + white, curve.move((20pt, 0pt)), curve.line((34pt, 98pt))))
  place(curve(stroke: 2pt + rgb("#fdd663"), curve.move((0pt, 30pt)), curve.cubic((20pt, 34pt), (40pt, 20pt), (56pt, 26pt))))
  place(dx: 4pt, dy: 4pt, box(width: 48pt, height: 10pt, radius: 5pt, fill: white, stroke: 0.4pt + line-c,
    align(horizon, pad(left: 4pt, text(size: 5pt, fill: sub)[Google Maps]))))
  // ピン
  place(dx: 23pt, dy: 42pt, box(width: 10pt, height: 14pt, {
    place(circle(radius: 5pt, fill: rgb("#ea4335")))
    place(dy: 6pt, polygon(fill: rgb("#ea4335"), (1pt, 0pt), (9pt, 0pt), (5pt, 8pt)))
    place(dx: 3pt, dy: 3pt, circle(radius: 2pt, fill: rgb("#a50e0e")))
  }))
})

// ---- 頭 ----
#hero(
  "v0.5.6 — 2026/04/12",
  [ポイントの場所へ、\ Google Maps で],
  [ポイントの詳細パネルに「Google Maps で開く」ボタンが付きました。Android では Google Maps アプリが直接開きます。PC やアプリが無いときはブラウザで開きます。],
  grid(
    columns: (auto, auto, auto), column-gutter: 14pt, align: horizon,
    phone(label: "詳細パネルで押す", detail-screen([ポイント 12], panel-btn(48pt, [Google Maps \ で開く], on: true))),
    arrow-r(w: 26pt),
    phone(label: "Google Maps が開く", gmaps-screen),
  ),
)

// ---- 長押しで削除 ----
#scene(
  [削除は、1 秒の長押しで],
  [すべての地物と写真の詳細パネルに「削除」ボタンが付きました。押し間違えないよう、1 秒押し続けると消えます。押している間は赤いゲージが伸びます。],
  grid(
    columns: (auto, auto), column-gutter: 18pt, align: horizon,
    stack(dir: ttb, spacing: 4pt,
      bubble[長押し],
      phone(detail-screen([ポイント 12], delete-btn(48pt, 0.5, [削除], h: 11pt, size: 5.5pt))),
    ),
    grid(
      columns: (auto, auto), column-gutter: 6pt, row-gutter: 9pt, align: (right + horizon, left + horizon),
      caption[押しはじめ], delete-btn(80pt, 0, [削除]),
      caption[0.5 秒], delete-btn(80pt, 0.5, [削除]),
      caption(fill: map-red)[1 秒], stack(dir: ltr, spacing: 4pt, delete-btn(80pt, 1, [削除]), caption(fill: map-red)[消える]),
    ),
  ),
)

// ---- 細かな変更 ----
#fixes(
  "ほかにも",
  [クラスタの大きさが、ポイントの大きさ設定に連動],
  [ギャラリーの写真の位置・撮影日時が抜けていた],
  [写真マーカーやクラスタの数字が出ていなかった],
  [圏外で地図上の文字が消えることがあった],
  [GPS 座標が NaN の写真を読むと落ちていた],
  [地図エンジン MapLibre を v0.3.5 に更新],
)
