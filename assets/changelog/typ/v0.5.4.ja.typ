// 更新履歴（図解）: v0.5.4。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

// 設定画面（スマホの画面 56 × 98）。rows は (項目, 値)。size で字の大きさを変える
#let settings-screen(title, rows, size: 6pt) = box(width: 56pt, height: 98pt, clip: true, fill: white,
  place(top + left, stack(dir: ttb,
    block(width: 56pt, fill: accent-soft, inset: (x: 4pt, y: 4pt),
      text(size: size + 0.5pt, weight: "bold", fill: accent)[#title]),
    ..rows.map(((k, val)) => block(width: 56pt, inset: (x: 4pt, y: size * 0.6), stroke: (bottom: 0.4pt + line-c), {
      text(size: size)[#k]
      if val != none { h(1fr); text(size: size, fill: accent, weight: "bold")[#val] }
    })),
  )))

// 画面の上の「圏外」
#let offline-chip = box(fill: ink.transparentize(25%), radius: 2pt, inset: (x: 2.5pt, y: 1.5pt),
  text(size: 5pt, fill: white, weight: "bold")[圏外])

// 権限の案内画面（ステップ・権限名）
#let perm-screen(step, name) = box(width: 50pt, height: 84pt, fill: white, {
  place(dx: 4pt, dy: 5pt, text(size: 5pt, fill: sub)[#step / 3])
  place(dx: 15pt, dy: 15pt, circle(radius: 10pt, fill: accent-soft))
  place(dy: 40pt, box(width: 50pt, align(center, text(size: 6pt, weight: "bold")[#name])))
  place(dx: 6pt, dy: 51pt, rect(width: 38pt, height: 2pt, fill: line-c))
  place(dx: 6pt, dy: 56pt, rect(width: 30pt, height: 2pt, fill: line-c))
  place(dx: 6pt, dy: 66pt, box(width: 38pt, height: 10pt, radius: 3pt, fill: accent,
    align(center + horizon, text(size: 5pt, weight: "bold", fill: white)[許可する])))
})

// ---- 頭: 英語 ----
#hero(
  "v0.5.4 — 2026/04/10",
  [英語でも使えるように],
  [すべての画面が日本語と英語に対応しました。設定からワンタップで切り替えられます。],
  grid(
    columns: (auto, auto, auto), column-gutter: 12pt, align: horizon,
    phone(label: "日本語", settings-screen([設定], (([言語], [日本語]), ([一般], none), ([権限], none)))),
    arrow-lr(w: 30pt),
    phone(label: "English", settings-screen([Settings], (([Language], [English]), ([General], none), ([Permissions], none)))),
  ),
)

// ---- 圏外の地図 ----
#scene(
  [圏外でも地図がすぐ出る],
  [保存した背景地図（MBTiles）を地図エンジンが直接読むようになり、圏外での表示が安定しました。Android でバックグラウンドから戻ると地図が真っ白になる問題も直しました。],
  grid(
    columns: (auto, auto, auto), column-gutter: 12pt, align: horizon,
    stack(dir: ttb, spacing: 4pt,
      caption[これまで],
      phone(box(width: 56pt, height: 98pt, fill: white, place(dx: 3pt, dy: 3pt, offline-chip))),
      badge(ok: false)[戻ると真っ白],
    ),
    arrow-r(w: 20pt),
    stack(dir: ttb, spacing: 4pt,
      caption(fill: accent)[これから],
      phone(box(width: 56pt, height: 98pt, { place(mini-map(56pt, 98pt)); place(dx: 3pt, dy: 3pt, offline-chip) })),
      badge[圏外でも表示],
    ),
  ),
)

// ---- UI の大きさ ----
#let size-slider(w) = box(width: w, height: 24pt, {
  let labels = ("XS", "S", "M−", "M", "M+", "L", "XL")
  let step = (w - 12pt) / 6
  place(dx: 6pt, dy: 5pt, line(length: w - 12pt, stroke: 2pt + line-c))
  for (i, l) in labels.enumerate() {
    place(dx: 6pt + step * i - 1.5pt, dy: 3.5pt, circle(radius: 1.5pt, fill: sub.lighten(20%)))
    place(dx: 6pt + step * i - 10pt, dy: 12pt, box(width: 20pt, align(center, text(size: 6.5pt, fill: if i == 3 { accent } else { sub }, weight: if i == 3 { "bold" } else { "regular" })[#l])))
  }
  place(dx: 6pt + step * 3 - 5pt, dy: 0pt, circle(radius: 5pt, fill: accent))
})

#let size-rows = (([言語], none), ([UI サイズ], none), ([権限], none))

#scene(
  [文字とボタンの大きさを 7 段階で],
  [設定 → 一般 のスライダーで選べます。動かすとすぐ変わり、再起動は要りません。],
  stack(dir: ttb, spacing: 12pt,
    size-slider(200pt),
    grid(
      columns: (auto, auto), column-gutter: 30pt, align: bottom,
      phone(label: "XS", settings-screen([設定], size-rows, size: 4.5pt)),
      phone(label: "XL", settings-screen([設定], size-rows, size: 8.5pt)),
    ),
  ),
)

// ---- 初回の権限 ----
#scene(
  [はじめに権限を 1 つずつ案内],
  [初回起動で、ストレージ・位置情報・Bluetooth の権限を順番に、何に使うかを添えて案内します。あとから設定でも確認・やり直しができます。],
  grid(
    columns: (auto, auto, auto, auto, auto), column-gutter: 4pt, align: horizon,
    phone(w: 56pt, h: 98pt, perm-screen(1, [ストレージ])),
    arrow-r(w: 14pt),
    phone(w: 56pt, h: 98pt, perm-screen(2, [位置情報])),
    arrow-r(w: 14pt),
    phone(w: 56pt, h: 98pt, perm-screen(3, [Bluetooth])),
  ),
)

// ---- 細かな変更 ----
#fixes(
  "ほかにも",
  [ホームから使い方ガイドを読める（本文は AI 生成）],
  [更新のお知らせバナーと、アプリ内の更新履歴],
  [Android のナビゲーションバーを自動で隠す],
)
