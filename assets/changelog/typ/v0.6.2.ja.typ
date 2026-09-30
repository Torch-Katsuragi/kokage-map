// 更新履歴（図解）: v0.6.2。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup


// ---- この版だけの部品 ----

/// 地図の上の点（フィーチャ）。sel で選択中の縁取り
#let pt-mark(c: map-red, r: 2.8pt, sel: false) = box(width: 2 * r, height: 2 * r,
  circle(radius: r, fill: c, stroke: if sel { 1.6pt + accent } else { 0.8pt + white }))

/// 現在位置の青い点
#let loc-dot(r: 5pt) = box(width: 2 * r, height: 2 * r, circle(radius: r, fill: accent, stroke: 1.4pt + white))

/// ラベルの部品（カード）。fixed は固定の文字
#let label-card(body, fixed: false) = box(
  fill: if fixed { white } else { accent-soft },
  stroke: if fixed { (paint: sub, thickness: 0.7pt, dash: "dashed") } else { 0.7pt + accent },
  radius: 3pt, inset: (x: 5pt, y: 3pt),
  text(size: 7.5pt, weight: "bold", fill: if fixed { ink } else { accent })[#body])

/// 小班の区画にラベルを載せた地図
#let labeled-map(w, h, labels) = box(width: w, height: h, {
  place(mini-map(w, h))
  let cw = w * 0.42
  let ch = h * 0.36
  for ((x, y), lb) in ((0.05, 0.08), (0.52, 0.08), (0.05, 0.53), (0.52, 0.53)).zip(labels) {
    place(dx: w * x, dy: h * y + ch / 2 - 5pt, box(width: cw, align(center,
      text(size: 7pt, weight: "bold", fill: ink, stroke: 1.6pt + white)[#lb])))
  }
  // 文字の縁取りの上に、もう一度文字を重ねる（縁取りが字を太らせないように）
  for ((x, y), lb) in ((0.05, 0.08), (0.52, 0.08), (0.05, 0.53), (0.52, 0.53)).zip(labels) {
    place(dx: w * x, dy: h * y + ch / 2 - 5pt, box(width: cw, align(center,
      text(size: 7pt, weight: "bold", fill: ink)[#lb])))
  }
})

/// 地図の左上に出る情報カード（右上に ×）
#let info-card(w, title, lines) = block(width: w, fill: white, stroke: 0.6pt + line-c, radius: 3pt,
  inset: (x: 4pt, y: 3pt), {
    grid(columns: (1fr, auto), text(size: 6.5pt, weight: "bold")[#title], text(size: 6.5pt, fill: sub)[×])
    for l in lines {
      v(1.5pt, weak: true)
      text(size: 5.8pt, fill: sub)[#l]
    }
  })

/// 複数選択の切り替えボタン（有効のとき青）。重なった 2 つの四角
#let multi-button(on: true) = box(width: 15pt, height: 15pt, {
  place(rect(width: 15pt, height: 15pt, radius: 4pt, fill: if on { accent } else { white }, stroke: 0.6pt + line-c))
  let c = if on { white } else { sub }
  place(dx: 3.5pt, dy: 3.5pt, rect(width: 6pt, height: 6pt, radius: 1pt, stroke: 1pt + c))
  place(dx: 5.5pt, dy: 5.5pt, rect(width: 6pt, height: 6pt, radius: 1pt, fill: if on { accent } else { white }, stroke: 1pt + c))
})

/// 地図の下に出る確定ボタン
#let action-button(body) = box(fill: map-red, radius: 8pt, inset: (x: 6pt, y: 3pt),
  text(size: 6.5pt, weight: "bold", fill: white)[#body])

// ---- 頭: ラベル ----
#hero(
  "v0.6.2 — 2026/09/07",
  [ラベルを地図に出せる],
  [属性テーブルのラベルボタンで、列を選んで並べ、固定の文字も挟めます。],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    block(width: 104pt, fill: white, stroke: 0.6pt + line-c, radius: 5pt, inset: 6pt, align(left, {
      stack(dir: ttb, spacing: 5pt,
        text(size: 6.5pt, weight: "bold", fill: sub)[列を選ぶ],
        [#check-box() #h(2pt) #text(size: 7.5pt)[林班]],
        [#check-box() #h(2pt) #text(size: 7.5pt)[小班]],
        [#check-box(on: false) #h(2pt) #text(size: 7.5pt, fill: sub)[樹種]],
        pad(top: 5pt, text(size: 6.5pt, weight: "bold", fill: sub)[並べる]),
        [#label-card[林班]#h(2pt)#label-card(fixed: true)[-]#h(2pt)#label-card[小班]],
      )
    })),
    arrow-r(w: 18pt),
    phone(w: 72pt, h: 128pt, label: "点・線・面すべてに", labeled-map(66pt, 114pt, ("12-1", "12-2", "12-3", "12-4"))),
  ),
)

// ---- 複数選択 ----
#scene(
  [レイヤをまたいでまとめて選ぶ],
  [選択ツールで左下のボタンを有効にすると、タップや投げ縄で複数選べます。件数や合計を出し、まとめて削除できます。],
  grid(
    columns: (auto, auto), column-gutter: 10pt, align: horizon,
    phone(w: 96pt, h: 170pt, box(width: 90pt, height: 156pt, {
      place(rect(width: 90pt, height: 156pt, fill: map-bg))
      place(curve(stroke: (paint: map-road, thickness: 2pt, cap: "round"),
        curve.move((-2pt, 150pt)), curve.cubic((30pt, 120pt), (60pt, 150pt), (92pt, 112pt))))
      // 別のレイヤの区画（1 つは選択中）
      place(dx: 62pt, dy: 30pt, rect(width: 24pt, height: 20pt, radius: 1pt, fill: map-comp.lighten(20%), stroke: 0.6pt + map-comp.darken(35%)))
      place(dx: 34pt, dy: 90pt, rect(width: 28pt, height: 20pt, radius: 1pt, fill: map-comp.lighten(20%), stroke: 1.6pt + accent))
      // 投げ縄
      place(curve(stroke: (paint: accent, thickness: 1.2pt, dash: "dashed"), fill: accent.transparentize(88%),
        curve.move((18pt, 72pt)),
        curve.cubic((10pt, 48pt), (70pt, 50pt), (76pt, 76pt)),
        curve.cubic((82pt, 104pt), (62pt, 124pt), (40pt, 120pt)),
        curve.cubic((18pt, 116pt), (24pt, 96pt), (18pt, 72pt)),
      ))
      place(dx: 28pt, dy: 66pt, pt-mark(sel: true))
      place(dx: 56pt, dy: 72pt, pt-mark(sel: true))
      place(dx: 80pt, dy: 94pt, pt-mark())
      place(dx: 4pt, dy: 4pt, info-card(62pt, "3 件を選択", ("点の重心", "線の合計距離", "面の合計面積")))
      place(dx: 5pt, dy: 136pt, multi-button())
      place(dx: 50pt, dy: 138pt, action-button[削除])
    })),
    align(left, stack(dir: ttb, spacing: 6pt,
      bubble[左下を有効に],
      bubble[投げ縄で囲む],
      bubble[件数と合計が出る],
      bubble[まとめて削除],
    )),
  ),
)

// ---- 消しゴム ----
#scene(
  [消しゴムは集めてから消す],
  [触れたものをすぐには消さず、集めてから「N 件を削除」で確定します。],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    stack(dir: ttb, spacing: 4pt,
      bubble[なぞって集める],
      phone(w: 64pt, h: 114pt, box(width: 58pt, height: 100pt, {
        place(rect(width: 58pt, height: 100pt, fill: map-bg))
        place(curve(stroke: (paint: map-red.transparentize(55%), thickness: 7pt, cap: "round"),
          curve.move((8pt, 30pt)), curve.cubic((20pt, 20pt), (34pt, 60pt), (50pt, 50pt))))
        place(dx: 12pt, dy: 24pt, pt-mark(sel: true))
        place(dx: 28pt, dy: 40pt, pt-mark(sel: true))
        place(dx: 44pt, dy: 46pt, pt-mark(sel: true))
        place(dx: 16pt, dy: 70pt, pt-mark())
        place(dx: 38pt, dy: 80pt, pt-mark())
      })),
    ),
    arrow-r(w: 18pt),
    stack(dir: ttb, spacing: 4pt,
      bubble[押して確定],
      phone(w: 64pt, h: 114pt, box(width: 58pt, height: 100pt, {
        place(rect(width: 58pt, height: 100pt, fill: map-bg))
        place(dx: 16pt, dy: 70pt, pt-mark())
        place(dx: 38pt, dy: 80pt, pt-mark())
        place(dx: 6pt, dy: 30pt, action-button[3 件を削除])
      })),
    ),
  ),
  note: [対象は選択中のレイヤだけです。当たり判定は、これまでの 1/3 にしました。],
)

// ---- GPS バー ----
#scene(
  [GPS のバーをやめて地図が広く],
  [現在位置のマーカーは、選択ツールでタップできます。情報カードはほかのフィーチャと同じ場所に出ます。],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    phone(w: 64pt, h: 114pt, label: "これまで", box(width: 58pt, height: 100pt, {
      place(mini-map(58pt, 100pt))
      place(dx: 25pt, dy: 50pt, loc-dot())
      place(dy: 82pt, rect(width: 58pt, height: 18pt, fill: rgb("#f1eff4")))
      place(dx: 4pt, dy: 84pt, text(size: 5.5pt, weight: "bold", fill: sub)[GPS])
      place(dx: 4pt, dy: 92pt, rect(width: 40pt, height: 2.5pt, radius: 1pt, fill: line-c))
    })),
    arrow-r(w: 18pt),
    phone(w: 64pt, h: 114pt, label: [これから], box(width: 58pt, height: 100pt, {
      place(mini-map(58pt, 100pt))
      place(dx: 25pt, dy: 50pt, box(width: 10pt, height: 10pt, circle(radius: 5pt, fill: accent, stroke: 1.6pt + ink)))
      place(dx: 3pt, dy: 3pt, info-card(40pt, "現在位置", ()))
    })),
  ),
)

// ---- 細かな変更 ----
#fixes(
  "使い勝手",
  [ラベルの見た目は 設定 → レイヤスタイル → ラベル],
  [レイヤ一覧ボタンを右端に移した],
  [ツールを切り替えると、名前が地図の中央に一瞬出る],
  [地図上の情報カードは、すべて右上の × で閉じられる],
  [点の「Google Maps で開く」はリンクのコピーに（長押しで開く）],
)

#fixes(
  "直したこと",
  [起動のたびに Google のアカウント選択が出ていた],
  [削除したフィーチャが、たまに地図に残った],
  [取得に失敗した所の背景地図が、ボケたままだった（設定 → 背景地図 → キャッシュクリア で消える）],
  [県外で、保存済みの背景地図が再起動まで出なかった],
  [固有スタイルがあると、地図に何も描かれなかった],
)
