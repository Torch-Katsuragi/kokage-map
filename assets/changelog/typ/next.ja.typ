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

// ---- 頭 ----
#hero(
  "次のリリース",
  [練習用の地図で使い方を試せるように],
  [自分のデータが無くても始められます。練習用の地図を開き、押す場所を枠で示します。押すと次へ進みます。],
  grid(
    columns: (auto, auto, auto, auto, auto), column-gutter: 4pt, align: horizon,
    phone(label: "地図を動かす", screen(map-with-bar(), card: coach-card(50pt, "1 / 8", [地図を動かす]))),
    arrow-r(w: 10pt),
    phone(label: "レイヤを開く", screen(map-with-bar(), ring: (42pt, 0pt, 13pt, 9pt), card: coach-card(50pt, "2 / 8", [レイヤを開く]))),
    arrow-r(w: 10pt),
    phone(label: "点を打つ", screen(map-with-bar(), dot: (28pt, 42pt), card: coach-card(50pt, none, [できました]))),
  ),
)

// ---- いつ始めるか ----
#scene(
  [はじめてのときに一度だけ聞く],
  [初回の設定のあとに「使い方を試しますか？」と出ます。あとからはホームと設定から始められます。],
  stack(dir: ttb, spacing: 8pt,
    box(width: 170pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 9pt, align(left, {
      text(size: 9pt, weight: "bold")[使い方を試しますか？]
      v(3pt)
      text(size: 7.5pt, fill: sub)[練習用の地図で地図の動かし方から点を打つまでを 3 分ほどで試せます。]
      v(5pt)
      align(right, { text(size: 7.5pt, fill: accent)[あとで]; h(10pt); box(fill: accent, radius: 8pt, inset: (x: 7pt, y: 3pt), text(size: 7.5pt, fill: white)[はじめる]) })
    })),
  ),
  note: [練習用の地図は始めるたびに作り直します。置き場所は `Documents/KokageMap/練習` です。],
)

// ---- 細かな変更 ----
#fixes(
  "直したこと",
  [名前に空白や引用符を含むレイヤに書き込めなかった],
)
