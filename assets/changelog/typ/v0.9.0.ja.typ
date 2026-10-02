// 更新履歴（図解）: v0.9.0。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

// 画面（56 × 98pt）の上に、案内先の枠と下の札を重ねる
#let screen(body, card: none, ring: none, dot: none) = box(width: 56pt, height: 98pt, {
  place(body)
  if dot != none { let (x, y) = dot; place(dx: x - 3pt, dy: y - 3pt, circle(radius: 3pt, fill: map-red, stroke: 1pt + white)) }
  if ring != none { let (x, y, w, h) = ring; place(dx: x, dy: y, spot(w, h)) }
  if card != none { place(dx: 3pt, dy: 74pt, card) }
})
// 上の帯。右端はレイヤ一覧のボタン（重なった板）
#let bar = box(width: 56pt, height: 9pt, fill: white, {
  place(dx: 45.5pt, dy: 3.4pt, polygon(fill: sub.lighten(30%), (0pt, 2pt), (3.5pt, 0pt), (7pt, 2pt), (3.5pt, 4pt)))
  place(dx: 45.5pt, dy: 1.4pt, polygon(fill: sub, (0pt, 2pt), (3.5pt, 0pt), (7pt, 2pt), (3.5pt, 4pt)))
})
#let map-with-bar(comps: true) = stack(bar, mini-map(56pt, 89pt, comps: comps))

// 章の一覧の 1 行
#let chapter-row(n, name, done: false) = block(width: 100%, inset: (x: 6pt, y: 3.2pt), above: 0pt, below: 0pt, {
  let c = if done { okink } else { line-c }
  let f = if done { okink } else { white }
  box(width: 8pt, height: 8pt, baseline: 10%, circle(radius: 3.6pt, fill: f, stroke: 0.8pt + c))
  h(4pt)
  text(size: 7.5pt)[#n. #name]
})

// 写真の枠（位置ありは緑の枠とピン、位置なしは下に札）
#let photo(c, located) = box(width: 40pt, height: 40pt, {
  place(rect(width: 40pt, height: 40pt, fill: c))
  if not located {
    place(rect(width: 40pt, height: 40pt, fill: rgb(255, 255, 255, 140)))
    place(dx: 13pt, dy: 13pt, {
      place(circle(radius: 7pt, fill: rgb(0, 0, 0, 90)))
      place(dx: 4.5pt, dy: 3pt, circle(radius: 2.5pt, stroke: 1pt + white))
      place(line(start: (3pt, 11pt), end: (11pt, 3pt), stroke: 1.2pt + white))
    })
  }
})

// 編集中の画面: 左に編集の道具、赤い形と頂点、下にパネル
#let edit-screen = box(width: 56pt, height: 98pt, clip: true, {
  place(mini-map(56pt, 98pt, comps: false))
  place(dx: 0pt, dy: 0pt, rect(width: 9pt, height: 70pt, fill: white))
  for i in range(5) { place(dx: 2pt, dy: 4pt + i * 9pt, rect(width: 5pt, height: 5pt, radius: 1pt, fill: if i == 0 { accent } else { sub.lighten(40%) })) }
  let pts = ((18pt, 14pt), (44pt, 10pt), (50pt, 38pt), (30pt, 50pt), (16pt, 36pt))
  place(polygon(fill: rgb(211, 47, 47, 50), stroke: 1.2pt + map-red, ..pts))
  for p in pts { let (x, y) = p; place(dx: x - 2pt, dy: y - 2pt, circle(radius: 2pt, fill: white, stroke: 1pt + map-red)) }
  place(dy: 70pt, rect(width: 56pt, height: 28pt, fill: white, stroke: (top: 0.6pt + line-c)))
  place(dx: 30pt, dy: 86pt, box(width: 22pt, height: 8pt, radius: 4pt, fill: accent, align(center + horizon, text(size: 4.5pt, fill: white)[保存])))
})

// ---- 頭 ----
#hero(
  "v0.9.0 — 2026/10/02",
  [練習用の地図で使い方を試せるように],
  [自分のデータが無くても始められます。練習用の地図を開き、押す場所を枠で示します。押すと次へ進みます。],
  grid(
    columns: (auto, auto, auto, auto, auto), column-gutter: 4pt, align: horizon,
    phone(label: "地図を動かす", screen(map-with-bar(), card: coach-card(50pt, none, [地図を動かす]))),
    arrow-r(w: 10pt),
    phone(label: "レイヤを開く", screen(map-with-bar(), ring: (42pt, 0pt, 13pt, 9pt), card: coach-card(50pt, none, [レイヤを開く]))),
    arrow-r(w: 10pt),
    phone(label: "点を打つ", screen(map-with-bar(), dot: (28pt, 42pt), card: coach-card(50pt, none, [点を打つ]))),
  ),
)

// ---- 章 ----
#scene(
  [8 つの章から選ぶ],
  [見る・仕組み・見え方・記録・直す・写真・GPS・自分のデータ。どの章からでも始められ、終わった章には印が付きます。章を始めるたびに画面を決まった形に戻します。],
  box(width: 150pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: (y: 6pt), align(left, {
    block(inset: (x: 6pt), below: 4pt, text(size: 9pt, weight: "bold")[チュートリアル])
    chapter-row(1, [地図を見る], done: true)
    chapter-row(2, [データの仕組み], done: true)
    chapter-row(3, [見え方を変える])
    chapter-row(4, [記録する（点・名前・線・面）])
    chapter-row(5, [直す・消す])
    chapter-row(6, [写真を取り込む])
    chapter-row(7, [GPS で記録する])
    chapter-row(8, [自分のデータで])
  })),
  note: [はじめて使うときに一度だけ「チュートリアルをやりますか？」と聞きます。あとからはホームの「チュートリアル」と設定から。練習用の地図は始めるたびに作り直します。],
)

// ---- 写真 ----
#scene(
  [位置つきの写真がひと目で分かる],
  [写真をアプリの中で選ぶようになりました。日付ごとにサムネイルが並び、押すとその 1 枚を取り込みます。長押しで複数。位置情報のない写真は薄く出て印が付くので、取り込んでから気づくことがなくなります。],
  stack(dir: ttb, spacing: 6pt,
    grid(columns: 4, column-gutter: 3pt,
      photo(rgb("#7a9a6b"), true), photo(rgb("#a08a70"), false), photo(rgb("#6b8aa0"), true), photo(rgb("#b0a090"), false)),
    badge[「位置ありだけ」で絞れる],
  ),
)

// ---- 編集 ----
#scene(
  [情報パネルのまま形を直す],
  [「編集」を押すと地図が真上に固定され、左の道具が編集用に替わります。頂点・移動・回転・拡大縮小・延長・間引く・端を切る。元に戻す・やり直すも。属性に切り替えるとパネルが上までせり上がります。],
  phone(label: "編集中", edit-screen),
  note: [編集中は地図の上のボタンを隠します。← と端末の戻るは編集をやめる操作です。これまでの「編集」画面はなくしました。],
)

// ---- 細かな変更 ----
#fixes(
  "ほかにも変わりました",
  [情報パネルの背景に選んだ地物の形を薄く出す],
  [スマホの縦では、地図を開いたときにレイヤ一覧を閉じておく],
)

#fixes(
  "直したこと",
  [名前に空白や引用符を含むレイヤに書き込めなかった],
  [属性テーブルで、行の先頭以外のマスを編集できないことがあった],
  [地図で選んでから属性テーブルを開くと、その行に色が付かなかった],
  [地図を引くと線や面が細く薄れて見失いやすかった],
  [選んだ面の色が尾根などで一部抜けていた],
  [選んだ線の上に選ぶ前の線が重なっていた],
  [点のラベルの下に黒い点が重なっていた],
  [スタイル画面で色を選ぶ画面が開かなかった],
  [面を描いている途中に出る面積が大きく外れていた],
  [属性の入力中にキーボードでパネルがはみ出していた],
)
