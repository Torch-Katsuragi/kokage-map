// 更新履歴（図解）: 次のリリース。tool/changelog/build.py が切れごとの SVG に書き出す
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
  if located {
    place(rect(width: 40pt, height: 40pt, stroke: 2pt + okink))
    place(dx: 3pt, dy: 30pt, circle(radius: 4pt, fill: okink))
  } else {
    place(dy: 31pt, box(width: 40pt, height: 9pt, fill: rgb(0, 0, 0, 120), align(center + horizon, text(size: 5.5pt, fill: white)[位置なし])))
  }
})

// ---- 頭 ----
#hero(
  "次のリリース",
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
  [6 つの章から選ぶ],
  [見る・仕組み・記録・写真・GPS・自分のデータ。どの章からでも始められ、終わった章には印が付きます。],
  box(width: 150pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: (y: 6pt), align(left, {
    block(inset: (x: 6pt), below: 4pt, text(size: 9pt, weight: "bold")[チュートリアル])
    chapter-row(1, [地図を見る], done: true)
    chapter-row(2, [データの仕組み], done: true)
    chapter-row(3, [記録する（点・名前・線）])
    chapter-row(4, [写真を取り込む])
    chapter-row(5, [GPS で記録する])
    chapter-row(6, [自分のデータで])
  })),
  note: [はじめて使うときに一度だけ「チュートリアルをやりますか？」と聞きます。あとからはホームの「チュートリアル」と設定から。練習用の地図は始めるたびに作り直します。],
)

// ---- 写真 ----
#scene(
  [位置つきの写真がひと目で分かる],
  [写真をアプリの中で選ぶようになりました。位置情報つきは緑の枠とピン。取り込んでから位置が無かったと気づくことがなくなります。],
  stack(dir: ttb, spacing: 6pt,
    grid(columns: 4, column-gutter: 3pt,
      photo(rgb("#7a9a6b"), true), photo(rgb("#a08a70"), false), photo(rgb("#6b8aa0"), true), photo(rgb("#b0a090"), false)),
    badge[「位置ありだけ」で絞れる],
  ),
)

// ---- 細かな変更 ----
#fixes(
  "ほかにも変わりました",
  [情報パネルのまま形と属性を編集できる（頂点・移動・回転・拡大縮小・延長・間引く・端を切る）],
  [情報パネルの背景に選んだ地物の形を薄く出す],
  [スマホの縦では、地図を開いたときにレイヤ一覧を閉じておく],
)

#fixes(
  "直したこと",
  [名前に空白や引用符を含むレイヤに書き込めなかった],
  [属性テーブルで、行の先頭以外のマスを編集できないことがあった],
  [地図で選んでから属性テーブルを開くと、その行に色が付かなかった],
)
