// 更新履歴（図解）: v0.4.0。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

// 属性テーブル。rows は (値, 残るか)
#let attr-table(w: 150pt, field, expr, rows) = box(width: w, fill: white, stroke: 0.6pt + line-c, radius: 4pt, clip: true, {
  block(width: 100%, fill: rgb("#f1eff4"), inset: 4pt, below: 0pt,
    box(width: 100%, fill: white, stroke: 0.8pt + accent, radius: 3pt, inset: (x: 4pt, y: 3pt), align(left, text(size: 7.5pt)[#expr])))
  block(width: 100%, inset: (x: 6pt, y: 3pt), above: 0pt, below: 0pt, stroke: (bottom: 0.6pt + line-c),
    text(size: 7pt, weight: "bold", fill: sub)[ID #h(1fr) #field])
  for (i, (v, keep)) in rows.enumerate() {
    block(width: 100%, inset: (x: 6pt, y: 3pt), above: 0pt, below: 0pt,
      fill: if keep { white } else { rgb("#f6f5f8") },
      text(size: 7.5pt, fill: if keep { ink } else { sub.lighten(40%) })[#(i + 1) #h(1fr) #v])
  }
})

// 同期のボタン（丸に雲）
#let sync-icon(r: 6pt) = box(width: r * 2, height: r * 2, baseline: 25%, {
  place(circle(radius: r, fill: accent))
  place(dx: r * 0.3, dy: r * 0.62, cloud(w: r * 1.4))
})

// ---- 頭: Drive ----
#hero(
  "v0.4.0 — 2026/03/18",
  [Google Drive でデータを共有・バックアップ],
  [Google でサインインすると、フォルダごと Drive にクローンして、手動で同期（Push/Pull）できます。],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    phone(w: 62pt, h: 112pt, label: "フォルダ単位で", mini-map(56pt, 98pt)),
    stack(dir: ttb, spacing: 4pt,
      caption(fill: accent)[Push],
      arrow-lr(w: 40pt),
      caption(fill: accent)[Pull],
    ),
    stack(dir: ttb, spacing: 4pt, cloud(w: 78pt, label: "Drive"), caption[共有・バックアップ]),
  ),
)

// ---- タイトルバー ----
#scene(
  [同期はタイトルバーからワンタップ],
  [同期の操作をタイトルバーにまとめました。同期の状態はアイコンで分かり、アプリが自動でも確かめます。],
  grid(
    columns: (auto, auto), column-gutter: 12pt, align: horizon,
    phone(w: 62pt, h: 112pt, box(width: 56pt, height: 98pt, {
      place(mini-map(56pt, 98pt))
      place(rect(width: 56pt, height: 14pt, fill: white))
      place(dx: 4pt, dy: 3.5pt, text(size: 5.5pt, weight: "bold")[林小班])
      place(dx: 40pt, dy: 1.5pt, sync-icon(r: 5.5pt))
    })),
    stack(dir: ttb, spacing: 6pt,
      bubble[ここを押すと同期],
      block(width: 120pt, fill: white, stroke: 0.6pt + line-c, radius: 5pt, inset: 6pt, align(left, {
        folder-icon(warm); h(3pt); text(size: 8.5pt, weight: "bold")[林小班]; h(1fr); sync-icon(r: 7pt)
        v(4pt)
        text(size: 7.5pt, fill: sub)[同期の状態をアイコンで表示]
      })),
    ),
  ),
  note: [Drive の情報は `.kmeta.json` に残るので、次に起動したときも状態を引き継ぎます。],
)

// ---- 条件式で絞り込み ----
#scene(
  [条件式ですばやく絞り込む],
  [属性テーブルに QGIS 式のフィルタが付きました。大量のデータでも、条件に合うものだけ残せます。],
  stack(dir: ttb, spacing: 5pt,
    attr-table(w: 160pt, "面積", [`"面積" > 100`], (("85", false), ("240", true), ("130", true), ("60", false))),
    caption[条件に合わない行は外れる],
  ),
  note: [フィーチャの複製も加わりました。同じ構造のデータを一発でコピーできます。],
)

#fixes(
  "読み込みがもっと速く",
  [GeoPackage の読み込みを高速化],
  [地図エンジン maplibre を pub.dev の正式版に移行],
  [大きなファイルを分割して整理],
)
